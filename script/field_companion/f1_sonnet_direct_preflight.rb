# frozen_string_literal: true

# One no-retrieval direct Anthropic call. Does not run the calibration corpus.
#
#   F1CAL_SONNET_DIRECT=1 bin/rails runner script/field_companion/f1_sonnet_direct_preflight.rb

STDOUT.sync = true

require_relative "f1_sonnet_direct_generation"

Gen = FieldCompanion::F1SonnetDirectGeneration

abort "SONNET_DIRECT_ACCESS_BLOCKED" if Gen.api_key.blank?
abort "production query model must stay Haiku" unless BedrockClient::QUERY_MODEL_ID.to_s.include?("claude-haiku-4-5")

result = Gen.complete(
  prompt: Gen::PREFLIGHT_PROMPT,
  max_tokens: 64,
  temperature: 0
)

payload = {
  text: result[:text],
  exact: result[:text] == "PREFLIGHT_OK",
  requested_model_id: result[:requested_model_id],
  returned_model: result[:returned_model],
  thinking_type: result[:thinking_type],
  transport: result[:transport],
  fallback: false,
  usage: result[:usage],
  latency_ms: result[:latency_ms],
  cost_usd: result[:cost_usd],
  pricing: Gen::PRICING,
  production_query_model: BedrockClient::QUERY_MODEL_ID
}
path = Rails.root.join("tmp/f1cal/sonnet55_direct_preflight.json")
FileUtils.mkdir_p(path.dirname)
File.write(path, JSON.pretty_generate(payload))
puts JSON.pretty_generate(payload)
abort "preflight text was not exactly PREFLIGHT_OK" unless payload[:exact]
abort "preflight priced at zero" if payload[:cost_usd].to_f <= 0
