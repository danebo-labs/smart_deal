# frozen_string_literal: true

module Rag
  # File-backed ceiling for one local assignment. A later process reads the
  # same file. There is no reset: the caller does not delete the file, and a
  # new process does not start the counters at zero.
  class AssignmentSpend
    Stop = Class.new(Exception)
    # One recorded step. 150 -> 152, then 152 -> 164. Anything else stays.
    CALL_CAP_BUMPS = { 150 => 152, 152 => 164 }.freeze

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
    def admit_execution!(id:, cost_usd:, calls:, bump_call_cap_to: nil, bump_only_if_attempts: nil)
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
          "after_attempt" => state["attempts"].to_i,
          "cost_usd" => format_money(cost_usd),
          "calls" => calls.to_i,
          "at" => Time.now.utc.iso8601
        }
        grants << row
        write!(file, state)
        row
      end
    end

    # Reserves one attempt and its ceiling. The hold stays until settle!,
    # keep!, or release!.
    def reserve!(ceiling_usd:, **meta)
      ceiling = money(ceiling_usd)
      with_lock do |state, file|
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
      return true if exposure(state) + ceiling > @cost_cap

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

      scoped_exposure(state, after) + ceiling > decimal(auth["cost_usd"])
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
        "at" => Time.now.utc.iso8601
      }
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
