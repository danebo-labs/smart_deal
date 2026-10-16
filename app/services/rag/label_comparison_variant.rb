# frozen_string_literal: true

module Rag
  # One-paragraph variant of the captured phase 5 question (B) and the phase 3
  # summary (A). The production attribution contract is not changed. Historical
  # fixture hashes stay the hashes of the captures. A model call needs
  # LABEL_COMPARISON_VARIANT_AUTHORIZED=1 and AWS_MAX_ATTEMPTS=1.
  # One call per process, three calls at most: B1, then B2 only if B1 did not
  # repeat the identity defect, then A1 only if both B samples passed identity.
  # An error stops the sequence and is not replaced by the next call.
  # A partial reading does not authorize adoption or phase closure.
  # This does not accept phase 3 or phase 5 and does not score the answer.
  class LabelComparisonVariant
    AUTHORIZED_ENV = "LABEL_COMPARISON_VARIANT_AUTHORIZED"
    ATTEMPT_CAP = 3
    INPUT_USD_PER_THOUSAND = BigDecimal("0.001")
    OUTPUT_USD_PER_THOUSAND = BigDecimal("0.005")
    B_REFERENCE_INPUT_TOKENS = 15_881
    B_REFERENCE_OUTPUT_TOKENS = 468
    A_REFERENCE_INPUT_TOKENS = 11_928
    A_REFERENCE_OUTPUT_TOKENS = 545
    DEFAULT_OUTPUT = "tmp/label_comparison_variant"
    JOB_TERMS = %w[Chapa Elemont salida 24V].freeze
    READING_FIELDS = %w[identity function voltage dp_category prescribed_check location_path usefulness].freeze
    TERMINAL_RESULTS = %w[returned error].freeze
    STEPS = {
      "b1" => { "case" => "b", "attempt" => 1, "correlation" => "phase5:replay:b:v2:1" },
      "b2" => { "case" => "b", "attempt" => 2, "correlation" => "phase5:replay:b:v2:2" },
      "a1" => { "case" => "a", "attempt" => 1, "correlation" => "phase3:summary:v2:1" }
    }.freeze
    HISTORICAL_CORRELATIONS = %w[
      phase5:replay:b:1
      phase5:replay:b:2
      phase3:summary:20261014T205958Z:1
      phase3:summary:20261014T205958Z:2
      phase3:summary:20261014T205958Z:3
      phase3:15:t3
      phase3:15:t3:query
      query:c80668ea-f7e8-4448-bb2d-ddd842fe7524
    ].freeze
    # Last paragraph of the production contract and of the historical captures.
    # Pinned here so a later edit of the constant cannot be hidden by rewriting
    # those capture hashes.
    HISTORICAL_PARAGRAPH = <<~TEXT.strip.freeze
      When distinguishing two labels, explain their documented sections and locations first. A concise answer based on those distinctions is sufficient; do not enumerate every neighboring label or the complete circuit unless it helps answer the question. If the evidence does not settle which physical element the technician is following, say so and ask for one useful observation that the technician can see or read on the equipment or drawing. A closing question must not presuppose an undocumented function, connection, or value.
    TEXT
    # Candidate only. Not written into BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT.
    CANDIDATE_PARAGRAPH = <<~TEXT.strip.freeze
      When the question compares two labels, including whether they are the same element or whether one reference can replace the other, explain each label's documented section and location first. That distinction is enough to locate them; do not enumerate every neighboring label or the complete circuit unless it helps answer the question. A different section or a shared level number does not by itself establish that the labels designate the same physical element or different ones, nor that their function, supply, or voltage matches or differs. When the passages, including what they show graphically, settle one of those relations, state that conclusion and attribute it to that evidence. When they leave one unsettled, say these passages leave it open and do not attribute either answer for that relation to the drawing. If they do not settle whether one reference can replace the other, the useful conclusion is that these passages do not support using one in place of the other. If the evidence does not settle which physical element the technician is following or a label designates, ask for one useful observation that the technician can see or read on the equipment or drawing when its answer would change the guidance. A closing question must not presuppose an undocumented function, connection, or value.
    TEXT

    Substitution = Data.define(:text, :occurrences, :problem)

    Prepared = Data.define(
      :model_id, :temperature, :max_tokens, :anthropic_version,
      :b_prompt, :b_body, :b_original_prompt, :b_original_body,
      :a_system, :a_user, :a_body, :a_original_system, :a_original_body,
      :b_log_request_sha256, :a_capture_sha256
    )

    Outcome = Data.define(
      :status, :reason, :detail, :request, :samples, :quota, :output_dir, :step, :partial
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
          "partial" => partial,
          "adoption" => "not_authorized",
          "partial_authorizes_adoption" => false,
          "partial_closes_phases" => false,
          "phase3_acceptance" => "not_accepted",
          "phase5_acceptance" => "not_accepted",
          "phase4_status" => "unchanged",
          "episode" => "not_validated",
          "historical_failures_retained" => true,
          "determinism" => "not_claimed",
          "production_constant_adopted" => false,
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

    def self.preview(phase5_capture:, phase3_capture:, output_dir: nil)
      new(phase5_capture: phase5_capture, phase3_capture: phase3_capture, output_dir: output_dir).preview
    end

    def self.gate(phase5_capture:, phase3_capture:, output_dir:)
      new(phase5_capture: phase5_capture, phase3_capture: phase3_capture, output_dir: output_dir).gate
    end

    def self.run(phase5_capture:, phase3_capture:, output_dir:, client:)
      new(
        phase5_capture: phase5_capture,
        phase3_capture: phase3_capture,
        output_dir: output_dir,
        client: client
      ).run
    end

    def self.default_output_dir
      Rails.root.join(DEFAULT_OUTPUT)
    end

    def self.substitute(text)
      return Substitution.new(text: nil, occurrences: 0, problem: "not_text") unless text.is_a?(String)
      if text.include?(CANDIDATE_PARAGRAPH)
        return Substitution.new(text: nil, occurrences: 0, problem: "candidate_already_present")
      end

      occurrences = text.scan(HISTORICAL_PARAGRAPH).size
      unless occurrences == 1
        return Substitution.new(text: nil, occurrences: occurrences, problem: "occurrences")
      end

      before, _, after = text.partition(HISTORICAL_PARAGRAPH)
      replaced = "#{before}#{CANDIDATE_PARAGRAPH}#{after}"
      restored = replaced.sub(CANDIDATE_PARAGRAPH, HISTORICAL_PARAGRAPH)
      unless restored == text && replaced.scan(CANDIDATE_PARAGRAPH).size == 1 && replaced.exclude?(HISTORICAL_PARAGRAPH)
        return Substitution.new(text: nil, occurrences: occurrences, problem: "not_one_span")
      end

      Substitution.new(text: replaced, occurrences: 1, problem: nil)
    end

    def self.production_problem(contract)
      return { "problem" => "absent" } unless contract.is_a?(String)
      return { "problem" => "candidate_adopted" } if contract.include?(CANDIDATE_PARAGRAPH)
      return { "problem" => "historical_paragraph_missing" } unless contract.end_with?(HISTORICAL_PARAGRAPH)
      return { "problem" => "historical_paragraph_repeated" } unless contract.scan(HISTORICAL_PARAGRAPH).size == 1

      term = JOB_TERMS.find { |word| CANDIDATE_PARAGRAPH.downcase.include?(word.downcase) }
      return { "problem" => "candidate_term", "term" => term } if term
      return { "problem" => "candidate_has_newline" } if CANDIDATE_PARAGRAPH.include?("\n")
      return { "problem" => "historical_has_newline" } if HISTORICAL_PARAGRAPH.include?("\n")

      nil
    end

    def self.estimated_usd(input_tokens, output_tokens)
      cost = (BigDecimal(input_tokens) / 1000 * INPUT_USD_PER_THOUSAND) +
        (BigDecimal(output_tokens) / 1000 * OUTPUT_USD_PER_THOUSAND)
      format("%.6f", cost)
    end

    def self.estimated_usd_b
      estimated_usd(B_REFERENCE_INPUT_TOKENS, B_REFERENCE_OUTPUT_TOKENS)
    end

    def self.estimated_usd_a
      estimated_usd(A_REFERENCE_INPUT_TOKENS, A_REFERENCE_OUTPUT_TOKENS)
    end

    def self.estimated_usd_cap
      format("%.6f", (BigDecimal(estimated_usd_b) * 2) + BigDecimal(estimated_usd_a))
    end

    def initialize(phase5_capture:, phase3_capture:, output_dir: nil, client: nil)
      @phase5_capture = Pathname(phase5_capture)
      @phase3_capture = Pathname(phase3_capture)
      @output_dir = output_dir.nil? ? nil : Pathname(output_dir)
      @client = client
      @partial = false
      @reading_detail = nil
    end

    def preview
      prepared = prepare
      return prepared if prepared.is_a?(Outcome)

      quota = quota_document
      outcome("preview", nil, nil, request_document(prepared), nil, quota, @output_dir, quota["next_step"], @partial)
    end

    def gate
      prepared = prepare
      return prepared if prepared.is_a?(Outcome)

      refusal = execution_refusal
      return refusal if refusal

      action, step = dispatch
      detail = @reading_detail
      quota = quota_document
      document = request_document(prepared)
      unless action == "send"
        status = action == "blocked" ? "blocked" : "refused"
        return outcome(status, step, detail, document, nil, quota, nil, nil, @partial)
      end

      outcome("ready", nil, nil, document, nil, quota, @output_dir, step, @partial)
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
      problem = self.class.production_problem(BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT)
      return blocked("production_contract", problem) if problem

      phase5 = relay(Phase5GenerationReplay.captured(capture_dir: @phase5_capture))
      return phase5 if phase5.is_a?(Outcome)

      phase3 = relay(Phase3SummaryGenerationReplay.captured(capture_dir: @phase3_capture))
      return phase3 if phase3.is_a?(Outcome)

      mismatch = parameter_mismatch(phase5, phase3)
      return mismatch if mismatch

      user_problem = user_problem(phase3)
      return user_problem if user_problem

      b_substitution = self.class.substitute(phase5.content)
      return paragraph_block("b", b_substitution) if b_substitution.text.nil?

      a_substitution = self.class.substitute(phase3.system_bytes)
      return paragraph_block("a", a_substitution) if a_substitution.text.nil?

      b_original_body = Phase5GenerationReplay.invoke_body_for(
        anthropic_version: phase3.anthropic_version,
        max_tokens: phase5.max_tokens,
        temperature: phase5.temperature,
        content: phase5.content
      )
      unless digest(b_original_body) == Phase5GenerationReplay::EFFECTIVE_BODY_SHA256 &&
             b_original_body.bytesize == Phase5GenerationReplay::EFFECTIVE_BODY_BYTES
        return blocked("serializer", { "case" => "b", "actual_sha256" => digest(b_original_body) })
      end

      b_body = Phase5GenerationReplay.invoke_body_for(
        anthropic_version: phase3.anthropic_version,
        max_tokens: phase5.max_tokens,
        temperature: phase5.temperature,
        content: b_substitution.text
      )
      a_original_body = phase3_body(phase3, phase3.system_bytes)
      a_body = phase3_body(phase3, a_substitution.text)
      Prepared.new(
        model_id: phase5.model_id,
        temperature: phase5.temperature,
        max_tokens: phase5.max_tokens,
        anthropic_version: phase3.anthropic_version,
        b_prompt: b_substitution.text,
        b_body: b_body,
        b_original_prompt: phase5.content,
        b_original_body: b_original_body,
        a_system: a_substitution.text,
        a_user: phase3.user_bytes,
        a_body: a_body,
        a_original_system: phase3.system_bytes,
        a_original_body: a_original_body,
        b_log_request_sha256: Phase5GenerationReplay::REQUEST_SHA256,
        a_capture_sha256: phase3.capture_sha256
      )
    end

    def phase3_body(phase3, system)
      Phase3SummaryGenerationReplay.invoke_body_for(
        anthropic_version: phase3.anthropic_version,
        max_tokens: phase3.max_tokens,
        temperature: phase3.temperature,
        content: phase3.user_bytes,
        system: system
      )
    end

    def parameter_mismatch(phase5, phase3)
      expected = {
        "model_id" => phase5.model_id,
        "temperature" => phase5.temperature,
        "max_tokens" => phase5.max_tokens,
        "anthropic_version" => Phase5GenerationReplay::ANTHROPIC_VERSION
      }
      actual = {
        "model_id" => phase3.model_id,
        "temperature" => phase3.temperature,
        "max_tokens" => phase3.max_tokens,
        "anthropic_version" => phase3.anthropic_version
      }
      return if expected == actual && phase5.model_id == Phase5GenerationReplay::MODEL_ID &&
                phase5.temperature == Phase5GenerationReplay::TEMPERATURE &&
                phase5.max_tokens == Phase5GenerationReplay::MAX_TOKENS

      blocked("parameter_mismatch", { "b" => expected, "a" => actual })
    end

    def user_problem(phase3)
      if phase3.user_bytes.include?(HISTORICAL_PARAGRAPH) || phase3.user_bytes.include?(CANDIDATE_PARAGRAPH)
        return blocked("user_contains_paragraph", { "case" => "a" })
      end
      return if digest(phase3.user_bytes) == phase3.user_sha256

      blocked("sha256", {
        "field" => "user",
        "expected_sha256" => phase3.user_sha256,
        "actual_sha256" => digest(phase3.user_bytes)
      })
    end

    def paragraph_block(case_name, substitution)
      blocked("paragraph", {
        "case" => case_name,
        "occurrences" => substitution.occurrences,
        "problem" => substitution.problem
      })
    end

    def relay(loaded)
      return loaded unless loaded.is_a?(Phase5GenerationReplay::Outcome) || loaded.is_a?(Phase3SummaryGenerationReplay::Outcome)

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
        @phase5_capture,
        @phase3_capture,
        Rails.root.join(Phase5GenerationReplay::DEFAULT_OUTPUT),
        Rails.root.join(Phase5GenerationReplay::DEFAULT_CAPTURE),
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
      @partial = false
      @reading_detail = nil
      return [ "blocked", "sequence" ] if @output_dir && sequence_hole?
      return [ "send", "b1" ] if @output_dir.nil? || !sample_dir("b", 1).exist?

      b1 = terminal("b", 1)
      return [ "blocked", "sample_incomplete" ] if b1 == :incomplete
      return [ "refused", "sample_error" ] if b1["result"] == "error"

      decision = reading_decision("b", 1)
      return [ "refused", decision ] unless decision == "pass"
      return [ "send", "b2" ] unless sample_dir("b", 2).exist?

      b2 = terminal("b", 2)
      return [ "blocked", "sample_incomplete" ] if b2 == :incomplete
      return [ "refused", "sample_error" ] if b2["result"] == "error"

      decision = reading_decision("b", 2)
      return [ "refused", decision ] unless decision == "pass"
      return [ "send", "a1" ] unless sample_dir("a", 1).exist?

      a1 = terminal("a", 1)
      return [ "blocked", "sample_incomplete" ] if a1 == :incomplete
      return [ "refused", "sample_error" ] if a1["result"] == "error"

      [ "blocked", "cap_reached" ]
    end

    def sequence_hole?
      b1 = sample_dir("b", 1).exist?
      b2 = sample_dir("b", 2).exist?
      a1 = sample_dir("a", 1).exist?
      (b2 && !b1) || (a1 && (!b1 || !b2))
    end

    def reading_decision(case_name, attempt)
      path = sample_dir(case_name, attempt).join("reading.json")
      return "reading_absent" unless path.file?

      parsed = JSON.parse(path.read)
      return invalid_reading("unreadable") unless parsed.is_a?(Hash)

      missing = READING_FIELDS.reject { |field| parsed[field].is_a?(String) && parsed[field].strip.present? }
      return invalid_reading(missing) if missing.any?
      return invalid_reading("identity_passed") unless parsed["identity_passed"].is_a?(TrueClass) || parsed["identity_passed"] == false
      return invalid_reading("partial") unless parsed["partial"].is_a?(TrueClass) || parsed["partial"] == false
      return invalid_reading("partial") if parsed["identity_passed"] == false && parsed["partial"] == true
      return "identity_repeated" if parsed["identity_passed"] == false

      @partial = true if parsed["partial"] == true
      "pass"
    rescue JSON::ParserError
      invalid_reading("unreadable")
    end

    def invalid_reading(detail)
      @reading_detail = detail
      "reading_invalid"
    end

    def quota_document
      action, step = @output_dir.nil? ? [ "send", "b1" ] : dispatch
      recorded = @output_dir.nil? ? 0 : calls_recorded
      would_send = action == "send" ? 1 : 0
      {
        "attempt_cap" => ATTEMPT_CAP,
        "calls_recorded" => recorded,
        "calls_the_next_authorized_process_would_send" => would_send,
        "calls_remaining_in_cap" => ATTEMPT_CAP - recorded,
        "calls_remaining_after_that_process" => ATTEMPT_CAP - recorded - would_send,
        "next_step" => would_send == 1 ? step : nil,
        "dispatch" => would_send == 1 ? "send" : step,
        "estimated_usd_b_reference" => self.class.estimated_usd_b,
        "estimated_usd_a_reference" => self.class.estimated_usd_a,
        "estimated_usd_cap_reference" => self.class.estimated_usd_cap,
        "estimate_is_ceiling" => false,
        "b_reference_input_tokens" => B_REFERENCE_INPUT_TOKENS,
        "b_reference_output_tokens" => B_REFERENCE_OUTPUT_TOKENS,
        "a_reference_input_tokens" => A_REFERENCE_INPUT_TOKENS,
        "a_reference_output_tokens" => A_REFERENCE_OUTPUT_TOKENS,
        "paragraph_delta_bytes" => CANDIDATE_PARAGRAPH.bytesize - HISTORICAL_PARAGRAPH.bytesize,
        "retries" => false,
        "partial" => @partial,
        "adoption" => "not_authorized"
      }
    end

    def calls_recorded
      [ [ "b", 1 ], [ "b", 2 ], [ "a", 1 ] ].count { |case_name, attempt| terminal(case_name, attempt).is_a?(Hash) }
    end

    def terminal(case_name, attempt)
      path = sample_dir(case_name, attempt).join("events.json")
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

    def execute(step_id)
      action, actual = dispatch
      unless action == "send" && actual == step_id
        return blocked("sequence", { "expected" => step_id, "actual" => actual })
      end

      prepared = prepare
      return prepared if prepared.is_a?(Outcome)

      step = STEPS.fetch(step_id)
      directory = sample_dir(step["case"], step["attempt"])
      FileUtils.mkdir_p(directory.dirname)
      begin
        Dir.mkdir(directory)
      rescue Errno::EEXIST
        return blocked("evidence_exists")
      end

      body = step["case"] == "b" ? prepared.b_body : prepared.a_body
      written = directory.join("request_body.json")
      File.binwrite(written, body)
      unless digest(File.binread(written)) == digest(body)
        FileUtils.remove_entry(directory)
        return blocked("sha256", { "field" => "invoke_body", "step" => step_id })
      end
      write_step_texts(directory, prepared, step)
      write_json(directory.join("paragraph.json"), paragraph_record(prepared, step))

      request = sample_request(prepared, step, sent: false)
      events = [ sample_event("prepared", step, request) ]
      write_sample(directory, request, events)
      write_json(directory.join("client_retry.json"), @retry_record)
      request = request.merge("sent" => true)
      events << sample_event("attempt_started", step, nil)
      write_sample(directory, request, events)
      events << invoke_once(prepared, step, directory, body)
      finish_sample(directory, step, events, request)
    end

    def write_step_texts(directory, prepared, step)
      if step["case"] == "b"
        File.binwrite(directory.join("prompt.txt"), prepared.b_prompt)
      else
        File.binwrite(directory.join("system.txt"), prepared.a_system)
        File.binwrite(directory.join("user.txt"), prepared.a_user)
      end
    end

    def invoke_once(prepared, step, directory, body)
      response = @client.invoke_model(model_id: prepared.model_id, body: body)
      raw = response.body.read
      parsed = JSON.parse(raw)
      text = parsed.is_a?(Hash) ? parsed.dig("content", 0, "text") : nil
      return error_event(step, "unavailable", "response text absent") unless text.is_a?(String)

      File.binwrite(directory.join("response.txt"), text)
      File.binwrite(directory.join("response_body.json"), raw)
      usage = usage_from(parsed)
      write_json(directory.join("usage.json"), usage)
      returned_event(step, text, usage, parsed["stop_reason"])
    rescue StandardError => error
      error_event(step, error.class.name, error.message)
    end

    def finish_sample(directory, step, events, request)
      write_sample(directory, request, events)
      terminal = events.last
      write_template(directory, step["case"]) if terminal["result"] == "returned"
      samples = recorded_samples
      write_json(@output_dir.join("run.json"), run_document(samples, terminal))
      outcome(
        "recorded",
        nil,
        terminal["result"] == "error" ? { "step" => step["correlation"], "sequence_stopped" => true } : nil,
        request,
        samples,
        quota_document,
        @output_dir,
        step["correlation"],
        @partial
      )
    end

    def recorded_samples
      STEPS.map { |step_id, step|
        found = terminal(step["case"], step["attempt"])
        next unless found.is_a?(Hash)

        {
          "step" => step_id,
          "attempt" => step["attempt"],
          "case" => step["case"],
          "correlation_id" => step["correlation"],
          "result" => found["result"],
          "directory" => sample_dir(step["case"], step["attempt"]).to_s
        }
      }.compact
    end

    def run_document(samples, terminal)
      {
        "status" => "recorded",
        "adoption" => "not_authorized",
        "partial_authorizes_adoption" => false,
        "partial_closes_phases" => false,
        "phase3_acceptance" => "not_accepted",
        "phase5_acceptance" => "not_accepted",
        "phase4_status" => "unchanged",
        "episode" => "not_validated",
        "historical_failures_retained" => true,
        "determinism" => "not_claimed",
        "production_constant_adopted" => false,
        "attempt_cap" => ATTEMPT_CAP,
        "retries" => false,
        "substitution_of_failed_call" => false,
        "sequence_stopped" => terminal["result"] == "error",
        "partial" => @partial,
        "samples" => samples
      }
    end

    def usage_from(parsed)
      usage = parsed["usage"].is_a?(Hash) ? parsed["usage"] : {}
      {
        "input_tokens" => usage["input_tokens"] || usage["inputTokens"] || "unavailable",
        "output_tokens" => usage["output_tokens"] || usage["outputTokens"] || "unavailable",
        "stop_reason" => parsed["stop_reason"]
      }
    end

    def returned_event(step, text, usage, stop_reason)
      {
        "result" => "returned",
        "attempt" => step["attempt"],
        "correlation_id" => step["correlation"],
        "answer_bytes" => text.b.bytesize,
        "answer_sha256" => digest(text),
        "stop_reason" => stop_reason,
        "usage" => usage
      }
    end

    def error_event(step, error_class, message = nil)
      {
        "result" => "error",
        "attempt" => step["attempt"],
        "correlation_id" => step["correlation"],
        "error_class" => error_class,
        "message" => message
      }
    end

    def sample_request(prepared, step, sent:)
      request_document(prepared).merge(
        "correlation_id" => step["correlation"],
        "case" => step["case"],
        "attempt" => step["attempt"],
        "sent" => sent
      )
    end

    def sample_event(result, step, request)
      {
        "result" => result,
        "attempt" => step["attempt"],
        "correlation_id" => step["correlation"],
        "request" => request
      }.compact
    end

    def write_sample(directory, request, events)
      write_json(directory.join("request.json"), request)
      write_json(directory.join("events.json"), events)
    end

    def write_template(directory, case_name)
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
        "note" => reading_note(case_name)
      })
    end

    def reading_note(case_name)
      parts = [
        "Anotar por separado identidad, función, voltaje, categoría de Dp, comprobación, ubicación o recorrido, y utilidad. El servicio no lee la respuesta para puntuar.",
        "identity_passed true solo si la identidad no repite el defecto. partial true si la identidad pasó y otro criterio falló. Un parcial no autoriza adopción ni cierra fases.",
        "La identidad falla si afirma igualdad, diferencia, intercambiabilidad o probabilidad como hecho del plano, o como inferencia sacada solo de la sección o del nivel.",
        "No falla dejar la relación abierta, ni una conclusión que los pasajes sí resuelven, incluida la evidencia gráfica, atribuida a esa evidencia.",
        "Una inferencia fundada y presentada como inferencia no falla por ser inferencia.",
        "La función y el voltaje fallan si se igualan o contrastan sin evidencia documental suficiente. No falla lo que los pasajes sí respaldan. Nombrar los rieles impresos del recorrido no falla.",
        "Dp falla si Dp3 queda como contacto, NA o NC. «símbolo Dp3» no falla.",
        "La comprobación falla si prescribe revisar porque son o no son lo mismo, o da pasos para puentear o sustituir. Pedir una observación o el síntoma no falla.",
        "Ubicación y recorrido se evalúan por significado. No hace falta el recorrido completo cuando no responde la pregunta. «Posición 7» sigue como reserva de la fase 4.",
        "La utilidad falla si solo hay abstención o si falta la respuesta práctica sobre la sustitución. No hacer una pregunta no falla.",
        "identity_passed false detiene la secuencia y partial tiene que ser false. identity_passed true abre el paso siguiente aunque partial sea true."
      ]
      if case_name == "b"
        parts << "En B, falla si pierde Chapa nivel 3 en la Botonera con su recorrido, Com 18vdc, Dp3 y el cruce sin unión con PasCom 24V, o Seguridad Puerta nivel 3 entre la 4 y la 2 en la Línea de Seguridad."
      elsif case_name == "a"
        parts << "En A, la identidad también falla si mete Chapa nivel 3 en la cadena o presenta Seguridad Puerta nivel 3 como su correspondiente. El resumen tiene que conservar la corrección a nivel 3."
      end
      parts.join(" ")
    end

    def request_document(prepared)
      {
        "model_id" => prepared.model_id,
        "temperature" => prepared.temperature,
        "max_tokens" => prepared.max_tokens,
        "anthropic_version" => prepared.anthropic_version,
        "stream" => false,
        "production_constant_adopted" => false,
        "paragraph_occurrences" => 1,
        "paragraph" => {
          "historical_bytes" => HISTORICAL_PARAGRAPH.bytesize,
          "historical_sha256" => digest(HISTORICAL_PARAGRAPH),
          "candidate_bytes" => CANDIDATE_PARAGRAPH.bytesize,
          "candidate_sha256" => digest(CANDIDATE_PARAGRAPH),
          "delta_bytes" => CANDIDATE_PARAGRAPH.bytesize - HISTORICAL_PARAGRAPH.bytesize
        },
        "b" => b_document(prepared),
        "a" => a_document(prepared),
        "correlations" => STEPS.values.pluck("correlation"),
        "historical_correlations_not_reused" => HISTORICAL_CORRELATIONS,
        "directories" => {
          "output" => DEFAULT_OUTPUT,
          "b_sample_1" => "b/sample_1",
          "b_sample_2" => "b/sample_2",
          "a_sample_1" => "a/sample_1"
        }
      }
    end

    def b_document(prepared)
      {
        "system" => false,
        "messages" => [ { "role" => "user" } ],
        "log_request_sha256" => prepared.b_log_request_sha256,
        "log_request_bytes" => Phase5GenerationReplay::REQUEST_BYTES,
        "original_prompt_sha256" => digest(prepared.b_original_prompt),
        "original_prompt_bytes" => prepared.b_original_prompt.bytesize,
        "candidate_prompt_sha256" => digest(prepared.b_prompt),
        "candidate_prompt_bytes" => prepared.b_prompt.bytesize,
        "original_invoke_body_sha256" => digest(prepared.b_original_body),
        "original_invoke_body_bytes" => prepared.b_original_body.bytesize,
        "candidate_invoke_body_sha256" => digest(prepared.b_body),
        "candidate_invoke_body_bytes" => prepared.b_body.bytesize,
        "correlations" => [ "phase5:replay:b:v2:1", "phase5:replay:b:v2:2" ]
      }
    end

    def a_document(prepared)
      {
        "messages" => [ { "role" => "user" } ],
        "system" => true,
        "capture_sha256" => prepared.a_capture_sha256,
        "original_system_sha256" => digest(prepared.a_original_system),
        "original_system_bytes" => prepared.a_original_system.bytesize,
        "candidate_system_sha256" => digest(prepared.a_system),
        "candidate_system_bytes" => prepared.a_system.bytesize,
        "user_sha256" => digest(prepared.a_user),
        "user_bytes" => prepared.a_user.bytesize,
        "user_intact" => true,
        "original_invoke_body_sha256" => digest(prepared.a_original_body),
        "original_invoke_body_bytes" => prepared.a_original_body.bytesize,
        "original_invoke_body_provenance" => "reconstructed_from_captured_system_and_user",
        "candidate_invoke_body_sha256" => digest(prepared.a_body),
        "candidate_invoke_body_bytes" => prepared.a_body.bytesize,
        "correlation" => "phase3:summary:v2:1"
      }
    end

    def paragraph_record(prepared, step)
      {
        "occurrences" => 1,
        "historical_sha256" => digest(HISTORICAL_PARAGRAPH),
        "candidate_sha256" => digest(CANDIDATE_PARAGRAPH),
        "case" => step["case"],
        "correlation_id" => step["correlation"],
        "user_sha256" => step["case"] == "a" ? digest(prepared.a_user) : nil,
        "user_intact" => step["case"] == "a"
      }.compact
    end

    def sample_dir(case_name, attempt)
      @output_dir.join(case_name, format("sample_%d", attempt))
    end

    def digest(text)
      Digest::SHA256.hexdigest(text.b)
    end

    def outcome(status, reason, detail, request, samples, quota, output_dir = nil, step = nil, partial = false)
      Outcome.new(
        status: status,
        reason: reason,
        detail: detail,
        request: request,
        samples: samples,
        quota: quota,
        output_dir: output_dir,
        step: step,
        partial: partial
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
