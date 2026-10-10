# frozen_string_literal: true

module Rag
  # Isolated interpreter comparison. Both models go through the Anthropic
  # Messages API: claude-haiku-5-5 and claude-haiku-4-5-20251001.
  # It does not call Bedrock, does not write an episode, and does not run RAG.
  # Live execution stays closed until the approval record, the explicit
  # authorization, and the frozen quota all pass together.
  class InterpreterAnthropicExperiment
    LIVE_CALLS_ENABLED = false
    LANES = %w[prepared stubs runs].freeze
    PHASE1_TEXT = "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. " \
                  "Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta " \
                  "y cómo se relaciona con las demás seguridades?"
    ACTIVE_GOAL = "problema de puerta en el nivel 2"
    ACTIVE_CONTEXT_ID = "ep_experiment_active"
    MODELS = InterpreterAnthropicAdapter::ACCEPTED_MODELS
    # Frozen after the matrix below. A later edit of the matrix does not
    # rewrite this hash and does not raise the caps.
    APPROVED_MATRIX_SHA256 = "1d1c17b57e819d3040d7d011c44b4f5d20c370086dff7a8428e909259d208954"
    # One initial probe: phase 1, two models, two prompts. Not opened.
    # The full matrix with both prompts would be 100 calls. That quota is
    # not this cap and is not authorized.
    PROBE_ATTEMPT_CAP = 4
    DEFERRED_BOTH_PROMPTS_CALLS = 100
    PROBE_PAIRS = [
      [ InterpreterAnthropicAdapter::HAIKU_45, InterpreterPromptCatalog::ORIGINAL ],
      [ InterpreterAnthropicAdapter::HAIKU_55, InterpreterPromptCatalog::ORIGINAL ],
      [ InterpreterAnthropicAdapter::HAIKU_45, InterpreterPromptCatalog::OPUS ],
      [ InterpreterAnthropicAdapter::HAIKU_55, InterpreterPromptCatalog::OPUS ]
    ].freeze

    class Error < StandardError
      attr_reader :code

      def initialize(code, message = nil)
        @code = code
        super(message || code)
      end
    end

    class Interrupted < Error
      attr_reader :stage, :original
      attr_accessor :emergency_write_failed, :cost_note

      def initialize(stage, original)
        @stage = stage.to_s
        @original = original
        super("evidence_incomplete")
      end

      def message
        text = "evidence_incomplete:#{stage}:#{original.class}"
        text += ";emergency_write_failed" if emergency_write_failed
        text += ";#{cost_note}" if emergency_write_failed && cost_note
        text
      end
    end

    class Budget
      # INPUT_RESERVATION estimates the frozen matrix. It is not a provider
      # limit. max_tokens caps output only. The money cap refuses the next
      # call when this estimate would not fit, and stops after a priced call
      # that exceeds its own reservation. That does not guarantee the
      # provider will bill less than the estimate on a call that already left.
      INPUT_RESERVATION = {
        InterpreterAnthropicAdapter::HAIKU_45 => 2500,
        InterpreterAnthropicAdapter::HAIKU_55 => 3500
      }.freeze
      OUTPUT_RESERVATION = TurnInterpreter::MAX_TOKENS
      ATTEMPT_CAP = 50
      MONEY_CAP = BigDecimal("0.141650")

      class Ledger
        attr_reader :attempts, :spent, :close_reason, :undetermined_attempts

        # spent is the sum of priced attempts. It is not the provider total
        # while undetermined_attempts is positive: a missing usage is not zero.
        def initialize(state = nil, attempt_cap: ATTEMPT_CAP, money_cap: MONEY_CAP)
          state ||= {}
          @attempt_cap = attempt_cap
          @money_cap = money_cap
          @attempts = state["attempts"].to_i
          @spent = decimal(state["spent_usd"] || state["known_cost_usd"] || "0")
          @undetermined_attempts = state["undetermined_attempts"].to_i
          @closed = state["closed"] == true
          @close_reason = state["close_reason"]
          @last_reservation = BigDecimal("0")
        end

        def closed?
          @closed
        end

        def reserve!(model_id)
          return "execution_closed" if @closed
          return "cost_incomplete" if @undetermined_attempts.positive?
          return "attempt_cap" if @attempts >= @attempt_cap

          reservation = Budget.reservation_usd(model_id)
          return "money_cap" if @spent + reservation > @money_cap

          @attempts += 1
          @last_reservation = reservation
          nil
        end

        def close!(reason)
          @closed = true
          @close_reason ||= reason
          nil
        end

        def close_for_evidence!(reason)
          @closed = true
          @close_reason = reason
          nil
        end

        def cost_total_determined?
          @undetermined_attempts.zero?
        end

        def record_cost!(priced)
          if priced["cost_status"] == "priced" && priced["cost_usd"]
            amount = decimal(priced["cost_usd"])
            @spent += amount
            close!("reservation_exceeded") if amount > @last_reservation
          else
            @undetermined_attempts += 1
          end
          nil
        end

        def reconcile!(model_id, provider_result:, usage:)
          priced = InterpreterAnthropicAdapter.price(model_id, usage)
          record_cost!(priced)
          if provider_result != "returned" || priced["cost_status"] != "priced"
            close!(provider_result == "returned" ? priced["cost_status"] : "provider_error")
          end
          priced
        end

        def cost_fields
          amount = format("%.6f", @spent)
          {
            "spent_usd" => amount,
            "known_cost_usd" => amount,
            "cost_total_determined" => cost_total_determined?,
            "undetermined_attempts" => @undetermined_attempts
          }
        end

        private

        def decimal(value)
          value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        end
      end

      def self.attempt_cap
        ATTEMPT_CAP
      end

      def self.money_cap
        MONEY_CAP
      end

      def self.reservation_usd(model_id)
        rates = InterpreterAnthropicAdapter::RATES.fetch(model_id)
        input = INPUT_RESERVATION.fetch(model_id)
        (BigDecimal(input) * rates[:input]) + (BigDecimal(OUTPUT_RESERVATION) * rates[:output])
      end

      def self.estimate_usd
        MODELS.sum { |model_id| reservation_usd(model_id) * matrix_cases }
      end

      def self.matrix_cases
        InterpreterAnthropicExperiment.matrix.size
      end

      # live and credential_present are explicit arguments. Nothing here reads
      # the process environment or a credential store. live: true is not
      # authorization to call.
      def self.gate(model_id, attempts:, spent_usd:, live:, credential_present:, closed: false)
        return "execution_closed" if closed
        return "live_calls_closed" unless live
        return "attempt_cap" if attempts >= ATTEMPT_CAP

        spent = spent_usd.is_a?(BigDecimal) ? spent_usd : BigDecimal(spent_usd.to_s)
        return "money_cap" if spent + reservation_usd(model_id) > MONEY_CAP
        return "credential_absent" unless credential_present

        nil
      end

      def self.continue_after?(provider_result, cost_status: "priced", cost_usd: nil, reservation_usd: nil)
        return false unless provider_result == "returned" && cost_status == "priced"
        return false if cost_usd && reservation_usd && BigDecimal(cost_usd.to_s) > BigDecimal(reservation_usd.to_s)

        true
      end
    end

    def self.matrix
      @matrix ||= build_matrix.freeze
    end

    def self.matrix_sha256
      payload = matrix.map { |row|
        %w[
          id text context disposition allowed_moves forbidden_moves
          empty_observations empty_assertions pair_of justification
        ].index_with { |key| row[key] }
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def self.approval
      @approval ||= {
        "enabled" => false,
        "provider" => "anthropic",
        "matrix_sha256" => APPROVED_MATRIX_SHA256,
        "attempt_cap" => Budget::ATTEMPT_CAP,
        "money_cap_usd" => format("%.6f", Budget::MONEY_CAP),
        "models" => MODELS,
        "endpoint" => InterpreterAnthropicAdapter::ENDPOINT,
        "retries" => InterpreterAnthropicTransport::RETRIES,
        "haiku_55" => InterpreterAnthropicAdapter::HAIKU_55,
        "haiku_45" => InterpreterAnthropicAdapter::HAIKU_45,
        "run_id" => nil,
        "scope" => "matrix"
      }.freeze
    end

    def self.probe_money_cap
      pairs = PROBE_PAIRS.map(&:first)
      pairs.sum { |model_id| Budget.reservation_usd(model_id) }
    end

    def self.probe_approval
      @probe_approval ||= {
        "enabled" => false,
        "scope" => "phase1_prompt_probe",
        "provider" => "anthropic",
        "run_id" => nil,
        "attempt_cap" => PROBE_ATTEMPT_CAP,
        "money_cap_usd" => format("%.6f", probe_money_cap),
        "models" => MODELS,
        "cases" => [ "phase1" ],
        "prompts" => InterpreterPromptCatalog.catalog,
        "endpoint" => InterpreterAnthropicAdapter::ENDPOINT,
        "retries" => InterpreterAnthropicTransport::RETRIES,
        "haiku_55" => InterpreterAnthropicAdapter::HAIKU_55,
        "haiku_45" => InterpreterAnthropicAdapter::HAIKU_45
      }.freeze
    end

    def self.approval_refusal(record = approval, matrix_sha: matrix_sha256, run_id: record["run_id"])
      return "execution_not_approved" unless record.is_a?(Hash) && record["enabled"] == true
      return "provider_unapproved" unless record["provider"] == "anthropic"
      return "models_unapproved" unless record["models"] == MODELS
      return "endpoint_unapproved" unless record["endpoint"] == InterpreterAnthropicAdapter::ENDPOINT
      return "retries_unapproved" unless record["retries"] == 0
      return "attempt_cap_unapproved" unless record["attempt_cap"] == Budget::ATTEMPT_CAP
      return "money_cap_unapproved" unless record["money_cap_usd"] == format("%.6f", Budget::MONEY_CAP)
      return "matrix_unapproved" unless record["matrix_sha256"] == matrix_sha && matrix_sha == APPROVED_MATRIX_SHA256
      return "scope_unapproved" unless record["scope"] == "matrix"
      return "run_id_unapproved" if record["run_id"].blank? || record["run_id"] != run_id

      nil
    end

    def self.probe_refusal(record = probe_approval, run_id: record["run_id"])
      return "execution_not_approved" unless record.is_a?(Hash) && record["enabled"] == true
      return "scope_unapproved" unless record["scope"] == "phase1_prompt_probe"
      return "provider_unapproved" unless record["provider"] == "anthropic"
      return "models_unapproved" unless record["models"] == MODELS
      return "endpoint_unapproved" unless record["endpoint"] == InterpreterAnthropicAdapter::ENDPOINT
      return "retries_unapproved" unless record["retries"] == 0
      return "attempt_cap_unapproved" unless record["attempt_cap"] == PROBE_ATTEMPT_CAP
      return "money_cap_unapproved" unless record["money_cap_usd"] == format("%.6f", probe_money_cap)
      return "cases_unapproved" unless record["cases"] == [ "phase1" ]
      return "prompts_unapproved" unless record["prompts"] == InterpreterPromptCatalog.catalog
      return "run_id_unapproved" if record["run_id"].blank? || record["run_id"] != run_id

      nil
    end

    def self.env_credential_reads
      @env_credential_reads.to_i
    end

    def self.env_credential
      @env_credential_reads = env_credential_reads + 1
      ENV["ANTHROPIC_API_KEY"].to_s
    end

    def self.credential_status(explicit_key)
      explicit_key.to_s.empty? ? "absent" : "present"
    end

    def self.prepare(evidence_root:, run_id:)
      new(evidence_root: evidence_root, run_id: run_id, lane: "prepared").prepare
    end

    def self.prepare_probe(evidence_root:, run_id:)
      raise Error, "evidence_root_missing" if evidence_root.to_s.empty?

      new(evidence_root: evidence_root, run_id: run_id.presence || "phase1-probe", lane: "prepared").prepare_probe
    end

    def self.rehearse(evidence_root:, run_id:, scenario_id:, model_id:, native:, latency_ms: nil)
      new(evidence_root: evidence_root, run_id: run_id, lane: "stubs").rehearse(
        scenario_id: scenario_id, model_id: model_id, native: native, latency_ms: latency_ms
      )
    end

    def self.execute(evidence_root:, run_id:, approval: nil, transport: nil, credential_source: nil, only: nil, budget_state: nil, ledger_root: nil, scope: "matrix")
      approval ||= scope == "probe" ? probe_approval : self.approval
      new(evidence_root: evidence_root, run_id: run_id, lane: "runs").execute(
        approval: approval,
        transport: transport,
        credential_source: credential_source,
        only: only,
        budget_state: budget_state,
        ledger_root: ledger_root,
        scope: scope
      )
    end

    def self.command(prepare:, authorized:, evidence_root: nil, run_id: nil)
      if prepare
        return blocked_command("evidence_root_missing") if evidence_root.to_s.empty?

        summary = self.prepare(evidence_root: evidence_root, run_id: run_id.presence || "prepared")
        return {
          "exit_code" => 0,
          "output" => summary.merge("status" => "prepared", "credential_read" => false, "provider_call" => false)
        }
      end
      return blocked_command("authorization_absent") unless authorized

      refusal = approval_refusal(approval, run_id: run_id)
      return blocked_command(refusal) if refusal

      summary = execute(evidence_root: evidence_root, run_id: run_id.presence || "run", approval: approval)
      { "exit_code" => 0, "output" => summary }
    rescue Error => error
      blocked_command(error.code)
    end

    def self.judge(row, tool_input, stop_reason: "tool_use", provider_result: "returned", sent_turn: nil)
      new(evidence_root: ".", run_id: "judge", lane: "prepared").send(
        :judge, row, tool_input, stop_reason: stop_reason, provider_result: provider_result, sent_turn: sent_turn
      )
    end

    def self.blocked_command(reason)
      {
        "exit_code" => 2,
        "output" => {
          "status" => "blocked",
          "reason" => reason,
          "live_calls_enabled" => LIVE_CALLS_ENABLED,
          "credential_read" => false,
          "provider_call" => false
        }
      }
    end

    def initialize(evidence_root:, run_id:, lane:)
      raise Error, "lane" unless LANES.include?(lane.to_s)

      @evidence_root = Pathname(evidence_root.to_s)
      @run_id = run_id.to_s
      @lane = lane.to_s
    end

    def prepare
      raise Error, "lane" unless @lane == "prepared"
      raise Error, "run_exists" if run_dir.exist?

      root = run_dir
      FileUtils.mkdir_p(root)
      events = ValidationCapture.capture do
        ValidationCapture.bind(run_id: @run_id)
        record_configuration
        self.class.matrix.each do |row|
          MODELS.each { |model_id| write_blocked(row, model_id, "live_calls_closed") }
        end
      end
      write_capture(root, events)
      { "lane" => @lane, "run_id" => @run_id, "cases" => self.class.matrix.size * MODELS.size, "calls" => 0 }
    end

    def prepare_probe
      raise Error, "lane" unless @lane == "prepared"
      raise Error, "evidence_root_missing" if @run_id.empty? || evidence_root_blank?
      raise Error, "run_exists" if run_dir.exist?

      @scope = "probe"
      root = run_dir
      FileUtils.mkdir_p(root)
      row = self.class.matrix.find { |item| item["id"] == "phase1" }
      combinations = self.class::PROBE_PAIRS.map { |model_id, version|
        built = build(row, model_id, prompt_version: version)
        write_files(
          root.join(row["id"], model_id, version),
          "case.json" => case_payload(row, model_id, built).merge(
            "probe" => "phase1_prompt", "block_reason" => "probe_not_authorized", "calls" => 0
          ),
          "prepared_request.json" => built[:params],
          "client_input.json" => built[:translated]
        )
        {
          "case_id" => row["id"],
          "model_id" => model_id,
          "prompt_version" => version,
          "prompt_sha256" => built[:prompt_sha256],
          "max_tokens" => built[:translated].dig("body", "max_tokens"),
          "temperature" => built[:translated].dig("body", "temperature"),
          "tool_schema_sha256" => Digest::SHA256.hexdigest(JSON.generate(built[:translated].dig("body", "tools"))),
          "message_sha256" => Digest::SHA256.hexdigest(built.dig(:translated, "body", "messages", 0, "content", 0, "text").to_s)
        }
      }
      plan = {
        "authorized" => false,
        "executed" => false,
        "calls" => 0,
        "attempt_cap" => PROBE_ATTEMPT_CAP,
        "money_cap_usd" => format("%.6f", self.class.probe_money_cap),
        "estimate_kind" => "reservation_sum_not_provider_limit",
        "deferred_matrix_calls" => DEFERRED_BOTH_PROMPTS_CALLS,
        "combinations" => combinations,
        "opus_delta" => InterpreterPromptCatalog::OPUS_DELTA,
        "provider_call" => false,
        "credential_read" => false
      }
      File.write(root.join("probe_plan.json"), JSON.pretty_generate(export_value(plan)))
      plan
    end

    def rehearse(scenario_id:, model_id:, native:, latency_ms: nil)
      raise Error, "lane" unless @lane == "stubs"

      row = self.class.matrix.find { |item| item["id"] == scenario_id }
      raise Error, "scenario" unless row
      raise Error, "run_exists" if run_dir.exist?

      root = run_dir
      FileUtils.mkdir_p(root)
      events = ValidationCapture.capture do
        ValidationCapture.bind(run_id: @run_id)
        write_stub(row, model_id, native, latency_ms)
      end
      write_capture(root, events)
      { "lane" => @lane, "provider_call" => false }
    end

    def execute(approval:, transport:, credential_source:, only:, budget_state:, ledger_root: nil, scope: "matrix")
      raise Error, "lane" unless @lane == "runs"

      @scope = scope.to_s
      @active_approval = approval
      @ledger_root = ledger_root
      @claimed = false
      refusal = entry_refusal
      raise Error, refusal if refusal
      raise Error, "evidence_root_missing" if @run_id.empty? || evidence_root_blank?
      raise Error, "run_exists" if run_dir.exist?

      claim_run!(approval)
      source = credential_source || self.class.method(:env_credential)
      key = source.call.to_s
      raise_after_claim("credential_absent") if key.empty?

      client = transport || InterpreterAnthropicTransport.live
      budget = Budget::Ledger.new(budget_state, attempt_cap: attempt_cap_for_scope, money_cap: money_cap_for_scope)
      calls = 0
      failure = nil
      events = []
      root = run_dir
      FileUtils.mkdir_p(root)
      begin
        ValidationCapture.capture do |bucket|
          events = bucket
          ValidationCapture.bind(run_id: @run_id)
          record_configuration(approval)
          each_target(only, budget) do |row, model_id, prompt_version|
            calls += run_authorized_case(row, model_id, client, key, budget, prompt_version: prompt_version)
          end
        end
      rescue Interrupted => error
        failure = error
        budget.close!(error.stage)
      end
      finish_evidence(root, events, budget, client, failure)
      {
        "lane" => @lane,
        "run_id" => @run_id,
        "scope" => @scope,
        "status" => execution_status(budget, calls),
        "calls" => calls,
        "attempts" => budget.attempts,
        **budget.cost_fields,
        "closed" => budget.closed?,
        "close_reason" => budget.close_reason,
        "provider_call" => transport_live?(client),
        "evidence_complete" => true,
        "credential_read" => true
      }
    ensure
      close_claim!(@quota_close_reason || failure&.stage || "failed")
    end

    private

    def evidence_root_blank?
      text = @evidence_root.to_s
      text.empty? || text == "."
    end

    def selected_rows(only)
      return self.class.matrix if only.nil?

      ids = Array(only)
      rows = ids.filter_map { |id| self.class.matrix.find { |row| row["id"] == id } }
      raise Error, "scenario" if rows.size != ids.size

      rows
    end

    def each_target(only, budget)
      targets(only).each do |row, model_id, prompt_version|
        break if budget.closed?

        yield row, model_id, prompt_version
      end
    end

    def targets(only)
      if @scope == "probe"
        row = self.class.matrix.find { |item| item["id"] == "phase1" }
        return self.class::PROBE_PAIRS.map { |model_id, version| [ row, model_id, version ] }
      end

      selected_rows(only).flat_map { |row| MODELS.map { |model_id| [ row, model_id, "original" ] } }
    end

    def entry_refusal
      if @scope == "probe"
        self.class.probe_refusal(@active_approval, run_id: @run_id)
      else
        self.class.approval_refusal(@active_approval, run_id: @run_id)
      end
    end

    def attempt_cap_for_scope
      @scope == "probe" ? PROBE_ATTEMPT_CAP : Budget::ATTEMPT_CAP
    end

    def money_cap_for_scope
      @scope == "probe" ? self.class.probe_money_cap : Budget::MONEY_CAP
    end

    def raise_after_claim(code)
      @quota_close_reason = code
      raise Error, code
    end

    def claim_run!(approval)
      path = ledger_file
      FileUtils.mkdir_p(path.dirname)
      body = JSON.generate(
        "run_id" => @run_id,
        "scope" => @scope,
        "status" => "consumed",
        "attempt_cap" => approval["attempt_cap"],
        "money_cap_usd" => approval["money_cap_usd"],
        "matrix_sha256" => approval["matrix_sha256"],
        "prompts" => approval["prompts"]
      )
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(body) }
      @claimed = true
    rescue Errno::EEXIST
      raise Error, "authorization_consumed"
    end

    def close_claim!(reason)
      return unless @claimed

      path = ledger_file
      payload = JSON.parse(path.read)
      payload["status"] = "closed"
      payload["close_reason"] = @quota_close_reason || reason
      File.write(path, JSON.generate(payload))
    rescue StandardError
      nil
    end

    def ledger_file
      root = @ledger_root.nil? ? self.class.default_ledger_root : Pathname(@ledger_root.to_s)
      digest = Digest::SHA256.hexdigest("#{@scope}:#{@run_id}")
      root.join("#{digest}.json")
    end

    def self.default_ledger_root
      Rails.root.join("tmp/interpreter_anthropic_quota")
    end

    def live_grant
      return nil if entry_refusal
      return nil unless @claimed

      { "granted" => true, "run_id" => @run_id }
    end

    def remember_known_cost!(budget, model_id, result)
      usage = result&.payload.is_a?(Hash) ? result.payload["usage"] : nil
      budget.record_cost!(InterpreterAnthropicAdapter.price(model_id, usage))
    end

    def interrupt!(stage, error, budget)
      budget.close_for_evidence!(stage)
      ValidationCapture.record(
        "experiment_evidence",
        "result" => "incomplete",
        "stage" => stage,
        "error_class" => error.class.name,
        "reason" => InterpreterAnthropicAdapter.scrub_text(error.message.to_s).truncate(180),
        "provider_call" => false,
        "lane" => @lane
      )
      raise Interrupted.new(stage, error)
    end

    def finish_evidence(root, events, budget, client, failure)
      capture_error = nil
      begin
        write_capture(root, events)
      rescue StandardError => error
        capture_error = error
      end
      reported = failure || (capture_error && Interrupted.new("export", capture_error))
      state_error = nil
      begin
        write_state(root, budget, client, failure: reported)
      rescue StandardError => error
        state_error = error
      end
      marker_error = nil
      if reported
        begin
          write_incomplete_marker(root, reported, capture_error, state_error, budget)
        rescue StandardError => error
          marker_error = error
        end
      end
      if failure
        failure.emergency_write_failed = marker_error.present? && (capture_error || state_error)
        failure.cost_note = budget.cost_fields.map { |key, value| "#{key}=#{value}" }.join(";")
        @quota_close_reason = failure.stage
        raise failure
      end
      if capture_error
        @quota_close_reason = "export"
        raise capture_error
      end
      raise Error, "evidence_incomplete" if state_error

      @quota_close_reason = budget.closed? ? budget.close_reason : "completed"
      nil
    end

    def write_incomplete_marker(root, reported, capture_error, state_error, budget)
      FileUtils.mkdir_p(root)
      File.write(root.join("evidence_incomplete.json"), JSON.generate(
        {
          "evidence_complete" => false,
          "failure_stage" => reported.stage,
          "error_class" => reported.original.class.name,
          "capture_saved" => capture_error.nil?,
          "state_saved" => state_error.nil?,
          "emergency_write_failed" => false
        }.merge(budget.cost_fields)
      ))
    end

    def run_authorized_case(row, model_id, client, api_key, budget, prompt_version: "original")
      if transport_live?(client) && live_grant.nil?
        budget.close!("execution_not_approved")
        return 0
      end

      built = build(row, model_id, prompt_version: prompt_version)
      sent_turn = built.dig(:message, "turn").to_s
      block = budget.reserve!(model_id)
      if block
        budget.close!(block) if block == "attempt_cap" || block == "cost_incomplete"
        write_blocked(row, model_id, block, prompt_version: prompt_version)
        return 0
      end

      ValidationCapture.with_turn(correlation(row, model_id, prompt_version)) do
        ValidationCapture.attempt = budget.attempts
        record_prepared_request(row, model_id, built, client)
        ValidationCapture.record(
          "interpreter_attempt",
          "stage" => "converse",
          "result" => "attempt_started",
          "operation" => "interpreter_experiment",
          "provider" => "anthropic",
          "model_id" => model_id,
          "case_id" => row["id"],
          "prompt_version" => prompt_version,
          "prompt_sha256" => built[:prompt_sha256],
          "provider_call" => transport_live?(client),
          "transport" => transport_name(client),
          "lane" => "runs",
          "endpoint" => InterpreterAnthropicAdapter::ENDPOINT
        )
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = post_once(client, built, api_key)
        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        begin
          outcome = interpret_transport(result)
        rescue StandardError => error
          remember_known_cost!(budget, model_id, result)
          interrupt!("normalize", error, budget)
        end
        budget.reconcile!(model_id, provider_result: outcome[:provider_result], usage: outcome[:usage])
        judgment = judgment_for(row, outcome, sent_turn)
        record_terminal(outcome, judgment, client)
        begin
          write_files(
            case_dir(row, model_id, prompt_version),
            call_files(row, model_id, built, outcome, judgment, latency_ms, client)
          )
        rescue StandardError => error
          interrupt!("write_files", error, budget)
        end
      end
      1
    end

    def post_once(client, built, api_key)
      kwargs = {
        endpoint: InterpreterAnthropicAdapter::ENDPOINT,
        headers: {
          "content-type" => "application/json",
          "anthropic-version" => InterpreterAnthropicAdapter::ANTHROPIC_VERSION,
          "x-api-key" => api_key
        },
        body: built[:translated]["body"],
        open_timeout: InterpreterAnthropicTransport::OPEN_TIMEOUT_SECONDS,
        read_timeout: InterpreterAnthropicTransport::READ_TIMEOUT_SECONDS
      }
      kwargs[:authorization] = live_grant if client.is_a?(InterpreterAnthropicTransport) && client.live?
      client.post(**kwargs)
    rescue StandardError => error
      InterpreterAnthropicTransport::Result.new(
        http_status: nil,
        payload: nil,
        error_code: "transport_error",
        error_message: InterpreterAnthropicAdapter.scrub_text(error.message.to_s).truncate(180)
      )
    end

    def judgment_for(row, outcome, sent_turn)
      if outcome[:provider_result] == "error"
        incomplete_judgment("provider_error", outcome[:stop_reason])
      else
        judge(
          row, outcome[:tool_input],
          stop_reason: outcome[:stop_reason], provider_result: "returned", sent_turn: sent_turn
        )
      end
    end

    def run_dir
      @evidence_root.join(@lane, @run_id)
    end

    def write_blocked(row, model_id, reason, prompt_version: "original")
      built = build(row, model_id, prompt_version: prompt_version)
      dir = case_dir(row, model_id, prompt_version)
      ValidationCapture.with_turn(correlation(row, model_id, prompt_version)) do
        ValidationCapture.record(
          "interpreter_request",
          "stage" => "converse",
          "result" => "prepared",
          "operation" => "interpreter_experiment",
          "provider" => "anthropic",
          "model_id" => model_id,
          "case_id" => row["id"],
          "lane" => @lane,
          "provider_call" => false,
          "request" => export_value(built[:params]),
          "client_input" => export_value(built[:translated])
        )
        ValidationCapture.record(
          "model_call",
          "operation" => "interpreter_experiment",
          "result" => "blocked",
          "reason" => reason,
          "provider_call" => false,
          "lane" => @lane,
          "case_id" => row["id"],
          "model_id" => model_id
        )
      end
      write_files(dir, blocked_files(row, model_id, built, reason))
    end

    def write_stub(row, model_id, native, latency_ms)
      built = build(row, model_id)
      outcome = interpret_native(native)
      sent_turn = built.dig(:message, "turn").to_s
      judgment = judgment_for(row, outcome, sent_turn)
      dir = case_dir(row, model_id)
      ValidationCapture.with_turn(correlation(row, model_id)) do
        ValidationCapture.record(
          "interpreter_request",
          "stage" => "converse",
          "result" => "prepared",
          "operation" => "interpreter_experiment",
          "provider" => "anthropic",
          "model_id" => model_id,
          "case_id" => row["id"],
          "lane" => "stubs",
          "provider_call" => false,
          "transport" => "injected_native"
        )
        record_observed(outcome, judgment, live: false, transport: "injected_native")
      end
      write_files(dir, stub_files(row, model_id, built, outcome, judgment, latency_ms))
    end

    def record_prepared_request(row, model_id, built, client)
      ValidationCapture.record(
        "interpreter_request",
        "stage" => "converse",
        "result" => "prepared",
        "operation" => "interpreter_experiment",
        "provider" => "anthropic",
        "model_id" => model_id,
        "case_id" => row["id"],
        "lane" => "runs",
        "provider_call" => transport_live?(client),
        "transport" => transport_name(client),
        "request" => export_value(built[:params]),
        "client_input" => export_value(built[:translated])
      )
    end

    def record_terminal(outcome, judgment, client)
      record_observed(outcome, judgment, live: transport_live?(client), transport: transport_name(client))
    end

    def record_observed(outcome, judgment, live:, transport:)
      if outcome[:error]
        ValidationCapture.record(
          "interpreter_failure",
          "stage" => "converse",
          "result" => "error",
          "operation" => "interpreter_experiment",
          "error_class" => outcome[:error].class.name,
          "reason" => outcome[:error].message,
          "provider_call" => live,
          "transport" => transport,
          "lane" => @lane
        )
      else
        ValidationCapture.record(
          "interpreter_response",
          "stage" => "extract",
          "result" => "returned",
          "operation" => "interpreter_experiment",
          "provider_call" => live,
          "transport" => transport,
          "lane" => @lane,
          "stop_reason" => outcome[:stop_reason],
          "response" => export_value(outcome[:observed].native)
        )
        ValidationCapture.record(
          "interpreter_raw",
          "stage" => "extract",
          "result" => outcome[:tool_input].nil? ? "empty" : "tool_input",
          "tool_input" => export_value(outcome[:tool_input]),
          "provider_call" => live,
          "transport" => transport,
          "lane" => @lane
        )
      end
      ValidationCapture.record(
        "experiment_judgment",
        "result" => judgment["judgment"],
        "classification" => judgment["classification"],
        "reason" => judgment["reason"],
        "stop_reason" => judgment["stop_reason"],
        "validation" => export_value(judgment["validation"]),
        "provider_call" => live,
        "transport" => transport,
        "lane" => @lane
      )
    end

    def interpret_native(native)
      observed = InterpreterAnthropicAdapter.normalize(native)
      {
        observed: observed,
        tool_input: InterpreterAnthropicAdapter.tool_input(observed.output.message.content),
        error: nil,
        usage: observed.normalized["usage"],
        stop_reason: observed.stop_reason,
        provider_result: "returned"
      }
    rescue InterpreterAnthropicAdapter::ProviderError => error
      {
        observed: nil,
        tool_input: nil,
        error: error,
        usage: error.native.is_a?(Hash) ? error.native["usage"] : nil,
        stop_reason: nil,
        provider_result: "error"
      }
    end

    def interpret_transport(result)
      if result.nil? || result.error_code
        payload = result&.payload
        return transport_failure(error_from_transport(result), payload)
      end

      observed = InterpreterAnthropicAdapter.normalize(result.payload)
      {
        observed: observed,
        tool_input: InterpreterAnthropicAdapter.tool_input(observed.output.message.content),
        error: nil,
        usage: observed.normalized["usage"],
        stop_reason: observed.stop_reason,
        provider_result: "returned"
      }
    rescue InterpreterAnthropicAdapter::ProviderError => error
      transport_failure(error, result.payload)
    end

    def transport_failure(error, payload)
      {
        observed: nil,
        tool_input: nil,
        error: error,
        usage: payload.is_a?(Hash) ? payload["usage"] : nil,
        stop_reason: nil,
        provider_result: "error"
      }
    end

    def error_from_transport(result)
      payload = result&.payload
      if payload.is_a?(Hash) && (payload["type"] == "error" || payload["error"].is_a?(Hash))
        return InterpreterAnthropicAdapter::ProviderError.new(payload)
      end

      InterpreterAnthropicAdapter::Error.new(result&.error_code || "transport_error", result&.error_message)
    end

    def build(row, model_id, prompt_version: "original")
      params = converse_params(row, prompt_version)
      translated = InterpreterAnthropicAdapter.translate(params, model_id: model_id)
      prompt = translated.dig("body", "system", 0, "text")
      expected = InterpreterPromptCatalog.text(prompt_version)
      raise Error, "prompt_drift" unless prompt == expected
      raise Error, "max_tokens" unless translated.dig("body", "max_tokens") == TurnInterpreter::MAX_TOKENS
      unless InterpreterAnthropicAdapter::ACCEPTED_MODELS.include?(translated.dig("body", "model"))
        raise Error, "model_rejected"
      end

      {
        params: params,
        translated: translated,
        message: message_payload(translated),
        prompt_version: prompt_version,
        prompt_sha256: InterpreterPromptCatalog.sha256(prompt_version)
      }
    end

    def converse_params(row, prompt_version = "original")
      params = TurnInterpreter.new(
        turn: row["text"],
        episode: episode_for(row["context"]),
        viewer_account: nil,
        correlation_id: "interpreter-experiment:#{row["id"]}",
        attribution: nil,
        client: :closed,
        catalog: :closed
      ).send(:converse_params)
      params[:system] = [ { text: InterpreterPromptCatalog.text(prompt_version) } ]
      params
    end

    def episode_for(context)
      episode = ActiveEpisode.new
      return episode if context == "empty"

      episode.episode_id = ACTIVE_CONTEXT_ID
      episode.assign_goal!(ACTIVE_GOAL, correlation_id: "interpreter-experiment")
      episode.append_observation!(ACTIVE_GOAL, correlation_id: "interpreter-experiment")
      episode
    end

    def message_payload(translated)
      text = translated.dig("body", "messages", 0, "content", 0, "text").to_s
      parsed = JSON.parse(text)
      parsed.is_a?(Hash) ? parsed : { "provenance" => "uncaptured" }
    rescue JSON::ParserError
      { "provenance" => "uncaptured" }
    end

    def blocked_files(row, model_id, built, reason)
      {
        "case.json" => case_payload(row, model_id, built).merge("block_reason" => reason),
        "prepared_request.json" => built[:params],
        "client_input.json" => built[:translated],
        "native_response.json" => { "provenance" => "not_executed", "reason" => reason },
        "normalized.json" => { "provenance" => "not_executed" },
        "tool_input.json" => { "tool_input" => nil, "provenance" => "not_executed" },
        "judgment.json" => expected_and_observed(row, nil, not_judged("not_called")),
        "usage.json" => usage_payload(model_id, nil, nil, "not_called", [])
      }
    end

    def stub_files(row, model_id, built, outcome, judgment, latency_ms)
      files_for(row, model_id, built, outcome, judgment, latency_ms, provider_call: false, transport: "injected_native")
    end

    def call_files(row, model_id, built, outcome, judgment, latency_ms, client)
      files_for(
        row, model_id, built, outcome, judgment, latency_ms,
        provider_call: transport_live?(client), transport: transport_name(client)
      )
    end

    def files_for(row, model_id, built, outcome, judgment, latency_ms, provider_call:, transport:)
      usage = outcome_usage(outcome)
      if outcome[:error]
        native = outcome[:error].respond_to?(:native) ? outcome[:error].native : nil
        native ||= { "provenance" => "transport_error", "code" => outcome[:error].code }
        normalized = { "provenance" => "not_normalized", "reason" => "provider_error" }
        errors = [ { "code" => outcome[:error].code } ]
        errors[0]["error_type"] = outcome[:error].error_type if outcome[:error].respond_to?(:error_type)
        status = "error"
      else
        native = outcome[:observed].native
        normalized = outcome[:observed].normalized
        errors = []
        status = "returned"
      end
      {
        "case.json" => case_payload(row, model_id, built).merge(
          "transport" => transport, "provider_result" => status, "provider_call" => provider_call
        ),
        "prepared_request.json" => built[:params],
        "client_input.json" => built[:translated],
        "native_response.json" => native,
        "normalized.json" => normalized,
        "tool_input.json" => { "tool_input" => outcome[:tool_input], "provider_call" => provider_call },
        "judgment.json" => expected_and_observed(row, outcome[:tool_input], judgment).merge(
          "provider_result" => status, "provider_call" => provider_call
        ),
        "usage.json" => usage_payload(model_id, usage, latency_ms, status, errors)
      }
    end

    def outcome_usage(outcome)
      return outcome[:usage] if outcome[:usage].is_a?(Hash)
      return nil unless outcome[:error].respond_to?(:native) && outcome[:error].native.is_a?(Hash)

      outcome[:error].native["usage"]
    end

    def case_payload(row, model_id, built)
      {
        "id" => row["id"],
        "context" => {
          "id" => row["context"],
          "persisted" => false,
          "episode_id" => row["context"] == "active" ? ACTIVE_CONTEXT_ID : nil,
          "work_context" => built[:message]["work_context"]
        },
        "pair_of" => row["pair_of"],
        "text" => row["text"],
        "sent_turn" => built.dig(:message, "turn"),
        "provider" => "anthropic",
        "endpoint" => InterpreterAnthropicAdapter::ENDPOINT,
        "model_id" => model_id,
        "run_id" => @run_id,
        "prompt_version" => built[:prompt_version],
        "prompt_sha256" => built[:prompt_sha256],
        "lane" => @lane,
        "provider_call" => false,
        "live_calls_enabled" => LIVE_CALLS_ENABLED,
        "exports" => {
          "native_response" => {
            "provenance" => "sanitized_export",
            "transformations" => %w[drop_secret_keys redact_secret_text]
          },
          "normalized" => {
            "provenance" => "normalized_then_sanitized_export",
            "normalization" => %w[stringify_keys map_content_blocks],
            "export" => %w[drop_secret_keys redact_secret_text]
          }
        }
      }
    end

    def expected_and_observed(row, tool_input, judgment)
      {
        "expected" => {
          "disposition" => row["disposition"],
          "allowed_moves" => row["allowed_moves"],
          "forbidden_moves" => row["forbidden_moves"],
          "justification" => row["justification"]
        },
        "observed" => tool_input,
        "judgment" => judgment["judgment"],
        "classification" => judgment["classification"],
        "reason" => judgment["reason"],
        "stop_reason" => judgment["stop_reason"],
        "validation" => judgment["validation"]
      }
    end

    def usage_payload(model_id, usage, latency_ms, status, errors)
      priced = InterpreterAnthropicAdapter.price(model_id, usage)
      if status == "not_called"
        priced["cost_status"] = "not_called"
        priced["cost_usd"] = nil
      end
      priced["latency_ms"] = latency_ms
      priced["errors"] = errors
      priced["provider_result"] = status
      priced
    end

    def judge(row, tool_input, stop_reason:, provider_result:, sent_turn:)
      sent = sent_turn.nil? ? row["text"].to_s : sent_turn.to_s
      return not_judged("not_called") if provider_result == "not_called"
      return incomplete_judgment("provider_error", stop_reason) if provider_result == "error"
      return incomplete_judgment("max_tokens", stop_reason) if stop_reason.to_s == "max_tokens"
      if %w[refusal stop_sequence pause_turn].include?(stop_reason.to_s)
        return incomplete_judgment(stop_reason.to_s, stop_reason)
      end
      unless provider_result == "returned" && tool_input.is_a?(Hash) && %w[tool_use end_turn].include?(stop_reason.to_s)
        reason = tool_input.nil? ? (stop_reason.nil? ? "empty_response" : "tool_absent") : "stop_not_complete"
        return incomplete_judgment(reason, stop_reason)
      end

      validation = InterpreterPayloadContract.evaluate(tool_input, sent_turn: sent)
      unless validation["valid"]
        return fail_judgment(validation["reason"], "contract_failure", stop_reason, validation)
      end
      if row["forbidden_moves"].include?(tool_input["move"])
        return fail_judgment("forbidden_move", "interpretation_failure", stop_reason, validation)
      end
      if contaminated_observations?(row, tool_input)
        return fail_judgment("observation_on_non_symptom", "interpretation_failure", stop_reason, validation)
      end
      if contaminated_assertions?(row, tool_input)
        return fail_judgment("assertion_on_non_symptom", "interpretation_failure", stop_reason, validation)
      end
      unless row["allowed_moves"].include?(tool_input["move"])
        return fail_judgment("move_outside_contract", "interpretation_failure", stop_reason, validation)
      end
      return review_judgment(stop_reason, validation) if row["disposition"] == "review"

      pass_judgment(stop_reason, validation)
    end

    def contaminated_observations?(row, tool_input)
      row["empty_observations"] && tool_input["observations"].any? { |item| item.to_s.strip != "" }
    end

    def contaminated_assertions?(row, tool_input)
      row["empty_assertions"] && tool_input["assertions"].any?
    end

    def not_judged(reason)
      {
        "judgment" => "not_judged",
        "classification" => "not_judged",
        "reason" => reason,
        "stop_reason" => nil,
        "validation" => nil
      }
    end

    def incomplete_judgment(reason, stop_reason)
      {
        "judgment" => "incomplete",
        "classification" => "incomplete_response",
        "reason" => reason,
        "stop_reason" => stop_reason,
        "validation" => nil
      }
    end

    def fail_judgment(reason, classification, stop_reason, validation)
      {
        "judgment" => "fail",
        "classification" => classification,
        "reason" => reason,
        "stop_reason" => stop_reason,
        "validation" => validation
      }
    end

    def review_judgment(stop_reason, validation)
      {
        "judgment" => "review",
        "classification" => "pending_review",
        "reason" => "ambiguous_case",
        "stop_reason" => stop_reason,
        "validation" => validation
      }
    end

    def pass_judgment(stop_reason, validation)
      {
        "judgment" => "pass",
        "classification" => "pass",
        "reason" => "allowed_move",
        "stop_reason" => stop_reason,
        "validation" => validation
      }
    end

    def record_configuration(approval = nil)
      ValidationCapture.record(
        "experiment_configuration",
        "result" => "prepared",
        "operation" => "interpreter_experiment",
        "provider" => "anthropic",
        "endpoint" => InterpreterAnthropicAdapter::ENDPOINT,
        "models" => MODELS,
        "live_calls_enabled" => LIVE_CALLS_ENABLED,
        "execution_approved" => approval.is_a?(Hash) && approval["enabled"] == true,
        "attempt_cap" => attempt_cap_for_scope,
        "money_cap_usd" => format("%.6f", money_cap_for_scope),
        "matrix_sha256" => self.class.matrix_sha256,
        "approved_matrix_sha256" => APPROVED_MATRIX_SHA256,
        "input_reservation" => Budget::INPUT_RESERVATION,
        "reservation_kind" => "estimate_not_provider_limit",
        "retries" => InterpreterAnthropicTransport::RETRIES,
        "open_timeout_seconds" => InterpreterAnthropicTransport::OPEN_TIMEOUT_SECONDS,
        "read_timeout_seconds" => InterpreterAnthropicTransport::READ_TIMEOUT_SECONDS,
        "sources" => InterpreterAnthropicAdapter::SOURCES,
        "consulted_on" => InterpreterAnthropicAdapter::CONSULTED_ON,
        "provider_call" => false,
        "prompts" => InterpreterPromptCatalog.catalog,
        "active_scope" => @scope || "prepared"
      )
    end

    def write_state(root, budget, client, failure: nil)
      File.write(root.join("execution_state.json"), JSON.pretty_generate(
        "run_id" => @run_id,
        "scope" => @scope,
        "attempts" => budget.attempts,
        **budget.cost_fields,
        "closed" => budget.closed?,
        "close_reason" => budget.close_reason,
        "evidence_complete" => failure.nil?,
        "failure_stage" => failure&.stage,
        "error_class" => failure&.original&.class&.name,
        "matrix_sha256" => self.class.matrix_sha256,
        "approved_matrix_sha256" => APPROVED_MATRIX_SHA256,
        "attempt_cap" => attempt_cap_for_scope,
        "money_cap_usd" => format("%.6f", money_cap_for_scope),
        "provider" => "anthropic",
        "provider_call" => transport_live?(client)
      ))
    end

    def write_capture(root, events)
      document = ValidationCapture.export_capture(events, root, run_id: @run_id)
      File.write(root.join("capture.json"), JSON.pretty_generate(document))
    rescue StandardError => error
      begin
        FileUtils.mkdir_p(root)
        File.write(root.join("export_failed.json"), JSON.generate(
          "evidence_complete" => false, "reason" => "export_failed", "error_class" => error.class.name
        ))
      rescue StandardError
        nil
      end
      raise Error, "export_failed"
    end

    def write_files(dir, files)
      FileUtils.mkdir_p(dir)
      files.each do |name, value|
        File.write(dir.join(name), JSON.pretty_generate(export_value(value)))
      end
    end

    def export_value(value)
      InterpreterAnthropicAdapter.scrub(json_ready(value))
    end

    def json_ready(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key.to_s] = json_ready(item) }
      when Array
        value.map { |item| json_ready(item) }
      when BigDecimal
        format("%.6f", value)
      when Symbol
        value.to_s
      else
        value
      end
    end

    def case_dir(row, model_id, prompt_version = "original")
      dir = run_dir.join(row["id"], model_id)
      return dir unless @scope == "probe"

      dir.join(prompt_version)
    end

    def correlation(row, model_id, prompt_version = "original")
      base = "interpreter-experiment:#{row["id"]}:#{model_id}"
      return base if prompt_version == "original" && @scope != "probe"

      "#{base}:#{prompt_version}"
    end

    def execution_status(budget, calls)
      return "stopped" if budget.closed?
      return "blocked" if calls.zero?

      "completed"
    end

    def transport_live?(client)
      client.respond_to?(:live?) && client.live?
    end

    def transport_name(client)
      transport_live?(client) ? "anthropic_https" : "stub"
    end

    def self.build_matrix
      technical = { "disposition" => "score", "allowed_moves" => %w[report],
                    "forbidden_moves" => %w[meta follow_up answer_pending correct new_work unclear],
                    "empty_observations" => false, "empty_assertions" => false }
      meta = { "disposition" => "score", "allowed_moves" => %w[meta],
               "forbidden_moves" => %w[report follow_up answer_pending correct new_work unclear],
               "empty_observations" => true, "empty_assertions" => true }
      [
        row("phase1", PHASE1_TEXT, "empty", technical,
            "Declara un trabajo y pregunta por el equipo. Sin trabajo abierto, el contrato usa report. " \
            "meta queda prohibido. La etiqueta no alcanza: el payload cumple el esquema y, si trae spans " \
            "u observaciones, son literales del texto enviado. Una observación no es obligatoria."),
        row("variador", "El variador no arranca", "empty", technical,
            "Declara una falla. El contrato usa report. meta queda prohibido."),
        row("saludo_variador", "Buenas tardes. El variador no arranca", "empty", technical,
            "El saludo no borra la falla. report. meta queda prohibido. Par de variador con saludo.",
            pair_of: "variador"),
        row("oferta_variador", "Puedo enviarte una foto. El variador no arranca", "empty", technical,
            "La oferta no borra la falla. report. meta queda prohibido. Par de variador con oferta.",
            pair_of: "variador"),
        row("circuito", "Según el manual, ¿cómo funciona el circuito de seguridad?", "empty", technical,
            "Pregunta por el equipo. No pregunta qué necesita Danebo. report. meta queda prohibido. " \
            "No exige observación."),
        row("kse", "¿Para qué sirve el contacto KSE según el plano?", "empty", technical,
            "Una pregunta por un designador es report, como «¿Qué es Q2?». meta queda prohibido. " \
            "No exige observación. Un span, si viene, es literal."),
        row("foto_variador", "Te envío una foto: el variador no arranca", "empty", technical,
            "La misma frase trae una falla. La oferta no la borra. report. meta queda prohibido."),
        row("necesitas_motor", "¿Qué necesitas para investigar por qué el motor se detiene?", "empty", technical,
            "Pregunta qué hace falta y declara que el motor se detiene. El contrato no deja esa falla en meta."),
        row("foto_fallas", "Puedo enviarte una foto de las fallas que muestra el display", "empty",
            review_case(%w[meta report unclear], %w[follow_up answer_pending correct new_work],
                        observations: false, assertions: false),
            "Oferta de una lectura de display. El prompt manda meta si no hay falla y clasificación normal " \
            "si la misma frase trae una falla. «las fallas que muestra el display» no fija cuál de las dos es. " \
            "Revisión. No cuenta como acierto ni como superioridad de un modelo."),
        row("perfecto", "Perfecto, entendido", "empty", review_admin(%w[meta unclear]),
            "No declara trabajo ni falla. El prompt no la nombra. Revisión. " \
            "Falla si escribe trabajo, observación o aserción."),
        row("buenas_tardes", "Buenas tardes", "empty", meta,
            "Saludo sin contenido técnico. meta, sin observación ni aserción."),
        row("necesitas_mande", "¿Qué necesitas que te mande?", "empty", meta,
            "Pregunta qué debe enviar, sin falla. meta, sin observación ni aserción."),
        row("puedo_foto", "Puedo enviarte una foto", "empty", meta,
            "Oferta sola de una foto, sin falla. meta, sin observación ni aserción."),
        row("puedo_fotos", "Puedo enviarte unas fotos", "empty", meta,
            "Oferta sola, en plural, sin falla. meta. Par de puedo_foto.", pair_of: "puedo_foto"),
        row("como_uso", "¿Cómo uso Danebo?", "empty", review_admin(%w[meta unclear]),
            "No es una pregunta de equipo ni declara una falla. El prompt no la nombra. Revisión."),
        row("como_selecciono", "¿Cómo selecciono un manual?", "empty", review_admin(%w[meta unclear]),
            "Operación del producto, no del equipo. El prompt no la nombra. Revisión."),
        row("donde_veo_plano", "¿Dónde veo el plano seleccionado?", "empty",
            review_case(%w[meta report unclear], %w[follow_up answer_pending correct new_work],
                        observations: true, assertions: false),
            "Puede ser la pantalla de Danebo o el plano. Revisión. Una observación inventada falla. " \
            "No se exige una observación para aprobar un report."),
        row("foto_resumen", "Te mando una foto y el resumen de lo que vi", "empty", meta,
            "Oferta inicial de foto y de un resumen, sin la falla y sin el contenido del resumen. " \
            "meta, sin observación ni aserción. No es un pedido ni una respuesta de resumen con un trabajo abierto."),
        row("puerta_singular", "La puerta no cierra", "empty", technical,
            "Declara una falla, en singular. report. meta queda prohibido."),
        row("puertas_plural", "Las puertas no cierran", "empty", technical,
            "La misma falla, en plural. report. meta queda prohibido. Par de puerta_singular.",
            pair_of: "puerta_singular"),
        row("phase1_active", PHASE1_TEXT, "active",
            { "disposition" => "score", "allowed_moves" => %w[follow_up report],
              "forbidden_moves" => %w[meta new_work answer_pending correct unclear],
              "empty_observations" => false, "empty_assertions" => false },
            "El trabajo abierto es esa puerta. follow_up o report respetan el contrato. meta y new_work no. " \
            "La etiqueta no alcanza sin un payload literal."),
        row("variador_active", "El variador no arranca", "active",
            review_case(%w[report follow_up new_work unclear], %w[meta answer_pending correct],
                        observations: false, assertions: false),
            "El variador puede ser otro trabajo o parte del de la puerta. Revisión. meta falla. " \
            "No cuenta como acierto."),
        row("perfecto_active", "Perfecto, entendido", "active",
            review_case(%w[meta unclear follow_up], %w[report new_work answer_pending correct],
                        observations: true, assertions: true),
            "No sustituye el objetivo. Revisión. report, new_work o una observación fallan."),
        row("necesitas_active", "¿Qué necesitas que te mande?", "active", meta,
            "Pregunta qué enviar, sin falla. meta, sin observación. No abre otro trabajo."),
        row("resumen_pedido_active", "¿Me haces un resumen de lo que vimos?", "active",
            { "disposition" => "score", "allowed_moves" => %w[follow_up],
              "forbidden_moves" => %w[meta report new_work answer_pending correct unclear],
              "empty_observations" => true, "empty_assertions" => true },
            "Pide el resumen del trabajo ya abierto. No ofrece una foto ni entrega el contenido. follow_up. " \
            "No es la oferta inicial «Te mando una foto y el resumen de lo que vi», que sigue en meta.")
      ]
    end

    def self.row(id, text, context, rules, justification, pair_of: nil)
      copied = rules.merge(
        "id" => id,
        "text" => text,
        "context" => context,
        "pair_of" => pair_of,
        "justification" => justification
      )
      copied["allowed_moves"] = copied["allowed_moves"].dup
      copied["forbidden_moves"] = copied["forbidden_moves"].dup
      copied.freeze
    end

    def self.review_admin(allowed)
      review_case(allowed, TurnPerception::MOVES - allowed, observations: true, assertions: true)
    end

    def self.review_case(allowed, forbidden, observations:, assertions:)
      {
        "disposition" => "review",
        "allowed_moves" => allowed,
        "forbidden_moves" => forbidden,
        "empty_observations" => observations,
        "empty_assertions" => assertions
      }
    end
    private_class_method :build_matrix, :row, :review_admin, :review_case, :blocked_command
  end
end
