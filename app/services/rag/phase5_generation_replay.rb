# frozen_string_literal: true

module Rag
  # Literal replay of the phase 5 generation captured on 2026-10-14.
  # The captured request_body.json is the pretty-printed ModelInvocationLog
  # input.inputBodyJson. That object carries model and stream, which
  # a7efafb BedrockClient#generate_text does not put in the InvokeModel body.
  # Those two keys are removed. The remaining object is serialized with the
  # same Hash#to_json as generate_text. The message, model id, temperature,
  # max_tokens and the absence of system stay. It does not open a session,
  # search, or score the answer.
  # One call per process. The second call exists only after a human reading
  # records that the first answer did not meet the case. An error is not repeated.
  # A model call needs PHASE5_GENERATION_REPLAY_AUTHORIZED=1 and AWS_MAX_ATTEMPTS=1.
  # This does not accept phase 3 or phase 5.
  class Phase5GenerationReplay
    AUTHORIZED_ENV = "PHASE5_GENERATION_REPLAY_AUTHORIZED"
    ATTEMPT_CAP = 2
    ANTHROPIC_VERSION = "bedrock-2023-05-31"
    MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    TEMPERATURE = 0.1
    MAX_TOKENS = 3000
    REQUEST_SHA256 = "2f8e64afef98363ca5590f531d8741ee3f8d240eeecc21679cb475cbb29c9011"
    REQUEST_BYTES = 47_221
    EFFECTIVE_BODY_SHA256 = "9b0d8861a4da67c97fbe7c019238fafa3207bdd5fcaa867932699f5c7678d9c6"
    EFFECTIVE_BODY_BYTES = 47_331
    PROMPT_SHA256 = "8a771ae3aedee0ddda50dec7c347e843e5daee3c95060dbaa2d00ce6dae33b6a"
    PROMPT_BYTES = 46_068
    RAW_ANSWER_SHA256 = "bc9c12b1a6865a3e7024d3ce1b9473a3a57d9e3add9693ba197307ba5a354284"
    RAW_ANSWER_BYTES = 1410
    HISTORICAL_REQUEST_ID = "c1e4bdc5-91a1-423c-a6fa-c274673e383a"
    HISTORICAL_CORRELATION = "query:c80668ea-f7e8-4448-bb2d-ddd842fe7524"
    REFERENCE_INPUT_TOKENS = 15_881
    REFERENCE_OUTPUT_TOKENS = 468
    INPUT_USD_PER_THOUSAND = BigDecimal("0.001")
    OUTPUT_USD_PER_THOUSAND = BigDecimal("0.005")
    READING_FIELDS = %w[identity function dp_category prescribed_check usefulness].freeze
    TERMINAL_RESULTS = %w[returned error].freeze
    DEFAULT_CAPTURE = "tmp/generation_design_review_2026-10-14/case_b_phase5_question"
    DEFAULT_OUTPUT = "tmp/phase5_generation_replay/case_b"
    SHA256_HEX = /\A[0-9a-f]{64}\z/

    RetryView = Data.define(:max_attempts, :retry_limit, :retry_mode)

    Loaded = Data.define(:body, :model_id, :temperature, :max_tokens, :content)

    Outcome = Data.define(:status, :reason, :detail, :request, :samples, :quota, :output_dir) do
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
          "phase5_acceptance" => "not_accepted",
          "historical_failures_retained" => true,
          "determinism" => "not_claimed",
          "question_required" => false,
          "attempt_cap" => ATTEMPT_CAP,
          "retries" => false,
          "request" => request,
          "quota" => quota,
          "samples" => samples,
          "output_dir" => output_dir&.to_s
        }.compact
      end
    end

    def self.preview(capture_dir:, output_dir: nil)
      new(capture_dir: capture_dir, output_dir: output_dir).preview
    end

    def self.gate(capture_dir:, output_dir:)
      new(capture_dir: capture_dir, output_dir: output_dir).gate
    end

    def self.run(capture_dir:, output_dir:, client:)
      new(capture_dir: capture_dir, output_dir: output_dir, client: client).run
    end

    def self.default_capture_dir
      Rails.root.join(DEFAULT_CAPTURE)
    end

    def self.default_output_dir
      Rails.root.join(DEFAULT_OUTPUT)
    end

    # Read-only load. LabelComparisonVariant reuses this instead of a second parser.
    def self.captured(capture_dir:)
      new(capture_dir: capture_dir).captured
    end

    # Same Hash#to_json and key order as invoke_body. The variant calls this
    # after substituting one paragraph; the literal replay passes the captured content.
    def self.invoke_body_for(anthropic_version:, max_tokens:, temperature:, content:)
      {
        anthropic_version: anthropic_version,
        max_tokens: max_tokens,
        temperature: temperature,
        messages: [ { role: "user", content: content } ]
      }.to_json
    end

    def captured
      load_capture
    end

    def self.estimated_usd_one_call
      cost = (BigDecimal(REFERENCE_INPUT_TOKENS) / 1000 * INPUT_USD_PER_THOUSAND) +
        (BigDecimal(REFERENCE_OUTPUT_TOKENS) / 1000 * OUTPUT_USD_PER_THOUSAND)
      format("%.6f", cost)
    end

    def self.estimated_usd_cap
      format("%.6f", BigDecimal(estimated_usd_one_call) * ATTEMPT_CAP)
    end

    def initialize(capture_dir:, output_dir: nil, client: nil)
      @capture_dir = Pathname(capture_dir)
      @output_dir = output_dir.nil? ? nil : Pathname(output_dir)
      @client = client
    end

    def preview
      loaded = load_capture
      return loaded if loaded.is_a?(Outcome)

      outcome("preview", nil, nil, request_document, nil, quota_document)
    end

    def gate
      loaded = load_capture
      return loaded if loaded.is_a?(Outcome)

      refusal = execution_refusal
      return refusal if refusal

      action, reason = dispatch
      document = quota_document
      return outcome(action, reason, @reading_detail, request_document, nil, document) unless action == "send"

      outcome("ready", nil, nil, request_document, nil, document)
    end

    def run
      gated = gate
      return gated unless gated.sendable?

      refusal = retry_refusal
      return refusal if refusal

      execute(load_capture)
    end

    private

    def load_capture
      body = read_hashed("request_body.json", REQUEST_SHA256, REQUEST_BYTES)
      return body if body.is_a?(Outcome)

      parsed = parse_body(body)
      return parsed if parsed.is_a?(Outcome)

      problem = parameter_problem(parsed)
      return problem if problem

      prompt = read_hashed("prompt_single_user.txt", PROMPT_SHA256, PROMPT_BYTES)
      return prompt if prompt.is_a?(Outcome)

      content = parsed.dig("messages", 0, "content")
      unless content.b == prompt.b && Digest::SHA256.hexdigest(content) == PROMPT_SHA256
        return blocked("sha256", {
          "field" => "prompt_single_user.txt",
          "expected_sha256" => PROMPT_SHA256,
          "content_sha256" => Digest::SHA256.hexdigest(content)
        })
      end

      raw = read_hashed("raw_answer.txt", RAW_ANSWER_SHA256, RAW_ANSWER_BYTES)
      return raw if raw.is_a?(Outcome)

      effective = invoke_body(parsed)
      digest = Digest::SHA256.hexdigest(effective)
      unless digest == EFFECTIVE_BODY_SHA256 && effective.bytesize == EFFECTIVE_BODY_BYTES
        return blocked("sha256", {
          "field" => "invoke_body",
          "expected_sha256" => EFFECTIVE_BODY_SHA256,
          "actual_sha256" => digest,
          "expected_bytes" => EFFECTIVE_BODY_BYTES,
          "actual_bytes" => effective.bytesize
        })
      end

      Loaded.new(
        body: effective,
        model_id: parsed.fetch("model"),
        temperature: parsed.fetch("temperature"),
        max_tokens: parsed.fetch("max_tokens"),
        content: parsed.dig("messages", 0, "content")
      )
    end

    def read_hashed(name, expected_sha, expected_bytes)
      path = @capture_dir.join(name)
      return refuse("absent", [ name ]) unless path.file?

      bytes = path.binread
      actual = Digest::SHA256.hexdigest(bytes)
      return bytes if actual == expected_sha && bytes.bytesize == expected_bytes && expected_sha.match?(SHA256_HEX)

      blocked("sha256", {
        "field" => name,
        "expected_sha256" => expected_sha,
        "actual_sha256" => actual,
        "expected_bytes" => expected_bytes,
        "actual_bytes" => bytes.bytesize
      })
    end

    def parse_body(body)
      parsed = JSON.parse(body)
      return blocked("capture", { "invalid" => "request_body.json" }) unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      blocked("capture", { "invalid" => "request_body.json" })
    end

    def parameter_problem(parsed)
      messages = parsed["messages"]
      return blocked("parameter", { "absent" => "messages" }) unless messages.is_a?(Array) && messages.one? && messages.first.is_a?(Hash)
      return blocked("role", { "role" => messages.first["role"] }) unless messages.first["role"] == "user"
      return blocked("parameter", { "message_keys" => messages.first.keys }) unless messages.first.keys == %w[role content]
      return blocked("parameter", { "absent" => "messages.0.content" }) unless messages.first["content"].is_a?(String)
      return blocked("system", { "present" => true }) if parsed.key?("system")
      return blocked("model_id", { "captured" => parsed["model"], "expected" => MODEL_ID }) unless parsed["model"] == MODEL_ID
      return blocked("temperature", { "captured" => parsed["temperature"], "expected" => TEMPERATURE }) unless parsed["temperature"] == TEMPERATURE
      return blocked("max_tokens", { "captured" => parsed["max_tokens"], "expected" => MAX_TOKENS }) unless parsed["max_tokens"] == MAX_TOKENS
      unless parsed["anthropic_version"] == ANTHROPIC_VERSION
        return blocked("anthropic_version", { "captured" => parsed["anthropic_version"], "expected" => ANTHROPIC_VERSION })
      end
      return blocked("stream", { "captured" => parsed["stream"] }) unless parsed["stream"] == false
      unknown = parsed.keys - %w[anthropic_version max_tokens temperature messages model stream]
      return blocked("parameter", { "unknown" => unknown }) if unknown.any?

      nil
    end

    def invoke_body(parsed)
      self.class.invoke_body_for(
        anthropic_version: parsed.fetch("anthropic_version"),
        max_tokens: parsed.fetch("max_tokens"),
        temperature: parsed.fetch("temperature"),
        content: parsed.dig("messages", 0, "content")
      )
    end

    def execution_refusal
      return refuse("authorization_absent") unless ENV[AUTHORIZED_ENV] == "1"
      return refuse("aws_max_attempts") unless ENV["AWS_MAX_ATTEMPTS"] == "1"
      return refuse("budget_armed") if budget_armed?
      return refuse("absent", [ "output_dir" ]) if @output_dir.nil?
      return blocked("evidence_overlaps_source") if evidence_overlaps?

      nil
    end

    def evidence_overlaps?
      capture = @capture_dir.expand_path.to_s
      output = @output_dir.expand_path.to_s
      output == capture || output.start_with?("#{capture}/") || capture.start_with?("#{output}/")
    end

    def budget_armed?
      (defined?(Rag::Phase1ModelBudget) && Rag::Phase1ModelBudget.armed?) ||
        (defined?(Rag::Phase2ModelBudget) && Rag::Phase2ModelBudget.armed?) ||
        (defined?(Rag::Phase3ModelBudget) && Rag::Phase3ModelBudget.armed?)
    end

    def dispatch
      @reading_detail = nil
      return [ "send", nil ] unless sample_dir(1).exist?

      terminal = terminal_event(1)
      return [ "blocked", "sample_incomplete" ] if terminal.nil?
      return [ "blocked", "cap_reached" ] if sample_dir(2).exist?
      return [ "refused", "first_sample_error" ] if terminal["result"] == "error"

      decision = reading_decision
      return [ "send", nil ] if decision == "fail"

      [ "refused", decision ]
    end

    def reading_decision
      path = sample_dir(1).join("reading.json")
      return "reading_absent" unless path.file?

      parsed = JSON.parse(path.read)
      return invalid_reading("unreadable") unless parsed.is_a?(Hash)
      return "first_sample_met" if parsed["meets_case_b"] == true
      return invalid_reading("meets_case_b") unless parsed["meets_case_b"] == false

      missing = READING_FIELDS.reject { |field| parsed[field].is_a?(String) && parsed[field].strip.present? }
      return invalid_reading(missing) if missing.any?

      "fail"
    rescue JSON::ParserError
      invalid_reading("unreadable")
    end

    def invalid_reading(detail)
      @reading_detail = detail
      "reading_invalid"
    end

    def quota_document
      action, reason = @output_dir.nil? ? [ "send", nil ] : dispatch
      recorded = @output_dir.nil? ? 0 : calls_recorded
      would_send = action == "send" ? 1 : 0
      {
        "attempt_cap" => ATTEMPT_CAP,
        "calls_recorded" => recorded,
        "calls_the_next_authorized_process_would_send" => would_send,
        "calls_remaining_in_cap" => ATTEMPT_CAP - recorded,
        "calls_remaining_after_that_process" => ATTEMPT_CAP - recorded - would_send,
        "next_sample" => would_send == 1 ? next_sample_number : nil,
        "dispatch" => would_send == 1 ? "send" : reason,
        "estimated_usd_one_call" => self.class.estimated_usd_one_call,
        "estimated_usd_if_the_next_authorized_process_sends" => would_send == 1 ? self.class.estimated_usd_one_call : "0.000000",
        "estimated_usd_cap_reference" => self.class.estimated_usd_cap,
        "estimate_is_ceiling" => false,
        "reference_input_tokens" => REFERENCE_INPUT_TOKENS,
        "reference_output_tokens" => REFERENCE_OUTPUT_TOKENS,
        "retries" => false
      }
    end

    def next_sample_number
      sample_dir(1).exist? ? 2 : 1
    end

    def calls_recorded
      (1..ATTEMPT_CAP).count { |attempt| terminal_event(attempt) }
    end

    def terminal_event(attempt)
      path = sample_dir(attempt).join("events.json")
      return unless path.file?

      events = JSON.parse(path.read)
      return unless events.is_a?(Array)

      events.reverse.find { |event| event.is_a?(Hash) && TERMINAL_RESULTS.include?(event["result"]) }
    rescue JSON::ParserError
      nil
    end

    def retry_refusal
      return refuse("client_absent") unless @client.respond_to?(:invoke_model) && @client.respond_to?(:retry_view)

      view = @client.retry_view
      return refuse("retry_view_absent") if view.nil?

      @retry_record = {
        "max_attempts" => view.max_attempts,
        "retry_limit" => view.retry_limit,
        "retry_mode" => view.retry_mode.to_s
      }
      return refuse("max_attempts", @retry_record) unless view.max_attempts == 1
      return refuse("retry_limit", @retry_record) unless view.retry_limit == 0

      nil
    end

    def execute(loaded)
      return loaded if loaded.is_a?(Outcome)

      attempt = next_sample_number
      directory = sample_dir(attempt)
      FileUtils.mkdir_p(@output_dir)
      begin
        Dir.mkdir(directory)
      rescue Errno::EEXIST
        return blocked("evidence_exists")
      end

      written = directory.join("request_body.json")
      File.binwrite(written, loaded.body)
      actual = Digest::SHA256.file(written).hexdigest
      unless actual == EFFECTIVE_BODY_SHA256 && File.binread(written).b == loaded.body.b
        FileUtils.remove_entry(directory)
        return blocked("sha256", {
          "field" => "invoke_body",
          "expected_sha256" => EFFECTIVE_BODY_SHA256,
          "actual_sha256" => actual
        })
      end
      write_json(directory.join("body_transform.json"), body_transform)

      correlation = "phase5:replay:b:#{attempt}"
      request = sample_request(correlation, attempt, sent: false)
      events = [ sample_event("prepared", attempt, correlation, request) ]
      write_sample(directory, request, events)
      write_json(directory.join("client_retry.json"), @retry_record)
      request = request.merge("sent" => true)
      events << sample_event("attempt_started", attempt, correlation, nil)
      write_sample(directory, request, events)
      events << invoke_once(loaded, attempt, correlation, directory)
      finish_sample(directory, attempt, events.last, invoked: true, events: events, request: request)
    end

    def finish_sample(directory, attempt, terminal, invoked:, events: nil, request: nil)
      events ||= [ sample_event("prepared", attempt, "phase5:replay:b:#{attempt}", nil), terminal ]
      request ||= sample_request("phase5:replay:b:#{attempt}", attempt, sent: invoked)
      write_sample(directory, request, events)
      write_template(directory) if attempt == 1 && terminal["result"] == "returned"
      samples = (1..attempt).map { |index| sample_summary(index) }
      write_json(@output_dir.join("run.json"), {
        "status" => "recorded",
        "phase3_acceptance" => "not_accepted",
        "phase5_acceptance" => "not_accepted",
        "historical_failures_retained" => true,
        "determinism" => "not_claimed",
        "attempt_cap" => ATTEMPT_CAP,
        "retries" => false,
        "samples" => samples
      })
      outcome("recorded", nil, nil, request_document, samples, quota_document, @output_dir)
    end

    def invoke_once(loaded, attempt, correlation, directory)
      response = @client.invoke_model(model_id: loaded.model_id, body: loaded.body)
      raw = response.body.read
      parsed = JSON.parse(raw)
      text = parsed.is_a?(Hash) ? parsed.dig("content", 0, "text") : nil
      return error_event(attempt, correlation, "unavailable", "response text absent") unless text.is_a?(String)

      File.binwrite(directory.join("response.txt"), text)
      File.binwrite(directory.join("response_body.json"), raw)
      usage = usage_from(parsed)
      write_json(directory.join("usage.json"), usage)
      returned_event(attempt, correlation, text, usage, parsed["stop_reason"])
    rescue StandardError => error
      error_event(attempt, correlation, error.class.name, error.message)
    end

    def usage_from(parsed)
      usage = parsed["usage"].is_a?(Hash) ? parsed["usage"] : {}
      input = usage["input_tokens"] || usage["inputTokens"]
      output = usage["output_tokens"] || usage["outputTokens"]
      {
        "input_tokens" => input.nil? ? "unavailable" : input,
        "output_tokens" => output.nil? ? "unavailable" : output,
        "stop_reason" => parsed["stop_reason"]
      }
    end

    def returned_event(attempt, correlation, text, usage, stop_reason)
      {
        "result" => "returned",
        "attempt" => attempt,
        "correlation_id" => correlation,
        "answer_bytes" => text.b.bytesize,
        "answer_sha256" => Digest::SHA256.hexdigest(text),
        "stop_reason" => stop_reason,
        "usage" => usage
      }
    end

    def error_event(attempt, correlation, error_class, message = nil)
      {
        "result" => "error",
        "attempt" => attempt,
        "correlation_id" => correlation,
        "error_class" => error_class,
        "message" => message
      }
    end

    def sample_request(correlation, attempt, sent:)
      request_document.merge(
        "correlation_id" => correlation,
        "attempt" => attempt,
        "sent" => sent
      )
    end

    def sample_event(result, attempt, correlation, request)
      { "result" => result, "attempt" => attempt, "correlation_id" => correlation, "request" => request }.compact
    end

    def write_sample(directory, request, events)
      write_json(directory.join("request.json"), request)
      write_json(directory.join("events.json"), events)
    end

    def write_template(directory)
      write_json(directory.join("reading.template.json"), {
        "identity" => "",
        "function" => "",
        "dp_category" => "",
        "prescribed_check" => "",
        "usefulness" => "",
        "meets_case_b" => nil,
        "note" => reading_note
      })
    end

    def reading_note
      "Anotar por separado identidad, función, categoría de Dp, comprobación prescrita y utilidad. " \
        "Una pregunta al técnico no es obligatoria si la respuesta ya resuelve la consulta sin inventar. " \
        "La categoría de Dp se evalúa. El arrastre desde Sp es una hipótesis, no una causa demostrada. " \
        "meets_case_b true detiene el replay. false, con los cinco campos escritos, abre la segunda muestra. " \
        "Una muestra que cumple no borra los fallos históricos ni acepta las fases 3 o 5. " \
        "Dos fallos no prueban determinismo."
    end

    def sample_summary(attempt)
      terminal = terminal_event(attempt) || {}
      {
        "attempt" => attempt,
        "correlation_id" => "phase5:replay:b:#{attempt}",
        "result" => terminal["result"],
        "directory" => sample_dir(attempt).to_s
      }
    end

    def sample_dir(attempt)
      @output_dir.join(format("sample_%d", attempt))
    end

    def request_document
      {
        "model_id" => MODEL_ID,
        "temperature" => TEMPERATURE,
        "max_tokens" => MAX_TOKENS,
        "anthropic_version" => ANTHROPIC_VERSION,
        "stream" => false,
        "system" => false,
        "messages" => [ { "role" => "user" } ],
        "log_request_bytes" => REQUEST_BYTES,
        "log_request_sha256" => REQUEST_SHA256,
        "invoke_body_bytes" => EFFECTIVE_BODY_BYTES,
        "invoke_body_sha256" => EFFECTIVE_BODY_SHA256,
        "prompt_bytes" => PROMPT_BYTES,
        "prompt_sha256" => PROMPT_SHA256,
        "raw_answer_bytes" => RAW_ANSWER_BYTES,
        "raw_answer_sha256" => RAW_ANSWER_SHA256,
        "historical_request_id" => HISTORICAL_REQUEST_ID,
        "historical_correlation" => HISTORICAL_CORRELATION,
        "provenance" => "log_input_body_without_model_and_stream",
        "body_includes_model_and_stream" => false,
        "log_only_keys_removed" => %w[model stream]
      }
    end

    def body_transform
      {
        "source" => "pretty-printed ModelInvocationLog input.inputBodyJson",
        "source_sha256" => REQUEST_SHA256,
        "removed_keys" => %w[model stream],
        "kept_keys" => %w[anthropic_version max_tokens temperature messages],
        "model_id_parameter" => MODEL_ID,
        "serialization" => "Hash#to_json with the key order of BedrockClient#generate_text",
        "system" => false
      }
    end

    def outcome(status, reason, detail, request, samples, quota, output_dir = nil)
      Outcome.new(status: status, reason: reason, detail: detail, request: request, samples: samples, quota: quota, output_dir: output_dir)
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
