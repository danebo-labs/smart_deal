# frozen_string_literal: true

# Phase 2 pinned turns. Refuses unless PHASE2_PINNED_TURN_AUTHORIZED=1.
# PHASE2_PINNED_TURN_REQUIRE=1 loads without running.
# start writes the pause. continue reads PHASE2_PAUSE_PATH and
# PHASE2_CANDIDATE_ANSWERS=yes or no. Any other value stops before a call.

def phase2_pinned_turn_main
  case ARGV[0].to_s
  when "start"
    result = Rag::Phase2PinnedTurn.run_start(evidence_root: ENV["PHASE2_PINNED_TURN_EVIDENCE_ROOT"])
  when "continue"
    answer = ENV["PHASE2_CANDIDATE_ANSWERS"]
    unless answer == "yes" || answer == "no"
      puts({ "status" => "refused", "reason" => "decision_absent" }.to_json)
      return 2
    end
    result = Rag::Phase2PinnedTurn.run_continue(
      pause_path: ENV["PHASE2_PAUSE_PATH"],
      accept_candidate: answer == "yes",
      evidence_root: ENV["PHASE2_PINNED_TURN_EVIDENCE_ROOT"]
    )
  else
    puts({ "status" => "refused", "reason" => "command_absent" }.to_json)
    return 2
  end

  puts({
    "status" => result.status,
    "reason" => result.reason,
    "session_id" => result.session_id,
    "attempts" => result.attempts,
    "pause_path" => result.pause_path,
    "evidence_path" => result.evidence_path,
    "documentary_acceptance" => "pending"
  }.to_json)
  %w[awaiting_decision withheld second_turn_recorded completed].include?(result.status) ? 0 : 2
end

unless ENV["PHASE2_PINNED_TURN_REQUIRE"] == "1"
  code = phase2_pinned_turn_main
  exit code unless code.zero?
end
