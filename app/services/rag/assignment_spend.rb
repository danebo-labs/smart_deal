# frozen_string_literal: true

module Rag
  # File-backed ceiling for one local assignment. A later process reads the
  # same file. There is no reset: the caller does not delete the file, and a
  # new process does not start the counters at zero.
  class AssignmentSpend
    Stop = Class.new(Exception)

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

    # Reserves one attempt and its ceiling. The hold stays until settle!,
    # keep!, or release!.
    def reserve!(ceiling_usd:, **meta)
      ceiling = money(ceiling_usd)
      with_lock do |state, file|
        if state["attempts"] + 1 > @call_cap || exposure(state) + ceiling > @cost_cap
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
        state["call_cap"] = @call_cap
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
        "call_cap" => @call_cap,
        "cost_cap_usd" => @cost_cap.to_s("F"),
        "entries" => state["entries"]
      }
    end

    def exposure(state)
      decimal(state["committed"]) + decimal(state["unknown"]) + state["open"].values.sum(BigDecimal("0")) { |amount| decimal(amount) }
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
