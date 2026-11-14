# frozen_string_literal: true

module Rag
  # File-backed ceiling for one local assignment. A later process reads the
  # same file. There is no reset: the caller does not delete the file, and a
  # new process does not start the counters at zero.
  class AssignmentSpend
    Stop = Class.new(Exception)
    # One recorded step. 150 -> 152, then 152 -> 164, then 164 -> 166,
    # then 166 -> 174, then 174 -> 175, then 175 -> 180, then 180 -> 185,
    # then 185 -> 194, then 194 -> 196, then 196 -> 211. The 194 step is the
    # seven verified calls that never reached this file plus two T3 replay
    # attempts. The 196 step is two more T3 calls at US$0.028300 each. The
    # 211 step is the authorized direct guion: the one free call already on
    # the file plus fifteen, sixteen in total, six for guion 2 and ten for
    # guion 1. The 213 step is two more attempts for the Sonnet 4.5
    # comparison, three calls in total and no retry. The 229 step is the
    # case-record pass: sixteen calls, eight turns, interpreter and
    # generation, no retry. The 245 step is the Sonnet 4.5 case-record
    # pass: sixteen new ledger calls and no retry. The 295 step is the
    # Haiku 5.5 direct pass: G2, G1, and the reserved Elemont script, with
    # one corrective repetition, fifty ledger calls. The 311 step is the
    # second Haiku 5.5 grant: G1 and Elemont, eighteen calls. The 320 step is
    # the third: Elemont and one network rerun, sixteen calls. The 328 step
    # is the fourth: one Elemont T1–T4 run, eight calls. The 1000 step is
    # the live HTTP validation of Haiku 5.5 (Lahiri, 2026-11-10): US$2.29 of
    # new spend, priced at the documented Haiku 5.5 rate, so the dollar
    # successor at 326 is the real limit. The 1015 step is the live
    # validation of 79723a5 (Lahiri, 2026-11-12): sixteen new calls above
    # attempt 999, no retry. The monetary cap does not move. The 1034 step is
    # the live validation of a200991 (Lahiri, 2026-11-12): the 2,5 case and
    # guion 3, each planned twice, twenty new calls above attempt 1014.
    # The 1190 step is the field validation: ten acceptance calls and
    # thirty-seven regression calls above attempt 1143. The dollar cap stays
    # US$4. Anything else stays.
    CALL_CAP_BUMPS = { 150 => 152, 152 => 164, 164 => 166, 166 => 174, 174 => 175, 175 => 180, 180 => 185, 185 => 194, 194 => 196, 196 => 211, 211 => 213, 213 => 229, 229 => 245, 245 => 295, 295 => 311, 311 => 320, 320 => 328, 328 => 1000, 1000 => 1015, 1015 => 1034, 1034 => 1054, 1054 => 1158, 1158 => 1190 }.freeze
    # A later dollar grant. It does not rewrite authorization.cost_usd.
    # It applies only to entry ids above its attempt, and only when the
    # admitted execution matches this cost and this call count. 229 is the
    # Sonnet 4.5 pass: US$1.17. The window counts eighteen entries because
    # two rows were already stored above attempt 229; the sixteen new calls
    # are the rest. 326 is the Haiku 5.5 HTTP validation: US$2.29 new plus
    # US$0.006091 already stored in entries 327 and 328, 674 new calls plus
    # those two. Successors chain: each one closes the window before it.
    # A different cost or call count is not this grant.
    DOLLAR_SUCCESSORS = {
      229 => { "cost_usd" => "1.170000", "calls" => 18 }.freeze,
      326 => { "cost_usd" => "2.296091", "calls" => 676 }.freeze,
      # 79723a5 live validation: US$0.10 inside the unchanged cap, sixteen new
      # calls plus entries 1000 and 1001, already stored above attempt 999.
      999 => { "cost_usd" => "0.100000", "calls" => 18 }.freeze,
      # a200991 validation: US$0.10 inside the unchanged cap, twenty new calls
      # plus entries 1015 and 1016, already stored above attempt 1014.
      1014 => { "cost_usd" => "0.100000", "calls" => 22 }.freeze
    }.freeze

    CEA_COMPLETION_ID = "haiku55-http-cea-completion-20261112"
    CEA_COMPLETION_SEQUENCE = 1123
    CEA_COMPLETION_CALLS = 15
    # Carries the unused US$0.011939 of regression plus the US$0.043121
    # authorized for one complete CEA execution.
    CEA_COMPLETION_USD = "0.055060"

    # Field validation on the ledger that is at 1,143 attempts and sequence
    # 1,145. The cutoff is the sequence, so entries 1144 and 1145 stay in the
    # previous window. Acceptance can run while the cap is still 1158.
    # Regression is the 1158 -> 1190 step and starts at whatever the sequence
    # is after those acceptance calls, never earlier than 1145 and never more
    # than ten sequence numbers later.
    FIELD_ACCEPTANCE_ID = "haiku55-http-field-acceptance-20261113"
    FIELD_ACCEPTANCE_SEQUENCE = 1145
    FIELD_ACCEPTANCE_CALLS = 10
    FIELD_ACCEPTANCE_USD = "0.033640"
    FIELD_ACCEPTANCE_PREVIOUS_ID = "haiku55-http-guion3-final-e7a2991-20261113"
    FIELD_REGRESSION_ID = "haiku55-http-field-regression-20261113"
    FIELD_REGRESSION_CALLS = 37
    FIELD_REGRESSION_USD = "0.129988"
    FIELD_VALIDATION_CALL_CAP = 1190

    THYSSEN_AUDIT_ID = "haiku55-http-photo-engineering-audit"
    THYSSEN_AUDIT_CAP = 1213
    THYSSEN_AUDIT_CALLS = 18
    THYSSEN_AUDIT_USD = "0.064872"
    THYSSEN_AUDIT_ATTEMPTS = 1195
    THYSSEN_AUDIT_SEQUENCE = 1197
    THYSSEN_PRIOR = [
      [ "haiku55-http-accept-5892b69", 1181, "0.033640", 10 ],
      [ "haiku55-http-elemont-5892b69", 1189, "0.032116", 9 ]
    ].freeze

    THYSSEN_RECHECK_ID = "haiku55-http-photo-engineering-recheck"
    THYSSEN_RECHECK_CAP = 1223
    THYSSEN_RECHECK_ATTEMPTS = 1205
    THYSSEN_RECHECK_SEQUENCE = 1207

    FIELD_CONTINUATION_ID = "haiku55-http-field-continuation-20261114"
    FIELD_CONTINUATION_ATTEMPTS = 1217
    FIELD_CONTINUATION_SEQUENCE = 1219
    FIELD_CONTINUATION_CALLS = 33
    FIELD_CONTINUATION_CAP = FIELD_CONTINUATION_ATTEMPTS + FIELD_CONTINUATION_CALLS
    FIELD_CONTINUATION_USD = "0.120792"

    def self.field_continuation_baseline?(state)
      state.values_at("attempts", "seq", "cost_cap_usd") ==
        [ FIELD_CONTINUATION_ATTEMPTS, FIELD_CONTINUATION_SEQUENCE, "4.0" ] &&
        state.dig("authorization", "call_cap") == THYSSEN_RECHECK_CAP &&
        Array(state["executions"]).last&.values_at("id", "after_attempt", "cost_usd", "calls") ==
          [ THYSSEN_RECHECK_ID, THYSSEN_RECHECK_SEQUENCE, THYSSEN_AUDIT_USD, THYSSEN_AUDIT_CALLS ]
    end

    def admit_field_continuation!
      with_lock do |state, file|
        raise Stop, "field_continuation_ledger_baseline_changed" unless self.class.field_continuation_baseline?(state)
        if exposure(state) + decimal(FIELD_CONTINUATION_USD) > [ @cost_cap, decimal(state["cost_cap_usd"]) ].min
          raise Stop, "field_continuation_assignment_budget"
        end

        state.fetch("authorization")["call_cap"] = FIELD_CONTINUATION_CAP
        state["call_cap"] = FIELD_CONTINUATION_CAP
        row = {
          "id" => FIELD_CONTINUATION_ID, "after_attempt" => state.fetch("seq"),
          "cost_usd" => FIELD_CONTINUATION_USD, "calls" => FIELD_CONTINUATION_CALLS, "at" => Time.now.utc.iso8601
        }
        state.fetch("executions") << row
        write!(file, state)
        row
      end
    end

    def self.thyssen_baseline?(state, recheck: false)
      rows = Array(state["executions"]).last(3).map do |row|
        row.values_at("id", "after_attempt", "cost_usd", "calls") if row.is_a?(Hash)
      end
      if recheck
        state.values_at("attempts", "seq", "cost_cap_usd") == [ THYSSEN_RECHECK_ATTEMPTS, THYSSEN_RECHECK_SEQUENCE, "4.0" ] &&
          state.dig("authorization", "call_cap") == THYSSEN_AUDIT_CAP &&
          rows == THYSSEN_PRIOR + [[ THYSSEN_AUDIT_ID, THYSSEN_AUDIT_SEQUENCE, THYSSEN_AUDIT_USD, THYSSEN_AUDIT_CALLS ]]
      else
        state.values_at("attempts", "seq", "cost_cap_usd") == [ THYSSEN_AUDIT_ATTEMPTS, THYSSEN_AUDIT_SEQUENCE, "4.0" ] &&
          state.dig("authorization", "call_cap") == 1198 && rows.last(2) == THYSSEN_PRIOR
      end
    end

    def admit_thyssen_audit!(recheck: false)
      with_lock do |state, file|
        raise Stop, "thyssen_ledger_baseline_changed" unless self.class.thyssen_baseline?(state, recheck: recheck)
        if exposure(state) + decimal(THYSSEN_AUDIT_USD) > [ @cost_cap, decimal(state["cost_cap_usd"]) ].min
          raise Stop, "thyssen_assignment_budget"
        end

        cap = recheck ? THYSSEN_RECHECK_CAP : THYSSEN_AUDIT_CAP
        state.fetch("authorization")["call_cap"] = cap
        state["call_cap"] = cap
        row = {
          "id" => (recheck ? THYSSEN_RECHECK_ID : THYSSEN_AUDIT_ID), "after_attempt" => state.fetch("seq"),
          "cost_usd" => THYSSEN_AUDIT_USD, "calls" => THYSSEN_AUDIT_CALLS, "at" => Time.now.utc.iso8601
        }
        state.fetch("executions") << row
        write!(file, state)
        row
      end
    end

    def initialize(path:, call_cap:, cost_cap_usd:)
      @path = Pathname(path)
      @call_cap = Integer(call_cap)
      @cost_cap = BigDecimal(cost_cap_usd.to_s)
      raise ArgumentError, "call_cap" unless @call_cap.positive?
      raise ArgumentError, "cost_cap" unless @cost_cap.positive?
    end

    def snapshot
      with_lock { |state, _file| public_snapshot(state) }
    end

    # One persisted grant. A later process cannot rebase the cost, the
    # cutoff, or the id. call_cap may only rise through admit_execution!'s
    # recorded bump. Missing on an empty file is not a grant.
    def ensure_authorization!(id:, after_attempt:, cost_usd:, call_cap:)
      with_lock do |state, file|
        incoming_cost = format_money(cost_usd)
        current = state["authorization"]
        if current.nil?
          state["authorization"] = {
            "id" => id.to_s,
            "after_attempt" => after_attempt.to_i,
            "cost_usd" => incoming_cost,
            "call_cap" => call_cap.to_i
          }
          write!(file, state)
          return state["authorization"]
        end
        unless current.is_a?(Hash) && current["id"] == id.to_s &&
            current["after_attempt"].to_i == after_attempt.to_i &&
            decimal(current["cost_usd"]) == decimal(incoming_cost)
          raise Stop, "authorization_mismatch"
        end

        current
      end
    end

    # Records this execution once. The same id does not move the cutoff
    # backward or raise the ceiling. A call-cap bump is only the next
    # recorded step, and only while the file is still at that attempt count.
    def admit_execution!(id:, cost_usd:, calls:, bump_call_cap_to: nil, bump_only_if_attempts: nil, start_after_sequence: false)
      with_lock do |state, file|
        grants = state["executions"].is_a?(Array) ? state["executions"] : []
        state["executions"] = grants
        existing = grants.find { |row| row.is_a?(Hash) && row["id"] == id.to_s }
        if existing
          raise Stop, "execution_renewed" if decimal(cost_usd) > decimal(existing["cost_usd"]) || calls.to_i > existing["calls"].to_i

          return existing
        end

        apply_call_cap_bump!(state, bump_call_cap_to, bump_only_if_attempts)
        row = {
          "id" => id.to_s,
          "after_attempt" => state[start_after_sequence ? "seq" : "attempts"].to_i,
          "cost_usd" => format_money(cost_usd),
          "calls" => calls.to_i,
          "at" => Time.now.utc.iso8601
        }
        grants << row
        write!(file, state)
        row
      end
    end

    def admit_cea_completion!
      with_lock do |state, file|
        grants = state.fetch("executions")
        raise Stop, "cea_completion_already_started" unless state["seq"] == CEA_COMPLETION_SEQUENCE
        raise Stop, "cea_completion_already_admitted" if grants.any? { |row| row["id"] == CEA_COMPLETION_ID }

        previous = grants.last
        unless previous&.fetch("id") == "haiku55-http-guion3-20261112-regression" &&
            previous["calls"] == 104 && decimal(previous["cost_usd"]) == BigDecimal("0.100000") &&
            scoped_attempts(state, previous["after_attempt"]) + CEA_COMPLETION_CALLS <= previous["calls"] &&
            scoped_exposure(state, previous["after_attempt"]) + BigDecimal(CEA_COMPLETION_USD) <= BigDecimal("0.143121")
          raise Stop, "cea_completion_grant_mismatch"
        end

        row = {
          "id" => CEA_COMPLETION_ID, "after_attempt" => CEA_COMPLETION_SEQUENCE,
          "cost_usd" => CEA_COMPLETION_USD, "calls" => CEA_COMPLETION_CALLS, "at" => Time.now.utc.iso8601
        }
        grants << row
        write!(file, state)
        row
      end
    end

    # Reserves one attempt and its ceiling. The hold stays until settle!,
    # keep!, or release!.
    def reserve!(ceiling_usd:, required_execution: nil, scope: nil, **meta)
      ceiling = money(ceiling_usd)
      with_lock do |state, file|
        if required_execution && Array(state["executions"]).last&.dig("id") != required_execution
          raise Stop, "execution_not_admitted"
        end
        if scope
          rows = state["entries"].select { |row| row["run_scope"] == scope.fetch(:id) && row["status"] != "released" }
          if rows.size >= scope.fetch(:calls) ||
              rows.sum(BigDecimal("0")) { |row| exposure_of(state, row) } + ceiling > scope.fetch(:cost)
            raise Stop, "run_scope_exhausted"
          end
          meta[:run_scope] = scope.fetch(:id)
        end
        if over_cap?(state, ceiling)
          state["blocked"] = state["blocked"].to_i + 1
          write!(file, state)
          raise Stop, "assignment_spend"
        end

        state["attempts"] += 1
        state["seq"] += 1
        id = state["seq"]
        state["open"][id.to_s] = ceiling.to_s("F")
        state["entries"] << entry(meta, id:, status: "reserved", ceiling_usd: ceiling.to_s("F"))
        write!(file, state)
        id
      end
    end

    def settle!(id, actual_usd:, **meta)
      actual = money(actual_usd)
      with_lock do |state, file|
        return false unless state["open"].delete(id.to_s)

        state["committed"] = format_money(decimal(state["committed"]) + actual)
        state["priced"] = state["priced"].to_i + 1
        replace_entry(state, id, meta.merge("status" => "settled", "actual_usd" => actual.to_s("F")))
        write!(file, state)
        true
      end
    end

    # Writes the active caps onto an existing file. Attempts, committed
    # amounts, and entries stay as they were.
    def sync_caps!
      with_lock do |state, file|
        authorized = state.dig("authorization", "call_cap").to_i
        state["call_cap"] = [ @call_cap, authorized ].max
        state["cost_cap_usd"] = @cost_cap.to_s("F")
        state["unknown"] = format_money(state["unknown"])
        write!(file, state)
        public_snapshot(state)
      end
    end

    # The call left this process and came back without a usable price.
    # The reserved ceiling stays consumed.
    def keep!(id, **meta)
      with_lock do |state, file|
        held = state["open"].delete(id.to_s)
        return false unless held

        state["committed"] = format_money(decimal(state["committed"]) + decimal(held))
        state["priced"] = state["priced"].to_i + 1
        replace_entry(state, id, meta.merge("status" => "kept", "actual_usd" => decimal(held).to_s("F")))
        write!(file, state)
        true
      end
    end

    # No token usage came back. The ceiling moves out of the open hold into
    # unknown exposure. committed stays the calculated total. actual_usd is
    # not set, because this is not evidence of a zero bill.
    def unknown!(id, **meta)
      with_lock do |state, file|
        held = state["open"].delete(id.to_s)
        return false unless held

        state["unknown"] = format_money(decimal(state["unknown"]) + decimal(held))
        replace_entry(state, id, meta.merge("status" => "unknown", "cost_kind" => "unknown", "reserved_usd" => format_money(held)))
        write!(file, state)
        true
      end
    end

    # The provider method was not entered. The attempt does not count.
    def release!(id, **meta)
      with_lock do |state, file|
        return false unless state["open"].delete(id.to_s)

        state["attempts"] -= 1
        replace_entry(state, id, meta.merge("status" => "released"))
        write!(file, state)
        true
      end
    end

    private

    def with_lock
      @path.dirname.mkpath
      @path.open(File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        state = load_state(file)
        result = yield(state, file)
        result
      end
    end

    def load_state(file)
      file.rewind
      raw = file.read
      state = raw.empty? ? empty_state : JSON.parse(raw)
      state = empty_state unless state.is_a?(Hash)
      state["attempts"] = state["attempts"].to_i
      state["blocked"] = state["blocked"].to_i
      state["priced"] = state["priced"].to_i
      state["seq"] = state["seq"].to_i
      state["committed"] = decimal(state["committed"]).to_s("F")
      state["unknown"] = decimal(state["unknown"]).to_s("F")
      state["open"] = state["open"].is_a?(Hash) ? state["open"] : {}
      state["entries"] = state["entries"].is_a?(Array) ? state["entries"] : []
      state
    end

    def write!(file, state)
      encoded = JSON.generate(state)
      file.rewind
      file.write(encoded)
      file.flush
      file.truncate(encoded.bytesize)
    end

    def empty_state
      {
        "call_cap" => @call_cap,
        "cost_cap_usd" => @cost_cap.to_s("F"),
        "attempts" => 0,
        "blocked" => 0,
        "priced" => 0,
        "seq" => 0,
        "committed" => format_money(0),
        "unknown" => format_money(0),
        "open" => {},
        "entries" => []
      }
    end

    def public_snapshot(state)
      {
        "attempts" => state["attempts"],
        "blocked" => state["blocked"],
        "priced" => state["priced"],
        "committed_usd" => format_money(state["committed"]),
        "unknown_usd" => format_money(state["unknown"]),
        "held_usd" => format_money(state["open"].values.sum(BigDecimal("0")) { |amount| decimal(amount) }),
        "call_cap" => attempt_cap(state),
        "cost_cap_usd" => @cost_cap.to_s("F"),
        "authorization" => state["authorization"],
        "executions" => state["executions"],
        "entries" => state["entries"]
      }
    end

    def exposure(state)
      decimal(state["committed"]) + decimal(state["unknown"]) + state["open"].values.sum(BigDecimal("0")) { |amount| decimal(amount) }
    end

    def over_cap?(state, ceiling)
      return true if state["attempts"] + 1 > attempt_cap(state)
      return true if exposure(state) + ceiling > [ @cost_cap, decimal(state["cost_cap_usd"]) ].select(&:positive?).min

      authorization_exceeded?(state, ceiling) || executions_exceeded?(state, ceiling)
    end

    # The constructor cap and a persisted authorization cap both apply.
    # The authorization cannot be raised here; admit_execution! is the only bump.
    def attempt_cap(state)
      authorized = state.dig("authorization", "call_cap").to_i
      return @call_cap unless authorized.positive?

      [ @call_cap, authorized ].min
    end

    def authorization_exceeded?(state, ceiling)
      auth = state["authorization"]
      return false unless auth.is_a?(Hash)

      after = auth["after_attempt"].to_i
      room = auth["call_cap"].to_i - after
      return true if scoped_attempts(state, after) + 1 > room

      active = dollar_successors(state).select { |row| state["seq"].to_i + 1 > row["after_attempt"].to_i }
      windows = [ [ after, auth["cost_usd"] ] ] + active.map { |row| [ row["after_attempt"].to_i, row["cost_usd"] ] }
      windows.each_cons(2) do |(from, budget), (to, _next_budget)|
        return true if scoped_exposure_between(state, from, to) > decimal(budget)
      end

      from, budget = windows.last
      scoped_exposure(state, from) + ceiling > decimal(budget)
    end

    def dollar_successors(state)
      Array(state["executions"]).select { |row|
        next false unless row.is_a?(Hash)

        terms = row.values_at("id", "after_attempt", "cost_usd", "calls")
        next true if THYSSEN_PRIOR.include?(terms)
        next true if terms == [ FIELD_CONTINUATION_ID, FIELD_CONTINUATION_SEQUENCE, FIELD_CONTINUATION_USD, FIELD_CONTINUATION_CALLS ]
        next true if terms == [ THYSSEN_AUDIT_ID, THYSSEN_AUDIT_SEQUENCE, THYSSEN_AUDIT_USD, THYSSEN_AUDIT_CALLS ]
        next true if terms == [ THYSSEN_RECHECK_ID, THYSSEN_RECHECK_SEQUENCE, THYSSEN_AUDIT_USD, THYSSEN_AUDIT_CALLS ]

        if row["id"] == CEA_COMPLETION_ID
          next row["after_attempt"] == CEA_COMPLETION_SEQUENCE &&
            row["calls"] == CEA_COMPLETION_CALLS && decimal(row["cost_usd"]) == BigDecimal(CEA_COMPLETION_USD)
        end
        if row["id"] == FIELD_ACCEPTANCE_ID
          next row["after_attempt"] == FIELD_ACCEPTANCE_SEQUENCE &&
            row["calls"] == FIELD_ACCEPTANCE_CALLS &&
            decimal(row["cost_usd"]) == BigDecimal(FIELD_ACCEPTANCE_USD)
        end
        if row["id"] == FIELD_REGRESSION_ID
          after = row["after_attempt"].to_i
          next after >= FIELD_ACCEPTANCE_SEQUENCE &&
            after <= FIELD_ACCEPTANCE_SEQUENCE + FIELD_ACCEPTANCE_CALLS &&
            row["calls"] == FIELD_REGRESSION_CALLS &&
            decimal(row["cost_usd"]) == BigDecimal(FIELD_REGRESSION_USD)
        end

        spec = DOLLAR_SUCCESSORS[row["after_attempt"].to_i]
        if row["id"].to_s.start_with?("haiku55-http-guion3-20261112-")
          cap = { "acceptance" => 24, "regression" => 104 }[row["id"].to_s.split("-").last]
          next row["calls"] == cap && cap.present? && decimal(row["cost_usd"]) == BigDecimal("0.1")
        end
        spec && row["calls"].to_i == spec["calls"].to_i && decimal(row["cost_usd"]) == decimal(spec["cost_usd"])
      }.sort_by { |row| row["after_attempt"].to_i }
    end

    def executions_exceeded?(state, ceiling)
      grants = Array(state["executions"]).select { |grant| grant.is_a?(Hash) }.sort_by { |grant| grant["after_attempt"].to_i }
      grants.each_with_index.any? do |grant, index|
        after = grant["after_attempt"].to_i
        boundary = grants[index + 1]&.fetch("after_attempt", nil)&.to_i
        incoming = boundary.nil?
        scoped_between(state, after, boundary) + (incoming ? 1 : 0) > grant["calls"].to_i ||
          scoped_exposure_between(state, after, boundary) + (incoming ? ceiling : 0) > decimal(grant["cost_usd"])
      end
    end

    def scoped_between(state, after_attempt, boundary)
      state["entries"].count { |entry|
        counts_toward?(entry, after_attempt) && (boundary.nil? || entry["id"].to_i <= boundary)
      }
    end

    def scoped_exposure_between(state, after_attempt, boundary)
      state["entries"].sum(BigDecimal("0")) do |entry|
        next BigDecimal("0") unless counts_toward?(entry, after_attempt)
        next BigDecimal("0") if boundary && entry["id"].to_i > boundary

        exposure_of(state, entry)
      end
    end

    def exposure_of(state, entry)
      case entry["status"]
      when "settled", "kept"
        decimal(entry["actual_usd"])
      when "unknown"
        decimal(entry["reserved_usd"].presence || entry["ceiling_usd"])
      when "reserved"
        decimal(state.dig("open", entry["id"].to_s).presence || entry["ceiling_usd"])
      else
        BigDecimal("0")
      end
    end

    def apply_call_cap_bump!(state, bump_call_cap_to, bump_only_if_attempts)
      return unless bump_only_if_attempts && state["attempts"].to_i == bump_only_if_attempts.to_i

      target = bump_call_cap_to.to_i
      auth = state["authorization"]
      return unless auth.is_a?(Hash) && CALL_CAP_BUMPS[auth["call_cap"].to_i] == target

      auth["call_cap"] = target
      state["call_cap"] = [ state["call_cap"].to_i, target ].max
    end

    def scoped_attempts(state, after_attempt)
      state["entries"].count { |entry| counts_toward?(entry, after_attempt) }
    end

    def scoped_exposure(state, after_attempt)
      state["entries"].sum(BigDecimal("0")) do |entry|
        next BigDecimal("0") unless counts_toward?(entry, after_attempt)

        case entry["status"]
        when "settled", "kept"
          decimal(entry["actual_usd"])
        when "unknown"
          decimal(entry["reserved_usd"].presence || entry["ceiling_usd"])
        when "reserved"
          decimal(state.dig("open", entry["id"].to_s).presence || entry["ceiling_usd"])
        else
          BigDecimal("0")
        end
      end
    end

    def counts_toward?(entry, after_attempt)
      entry.is_a?(Hash) && entry["id"].to_i > after_attempt && entry["status"] != "released"
    end

    def entry(meta, id:, status:, ceiling_usd:)
      {
        "id" => id,
        "status" => status,
        "ceiling_usd" => ceiling_usd,
        "model_id" => meta[:model_id].to_s,
        "turn" => meta[:turn],
        "run_scope" => meta[:run_scope],
        "at" => Time.now.utc.iso8601
      }.compact
    end

    def replace_entry(state, id, meta)
      row = state["entries"].reverse.find { |item| item.is_a?(Hash) && item["id"] == id }
      return unless row

      meta.each { |key, value| row[key.to_s] = value }
      row["at"] = Time.now.utc.iso8601
    end

    def money(value)
      decimal(value)
    end

    def format_money(value)
      format("%.6f", decimal(value))
    end

    def decimal(value)
      BigDecimal(value.nil? ? "0" : value.to_s)
    end
  end
end
