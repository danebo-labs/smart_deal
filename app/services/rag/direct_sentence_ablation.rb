# frozen_string_literal: true

module Rag
  # One-sentence ablation of the captured phase 5 question (B).
  # Removes "Start with one direct sentence. " from the original user message
  # and leaves the rest, including the historical attribution paragraph.
  # The production delivery directive and the B′ paragraph are not changed.
  # A model call needs DIRECT_SENTENCE_ABLATION_AUTHORIZED=1 and AWS_MAX_ATTEMPTS=1.
  # One call per process, two calls at most. The second exists only after a
  # human reading records that identity passed. An error is not replaced.
  # This does not score the answer and does not accept phase 3 or phase 5.
  class DirectSentenceAblation
    AUTHORIZED_ENV = "DIRECT_SENTENCE_ABLATION_AUTHORIZED"
    ATTEMPT_CAP = 2
    DEFAULT_OUTPUT = "tmp/direct_sentence_ablation"
    HISTORICAL_SENTENCE = "Start with one direct sentence. Do not restate the question."
    CANDIDATE_SENTENCE = "Do not restate the question."
    REMOVED = "Start with one direct sentence. "
    READING_FIELDS = %w[identity function voltage dp_category prescribed_check location_path usefulness].freeze
    TERMINAL_RESULTS = %w[returned error].freeze
    CORRELATIONS = {
      1 => "phase5:replay:b:direct:1",
      2 => "phase5:replay:b:direct:2"
    }.freeze
    HISTORICAL_CORRELATIONS = %w[
      phase5:replay:b:1
      phase5:replay:b:2
      phase5:replay:b:v2:1
      phase5:replay:b:v2:2
      phase3:summary:v2:1
      query:c80668ea-f7e8-4448-bb2d-ddd842fe7524
    ].freeze

    Substitution = Data.define(:text, :occurrences, :problem)

    Prepared = Data.define(
      :model_id, :temperature, :max_tokens, :anthropic_version,
      :prompt, :body, :original_prompt, :original_body
    )

    Outcome = Data.define(
      :status, :reason, :detail, :request, :samples, :quota, :output_dir, :step
    ) do
      def sendable?
        status == "ready"
      end

      def to_h
        {
          "status" => status,
          "reason" => reason,
          "detail" => detail,
          "sent" => status == "recorded",
          "step" => step,
          "adoption" => "not_authorized",
          "production_directive_adopted" => false,
          "b_prime_paragraph_adopted" => false,
          "phase3_acceptance" => "not_accepted",
          "phase5_acceptance" => "not_accepted",
          "phase4_status" => "unchanged",
          "episode" => "not_validated",
          "historical_failures_retained" => true,
          "determinism" => "not_claimed",
          "attempt_cap" => ATTEMPT_CAP,
          "retries" => false,
          "substitution_of_failed_call" => false,
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

    def self.default_output_dir
      Rails.root.join(DEFAULT_OUTPUT)
    end

    def self.substitute(text)
      return Substitution.new(text: nil, occurrences: 0, problem: "not_text") unless text.is_a?(String)
      unless REMOVED + CANDIDATE_SENTENCE == HISTORICAL_SENTENCE
        return Substitution.new(text: nil, occurrences: 0, problem: "sentence_mismatch")
      end

      occurrences = text.scan(HISTORICAL_SENTENCE).size
      prefix_count = text.scan(REMOVED).size
      unless occurrences == 1 && prefix_count == 1
        return Substitution.new(text: nil, occurrences: occurrences, problem: "occurrences")
      end

      candidate = text.sub(HISTORICAL_SENTENCE, CANDIDATE_SENTENCE)
      unless single_removal?(text, candidate, REMOVED) && candidate.scan(HISTORICAL_SENTENCE).empty? &&
             candidate.scan(CANDIDATE_SENTENCE).size == text.scan(CANDIDATE_SENTENCE).size
        return Substitution.new(text: nil, occurrences: occurrences, problem: "other_difference")
      end

      Substitution.new(text: candidate, occurrences: 1, problem: nil)
    end

    # True when candidate is original with exactly one copy of removed deleted.
    def self.single_removal?(original, candidate, removed)
      return false unless original.is_a?(String) && candidate.is_a?(String) && removed.is_a?(String)
      return false unless original.bytesize == candidate.bytesize + removed.bytesize

      index = 0
      limit = candidate.bytesize
      index += 1 while index < limit && original.getbyte(index) == candidate.getbyte(index)
      original.byteslice(index, removed.bytesize) == removed.b &&
        original.byteslice((index + removed.bytesize)..) == candidate.byteslice(index..)
    end

    def self.production_sentence_count
      path = Rails.root.join("app/services/bedrock_rag_service.rb")
      return 0 unless path.file?

      path.read.scan(HISTORICAL_SENTENCE).size
    end

    def self.estimated_usd(input_tokens, output_tokens)
      cost = (BigDecimal(input_tokens) / 1000 * Phase5GenerationReplay::INPUT_USD_PER_THOUSAND) +
        (BigDecimal(output_tokens) / 1000 * Phase5GenerationReplay::OUTPUT_USD_PER_THOUSAND)
      format("%.6f", cost)
    end

    def self.diff_text
      <<~DIFF.strip
        --- prompt_single_user.txt
        +++ prompt_single_user.txt
        @@
        -- Start with one direct sentence. Do not restate the question.
        +- Do not restate the question.
      DIFF
    end

    def initialize(capture_dir:, output_dir: nil, client: nil)
      @capture_dir = Pathname(capture_dir)
      @output_dir = output_dir.nil? ? nil : Pathname(output_dir)
      @client = client
      @reading_detail = nil
    end

    def preview
      prepared = prepare
      return prepared if prepared.is_a?(Outcome)

      outcome("preview", nil, nil, request_document(prepared), nil, quota_document, @output_dir, quota_document["next_step"])
    end

    def gate
      prepared = prepare
      return prepared if prepared.is_a?(Outcome)

      refusal = execution_refusal
      return refusal if refusal

      action, step = dispatch
      document = request_document(prepared)
      quota = quota_document
      unless action == "send"
        status = action == "blocked" ? "blocked" : "refused"
        return outcome(status, step, @reading_detail, document, nil, quota)
      end

      outcome("ready", nil, nil, document, nil, quota, @output_dir, step)
    end

    def run
      gated = gate
      return gated unless gated.sendable?

      refusal = retry_refusal
      return refusal if refusal

      execute(gated.step)
    end

    private

    def prepare
      count = self.class.production_sentence_count
      return blocked("production_directive", { "occurrences" => count }) unless count == 1

      loaded = relay(Phase5GenerationReplay.captured(capture_dir: @capture_dir))
      return loaded if loaded.is_a?(Outcome)

      mismatch = parameter_mismatch(loaded)
      return mismatch if mismatch

      substitution = self.class.substitute(loaded.content)
      return sentence_block(substitution) if substitution.text.nil?

      paragraph = paragraph_problem(loaded.content, substitution.text)
      return paragraph if paragraph

      original_body = loaded.body
      unless digest(original_body) == Phase5GenerationReplay::EFFECTIVE_BODY_SHA256 &&
             original_body.bytesize == Phase5GenerationReplay::EFFECTIVE_BODY_BYTES
        return blocked("sha256", { "field" => "invoke_body", "actual_sha256" => digest(original_body) })
      end

      candidate_body = Phase5GenerationReplay.invoke_body_for(
        anthropic_version: Phase5GenerationReplay::ANTHROPIC_VERSION,
        max_tokens: loaded.max_tokens,
        temperature: loaded.temperature,
        content: substitution.text
      )
      difference = body_difference(original_body, candidate_body, substitution.text)
      return difference if difference

      Prepared.new(
        model_id: loaded.model_id,
        temperature: loaded.temperature,
        max_tokens: loaded.max_tokens,
        anthropic_version: Phase5GenerationReplay::ANTHROPIC_VERSION,
        prompt: substitution.text,
        body: candidate_body,
        original_prompt: loaded.content,
        original_body: original_body
      )
    end

    def parameter_mismatch(loaded)
      expected = {
        "model_id" => Phase5GenerationReplay::MODEL_ID,
        "temperature" => Phase5GenerationReplay::TEMPERATURE,
        "max_tokens" => Phase5GenerationReplay::MAX_TOKENS
      }
      actual = {
        "model_id" => loaded.model_id,
        "temperature" => loaded.temperature,
        "max_tokens" => loaded.max_tokens
      }
      return if expected == actual

      blocked("parameter_mismatch", actual)
    end

    def paragraph_problem(original, candidate)
      historical = LabelComparisonVariant::HISTORICAL_PARAGRAPH
      foreign = LabelComparisonVariant::CANDIDATE_PARAGRAPH
      [ original, candidate ].each do |text|
        return blocked("b_prime_paragraph", { "present" => true }) if text.include?(foreign)
        next if text.scan(historical).size == 1

        return blocked("historical_paragraph", { "occurrences" => text.scan(historical).size })
      end
      nil
    end

    def body_difference(original_body, candidate_body, candidate_prompt)
      unless self.class.single_removal?(original_body, candidate_body, REMOVED) &&
             original_body.scan(HISTORICAL_SENTENCE).size == 1 &&
             candidate_body.scan(HISTORICAL_SENTENCE).empty?
        return blocked("other_difference", { "field" => "invoke_body" })
      end

      original = JSON.parse(original_body)
      candidate = JSON.parse(candidate_body)
      unless original.is_a?(Hash) && candidate.is_a?(Hash)
        return blocked("other_difference", { "field" => "invoke_body" })
      end
      unless original.keys == %w[anthropic_version max_tokens temperature messages] && candidate.keys == original.keys
        return blocked("other_difference", { "keys" => candidate.keys })
      end
      return blocked("system", { "present" => true }) if original.key?("system") || candidate.key?("system")
      return blocked("parameter_mismatch", { "parameters" => candidate.except("messages") }) unless original.except("messages") == candidate.except("messages")

      message = candidate.dig("messages", 0)
      unless message.is_a?(Hash) && message.keys == %w[role content] && message["role"] == "user" &&
             message["content"].b == candidate_prompt.b
        return blocked("other_difference", { "field" => "messages" })
      end

      nil
    rescue JSON::ParserError
      blocked("other_difference", { "field" => "invoke_body" })
    end

    def sentence_block(substitution)
      blocked("sentence", { "occurrences" => substitution.occurrences, "problem" => substitution.problem })
    end

    def relay(loaded)
      return loaded unless loaded.is_a?(Phase5GenerationReplay::Outcome)

      outcome(loaded.status, loaded.reason, loaded.detail, nil, nil, nil)
    end

    def execution_refusal
      return refuse("authorization_absent") unless ENV[AUTHORIZED_ENV] == "1"
      return refuse("aws_max_attempts") unless ENV["AWS_MAX_ATTEMPTS"] == "1"
      return refuse("budget_armed") if budget_armed?
      return refuse("absent", [ "output_dir" ]) if @output_dir.nil?
      return blocked("evidence_overlaps_source") if reserved_output?

      nil
    end

    def reserved_output?
      output = @output_dir.expand_path.to_s
      reserved_roots.any? { |root| overlap?(output, root.expand_path.to_s) }
    end

    def reserved_roots
      [
        @capture_dir,
        Rails.root.join(Phase5GenerationReplay::DEFAULT_OUTPUT),
        Rails.root.join(Phase5GenerationReplay::DEFAULT_CAPTURE),
        Rails.root.join(LabelComparisonVariant::DEFAULT_OUTPUT),
        Rails.root.join(Phase3SummaryGenerationReplay::DEFAULT_CAPTURE),
        Rails.root.join("tmp/phase3_summary_generation"),
        Rails.root.join("test/fixtures/files/field_companion")
      ]
    end

    def overlap?(left, right)
      left == right || left.start_with?("#{right}/") || right.start_with?("#{left}/")
    end

    def budget_armed?
      (defined?(Rag::Phase1ModelBudget) && Rag::Phase1ModelBudget.armed?) ||
        (defined?(Rag::Phase2ModelBudget) && Rag::Phase2ModelBudget.armed?) ||
        (defined?(Rag::Phase3ModelBudget) && Rag::Phase3ModelBudget.armed?)
    end

    def dispatch
      @reading_detail = nil
      return [ "send", 1 ] if @output_dir.nil? || !sample_dir(1).exist?

      first = terminal(1)
      return [ "blocked", "sample_incomplete" ] if first == :incomplete
      return [ "refused", "sample_error" ] if first["result"] == "error"

      decision = reading_decision(1)
      return [ "refused", decision ] unless decision == "pass"
      return [ "send", 2 ] unless sample_dir(2).exist?

      second = terminal(2)
      return [ "blocked", "sample_incomplete" ] if second == :incomplete
      return [ "refused", "sample_error" ] if second["result"] == "error"

      [ "blocked", "cap_reached" ]
    end

    def reading_decision(attempt)
      path = sample_dir(attempt).join("reading.json")
      return "reading_absent" unless path.file?

      parsed = JSON.parse(path.read)
      return invalid_reading("unreadable") unless parsed.is_a?(Hash)

      missing = READING_FIELDS.reject { |field| parsed[field].is_a?(String) && parsed[field].strip.present? }
      return invalid_reading(missing) if missing.any?
      return invalid_reading("identity_passed") unless parsed["identity_passed"].is_a?(TrueClass) || parsed["identity_passed"] == false
      return invalid_reading("partial") unless parsed["partial"].is_a?(TrueClass) || parsed["partial"] == false
      return invalid_reading("partial") if parsed["identity_passed"] == false && parsed["partial"] == true
      return "identity_repeated" if parsed["identity_passed"] == false

      "pass"
    rescue JSON::ParserError
      invalid_reading("unreadable")
    end

    def invalid_reading(detail)
      @reading_detail = detail
      "reading_invalid"
    end

    def quota_document
      action, step = @output_dir.nil? ? [ "send", 1 ] : dispatch
      recorded = @output_dir.nil? ? 0 : calls_recorded
      would_send = action == "send" ? 1 : 0
      {
        "attempt_cap" => ATTEMPT_CAP,
        "calls_recorded" => recorded,
        "calls_the_next_authorized_process_would_send" => would_send,
        "calls_remaining_in_cap" => ATTEMPT_CAP - recorded,
        "next_step" => would_send == 1 ? step : nil,
        "dispatch" => would_send == 1 ? "send" : step,
        "estimated_usd_reference" => Phase5GenerationReplay.estimated_usd_one_call,
        "estimate_is_ceiling" => false,
        "reference_input_tokens" => Phase5GenerationReplay::REFERENCE_INPUT_TOKENS,
        "reference_output_tokens" => Phase5GenerationReplay::REFERENCE_OUTPUT_TOKENS,
        "removed_bytes" => REMOVED.bytesize,
        "retries" => false,
        "adoption" => "not_authorized"
      }
    end

    def calls_recorded
      [ 1, 2 ].count { |attempt| terminal(attempt).is_a?(Hash) }
    end

    def terminal(attempt)
      path = sample_dir(attempt).join("events.json")
      return :incomplete unless path.file?

      events = JSON.parse(path.read)
      return :incomplete unless events.is_a?(Array)

      events.reverse.find { |event| event.is_a?(Hash) && TERMINAL_RESULTS.include?(event["result"]) } || :incomplete
    rescue JSON::ParserError
      :incomplete
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

    def execute(step)
      action, actual = dispatch
      unless action == "send" && actual == step
        return blocked("sequence", { "expected" => step, "actual" => actual })
      end

      prepared = prepare
      return prepared if prepared.is_a?(Outcome)

      directory = sample_dir(step)
      FileUtils.mkdir_p(directory.dirname)
      begin
        Dir.mkdir(directory)
      rescue Errno::EEXIST
        return blocked("evidence_exists")
      end

      written = directory.join("request_body.json")
      File.binwrite(written, prepared.body)
      unless digest(File.binread(written)) == digest(prepared.body)
        FileUtils.remove_entry(directory)
        return blocked("sha256", { "field" => "invoke_body", "step" => step })
      end
      File.binwrite(directory.join("prompt.txt"), prepared.prompt)
      File.write(directory.join("diff.txt"), "#{self.class.diff_text}\n")
      write_json(directory.join("sentence.json"), sentence_record(prepared, step))

      correlation = CORRELATIONS.fetch(step)
      request = sample_request(prepared, step, sent: false)
      events = [ sample_event("prepared", step, correlation, request) ]
      write_sample(directory, request, events)
      write_json(directory.join("client_retry.json"), @retry_record)
      request = request.merge("sent" => true)
      events << sample_event("attempt_started", step, correlation, nil)
      write_sample(directory, request, events)
      events << invoke_once(prepared, step, correlation, directory)
      finish_sample(directory, step, events, request)
    end

    def invoke_once(prepared, step, correlation, directory)
      response = @client.invoke_model(model_id: prepared.model_id, body: prepared.body)
      raw = response.body.read
      parsed = JSON.parse(raw)
      text = parsed.is_a?(Hash) ? parsed.dig("content", 0, "text") : nil
      return error_event(step, correlation, "unavailable", "response text absent") unless text.is_a?(String)

      File.binwrite(directory.join("response.txt"), text)
      File.binwrite(directory.join("response_body.json"), raw)
      usage = usage_from(parsed)
      write_json(directory.join("usage.json"), usage)
      returned_event(step, correlation, text, usage, parsed)
    rescue StandardError => error
      error_event(step, correlation, error.class.name, error.message)
    end

    def finish_sample(directory, step, events, request)
      write_sample(directory, request, events)
      terminal = events.last
      write_template(directory) if terminal["result"] == "returned"
      samples = recorded_samples
      write_json(@output_dir.join("run.json"), run_document(samples, terminal))
      outcome(
        "recorded",
        nil,
        terminal["result"] == "error" ? { "step" => CORRELATIONS.fetch(step), "sequence_stopped" => true } : nil,
        request,
        samples,
        quota_document,
        @output_dir,
        step
      )
    end

    def recorded_samples
      [ 1, 2 ].filter_map { |attempt|
        found = terminal(attempt)
        next unless found.is_a?(Hash)

        {
          "attempt" => attempt,
          "correlation_id" => CORRELATIONS.fetch(attempt),
          "result" => found["result"],
          "directory" => sample_dir(attempt).to_s
        }
      }
    end

    def run_document(samples, terminal)
      {
        "status" => "recorded",
        "adoption" => "not_authorized",
        "production_directive_adopted" => false,
        "b_prime_paragraph_adopted" => false,
        "phase3_acceptance" => "not_accepted",
        "phase5_acceptance" => "not_accepted",
        "phase4_status" => "unchanged",
        "episode" => "not_validated",
        "historical_failures_retained" => true,
        "determinism" => "not_claimed",
        "attempt_cap" => ATTEMPT_CAP,
        "retries" => false,
        "substitution_of_failed_call" => false,
        "sequence_stopped" => terminal["result"] == "error",
        "samples" => samples
      }
    end

    def usage_from(parsed)
      usage = parsed["usage"].is_a?(Hash) ? parsed["usage"] : {}
      input = usage["input_tokens"] || usage["inputTokens"]
      output = usage["output_tokens"] || usage["outputTokens"]
      record = {
        "input_tokens" => input.nil? ? "unavailable" : input,
        "output_tokens" => output.nil? ? "unavailable" : output,
        "cache_read_input_tokens" => usage["cache_read_input_tokens"] || usage["cacheReadInputTokens"] || 0,
        "cache_creation_input_tokens" => usage["cache_creation_input_tokens"] || usage["cacheCreationInputTokens"] || 0,
        "stop_reason" => parsed["stop_reason"],
        "estimate_is_ceiling" => false,
        "estimate_is_s3_reconciliation" => false
      }
      if input.is_a?(Integer) && output.is_a?(Integer)
        record["estimated_usd"] = self.class.estimated_usd(input, output)
      end
      record
    end

    def returned_event(step, correlation, text, usage, parsed)
      {
        "result" => "returned",
        "attempt" => step,
        "correlation_id" => correlation,
        "answer_bytes" => text.b.bytesize,
        "answer_sha256" => digest(text),
        "stop_reason" => parsed["stop_reason"],
        "response_model" => parsed["model"],
        "response_id" => parsed["id"],
        "usage" => usage
      }
    end

    def error_event(step, correlation, error_class, message = nil)
      {
        "result" => "error",
        "attempt" => step,
        "correlation_id" => correlation,
        "error_class" => error_class,
        "message" => message
      }
    end

    def sample_request(prepared, step, sent:)
      request_document(prepared).merge(
        "correlation_id" => CORRELATIONS.fetch(step),
        "attempt" => step,
        "sent" => sent
      )
    end

    def sample_event(result, step, correlation, request)
      {
        "result" => result,
        "attempt" => step,
        "correlation_id" => correlation,
        "request" => request
      }.compact
    end

    def write_sample(directory, request, events)
      write_json(directory.join("request.json"), request)
      write_json(directory.join("events.json"), events)
    end

    def write_template(directory)
      write_json(directory.join("reading.template.json"), {
        "identity" => "",
        "function" => "",
        "voltage" => "",
        "dp_category" => "",
        "prescribed_check" => "",
        "location_path" => "",
        "usefulness" => "",
        "identity_passed" => nil,
        "partial" => nil,
        "note" => reading_note
      })
    end

    def reading_note
      [
        "Anotar por separado identidad, función, voltaje, categoría de Dp, comprobación, ubicación o recorrido, y utilidad. El servicio no lee la respuesta para puntuar.",
        "La identidad se lee en toda la respuesta, no solo en la primera oración. Una negativa que aparece más abajo también falla.",
        "identity_passed true solo si la identidad no repite el defecto. partial true si la identidad pasó y otro criterio falló. Un parcial no autoriza adopción ni cierra fases.",
        "La identidad falla si afirma igualdad, diferencia, intercambiabilidad o probabilidad como hecho del plano, o como inferencia sacada solo de la sección o del nivel.",
        "No falla dejar la relación abierta, ni una conclusión que los pasajes sí resuelven, incluida la evidencia gráfica, atribuida a esa evidencia.",
        "Una inferencia fundada y presentada como inferencia no falla por ser inferencia.",
        "La función y el voltaje fallan si se igualan o contrastan sin evidencia documental suficiente. No falla lo que los pasajes sí respaldan. Nombrar los rieles impresos del recorrido no falla.",
        "Dp falla si Dp3 queda como contacto, NA o NC. «símbolo Dp3» no falla.",
        "La comprobación falla si prescribe revisar porque son o no son lo mismo, o da pasos para puentear o sustituir. Pedir una observación o el síntoma no falla.",
        "Ubicación y recorrido se evalúan por significado. No exige vecinos inmediatos ni enumeración exhaustiva. «Posición 7» sigue como reserva de la fase 4. Perder el orden entre la 4 y la 2 no es un fallo.",
        "En B, falla si pierde Chapa nivel 3 en la Botonera con su recorrido, Com 18vdc, Dp3 y el cruce sin unión con PasCom 24V, o Seguridad Puerta nivel 3 en la Línea de Seguridad, en serie entre Seg In y Seg Out con los demás niveles.",
        "La utilidad falla si solo hay abstención o si falta la respuesta práctica sobre la sustitución. No hacer una pregunta no falla.",
        "identity_passed false detiene la secuencia y partial tiene que ser false. identity_passed true abre la muestra 2 aunque partial sea true. Esta corrida no envía la muestra 2 por sí sola."
      ].join(" ")
    end

    def request_document(prepared)
      {
        "model_id" => prepared.model_id,
        "temperature" => prepared.temperature,
        "max_tokens" => prepared.max_tokens,
        "anthropic_version" => prepared.anthropic_version,
        "stream" => false,
        "system" => false,
        "messages" => [ { "role" => "user" } ],
        "production_directive_adopted" => false,
        "b_prime_paragraph_adopted" => false,
        "sentence_occurrences" => 1,
        "sentence" => sentence_hashes(prepared),
        "original_prompt_sha256" => digest(prepared.original_prompt),
        "original_prompt_bytes" => prepared.original_prompt.bytesize,
        "candidate_prompt_sha256" => digest(prepared.prompt),
        "candidate_prompt_bytes" => prepared.prompt.bytesize,
        "original_invoke_body_sha256" => digest(prepared.original_body),
        "original_invoke_body_bytes" => prepared.original_body.bytesize,
        "candidate_invoke_body_sha256" => digest(prepared.body),
        "candidate_invoke_body_bytes" => prepared.body.bytesize,
        "correlations" => CORRELATIONS.values,
        "historical_correlations_not_reused" => HISTORICAL_CORRELATIONS,
        "directories" => {
          "output" => DEFAULT_OUTPUT,
          "sample_1" => "sample_1",
          "sample_2" => "sample_2"
        }
      }
    end

    def sentence_hashes(prepared)
      {
        "historical" => HISTORICAL_SENTENCE,
        "candidate" => CANDIDATE_SENTENCE,
        "removed" => REMOVED,
        "removed_bytes" => REMOVED.bytesize,
        "historical_prompt_sha256" => digest(prepared.original_prompt),
        "candidate_prompt_sha256" => digest(prepared.prompt)
      }
    end

    def sentence_record(prepared, step)
      {
        "occurrences" => 1,
        "removed" => REMOVED,
        "removed_bytes" => REMOVED.bytesize,
        "from" => HISTORICAL_SENTENCE,
        "to" => CANDIDATE_SENTENCE,
        "line_before" => "- #{HISTORICAL_SENTENCE}",
        "line_after" => "- #{CANDIDATE_SENTENCE}",
        "other_difference" => false,
        "b_prime_paragraph_adopted" => false,
        "original_prompt_sha256" => digest(prepared.original_prompt),
        "candidate_prompt_sha256" => digest(prepared.prompt),
        "original_invoke_body_sha256" => digest(prepared.original_body),
        "candidate_invoke_body_sha256" => digest(prepared.body),
        "correlation_id" => CORRELATIONS.fetch(step)
      }
    end

    def sample_dir(attempt)
      @output_dir.join(format("sample_%d", attempt))
    end

    def digest(text)
      Digest::SHA256.hexdigest(text.b)
    end

    def outcome(status, reason, detail, request, samples, quota, output_dir = nil, step = nil)
      Outcome.new(
        status: status,
        reason: reason,
        detail: detail,
        request: request,
        samples: samples,
        quota: quota,
        output_dir: output_dir,
        step: step
      )
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
