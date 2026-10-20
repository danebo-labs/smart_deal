# frozen_string_literal: true

require "digest"
require "json"
require "stringio"

module Rag
  # Replays one captured generate_text user message. The model id is an
  # argument. BEDROCK_MODEL_ID is not the model that is sent. The captured
  # temperature, max_tokens, anthropic version, and system text stay as they
  # were. A missing system stays missing.
  class CapturedGenerationReplay
    ANTHROPIC_VERSION = "bedrock-2023-05-31"
    ATTEMPT_LIMIT = 3
    HAIKU_45 = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    SONNET_45_GLOBAL = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
    SONNET_45_US = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
    CALL_CAP = 48
    COST_CAP_USD = "4"
    VF5_RUN = "vf5-bound-20261020T1728Z"
    VF5_TURNS = [
      { turn: 1, request_id: "354da85f-c20c-4d36-bb88-45a0c059bc2e", body: "bodies/b0005.txt" },
      { turn: 2, request_id: "8205d72d-d67f-4dcb-b9d6-532fb3373768", body: "bodies/b0005.txt" },
      { turn: 3, request_id: "76c894c8-7042-4798-90e2-c7ccd284daaf", body: "bodies/b0006.txt" }
    ].freeze
    # Frozen before any replay answer is read. Meaning is judged against these
    # ten checks. A missing passage is not a failure by itself.
    CRITERIA = [
      "Conserva «no observo una obstrucción» como observación, sin convertirla en comprobación concluyente.",
      "No afirma una causa probable ni ordena causas sin evidencia.",
      "Distingue ejemplo documental de mecanismo confirmado en este equipo.",
      "Mantiene el referente LED de fotocélula; no lo transforma en LED STATUS.",
      "Respeta LED apagado como dato vigente en los turnos 2 y 3.",
      "Conserva sensibilidad pendiente y ausencia de mediciones y reparaciones.",
      "Presenta correctamente las comprobaciones documentales disponibles, con sus condiciones.",
      "Separa reporte del técnico, contenido del manual e incertidumbres.",
      "No indica reemplazos o intervenciones sin respaldo y condiciones.",
      "Usa citas que correspondan a los pasajes de ese prompt."
    ].freeze
    TRANSIENT = %w[
      ServiceUnavailableException
      ThrottlingException
      TooManyRequestsException
      InternalServerException
      ModelTimeoutException
      ModelNotReadyException
      NetworkingError
      RequestTimeout
      TimeoutError
    ].freeze
    CONFIGURATION = %w[
      AccessDeniedException
      ResourceNotFoundException
      ValidationException
      UnrecognizedClientException
      InvalidSignatureException
    ].freeze
    MODEL_RESOLUTION = %w[ResourceNotFoundException ValidationException AccessDeniedException].freeze

    Prepared = Data.define(
      :turn, :request_id, :prompt, :prompt_sha256, :system, :system_sha256,
      :temperature, :max_tokens, :anthropic_version, :messages,
      :captured_model_id, :correlation_id, :body_json, :body_sha256
    )

    Sample = Data.define(
      :status, :model_id, :turn, :attempts, :text, :error_class, :error_message,
      :input_tokens, :output_tokens, :latency_ms, :cost_usd, :body_sha256,
      :prompt_sha256, :output_dir
    )

    class Refusal < StandardError; end

    def self.prepare(capture_dir:, body_path:, turn: nil, request_id: nil)
      new(capture_dir:, body_path:, turn:, request_id:).prepare
    end

    def self.invoke_body_json(prompt:, max_tokens:, temperature:, system: nil, anthropic_version: ANTHROPIC_VERSION)
      body = {
        anthropic_version: anthropic_version,
        max_tokens: max_tokens,
        temperature: temperature,
        messages: [ { role: "user", content: prompt } ]
      }
      body[:system] = system if system.present?
      body.to_json
    end

    def self.error_kind(class_name)
      name = class_name.to_s.split("::").last
      return "transient" if TRANSIENT.include?(name)
      return "configuration" if CONFIGURATION.include?(name)

      "other"
    end

    def self.model_resolution?(class_name)
      MODEL_RESOLUTION.include?(class_name.to_s.split("::").last)
    end

    # One generation, with up to ATTEMPT_LIMIT physical tries for a transient
    # error. Configuration errors are not retried. Each try that enters the
    # client is reserved on spend first.
    def self.run_sample(prepared:, model_id:, client:, spend:, output_dir:, run_id:, correlation_prefix: "vf5-benchmark", attempt_limit: ATTEMPT_LIMIT, backoff_seconds: [])
      runner = allocate
      runner.send(
        :initialize_runner,
        prepared:, model_id:, client:, spend:, output_dir:, run_id:,
        correlation_prefix:, attempt_limit:, backoff_seconds:
      )
      runner.send(:run_sample)
    end

    # models: [{ key:, ids: [preferred, fallback] }]. A configuration error
    # may use the next id once. It does not retry that same id. A budget stop
    # ends the run and keeps the samples already stored.
    def self.execute_benchmark(turns:, models:, client:, spend:, output_root:, run_id:)
      results = []
      stop = nil
      models.each do |spec|
        ids = Array(spec.fetch(:ids)).dup
        model_id = ids.shift
        key = spec.fetch(:key)
        turns.each do |prepared|
          sample = nil
          loop do
            directory = Pathname(output_root).join(key, "t#{prepared.turn}")
            sample = run_sample(
              prepared: prepared,
              model_id: model_id,
              client: client,
              spend: spend,
              output_dir: directory,
              run_id: run_id
            )
            results << { "key" => key, "model_id" => model_id, "sample" => sample }
            break if sample.status == "returned"
            break unless model_resolution?(sample.error_class) && ids.any?

            model_id = ids.shift
          end
          next if sample.status == "returned"

          stop = "#{key} t#{prepared.turn} #{sample.error_class}"
          break
        end
        break if stop
      end
      { "results" => results, "stop" => stop, "spend" => spend.snapshot }
    rescue AssignmentSpend::Stop, LocalPassLedger::Stop => error
      { "results" => results, "stop" => error.message, "spend" => spend.snapshot }
    end

    def initialize(capture_dir:, body_path:, turn: nil, request_id: nil)
      @capture_dir = Pathname(capture_dir)
      @body_path = body_path
      @turn = turn
      @request_id = request_id
    end

    def prepare
      capture = JSON.parse(@capture_dir.join("capture.json").read)
      event = prepared_event(capture)
      prompt = read_prompt(event)
      system = read_system(event)
      parameters = parameters_from(event)
      body_json = self.class.invoke_body_json(
        prompt: prompt,
        max_tokens: parameters.fetch(:max_tokens),
        temperature: parameters.fetch(:temperature),
        system: system,
        anthropic_version: parameters.fetch(:anthropic_version)
      )
      Prepared.new(
        turn: @turn,
        request_id: @request_id,
        prompt: prompt,
        prompt_sha256: Digest::SHA256.hexdigest(prompt),
        system: system,
        system_sha256: system.nil? ? nil : Digest::SHA256.hexdigest(system),
        temperature: parameters.fetch(:temperature),
        max_tokens: parameters.fetch(:max_tokens),
        anthropic_version: parameters.fetch(:anthropic_version),
        messages: parameters.fetch(:messages),
        captured_model_id: event.fetch("model_id"),
        correlation_id: event["correlation_id"],
        body_json: body_json,
        body_sha256: Digest::SHA256.hexdigest(body_json)
      )
    end

    private

    def initialize_runner(prepared:, model_id:, client:, spend:, output_dir:, run_id:, correlation_prefix: "vf5-benchmark", attempt_limit: self.class::ATTEMPT_LIMIT, backoff_seconds: [])
      @prepared = prepared
      @model_id = model_id
      @client = client
      @spend = spend
      @output_dir = Pathname(output_dir)
      @run_id = run_id
      @correlation_prefix = correlation_prefix
      @attempt_limit = attempt_limit
      @backoff_seconds = Array(backoff_seconds)
    end

    def run_sample
      attempts = []
      text = nil
      error_class = nil
      error_message = nil
      usage = {}
      latency_ms = nil
      @attempt_limit.times do |index|
        sample = one_attempt(index + 1)
        attempts << sample
        text = sample[:text]
        error_class = sample[:error_class]
        error_message = sample[:error_message]
        usage = sample[:usage] || {}
        latency_ms = sample[:latency_ms]
        break if sample[:status] == "returned"
        break unless self.class.error_kind(error_class) == "transient"

        wait = @backoff_seconds[index]
        sleep(wait) if wait.respond_to?(:positive?) && wait.positive?
      end
      returned = attempts.last
      Sample.new(
        status: returned[:status],
        model_id: @model_id,
        turn: @prepared.turn,
        attempts: attempts.size,
        text: text,
        error_class: error_class,
        error_message: error_message,
        input_tokens: usage["input_tokens"],
        output_tokens: usage["output_tokens"],
        latency_ms: latency_ms,
        cost_usd: returned[:cost_usd],
        body_sha256: @prepared.body_sha256,
        prompt_sha256: @prepared.prompt_sha256,
        output_dir: @output_dir.to_s
      )
    end

    def one_attempt(attempt)
      ceiling = LocalPassLedger.price(@model_id, @prepared.prompt.to_s.bytesize + @prepared.system.to_s.bytesize, @prepared.max_tokens)
      ticket = @spend.reserve!(ceiling_usd: ceiling, model_id: @model_id, turn: @prepared.turn)
      directory = @output_dir.join(format("attempt-%d", attempt))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      events = []
      text = nil
      raised = nil
      ValidationCapture.capture do |bucket|
        ValidationCapture.bind("run_id" => @run_id)
        ValidationCapture.correlation = correlation_for(attempt)
        ValidationCapture.attempt = attempt
        text = @client.generate_text(
          @prepared.prompt,
          model_id: @model_id,
          max_tokens: @prepared.max_tokens,
          temperature: @prepared.temperature,
          system: @prepared.system,
          tracking: { attempt: attempt, correlation_id: correlation_for(attempt) }
        )
      rescue LocalPassLedger::Stop => error
        raised = error
      ensure
        events.replace(bucket.dup)
      end
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      export(events, directory)
      sent = events.any? { |event| event["kind"] == "model_call" && event["result"] == "attempt_started" }
      unless sent
        @spend.release!(ticket, error_class: raised&.class&.name)
        raise raised if raised

        raise Refusal, "generate_text did not enter the client"
      end

      result = events.reverse.find { |event| event["kind"] == "generation_result" } || {}
      usage = usage_from(result)
      if result["result"] == "returned" && text.present?
        cost = usage_cost(usage)
        @spend.settle!(ticket, actual_usd: cost, input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"])
        write_answer(directory, text)
        return attempt_row("returned", text, nil, nil, usage, latency_ms, cost)
      end

      error_class = result["error_class"].presence || raised&.class&.name || "blank"
      message = result["error_message"].to_s
      message = message[0, 300]
      # A 503 with no usage is the 2026-10-20 VF5 case: Bedrock billed 0/0.
      # The byte-length ceiling is not that bill. The attempt still counts.
      if usage.empty?
        @spend.settle!(ticket, actual_usd: 0, error_class: error_class)
      else
        @spend.keep!(ticket, error_class: error_class)
      end
      attempt_row("error", nil, error_class, message, usage, latency_ms, nil)
    end

    def attempt_row(status, text, error_class, error_message, usage, latency_ms, cost)
      {
        status: status,
        text: text,
        error_class: error_class,
        error_message: error_message,
        usage: usage,
        latency_ms: latency_ms,
        cost_usd: cost&.to_s("F")
      }
    end

    def usage_from(result)
      input = result["input_tokens"]
      output = result["output_tokens"]
      return {} unless input.is_a?(Numeric) && output.is_a?(Numeric)

      { "input_tokens" => input.to_i, "output_tokens" => output.to_i }
    end

    def usage_cost(usage)
      LocalPassLedger.price(@model_id, usage["input_tokens"], usage["output_tokens"])
    end

    def correlation_for(attempt)
      "#{@correlation_prefix}:t#{@prepared.turn}:a#{attempt}:#{@model_id}"
    end

    def export(events, directory)
      directory.mkpath
      document = ValidationCapture.export_capture(events, directory, run_id: @run_id)
      directory.join("capture.json").write(JSON.generate(document))
      directory.join("ledger.json").write(JSON.generate(LocalPassLedger.snapshot))
    end

    def write_answer(directory, text)
      directory.mkpath
      directory.join("answer.txt").binwrite(text.to_s)
    end

    def prepared_event(capture)
      rows = Array(capture["events"]).select { |event|
        event.is_a?(Hash) && event["kind"] == "generate_text" && event["result"] == "prepared"
      }
      raise Refusal, "generate_text.prepared missing" if rows.empty?
      raise Refusal, "generate_text.prepared duplicated" unless rows.one?

      rows.first
    end

    def parameters_from(event)
      unless event["anthropic_version"] == ANTHROPIC_VERSION
        raise Refusal, "anthropic_version #{event["anthropic_version"]}"
      end
      unless event["messages"] == [ { "role" => "user" } ]
        raise Refusal, "messages"
      end
      temperature = event["temperature"]
      max_tokens = event["max_tokens"]
      raise Refusal, "temperature" unless temperature.is_a?(Numeric)
      raise Refusal, "max_tokens" unless max_tokens.is_a?(Integer)

      {
        temperature: temperature,
        max_tokens: max_tokens,
        anthropic_version: event["anthropic_version"],
        messages: event["messages"]
      }
    end

    def read_prompt(event)
      evidence = event["prompt"]
      raise Refusal, "prompt" unless evidence.is_a?(Hash)
      raise Refusal, "prompt.path" unless evidence["path"] == @body_path
      raise Refusal, "prompt.truncated" if evidence["truncated"] == true || evidence["absent"] == true
      expected = evidence["sha256"]
      raise Refusal, "prompt.sha256" unless expected.is_a?(String) && expected == event["user_sha256"]

      bytes = @capture_dir.join(@body_path).binread
      raise Refusal, "prompt.bytes" unless bytes.bytesize == evidence["bytes"]
      raise Refusal, "prompt.sha256 mismatch" unless Digest::SHA256.hexdigest(bytes) == expected

      bytes.force_encoding(Encoding::UTF_8)
    end

    def read_system(event)
      return nil unless event.key?("system")

      evidence = event["system"]
      if evidence.is_a?(String)
        raise Refusal, "system.sha256" unless Digest::SHA256.hexdigest(evidence) == event["system_sha256"]

        return evidence
      end
      raise Refusal, "system" unless evidence.is_a?(Hash)

      path = @capture_dir.join(evidence.fetch("path"))
      bytes = path.binread
      raise Refusal, "system.sha256 mismatch" unless Digest::SHA256.hexdigest(bytes) == evidence["sha256"]
      raise Refusal, "system.sha256" unless evidence["sha256"] == event["system_sha256"]

      bytes.force_encoding(Encoding::UTF_8)
    end
  end
end
