# frozen_string_literal: true

# Phase 1 pinned turn. Reads the environment, calls the service, prints.
# Refuses unless PHASE1_PINNED_TURN_AUTHORIZED=1. Does not edit .env and
# does not run Journey A. PHASE1_PINNED_TURN_REQUIRE=1 loads without running.
# PHASE1_PINNED_TURN_EVIDENCE_ROOT, when set, replaces the default runs directory.

def phase1_pinned_turn_main
  result = Rag::Phase1PinnedTurn.run(evidence_root: ENV["PHASE1_PINNED_TURN_EVIDENCE_ROOT"])
  puts({
    "status" => result.status,
    "reason" => result.reason,
    "session_id" => result.session_id,
    "evidence_path" => result.evidence_path,
    "documentary_acceptance" => "pending"
  }.to_json)
  result.status == "completed" ? 0 : 2
end

unless ENV["PHASE1_PINNED_TURN_REQUIRE"] == "1"
  code = phase1_pinned_turn_main
  exit code unless code.zero?
end
