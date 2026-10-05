# frozen_string_literal: true

# One no-retrieval Grok call. Does not run the calibration corpus.
#
#   F1CAL_GROK=1 BEDROCK_MODEL_ID=global.xai.grok-4.7 \
#     bin/rails runner script/field_companion/f1_grok_preflight.rb

STDOUT.sync = true

require_relative "f1_grok_generation"

Gen = FieldCompanion::F1GrokGeneration

abort "BEDROCK_MODEL_ID must be #{Gen::MODEL_ID}" unless BedrockClient::QUERY_MODEL_ID == Gen::MODEL_ID

Gen.install!
client = BedrockClient.new
runtime = client.instance_variable_get(:@client)
result = Gen.converse(
  client: runtime,
  prompt: Gen::PREFLIGHT_PROMPT,
  max_tokens: 512,
  temperature: 0
)

payload = result.merge(
  exact: result[:text].include?("PREFLIGHT_OK"),
  fallback: false,
  pricing: Gen::PRICING
)
path = Rails.root.join("tmp/f1cal/grok47_preflight.json")
FileUtils.mkdir_p(path.dirname)
File.write(path, JSON.pretty_generate(payload))
puts JSON.pretty_generate(payload)
abort "preflight text missing PREFLIGHT_OK" unless payload[:exact]
abort "preflight priced at zero" if payload[:cost_usd].to_f <= 0
