# frozen_string_literal: true

module Rag
  # Literal generation replay of turn 3 from 20261014T194442Z.
  # Sends the captured system and user bytes and the parameters of that
  # prepared generate_text event. It does not rebuild the prompt, continue
  # the session, or score the answer. A model call needs
  # PHASE3_SUMMARY_GENERATION_AUTHORIZED=1 and AWS_MAX_ATTEMPTS=1.
  # Three samples, one call each. An error is not retried.
  # This does not accept phase 3 and it does not read the closed stage-2 ledger.
  class Phase3SummaryGenerationReplay
    AUTHORIZED_ENV = "PHASE3_SUMMARY_GENERATION_AUTHORIZED"
    ATTEMPT_CAP = 3
    ANTHROPIC_VERSION = "bedrock-2023-05-31"
    DEFAULT_CAPTURE = "tmp/phase3_pinned_turn/runs/20261014T194442Z/turn_3"
    HISTORICAL_RUN_ID = "20261014T194442Z"
    HISTORICAL_CORRELATIONS = %w[phase3:15:t3 phase3:15:t3:query].freeze
    SYSTEM_PATH = "bodies/b0007.txt"
    USER_PATH = "bodies/b0008.txt"
    SHA256_HEX = /\A[0-9a-f]{64}\z/
    RUN_ID_PATTERN = /\A\d{8}T\d{6}Z\z/
    PARAMETER_KEYS = %w[model_id temperature max_tokens anthropic_version messages].freeze

    Loaded = Data.define(
      :model_id, :temperature, :max_tokens, :anthropic_version, :messages,
      :system_bytes, :user_bytes, :system_sha256, :user_sha256, :historical, :capture_sha256
    )

    Outcome = Data.define(:status, :reason, :detail, :request, :samples, :output_dir) do
      def sendable?
        status == "ready"
      end

      def to_h
        {
          "status" => status,
          "reason" => reason,
          "detail" => detail,
          "sent" => status == "recorded",
          "phase3_acceptance" => "not_accepted",
          "attempt_cap" => ATTEMPT_CAP,
          "retries" => false,
          "request" => request,
          "samples" => samples,
          "output_dir" => output_dir&.to_s
        }.compact
      end
    end

    def self.preview(capture_dir:)
      new(capture_dir: capture_dir).preview
    end

    def self.gate(capture_dir:, output_dir:, run_id:)
      new(capture_dir: capture_dir, output_dir: output_dir, run_id: run_id).gate
    end

    def self.run(capture_dir:, output_dir:, run_id:, client:)
      new(capture_dir: capture_dir, output_dir: output_dir, run_id: run_id, client: client).run
    end

    def self.default_capture_dir
      Rails.root.join(DEFAULT_CAPTURE)
    end

    # Read-only load. LabelComparisonVariant reuses this instead of a second parser.
    def self.captured(capture_dir:)
      new(capture_dir: capture_dir).captured
    end

    # Key order matches BedrockClient#generate_text when system is present.
    # The variant serializes with this method and does not call generate_text.
    def self.invoke_body_for(anthropic_version:, max_tokens:, temperature:, content:, system:)
      {
        anthropic_version: anthropic_version,
        max_tokens: max_tokens,
        temperature: temperature,
        messages: [ { role: "user", content: content } ],
        system: system
      }.to_json
    end

    def captured
      load_capture
    end

    def initialize(capture_dir:, output_dir: nil, run_id: nil, client: nil)
      @capture_dir = Pathname(capture_dir)
      @output_dir = output_dir.nil? ? nil : Pathname(output_dir)
      @run_id = run_id.to_s
      @client = client
    end

    def preview
      loaded = load_capture
      return loaded if loaded.is_a?(Outcome)

      outcome("preview", nil, nil, request_document(loaded), nil, nil)
    end

    def gate
      loaded = load_capture
      return loaded if loaded.is_a?(Outcome)

      refusal = execution_refusal
      return refusal if refusal

      outcome("ready", nil, nil, request_document(loaded), nil, @output_dir)
    end

    def run
      gated = gate
      return gated unless gated.sendable?
      return refuse("client_absent") unless @client.respond_to?(:generate_text)

      execute(load_capture)
    end

    private

    def load_capture
      capture_path = @capture_dir.join("capture.json")
      return refuse("absent", [ "capture.json" ]) unless capture_path.file?

      capture = parse_capture(capture_path)
      return capture if capture.is_a?(Outcome)

      prepared = prepared_event(capture)
      return prepared if prepared.is_a?(Outcome)

      system_bytes = read_body(prepared, "system", SYSTEM_PATH, "system_sha256")
      return system_bytes if system_bytes.is_a?(Outcome)

      user_bytes = read_body(prepared, "prompt", USER_PATH, "user_sha256")
      return user_bytes if user_bytes.is_a?(Outcome)

      parameters = read_parameters(prepared)
      return parameters if parameters.is_a?(Outcome)

      Loaded.new(
        model_id: parameters.fetch(:model_id),
        temperature: parameters.fetch(:temperature),
        max_tokens: parameters.fetch(:max_tokens),
        anthropic_version: parameters.fetch(:anthropic_version),
        messages: parameters.fetch(:messages),
        system_bytes: system_bytes,
        user_bytes: user_bytes,
        system_sha256: prepared.fetch("system_sha256"),
        user_sha256: prepared.fetch("user_sha256"),
        historical: historical_reference(capture.fetch("events")),
        capture_sha256: Digest::SHA256.file(capture_path).hexdigest
      )
    end

    def parse_capture(path)
      parsed = JSON.parse(path.read)
      return refuse("capture", { "invalid" => "capture.json" }) unless parsed.is_a?(Hash)
      return refuse("absent", [ "events" ]) unless parsed["events"].is_a?(Array)

      parsed
    rescue JSON::ParserError
      refuse("capture", { "invalid" => "capture.json" })
    end

    def prepared_event(capture)
      rows = capture.fetch("events").select { |event|
        event.is_a?(Hash) && event["kind"] == "generate_text" && event["result"] == "prepared"
      }
      return refuse("absent", [ "generate_text.prepared" ]) if rows.empty?
      return refuse("capture", { "kind" => "generate_text", "result" => "prepared", "count" => rows.size }) unless rows.one?

      rows.first
    end

    def read_parameters(event)
      missing = PARAMETER_KEYS.select { |key| event[key].nil? || (event[key].is_a?(String) && event[key].empty?) }
      invalid = []
      invalid << "model_id" if event["model_id"].present? && !event["model_id"].is_a?(String)
      invalid << "temperature" unless event["temperature"].nil? || event["temperature"].is_a?(Numeric)
      invalid << "max_tokens" unless event["max_tokens"].nil? || event["max_tokens"].is_a?(Integer)
      invalid << "anthropic_version" if event["anthropic_version"].present? && !event["anthropic_version"].is_a?(String)
      invalid << "messages" unless event["messages"].nil? || event["messages"].is_a?(Array)
      return refuse("absent", missing) if missing.any?
      return blocked("parameter", { "invalid" => invalid }) if invalid.any?
      unless event["anthropic_version"] == ANTHROPIC_VERSION
        return blocked("anthropic_version", {
          "captured" => event["anthropic_version"],
          "bedrock" => ANTHROPIC_VERSION
        })
      end
      unless event["messages"] == [ { "role" => "user" } ]
        return blocked("role", { "messages" => event["messages"] })
      end

      {
        model_id: event["model_id"],
        temperature: event["temperature"],
        max_tokens: event["max_tokens"],
        anthropic_version: event["anthropic_version"],
        messages: event["messages"]
      }
    end

    def read_body(event, key, expected_path, sha_key)
      evidence = event[key]
      missing = []
      missing << key unless evidence.is_a?(Hash)
      return refuse("absent", missing) if missing.any?

      missing << "#{key}.path" unless evidence["path"].is_a?(String) && evidence["path"].present?
      missing << "#{key}.field" unless evidence["field"].is_a?(String) && evidence["field"].present?
      missing << "#{key}.sha256" unless evidence["sha256"].is_a?(String) && evidence["sha256"].present?
      missing << "#{key}.bytes" unless evidence["bytes"].is_a?(Integer)
      missing << sha_key unless event[sha_key].is_a?(String) && event[sha_key].present?
      return refuse("absent", missing) if missing.any?

      expected_field = key == "system" ? "system" : "prompt"
      unless evidence["path"] == expected_path && evidence["field"] == expected_field
        return blocked("reference", {
          "field" => key,
          "expected_path" => expected_path,
          "actual_path" => evidence["path"],
          "expected_field" => expected_field,
          "actual_field" => evidence["field"]
        })
      end

      sha_problem = incomplete_sha(key, evidence["sha256"], event[sha_key])
      return sha_problem if sha_problem
      return blocked("sha256", {
        "field" => sha_key,
        "evidence_sha256" => evidence["sha256"],
        "event_sha256" => event[sha_key]
      }) unless evidence["sha256"] == event[sha_key]

      path = body_path(expected_path)
      return refuse("absent", [ expected_path ]) unless path&.file?

      bytes = path.binread
      actual = Digest::SHA256.hexdigest(bytes)
      unless actual == evidence["sha256"] && bytes.bytesize == evidence["bytes"]
        return blocked("sha256", {
          "field" => key,
          "path" => expected_path,
          "expected_sha256" => evidence["sha256"],
          "actual_sha256" => actual,
          "expected_bytes" => evidence["bytes"],
          "actual_bytes" => bytes.bytesize
        })
      end

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return blocked("encoding", { "field" => key }) unless text.valid_encoding?

      text
    end

    def incomplete_sha(key, evidence_sha, event_sha)
      [ [ "#{key}.sha256", evidence_sha ], [ key == "system" ? "system_sha256" : "user_sha256", event_sha ] ].each do |field, value|
        next if value.match?(SHA256_HEX)

        return blocked("sha256", { "field" => field, "sha256" => value })
      end
      nil
    end

    def body_path(relative)
      return if relative.blank? || Pathname(relative).absolute?
      return if relative.split("/").include?("..")

      @capture_dir.join(relative)
    end

    def historical_reference(events)
      rows = events.select { |event| event.is_a?(Hash) && event["kind"] == "generation_result" }
      return { "absent" => [ "generation_result" ] } if rows.empty?
      return { "count" => rows.size, "kind" => "generation_result" } unless rows.one?

      row = rows.first
      answer = row["answer"]
      reference = {
        "result" => row["result"],
        "sequence" => row["sequence"],
        "input_tokens" => row["input_tokens"],
        "output_tokens" => row["output_tokens"],
        "error_class" => row["error_class"]
      }
      return reference.merge("absent" => [ "generation_result.answer" ]) unless answer.is_a?(String)

      reference.merge(
        "answer_bytes" => answer.b.bytesize,
        "answer_sha256" => Digest::SHA256.hexdigest(answer)
      )
    end

    def execution_refusal
      return refuse("authorization_absent") unless ENV[AUTHORIZED_ENV] == "1"
      return refuse("aws_max_attempts") unless ENV["AWS_MAX_ATTEMPTS"] == "1"
      return refuse("budget_armed") if budget_armed?
      return refuse("run_id") unless fresh_run_id?
      return refuse("absent", [ "output_dir" ]) if @output_dir.nil?
      return blocked("evidence_overlaps_source") if evidence_overlaps?
      return blocked("evidence_exists") unless evidence_clear?

      nil
    end

    def fresh_run_id?
      @run_id.match?(RUN_ID_PATTERN) && @run_id != HISTORICAL_RUN_ID && (correlations & HISTORICAL_CORRELATIONS).empty?
    end

    def correlations
      (1..ATTEMPT_CAP).map { |attempt| "phase3:summary:#{@run_id}:#{attempt}" }
    end

    def evidence_clear?
      (1..ATTEMPT_CAP).none? { |attempt| sample_dir(attempt).exist? }
    end

    def evidence_overlaps?
      capture = @capture_dir.expand_path.to_s
      output = @output_dir.expand_path.to_s
      output == capture || output.start_with?("#{capture}/") || capture.start_with?("#{output}/")
    end

    # defined? does not load the phase harness. A disarmed budget is not this cap.
    def budget_armed?
      (defined?(Rag::Phase1ModelBudget) && Rag::Phase1ModelBudget.armed?) ||
        (defined?(Rag::Phase2ModelBudget) && Rag::Phase2ModelBudget.armed?) ||
        (defined?(Rag::Phase3ModelBudget) && Rag::Phase3ModelBudget.armed?)
    end

    def execute(loaded)
      return loaded if loaded.is_a?(Outcome)

      FileUtils.mkdir_p(@output_dir)
      samples = []
      correlations.each_with_index do |correlation, index|
        samples << run_sample(loaded, correlation, index + 1)
      end
      write_json(@output_dir.join("run.json"), {
        "status" => "recorded",
        "phase3_acceptance" => "not_accepted",
        "run_id" => @run_id,
        "attempt_cap" => ATTEMPT_CAP,
        "retries" => false,
        "capture_sha256" => loaded.capture_sha256,
        "historical_generation_result" => loaded.historical,
        "correlations" => correlations,
        "samples" => samples
      })
      outcome("recorded", nil, nil, request_document(loaded), samples, @output_dir)
    end

    def run_sample(loaded, correlation, attempt)
      directory = sample_dir(attempt)
      Dir.mkdir(directory)
      File.binwrite(directory.join("system.txt"), loaded.system_bytes)
      File.binwrite(directory.join("user.txt"), loaded.user_bytes)
      request = request_document(loaded).merge(
        "correlation_id" => correlation,
        "attempt" => attempt,
        "sent" => false
      )
      events = [ sample_event("prepared", attempt, correlation, request.dup) ]
      write_sample(directory, request, events)
      request = request.merge("sent" => true)
      events << sample_event("attempt_started", attempt, correlation, nil)
      write_sample(directory, request, events)
      terminal = invoke_once(loaded, correlation, attempt, directory)
      events << terminal
      write_sample(directory, request, events)
      { "attempt" => attempt, "correlation_id" => correlation, "result" => terminal["result"], "directory" => directory.to_s }
    end

    def invoke_once(loaded, correlation, attempt, directory)
      error = nil
      text = nil
      product = ValidationCapture.capture do
        ValidationCapture.correlation = correlation
        ValidationCapture.attempt = attempt
        begin
          text = @client.generate_text(
            loaded.user_bytes,
            system: loaded.system_bytes,
            model_id: loaded.model_id,
            max_tokens: loaded.max_tokens,
            temperature: loaded.temperature,
            tracking: { correlation_id: correlation, attempt: attempt }
          )
        rescue StandardError => raised
          error = raised
        end
      end
      write_json(directory.join("product_capture.json"), product)
      return error_event(attempt, correlation, error) if error
      return returned_event(attempt, correlation, text, directory, product) if text.is_a?(String)

      error_event(attempt, correlation, nil, product)
    end

    def returned_event(attempt, correlation, text, directory, product)
      File.binwrite(directory.join("response.txt"), text)
      usage = usage_from(product)
      write_json(directory.join("usage.json"), usage)
      {
        "result" => "returned",
        "attempt" => attempt,
        "correlation_id" => correlation,
        "answer_bytes" => text.b.bytesize,
        "answer_sha256" => Digest::SHA256.hexdigest(text),
        "usage" => usage
      }
    end

    def error_event(attempt, correlation, error, product = [])
      recorded = product.find { |event|
        event["kind"] == "generation_result" && event["result"] == "error"
      } || {}
      {
        "result" => "error",
        "attempt" => attempt,
        "correlation_id" => correlation,
        "error_class" => error&.class&.name || recorded["error_class"] || "unavailable",
        "message" => error&.message
      }
    end

    def usage_from(product)
      recorded = product.find { |event| event["kind"] == "generation_result" && event["result"] == "returned" } || {}
      {
        "input_tokens" => recorded.fetch("input_tokens", "unavailable"),
        "output_tokens" => recorded.fetch("output_tokens", "unavailable")
      }
    end

    def sample_event(result, attempt, correlation, request)
      { "result" => result, "attempt" => attempt, "correlation_id" => correlation, "request" => request }.compact
    end

    def write_sample(directory, request, events)
      write_json(directory.join("request.json"), request)
      write_json(directory.join("events.json"), events)
    end

    def sample_dir(attempt)
      @output_dir.join(format("sample_%d", attempt))
    end

    def request_document(loaded)
      {
        "model_id" => loaded.model_id,
        "temperature" => loaded.temperature,
        "max_tokens" => loaded.max_tokens,
        "anthropic_version" => loaded.anthropic_version,
        "messages" => loaded.messages,
        "system_path" => SYSTEM_PATH,
        "system_bytes" => loaded.system_bytes.bytesize,
        "system_sha256" => loaded.system_sha256,
        "user_path" => USER_PATH,
        "user_bytes" => loaded.user_bytes.bytesize,
        "user_sha256" => loaded.user_sha256,
        "capture_sha256" => loaded.capture_sha256,
        "historical_generation_result" => loaded.historical,
        "provenance" => "captured"
      }
    end

    def outcome(status, reason, detail, request, samples, output_dir)
      Outcome.new(status: status, reason: reason, detail: detail, request: request, samples: samples, output_dir: output_dir)
    end

    def refuse(reason, detail = nil)
      outcome("refused", reason, detail, nil, nil, nil)
    end

    def blocked(reason, detail = nil)
      outcome("blocked", reason, detail, nil, nil, nil)
    end

    def write_json(path, payload)
      File.write(path, "#{JSON.pretty_generate(payload)}\n")
    end
  end
end
