# frozen_string_literal: true

module Rag
  # The 2026-10-09 diagnostic pass added 28 registered calls and
  # US$0.079340 to the previous 160 calls and US$0.343774. History is
  # now 188 calls and US$0.423114. That pass recorded no unbilled model
  # attempt. PASS_CALL_CAP is 0, so the closed ceiling does not open
  # another pass. Stage 2 stays at 188. Stage 3 keeps 42 inside the
  # global ceiling of 230. An empty BedrockQuery table does not reopen
  # this history. An unbilled model attempt still counts against the
  # attempt cap and does not invent a cost. Retrieve stays outside that
  # cap. The cost cap stays US$2.50.
  class Stage2RunBudget
    HISTORICAL_CALLS = 188
    HISTORICAL_COST_USD = BigDecimal("0.423114")
    STAGE2_CALL_CEILING = 188
    STAGE3_CALL_RESERVE = 42
    GLOBAL_CALL_CEILING = 230
    PASS_CALL_CAP = 0
    COST_CAP_USD = BigDecimal("2.50")
    INTERPRETER_CALL_USD = BigDecimal("0.0045")
    GENERATION_CALL_USD = BigDecimal("0.0115")
    # One no-pin turn tracks one interpreter call plus at most two generation
    # calls: publication and, when that contract is not accepted, guidance.
    # AWS_MAX_ATTEMPTS=1 limits retries. It does not prove a failure happened
    # before the request was sent. A BedrockQuery row is a registered call,
    # not every remote attempt that failed before a row existed. Retrieve
    # retries stay outside BedrockQuery.
    TURN_GENERATION_CALLS = 2
    TURN_CALL_MARGIN = 1 + TURN_GENERATION_CALLS
    TURN_COST_MARGIN_USD = INTERPRETER_CALL_USD + (TURN_GENERATION_CALLS * GENERATION_CALL_USD)

    def self.snapshot(new_calls:, new_cost_usd:, unbilled_attempts: 0)
      fresh_calls = new_calls.to_i
      unbilled = unbilled_attempts.to_i
      raise ArgumentError, "calls" if fresh_calls.negative? || unbilled.negative?

      fresh_attempts = fresh_calls + unbilled
      calls = HISTORICAL_CALLS + fresh_calls
      attempts = HISTORICAL_CALLS + fresh_attempts
      fresh_cost = decimal(new_cost_usd)
      cost = (HISTORICAL_COST_USD + fresh_cost).round(6)
      Snapshot.new(
        calls: calls,
        new_calls: fresh_calls,
        attempts: attempts,
        new_attempts: fresh_attempts,
        unbilled_attempts: unbilled,
        cost_usd: cost,
        new_cost_usd: fresh_cost.round(6),
        historical_calls: HISTORICAL_CALLS,
        historical_cost_usd: HISTORICAL_COST_USD,
        pass_calls_remaining: PASS_CALL_CAP - fresh_attempts,
        stage2_calls_remaining: STAGE2_CALL_CEILING - attempts,
        global_calls_remaining: GLOBAL_CALL_CEILING - STAGE3_CALL_RESERVE - attempts,
        admit_turn: room?(fresh_attempts, attempts, cost)
      )
    end

    def self.admit_turn?(new_calls:, new_cost_usd:, unbilled_attempts: 0)
      snapshot(new_calls: new_calls, new_cost_usd: new_cost_usd, unbilled_attempts: unbilled_attempts).admit_turn
    end

    # A new directory per run. The legacy trace directory stays untouched.
    def self.evidence_directory(root, run_id:, session_id:)
      stamp = run_id.to_s
      sid = session_id.to_s
      raise ArgumentError, "run id" if stamp.blank? || stamp.match?(%r{[/\\]})
      raise ArgumentError, "session id" if sid.blank? || sid.match?(%r{[/\\]})

      Pathname.new(root).join("runs", "#{stamp}-session-#{sid}")
    end

    def self.manifest(sha:, session_id:, run_id:, new_calls: 0, new_cost_usd: 0, unbilled_attempts: 0)
      spent = snapshot(new_calls: new_calls, new_cost_usd: new_cost_usd, unbilled_attempts: unbilled_attempts)
      {
        "sha" => sha.to_s,
        "run_id" => run_id.to_s,
        "session_id" => session_id,
        "historical_calls" => HISTORICAL_CALLS,
        "historical_cost_usd" => HISTORICAL_COST_USD.to_s("F"),
        "new_calls" => spent.new_calls,
        "unbilled_attempts" => spent.unbilled_attempts,
        "new_attempts" => spent.new_attempts,
        "attempts" => spent.attempts,
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

    def self.room?(fresh_attempts, attempts, cost)
      pass_room = PASS_CALL_CAP - fresh_attempts
      stage2_room = STAGE2_CALL_CEILING - attempts
      global_room = GLOBAL_CALL_CEILING - STAGE3_CALL_RESERVE - attempts
      call_room = [ pass_room, stage2_room, global_room ].min
      cost_room = COST_CAP_USD - cost
      call_room >= TURN_CALL_MARGIN && cost_room >= TURN_COST_MARGIN_USD
    end
    private_class_method :room?

    Snapshot = Data.define(
      :calls, :new_calls, :cost_usd, :new_cost_usd,
      :historical_calls, :historical_cost_usd,
      :pass_calls_remaining, :stage2_calls_remaining, :global_calls_remaining,
      :admit_turn, :attempts, :new_attempts, :unbilled_attempts
    )
  end
end
