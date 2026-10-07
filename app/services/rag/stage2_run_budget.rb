# frozen_string_literal: true

module Rag
  # Stage 2 spend already closed, plus the room for one future pass.
  # A fresh BedrockQuery baseline does not reopen the ceiling: the 80 calls
  # and US$0.161562 stay in the total even when this run has no rows yet.
  class Stage2RunBudget
    HISTORICAL_CALLS = 80
    HISTORICAL_COST_USD = BigDecimal("0.161562")
    STAGE2_CALL_CEILING = 126
    STAGE3_CALL_RESERVE = 42
    GLOBAL_CALL_CEILING = 168
    PASS_CALL_CAP = 42
    COST_CAP_USD = BigDecimal("2.50")
    INTERPRETER_CALL_USD = BigDecimal("0.0045")
    GENERATION_CALL_USD = BigDecimal("0.0115")
    TURN_GENERATION_CALLS = 2
    TURN_CALL_MARGIN = 1 + TURN_GENERATION_CALLS
    TURN_COST_MARGIN_USD = INTERPRETER_CALL_USD + (TURN_GENERATION_CALLS * GENERATION_CALL_USD)

    def self.snapshot(new_calls:, new_cost_usd:)
      fresh_calls = new_calls.to_i
      fresh_cost = decimal(new_cost_usd)
      calls = HISTORICAL_CALLS + fresh_calls
      cost = (HISTORICAL_COST_USD + fresh_cost).round(6)
      Snapshot.new(
        calls: calls,
        new_calls: fresh_calls,
        cost_usd: cost,
        new_cost_usd: fresh_cost.round(6),
        historical_calls: HISTORICAL_CALLS,
        historical_cost_usd: HISTORICAL_COST_USD,
        pass_calls_remaining: PASS_CALL_CAP - fresh_calls,
        stage2_calls_remaining: STAGE2_CALL_CEILING - calls,
        global_calls_remaining: GLOBAL_CALL_CEILING - STAGE3_CALL_RESERVE - calls,
        admit_turn: room?(fresh_calls, calls, cost)
      )
    end

    def self.admit_turn?(new_calls:, new_cost_usd:)
      snapshot(new_calls: new_calls, new_cost_usd: new_cost_usd).admit_turn
    end

    # A new directory per run. The legacy trace directory stays untouched.
    def self.evidence_directory(root, run_id:, session_id:)
      stamp = run_id.to_s
      sid = session_id.to_s
      raise ArgumentError, "run id" if stamp.blank? || stamp.match?(%r{[/\\]})
      raise ArgumentError, "session id" if sid.blank? || sid.match?(%r{[/\\]})

      Pathname.new(root).join("runs", "#{stamp}-session-#{sid}")
    end

    def self.manifest(sha:, session_id:, run_id:, new_calls: 0, new_cost_usd: 0)
      spent = snapshot(new_calls: new_calls, new_cost_usd: new_cost_usd)
      {
        "sha" => sha.to_s,
        "run_id" => run_id.to_s,
        "session_id" => session_id,
        "historical_calls" => HISTORICAL_CALLS,
        "historical_cost_usd" => HISTORICAL_COST_USD.to_s("F"),
        "new_calls" => spent.new_calls,
        "new_cost_usd" => spent.new_cost_usd.to_s("F"),
        "calls" => spent.calls,
        "cost_usd" => spent.cost_usd.to_s("F"),
        "pass_call_cap" => PASS_CALL_CAP,
        "turn_call_margin" => TURN_CALL_MARGIN,
        "stage2_call_ceiling" => STAGE2_CALL_CEILING,
        "stage3_call_reserve" => STAGE3_CALL_RESERVE,
        "global_call_ceiling" => GLOBAL_CALL_CEILING,
        "cost_cap_usd" => COST_CAP_USD.to_s("F")
      }
    end

    def self.decimal(value)
      BigDecimal(format("%.6f", value.to_f))
    end
    private_class_method :decimal

    def self.room?(fresh_calls, calls, cost)
      pass_room = PASS_CALL_CAP - fresh_calls
      stage2_room = STAGE2_CALL_CEILING - calls
      global_room = GLOBAL_CALL_CEILING - STAGE3_CALL_RESERVE - calls
      call_room = [ pass_room, stage2_room, global_room ].min
      cost_room = COST_CAP_USD - cost
      call_room >= TURN_CALL_MARGIN && cost_room >= TURN_COST_MARGIN_USD
    end
    private_class_method :room?

    Snapshot = Data.define(
      :calls, :new_calls, :cost_usd, :new_cost_usd,
      :historical_calls, :historical_cost_usd,
      :pass_calls_remaining, :stage2_calls_remaining, :global_calls_remaining,
      :admit_turn
    )
  end
end
