# frozen_string_literal: true

# Effects: five local Haiku calls, new development sessions, and one ledger
# admission on the existing assignment file. Does not edit production data
# or session 198. The product prompt is the quote contract. This script
# checks that its copy matches that prompt.
require "json"
require "bigdecimal"
require "fileutils"
require "digest"

SPEND_PATH = Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json").to_s
SOURCE_ROOT = Rails.root.join("tmp/field_companion/validation_captures/vf5-t2-candidate-20261103T213216Z")
EXECUTION_ID = "vf5-t2-quote-20261103"
STAMP = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
RUN_ID = "vf5-t2-quote-#{STAMP}"
SUMMARY_DIR = Rails.root.join("tmp/field_companion/vf5_t2_interpreter", RUN_ID)
CAPTURE_ROOT = Rails.root.join("tmp/field_companion/validation_captures", RUN_ID)
COST_LIMIT = BigDecimal("0.10")
GLOBAL_LIMIT = BigDecimal("4")
AUTH_LIMIT = BigDecimal("0.75")
CALLS = 5
MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
TURNS = {
  "t2" => "Fue solo la primera apertura. Después volvió a abrir y cerrar como antes.",
  "led" => "El LED STATUS está apagado.",
  "mixed" => "El LED STATUS está apagado. Fue solo la primera apertura.",
  "ac" => "Esto pasa solo cuando hace mucho calor afuera. De noche enfría bien.",
  "code" => "Muestra E4. Solo aparece después de las dos de la tarde."
}.freeze
CODE_QUESTION = "¿Qué código muestra el display y el ventilador interior gira?"
AC_QUESTION = "¿Lo que ves coincide con «El compresor arranca y se detiene a los pocos segundos» o con «El compresor no arranca y el ventilador funciona»?"
CASE_ORDER = [
  { "id" => "t2", "label" => "T2", "context" => "captured_t2" },
  { "id" => "led", "label" => "direct", "context" => "captured_t2" },
  { "id" => "mixed", "label" => "mixed", "context" => "captured_t2" },
  { "id" => "ac", "label" => "synthetic_ac", "context" => "synthetic" },
  { "id" => "code", "label" => "synthetic_code", "context" => "synthetic" }
].freeze

def money(value)
  BigDecimal(value.nil? ? "0" : value.to_s)
end

def scrub(text)
  text.to_s.gsub(
    /[^\n]*(?:authorization|x-api-key|x-amz-security-token|aws_secret_access_key|secret_access_key)[^\n]*/i,
    "[redacted]"
  ).slice(0, 300)
end

def plain(value)
  case value
  when Hash
    value.each_with_object({}) { |(key, item), out| out[key.to_s] = plain(item) }
  when Array
    value.map { |item| plain(item) }
  else
    defined?(Aws::Structure) && value.is_a?(Aws::Structure) ? plain(value.to_h) : value
  end
end

def write_json(path, payload)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate(payload))
end

def block!(reason, detail)
  payload = { "status" => "blocked", "reason" => reason, "detail" => detail, "run_id" => RUN_ID }
  path = SUMMARY_DIR.join("preflight.json")
  current = File.file?(path) ? JSON.parse(File.read(path)) : {}
  current = {} unless current.is_a?(Hash)
  write_json(path, current.merge(payload))
  puts JSON.generate("status" => "blocked", "reason" => reason, "detail" => detail, "run_id" => RUN_ID)
  exit 2
end

def load_json(directory)
  JSON.parse(File.read(directory.join("capture.json")))
end

def message_text(capture)
  event = capture["events"].find { |item| item["kind"] == "interpreter_request" }
  event["message_text"].to_s
end

def episode_before(capture)
  event = capture["events"].find { |item| item["kind"] == "episode_delta" && item["episode_before"] }
  raw = event["episode_before"]
  raw.is_a?(String) ? JSON.parse(raw) : raw
end

def exposure_of(entry)
  case entry["status"]
  when "settled", "kept" then money(entry["actual_usd"])
  when "unknown" then money(entry["reserved_usd"].presence || entry["ceiling_usd"])
  when "reserved" then money(entry["ceiling_usd"])
  else BigDecimal("0")
  end
end

def ceiling_for(params)
  args = [ params ]
  Rag::LocalPassLedger.price(
    Rag::LocalPassLedger.model_id_from(args, {}),
    Rag::LocalPassLedger.text_chars([ args, {} ]),
    Rag::LocalPassLedger.output_tokens_from(args, {})
  )
end

def context_without_turn(message)
  parsed = JSON.parse(message)
  parsed.delete("turn")
  parsed
end

def build_cases(prompt, schema)
  base_context = nil
  CASE_ORDER.map { |row|
    interpreter = load_json(SOURCE_ROOT.join(row["id"]))
    flow = load_json(SOURCE_ROOT.join("#{row['id']}-flow"))
    message = message_text(interpreter)
    parsed = JSON.parse(message)
    block!("turn", row["id"]) unless parsed["turn"] == TURNS.fetch(row["id"])
    block!("form", row["id"]) if parsed.dig("work_context", "pending")&.key?("form")
    if row["id"] == "t2"
      base_context = context_without_turn(message)
    elsif row["context"] == "captured_t2"
      block!("context", row["id"]) unless context_without_turn(message) == base_context
    end
    if row["id"] == "code"
      block!("code_question", parsed.dig("work_context", "pending", "question")) unless parsed.dig("work_context", "pending", "question") == CODE_QUESTION
    end
    if row["id"] == "ac"
      block!("ac_question", parsed.dig("work_context", "pending", "question")) unless parsed.dig("work_context", "pending", "question") == AC_QUESTION
    end
    params = Rag::QuoteReplyExperiment.prepare_params(message, prompt: prompt, schema: schema)
    episode = episode_before(flow)
    stored = Array(episode["observations"]).map { |item| item["text"].to_s }
    row.merge("turn" => parsed["turn"], "message" => message, "params" => params, "episode" => episode, "stored_observations" => stored)
  }
end

def tool_input_from(response)
  content = response.output&.message&.content
  block = Array(content).find { |item|
    tool = item.respond_to?(:tool_use) ? item.tool_use : nil
    tool && tool.name == Rag::TurnInterpreter::TOOL_NAME
  }
  return nil unless block

  plain(block.tool_use.input)
end

def usage_from(response)
  usage = response.usage
  return {} unless usage

  {
    "input_tokens" => usage.input_tokens.to_i,
    "output_tokens" => usage.output_tokens.to_i,
    "cache_read_input_tokens" => (usage.cache_read_input_tokens if usage.respond_to?(:cache_read_input_tokens)).to_i,
    "cache_write_input_tokens" => (usage.cache_write_input_tokens if usage.respond_to?(:cache_write_input_tokens)).to_i
  }
end

def export_capture(events, directory)
  FileUtils.mkdir_p(directory)
  document = Rag::ValidationCapture.export_capture(events, directory, run_id: RUN_ID)
  File.write(directory.join("capture.json"), JSON.generate(document))
  File.write(directory.join("ledger.json"), JSON.generate(Rag::LocalPassLedger.snapshot))
  directory
end

def stub_client(input)
  client = Object.new
  client.define_singleton_method(:converse) do |_params|
    tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, input)
    block = Struct.new(:tool_use).new(tool)
    message = Struct.new(:content).new([ block ])
    output = Struct.new(:message).new(message)
    usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
    Struct.new(:output, :usage).new(output, usage)
  end
  client
end

def flow_case(row, raw_input, account, user)
  episode = row["episode"].deep_dup
  updated = Time.zone.parse(episode["updated_at"].to_s)
  refreshed = updated.nil? || updated < Time.current - ConversationSession::EPISODE_WINDOW
  episode["updated_at"] = Time.current.iso8601 if refreshed
  session = ConversationSession.create!(
    identifier: "web:t2-quote-#{row['id']}-#{SecureRandom.hex(3)}",
    channel: "web",
    expires_at: 1.hour.from_now,
    user: user,
    account: account,
    active_episode: episode,
    conversation_history: []
  )
  raise "touched source session" if session.id == 198

  correlation_id = "query:t2-quote-#{row['id']}-#{SecureRandom.hex(3)}"
  events = Rag::ValidationCapture.capture do
    Rag::ValidationCapture.bind(run_id: RUN_ID, session_id: session.id, account_id: account.id, user_id: user.id)
    session.record_user_turn!(
      row["turn"],
      user_id: user.id,
      correlation_id: correlation_id,
      interpreter_client: stub_client(raw_input)
    )
  end
  raise "retrieve during flow" if events.any? { |event| %w[retrieve retrieval_results model_call companion_plan].include?(event["kind"]) }

  directory = export_capture(events, CAPTURE_ROOT.join("#{row['id']}-flow"))
  stored = Rag::ActiveEpisode.parse(session.reload.active_episode)
  report = session.last_answer_report || {}
  perception = events.find { |event| event["kind"] == "perception_applied" } || {}
  user_message = events.find { |event| event["kind"] == "user_message" } || {}
  request = events.find { |event| event["kind"] == "interpreter_request" } || {}
  route = events.find { |event| event["kind"] == "route_decision" } || {}
  persisted = events.find { |event| event["kind"] == "answer_report" && event["stage"] == "persisted" } || {}
  replies = Array(stored.replies).map { |reply|
    {
      "id" => reply["id"],
      "q" => reply["q"],
      "p" => reply["p"],
      "state" => reply["state"],
      "a" => reply["a"],
      "b" => reply["b"],
      "text" => Rag::AnswerContract.reconstruct(reply, session)
    }
  }
  observations = stored.observations.pluck("text")
  {
    "session_id" => session.id,
    "episode_copy_updated_at" => refreshed ? "refreshed" : "original",
    "capture" => directory.to_s,
    "move" => perception["move"],
    "clarification_target" => perception["clarification_target"],
    "valid" => perception["valid"],
    "observations" => observations,
    "perception_observations" => perception["observations"],
    "adjustments" => perception["adjustments"],
    "field_rejections" => perception["field_rejections"],
    "user_transform" => user_message["transform"],
    "turn_transform" => request["turn_transform"],
    "route" => route["result"],
    "retrieval" => route["retrieval"],
    "answer_field" => report["field"],
    "stored_reply_ids" => report["stored"],
    "refused" => report["refused"],
    "persisted" => persisted["persisted"],
    "persisted_result" => persisted["result"],
    "replies" => replies,
    "facts" => stored.facts,
    "identifiers" => stored.identifiers.pluck("value"),
    "pending_id" => stored.pending_question&.dig("id"),
    "pending_question" => stored.pending_question&.dig("question"),
    "part_ids" => Array(stored.pending_question&.dig("parts")).pluck("id"),
    "p1_state" => Rag::AnswerContract.part_state(stored, "p1"),
    "open_part_ids" => Rag::AnswerContract.open_parts(stored).pluck("id"),
    "phrase_coverage" => Rag::QuoteReplyExperiment.phrase_coverage(row["turn"], observations + replies.pluck("text"))
  }
rescue StandardError => error
  { "error_class" => error.class.name, "error" => scrub(error.message) }
end

product_prompt = Rag::TurnInterpreter::PROMPT
product_sha = Digest::SHA256.hexdigest(product_prompt)
block!("product_prompt", product_sha) unless product_sha == Rag::QuoteReplyExperiment::PRODUCT_PROMPT_SHA256
prompt = Rag::QuoteReplyExperiment.prompt_copy(product_prompt)
schema = Rag::QuoteReplyExperiment.schema_copy
prompt_sha = Rag::QuoteReplyExperiment.fingerprint(prompt)
schema_sha = Rag::QuoteReplyExperiment.schema_fingerprint(schema)
block!("product_prompt_copy", prompt_sha) unless prompt_sha == product_sha
block!("product_schema_copy", schema_sha) unless schema_sha == Rag::QuoteReplyExperiment.schema_fingerprint(Rag::TurnPerception.tool_schema)
block!("experimental_prompt", "offset instruction remains") if prompt.include?(Rag::QuoteReplyExperiment::OFFSET_INSTRUCTION)
block!("experimental_schema", "start remains") if schema.dig(:properties, :part_replies, :items, :properties).key?(:start)

cases = build_cases(prompt, schema)
block!("cases", cases.pluck("turn")) unless cases.pluck("turn").uniq.size == 5
cases.each do |row|
  config = row["params"][:inference_config]
  block!("parameters", row["id"]) unless config[:temperature] == 0 && config[:max_tokens] == 512
  block!("model_case", row["id"]) unless row["params"][:model_id] == MODEL_ID
end

ceilings = cases.map { |row| ceiling_for(row["params"]) }
ceiling_sum = ceilings.sum(BigDecimal("0"))
spend = Rag::AssignmentSpend.new(path: SPEND_PATH, call_cap: 185, cost_cap_usd: "4")
snap = spend.snapshot
auth = snap["authorization"] || {}
entries = Array(snap["entries"])
open_hold = money(snap["held_usd"])
committed = money(snap["committed_usd"])
unknown = money(snap["unknown_usd"])
after_auth = auth["after_attempt"].to_i
auth_exposure = entries.sum(BigDecimal("0")) { |entry|
  next BigDecimal("0") unless entry.is_a?(Hash) && entry["id"].to_i > after_auth && entry["status"] != "released"

  exposure_of(entry)
}
preflight = {
  "attempts" => snap["attempts"],
  "call_cap" => snap["call_cap"],
  "cost_cap_usd" => snap["cost_cap_usd"],
  "committed_usd" => snap["committed_usd"],
  "unknown_usd" => snap["unknown_usd"],
  "held_usd" => snap["held_usd"],
  "authorization" => auth,
  "execution_ids" => Array(snap["executions"]).pluck("id"),
  "auth_exposure_after_134" => format("%.6f", auth_exposure),
  "ceilings" => cases.each_with_index.map { |row, index| { "id" => row["id"], "usd" => format("%.6f", ceilings[index]) } },
  "ceiling_sum" => format("%.6f", ceiling_sum),
  "product_prompt_sha256" => product_sha,
  "prompt_sha256" => prompt_sha,
  "schema_sha256" => schema_sha,
  "prompt_bytes" => prompt.bytesize,
  "query_model_id" => BedrockClient::QUERY_MODEL_ID,
  "interpreter_model_id" => Rag::TurnInterpreter::MODEL_ID,
  "schema_matches_current_product" => false
}
write_json(SUMMARY_DIR.join("preflight.json"), preflight)
puts JSON.generate("status" => "ceilings", "sum" => format("%.6f", ceiling_sum), "rows" => preflight["ceilings"])

block!("attempts", snap["attempts"]) unless snap["attempts"] == 180
block!("call_cap", snap["call_cap"]) unless snap["call_cap"] == 180
block!("authorization_id", auth["id"]) unless auth["id"] == "f2f3-joint-after-134"
block!("authorization_after", auth["after_attempt"]) unless auth["after_attempt"] == 134
block!("authorization_cost", auth["cost_usd"]) unless money(auth["cost_usd"]) == AUTH_LIMIT
block!("authorization_cap", auth["call_cap"]) unless auth["call_cap"] == 180
block!("global_cap", snap["cost_cap_usd"]) unless money(snap["cost_cap_usd"]) == GLOBAL_LIMIT
block!("open_hold", snap["held_usd"]) unless open_hold.zero?
block!("ceiling", format("%.6f", ceiling_sum)) unless ceiling_sum <= COST_LIMIT
block!("global_room", format("%.6f", committed + unknown + ceiling_sum)) unless committed + unknown + ceiling_sum <= GLOBAL_LIMIT
block!("authorization_room", format("%.6f", auth_exposure + ceiling_sum)) unless auth_exposure + ceiling_sum <= AUTH_LIMIT
block!("bump_missing", Rag::AssignmentSpend::CALL_CAP_BUMPS[180]) unless Rag::AssignmentSpend::CALL_CAP_BUMPS[180] == 185
block!("cap_list", Rag::LocalPassLedger::ASSIGNMENT_CALL_CAPS) unless Rag::LocalPassLedger::ASSIGNMENT_CALL_CAPS.include?(185)
block!("environment", Rails.env) unless Rails.env.development?

database = ConversationSession.connection_db_config.database.to_s
block!("database", database) unless database == "smart_deal_development"
block!("shared_session", SharedSession::ENABLED) if SharedSession::ENABLED

ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
ENV["AWS_MAX_ATTEMPTS"] = "1"
ENV["AWS_RETRY_MODE"] = "standard"
ENV["RAG_ASSIGNMENT_SPEND_PATH"] = SPEND_PATH
ENV["RAG_LOCAL_PASS_GUARD"] = "1"
ENV["RAG_LOCAL_PASS_CALL_CAP"] = CALLS.to_s
ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = "0.100000"
ENV["RAG_VALIDATION_CAPTURE_RUN"] = RUN_ID
Rag::LocalPassLedger.reset!
Rag::LocalPassLedger.reset_local_process!
block!("ledger", Rag::LocalPassLedger.missing_requirements) unless Rag::LocalPassLedger.armed?

source_session = ConversationSession.find(198)
source_updated = source_session.updated_at
block!("source_session", source_session.id) unless source_session.id == 198
account = source_session.account
user = User.find(source_session.user_id)
client = BedrockClient.new
diagnostics = client.converse_diagnostics
preflight["transport"] = diagnostics
write_json(SUMMARY_DIR.join("preflight.json"), preflight)
block!("region", diagnostics["region"]) unless diagnostics["region"] == "us-east-1"
block!("sdk_attempts", diagnostics["max_attempts"]) unless diagnostics["max_attempts"] == 1
block!("retry_limit", diagnostics["retry_limit"]) unless diagnostics["retry_limit"].to_i.zero?

granted = spend.admit_execution!(
  id: EXECUTION_ID,
  cost_usd: "0.100000",
  calls: CALLS,
  bump_call_cap_to: 185,
  bump_only_if_attempts: 180
)
after_admit = spend.snapshot
block!("admit_cap", after_admit.dig("authorization", "call_cap")) unless after_admit.dig("authorization", "call_cap") == 185
block!("admit_cost", after_admit.dig("authorization", "cost_usd")) unless money(after_admit.dig("authorization", "cost_usd")) == AUTH_LIMIT
block!("admit_global", after_admit["cost_cap_usd"]) unless money(after_admit["cost_cap_usd"]) == GLOBAL_LIMIT
block!("admit_attempts", after_admit["attempts"]) unless after_admit["attempts"] == 180
block!("admit_history", after_admit["entries"].size) unless after_admit["entries"].size == 180

module TrackGuard
  def perform_later(*)
    raise "unexpected TrackBedrockQueryJob"
  end
end
TrackBedrockQueryJob.singleton_class.prepend(TrackGuard)

results = []
stopped = nil
cases.each do |row|
  before = spend.snapshot
  response = nil
  events = Rag::ValidationCapture.capture do
    Rag::ValidationCapture.bind(run_id: RUN_ID)
    Rag::ValidationCapture.correlation = "query:#{RUN_ID}:#{row['id']}"
    Rag::ValidationCapture.attempt = 1
    Rag::ValidationCapture.record(
      "interpreter_request",
      "stage" => "converse",
      "result" => "prepared",
      "operation" => "interpreter",
      "model_id" => row["params"][:model_id],
      "prompt_version" => prompt_sha,
      "system" => prompt,
      "message_text" => row["message"],
      "inference_config" => plain(row["params"][:inference_config]),
      "tool_config" => plain(row["params"][:tool_config]),
      "request" => plain(row["params"])
    )
    Rag::TurnInterpreter.record_attempt_started
    response = client.converse(row["params"])
    raw = tool_input_from(response)
    Rag::ValidationCapture.record(
      "interpreter_response",
      "stage" => "extract",
      "result" => "returned",
      "operation" => "interpreter",
      "stop_reason" => response.stop_reason,
      "usage" => usage_from(response)
    )
    Rag::ValidationCapture.record(
      "interpreter_raw",
      "stage" => "extract",
      "result" => raw.nil? ? "empty" : "tool_input",
      "tool_input" => raw
    )
  end
  directory = export_capture(events, CAPTURE_ROOT.join(row["id"]))
  after = spend.snapshot
  entry = Array(after["entries"]).find { |item| item["id"].to_i == before["attempts"].to_i + 1 }
  raw = events.find { |event| event["kind"] == "interpreter_raw" }&.dig("tool_input")
  usage = events.find { |event| event["kind"] == "interpreter_response" }&.dig("usage")
  prepared = raw.is_a?(Hash) ? Rag::QuoteReplyExperiment.adapt(raw, row["turn"], stored_observations: row["stored_observations"]) : nil
  flow = prepared ? flow_case(row, prepared["adapted"], account, user) : { "skipped" => "no_tool_input" }
  results << {
    "id" => row["id"],
    "label" => row["label"],
    "context" => row["context"],
    "turn" => row["turn"],
    "capture" => directory.to_s,
    "stop_reason" => response&.stop_reason,
    "usage" => usage,
    "cost_usd" => entry && entry["actual_usd"],
    "cost_status" => entry && entry["status"],
    "reserved_usd" => entry && (entry["reserved_usd"] || entry["ceiling_usd"]),
    "raw" => raw,
    "resolutions" => prepared && prepared["resolutions"],
    "observation_notes" => prepared && prepared["observation_notes"],
    "adapted_part_replies" => prepared && prepared.dig("adapted", "part_replies"),
    "adapted_observations" => prepared && prepared.dig("adapted", "observations"),
    "flow" => flow
  }
  break if results.size >= CALLS
rescue Rag::LocalPassLedger::Stop, Rag::AssignmentSpend::Stop => stop
  stopped = scrub(stop.message)
  results << { "id" => row["id"], "label" => row["label"], "turn" => row["turn"], "stopped" => stopped }
  break
rescue StandardError => raised
  error = "#{raised.class}: #{scrub(raised.message)}"
  after = spend.snapshot
  entry = Array(after["entries"]).find { |item| item["id"].to_i > before["attempts"].to_i }
  results << {
    "id" => row["id"],
    "label" => row["label"],
    "context" => row["context"],
    "turn" => row["turn"],
    "error" => error,
    "cost_usd" => entry && (entry["actual_usd"] || entry["reserved_usd"]),
    "cost_status" => entry && entry["status"]
  }
  break
end

source_after = ConversationSession.find(198)
reading_rows = results.map { |row|
  flow = row["flow"].is_a?(Hash) ? row["flow"] : {}
  {
    "id" => row["id"],
    "observations" => flow["observations"],
    "replies" => flow["replies"],
    "facts" => flow["facts"]
  }
}
final_spend = spend.snapshot.except("entries")
summary = {
  "run_id" => RUN_ID,
  "execution" => granted,
  "stopped" => stopped,
  "source_session_id" => 198,
  "source_session_updated_at_unchanged" => source_after.updated_at == source_updated,
  "product_prompt_sha256" => product_sha,
  "prompt_sha256" => prompt_sha,
  "schema_sha256" => schema_sha,
  "prompt_bytes" => prompt.bytesize,
  "model_id" => MODEL_ID,
  "query_model_id" => BedrockClient::QUERY_MODEL_ID,
  "transport" => diagnostics,
  "schema_matches_current_product" => false,
  "calls" => results,
  "reading" => Rag::QuoteReplyExperiment.reading(reading_rows),
  "spend" => final_spend
}
write_json(SUMMARY_DIR.join("summary.json"), summary)
puts JSON.generate("status" => "finished", "summary" => SUMMARY_DIR.join("summary.json").to_s, "calls" => results.size, "stopped" => stopped)
