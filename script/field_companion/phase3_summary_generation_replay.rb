# frozen_string_literal: true

# Literal generation replay of phase 3 turn 3, run 20261014T194442Z.
# Refuses unless PHASE3_SUMMARY_GENERATION_AUTHORIZED=1 and AWS_MAX_ATTEMPTS=1.
# PHASE3_SUMMARY_GENERATION_REQUIRE=1 loads without running.
# Does not construct BedrockClient unless that gate has already passed.
# Does not repeat the conversational cycle, Retrieve, or the historical session.

def phase3_summary_generation_replay_main
  capture = ENV["PHASE3_SUMMARY_GENERATION_CAPTURE"].presence ||
    Rag::Phase3SummaryGenerationReplay.default_capture_dir.to_s
  replay = Rag::Phase3SummaryGenerationReplay
  unless ENV[replay::AUTHORIZED_ENV] == "1"
    puts replay.preview(capture_dir: capture).to_h.to_json
    return 2
  end

  run_id = ENV["PHASE3_SUMMARY_GENERATION_RUN_ID"].presence || Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
  output = ENV["PHASE3_SUMMARY_GENERATION_OUTPUT"].presence ||
    Rails.root.join("tmp/phase3_summary_generation/runs", run_id).to_s
  gated = replay.gate(capture_dir: capture, output_dir: output, run_id: run_id)
  unless gated.sendable?
    puts gated.to_h.to_json
    return 2
  end

  result = replay.run(capture_dir: capture, output_dir: output, run_id: run_id, client: BedrockClient.new)
  puts result.to_h.to_json
  result.status == "recorded" ? 0 : 2
end

unless ENV["PHASE3_SUMMARY_GENERATION_REQUIRE"] == "1"
  code = phase3_summary_generation_replay_main
  exit code unless code.zero?
end
