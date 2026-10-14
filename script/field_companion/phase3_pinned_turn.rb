# frozen_string_literal: true

# Phase 3 pinned turns. Refuses unless PHASE3_PINNED_TURN_AUTHORIZED=1.
# PHASE3_PINNED_TURN_REQUIRE=1 loads without running.
# Reads PHASE3_SOURCE_ROOT read-only. Writes only under the phase 3 evidence
# root. Does not continue session 13 and does not repeat phase 2 calls.

def phase3_pinned_turn_main
  unless ENV["PHASE3_PINNED_TURN_AUTHORIZED"] == "1"
    puts({ "status" => "refused", "reason" => "authorization_absent", "phase3_acceptance" => "not_accepted" }.to_json)
    return 2
  end

  result = Rag::Phase3PinnedTurn.run_authorized(
    source_root: ENV["PHASE3_SOURCE_ROOT"],
    evidence_root: ENV["PHASE3_PINNED_TURN_EVIDENCE_ROOT"]
  )
  puts({
    "status" => result.status,
    "reason" => result.reason,
    "session_id" => result.session_id,
    "attempts" => result.attempts,
    "evidence_path" => result.evidence_path,
    "documentary_acceptance" => "pending",
    "phase3_acceptance" => "not_accepted",
    "real_interpreter_correct" => "pending"
  }.to_json)
  result.status == "turns_recorded" ? 0 : 2
end

unless ENV["PHASE3_PINNED_TURN_REQUIRE"] == "1"
  code = phase3_pinned_turn_main
  exit code unless code.zero?
end
