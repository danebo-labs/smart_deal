# frozen_string_literal: true

# Outbound request and ledger for the case-record run. Stops before any
# model, retrieve, or rerank call. CASE_RECORD_EXECUTE is not honored:
# the assignment ledger has no remaining call and this file does not bump it.

require "digest"
require "json"

ENV["RAG_COMPANION_GENERATION"] = "direct"
ENV["COMPANION_DIRECT_MODEL_ID"] = "claude-haiku-5-5"
ENV["COMPANION_DIRECT_MAX_TOKENS"] = "16000"
ENV["COMPANION_DIRECT_EFFORT"] = "high"
ENV["COMPANION_DIRECT_THINKING"] = "adaptive"

LEDGER = Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json")
TURNS = { "guion2" => 3, "guion1" => 5, "other_manual" => 3 }.freeze

def ledger_report
  raw = LEDGER.file? ? LEDGER.binread : ""
  state = raw.empty? ? {} : JSON.parse(raw)
  cap = state["call_cap"].to_i
  cap = state.dig("authorization", "call_cap").to_i if cap.zero?
  attempts = state["attempts"].to_i
  {
    "path" => LEDGER.to_s,
    "sha256" => Digest::SHA256.hexdigest(raw),
    "attempts" => attempts,
    "call_cap" => cap,
    "remaining_calls" => cap - attempts,
    "committed_usd" => state["committed"],
    "unknown_usd" => state["unknown"],
    "authorization_id" => state.dig("authorization", "id"),
    "next_bump" => Rag::AssignmentSpend::CALL_CAP_BUMPS[cap]
  }
end

def request_report(provider)
  ENV["COMPANION_DIRECT_PROVIDER"] = provider
  prepared = Rag::CompanionDirectAnswer.prepare(
    raw_question: "preflight",
    chunks: [],
    episode: nil,
    session: nil
  )
  outbound = Rag::CompanionDirectAnswer.outbound_request(prepared)
  params = prepared.params
  anthropic = Rag::CompanionDirectAnswer.anthropic_payload(params)
  {
    "provider" => provider,
    "generation" => ENV["RAG_COMPANION_GENERATION"],
    "model_id" => params[:model_id],
    "tracking_model_id" => Rag::CompanionDirectAnswer.tracking_model_id,
    "inference_config" => params[:inference_config],
    "tool_config" => params.key?(:tool_config),
    "additional_model_request_fields" => params[:additional_model_request_fields],
    "system_sha256" => Digest::SHA256.hexdigest(prepared.system),
    "system_chars" => prepared.system.length,
    "anthropic_keys" => anthropic.keys.map(&:to_s),
    "anthropic_model" => anthropic[:model],
    "anthropic_max_tokens" => anthropic[:max_tokens],
    "anthropic_effort" => anthropic.dig(:output_config, :effort),
    "anthropic_thinking" => anthropic[:thinking],
    "anthropic_temperature" => anthropic.key?(:temperature),
    "anthropic_tools" => anthropic.key?(:tools),
    "request_sha256" => Digest::SHA256.hexdigest(JSON.generate(outbound.except(:system)))
  }
end

def key_present?
  ENV["ANTHROPIC_API_KEY"].present? || Rails.application.credentials.dig(:anthropic, :api_key).present?
rescue StandardError
  false
end

ledger = ledger_report
turns = TURNS.values.sum * 2
report = {
  "status" => "refused",
  "reason" => "assignment_call_cap_exhausted",
  "stopped_before_model" => true,
  "execute_honored" => false,
  "turns" => TURNS.merge("repetitions" => 2, "total" => turns),
  "calls_per_turn_measured_on_session_269" => {
    "interpreter" => "bedrock global.anthropic.claude-haiku-4-5 converse",
    "retrieve" => "bedrock knowledge base Y7RZWMFJSR",
    "rerank" => "cohere.rerank-v3-5:0",
    "generation" => "companion_direct converse_message"
  },
  "ledger_calls_if_generation_stays_on_bedrock" => turns * 2,
  "ledger_calls_if_generation_moves_to_anthropic" => turns,
  "ledger" => ledger,
  "anthropic_key_present" => key_present?,
  "bedrock_haiku_55_profiles" => [
    "global.anthropic.claude-haiku-5-5",
    "us.anthropic.claude-haiku-5-5"
  ],
  "bedrock_profile_status" => "ACTIVE",
  "bedrock_profile_check" => "aws bedrock list-inference-profiles --region us-east-1",
  "model_id_note" => "claude-haiku-5-5 is the Anthropic Messages id. A Bedrock Converse call needs global.anthropic.claude-haiku-5-5. Effort and adaptive thinking in additional_model_request_fields were not sent.",
  "bedrock_request" => request_report("bedrock"),
  "anthropic_request" => request_report("anthropic"),
  "pin_checked_from_capture" => {
    "session" => 269,
    "knowledge_base_id" => "Y7RZWMFJSR",
    "filter_uri" => "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf",
    "source_uri_in_cited_passage" => "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
  }
}

puts JSON.generate(report)
exit(ledger["remaining_calls"].positive? ? 0 : 2)
