# frozen_string_literal: true

# Generation-only replay of the captured phase-2 prompt.
# Refuses unless PHASE2_ATTRIBUTION_GENERATION_AUTHORIZED=1.
# PHASE2_ATTRIBUTION_GENERATION_REQUIRE=1 loads without running.
# Correlations are phase2:attr:gen:<tag>:1 and :2. PHASE2_ATTRIBUTION_CORRELATION_TAG
# defaults to voices. Historical phase2:attr:gen:1 and phase2:attr:gen:2 are not reused.
# Does not repeat the conversational cycle, Retrieve, or a historical session.

def phase2_attribution_generation_main
  unless ENV[Rag::AttributionGenerationReplay::AUTHORIZED_ENV] == "1"
    puts({ "status" => "refused", "reason" => "authorization_absent" }.to_json)
    return 2
  end

  tag = Rag::AttributionGenerationReplay.correlation_tag
  if tag.nil?
    puts({ "status" => "refused", "reason" => "correlation_tag" }.to_json)
    return 2
  end

  capture = ENV["PHASE2_ATTRIBUTION_CAPTURE"].presence ||
    Rails.root.join("tmp/phase2_pinned_turn/runs/20261013T233715Z/turn_2/bodies/b0005.txt").to_s
  unless File.file?(capture)
    puts({ "status" => "refused", "reason" => "capture_absent" }.to_json)
    return 2
  end

  account = Account.find_by(id: 1)
  unless account
    puts({ "status" => "refused", "reason" => "account_absent" }.to_json)
    return 2
  end

  output = ENV["PHASE2_ATTRIBUTION_OUTPUT"].presence ||
    Rails.root.join("tmp/phase2_attribution_generation", Time.now.utc.strftime("%Y%m%dT%H%M%SZ")).to_s
  result = Rag::AttributionGenerationReplay.run(
    captured_prompt: File.binread(capture),
    account: account,
    client: BedrockClient.new,
    output_dir: output,
    correlation_tag: tag
  )
  puts result.to_h.to_json
  result.status == "recorded" ? 0 : 2
end

unless ENV["PHASE2_ATTRIBUTION_GENERATION_REQUIRE"] == "1"
  code = phase2_attribution_generation_main
  exit code unless code.zero?
end
