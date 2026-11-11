# frozen_string_literal: true

# Haiku 5.5 companion pass on the product route. Retrieve reads the
# production knowledge base with the manual pin, the session and the case
# record persist in the local database, and generation is one Anthropic
# Messages call per turn (claude-haiku-5-5, no effort, no thinking).
#
#   OPUS55_ITERATION=it1 OPUS55_PLAN=guion2:1      first turn of G2 only
#   OPUS55_PLAN=guion2,guion1,elemont              the three scripts
#   OPUS55_EXECUTE=1                               admit the grant and call
#
# Without OPUS55_EXECUTE the script prints the ceiling and stops before any
# model. An access rejection, a provider error, a turn without raw text, or a
# request whose shape differs from the plan stops the pass on that turn.

require "digest"
require "json"
require "fileutils"

ENV["GUION2_DIRECT_REQUIRE"] = "1"
load Rails.root.join("script/field_companion/run_guion2.rb")

module Haiku55Companion
  # Fourth grant, authorized at 320 → 328 for one Elemont T1–T4 run. The
  # earlier grants (-20261107 after 245, -b after 293, -c after 304) are
  # spent and stay in the ledger.
  EXECUTION_ID = "opus55-haiku55-20261107-d"
  FROM_ATTEMPTS = 318
  NEXT_CAP = 328
  # Entries 319 and 320 were stored above attempt 318 by the previous grant,
  # so the window holds eight new calls plus those two.
  GRANT_CALLS = 10
  GRANT_USD = "0.100000"
  MODEL_ID = "claude-haiku-5-5"
  KB_ID = "Y7RZWMFJSR"
  RERANK_USD = BigDecimal("0.002")
  NETWORK_HOSTS = %w[
    bedrock-runtime.us-east-1.amazonaws.com bedrock-agent-runtime.us-east-1.amazonaws.com api.anthropic.com
  ].freeze
  NETWORK_PROBES = 12
  NETWORK_WAIT_SECONDS = 10
  NETWORK_OPEN_TIMEOUT = 3
  ROOT = Rails.root.join("tmp/field_companion/opus55")
  ELEMONT_DOCUMENT_UID = "dcc8e046-037d-48a6-8913-1992aed28507"
  ELEMONT_TURNS = [
    "Estoy con un montacargas Elemont MH que no responde a las llamadas. No veo un código de falla y todavía no he hecho mediciones. En el plano, ¿el trazo de Chapa nivel 2 se une a PasCom 24V donde lo cruza?",
    "Me equivoqué: la referencia que estoy revisando es Chapa nivel 3, no Chapa nivel 2. ¿Cómo aparece ese recorrido?",
    "¿Y dónde está Seguridad Puerta del mismo nivel y qué tiene a sus lados en la línea?",
    "No sé cómo identificar en el equipo cuál es la Chapa nivel 3. ¿Con lo que tenemos puedes decirme qué reemplazar?"
  ].freeze
  SCRIPTS = {
    "guion2" => { "document_uid" => GUION2_DOCUMENT_UID, "turns" => GUION2_TURNS },
    "guion1" => { "document_uid" => GUION2_DOCUMENT_UID, "turns" => GUION1_TURNS },
    "elemont" => { "document_uid" => ELEMONT_DOCUMENT_UID, "turns" => ELEMONT_TURNS }
  }.freeze
  HASHED_FILES = %w[
    app/prompts/bedrock/companion_direct.txt
    app/services/rag/companion_direct_answer.rb
    app/services/rag/companion_case_record.rb
    app/services/rag/companion_case_write.rb
    app/services/rag/companion_turn_publication.rb
    app/services/rag/companion_claim_backing.rb
    app/services/rag/turn_interpreter.rb
    app/services/bedrock_rag_service.rb
    app/controllers/concerns/rag_query_concern.rb
    app/models/conversation_session.rb
    script/field_companion/run_haiku55_companion.rb
  ].freeze

  module_function

  def run(io: $stdout)
    prepare_environment
    iteration = ENV["OPUS55_ITERATION"].presence || "it0"
    plan = parse_plan(ENV["OPUS55_PLAN"].presence || "guion2:1")
    directory = ROOT.join(iteration)
    FileUtils.mkdir_p(directory)
    ceiling = ceiling_document(plan)
    File.write(directory.join("ceiling.json"), JSON.pretty_generate(ceiling))
    File.write(directory.join("manifest.json"), JSON.pretty_generate(manifest)) unless directory.join("manifest.json").file?
    io.puts JSON.generate(ceiling.except("per_turn"))
    return 0 unless ENV["OPUS55_EXECUTE"] == "1"
    return refuse(io, ceiling["decision"]) unless ceiling["decision"] == "execute"

    spend = assignment_spend
    return 2 unless admit!(spend, io)

    arm!(spend)
    return refuse(io, "ledger_not_armed:#{Rag::LocalPassLedger.missing_requirements.join(',')}") unless Rag::LocalPassLedger.armed?

    codes = plan.map { |name, count| run_script(io, directory, name, count) }
    codes.all?(&:zero?) ? 0 : 2
  end

  def parse_plan(text)
    text.split(",").map { |part|
      name, count = part.strip.split(":")
      turns = SCRIPTS.fetch(name)["turns"]
      [ name, count ? Integer(count).clamp(1, turns.size) : turns.size ]
    }
  end

  def prepare_environment
    ENV["RAG_COMPANION_GENERATION"] = "direct"
    ENV["COMPANION_DIRECT_PROVIDER"] = "anthropic"
    ENV["COMPANION_DIRECT_MODEL_ID"] = MODEL_ID
    ENV["COMPANION_DIRECT_MAX_TOKENS"] = max_tokens.to_s
    ENV.delete("COMPANION_DIRECT_EFFORT")
    if thinking_mode
      ENV["COMPANION_DIRECT_THINKING"] = thinking_mode
    else
      ENV.delete("COMPANION_DIRECT_THINKING")
    end
    # One attempt: a transport timeout stops the turn instead of spending the grant on retries.
    ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = "1"
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    ENV["AWS_RETRY_MODE"] = "standard"
    # A slow mobile link needs more than the 5 s default to open TCP; it costs nothing.
    ENV["AWS_HTTP_OPEN_TIMEOUT"] = "15"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = KB_ID
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = EXECUTION_ID
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = Guion2Direct.spend_path
  end

  def max_tokens
    Integer(ENV["OPUS55_MAX_TOKENS"].presence || "4000")
  end

  # adaptive is the product default. disabled is the only off switch.
  def thinking_mode
    value = ENV["OPUS55_THINKING"].to_s.strip
    return value if %w[adaptive disabled].include?(value)

    "adaptive"
  end

  def per_turn_ceiling
    interpreter_in = Rag::TurnInterpreter::PROMPT.length + 4_096
    generation_in = Rag::CompanionDirectAnswer::SYSTEM_PROMPT.length +
      Rag::CompanionDirectAnswer::HISTORY_MAX_CHARS +
      Rag::CompanionPlan::STATEMENTS_MAX_CHARS + Rag::CompanionCaseRecord::MAX_PASSAGE_CHARS + 2_000
    interpreter = Rag::LocalPassLedger.price(Rag::TurnInterpreter::TRACKING_MODEL_ID, interpreter_in, Rag::TurnInterpreter.max_output_tokens)
    generation = Rag::LocalPassLedger.price(Rag::CompanionDirectAnswer.tracking_model_id, generation_in, max_tokens)
    { "interpreter" => interpreter, "generation" => generation, "interpreter_in" => interpreter_in, "generation_in" => generation_in }
  end

  def ceiling_document(plan)
    ledger = JSON.parse(File.read(Guion2Direct.spend_path))
    turn = per_turn_ceiling
    turns = plan.sum { |_name, count| count }
    ledger_worst = (turn["interpreter"] + turn["generation"]) * turns
    rerank = RERANK_USD * turns
    granted = Array(ledger["executions"]).find { |row| row.is_a?(Hash) && row["id"] == EXECUTION_ID }
    window = window_usage(ledger, granted ? granted["after_attempt"].to_i : FROM_ATTEMPTS)
    room_usd = BigDecimal(GRANT_USD) - window["exposure"]
    room_calls = GRANT_CALLS - window["count"]
    global = decimal(ledger["committed"]) + decimal(ledger["unknown"]) + ledger_worst
    shape_ok = Rag::CompanionDirectAnswer.provider == "anthropic" &&
      Rag::CompanionDirectAnswer.configured_model_id == MODEL_ID &&
      Rag::CompanionDirectAnswer.effort.nil? && Rag::CompanionDirectAnswer.thinking_mode == thinking_mode &&
      Rag::CompanionDirectAnswer.generation_max_tokens == max_tokens
    key_present = ENV["ANTHROPIC_API_KEY"].present? || Rails.application.credentials.dig(:anthropic, :api_key).present?
    pins = plan.to_h { |name, _count|
      document = KbDocument.find_by(document_uid: SCRIPTS[name]["document_uid"])
      [ name, document&.display_s3_uri(KbDocument::KB_BUCKET) ]
    }
    decision = if !Guion2Direct.local_databases?
      "not_local_databases"
    elsif SharedSession::ENABLED
      "shared_session"
    elsif !key_present
      "anthropic_api_key_missing"
    elsif !shape_ok
      "request_shape"
    elsif pins.values.any?(&:blank?)
      "pin_missing"
    elsif ledger_worst > room_usd || turns * 2 > room_calls
      "grant_does_not_cover_plan"
    elsif global > BigDecimal(Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD)
      "global_cap"
    elsif !granted && ledger["attempts"].to_i != FROM_ATTEMPTS
      "ledger_not_at_from_attempts"
    else
      "execute"
    end
    {
      "status" => "ceiling",
      "decision" => decision,
      "execution_id" => EXECUTION_ID,
      "granted" => granted.present?,
      "plan" => plan,
      "turns" => turns,
      "ledger_calls" => turns * 2,
      "model_id" => MODEL_ID,
      "provider" => "anthropic",
      "api" => "messages",
      "max_tokens" => max_tokens,
      "temperature" => "omitted (anthropic_payload does not send it)",
      "effort" => nil,
      "thinking" => thinking_mode || "provider default (not sent)",
      "tools" => nil,
      "interpreter_model_id" => Rag::TurnInterpreter::MODEL_ID,
      "interpreter_max_tokens" => Rag::TurnInterpreter::MAX_TOKENS,
      "per_turn" => turn.transform_values { |value| value.is_a?(BigDecimal) ? money(value) : value },
      "ledger_ceiling_usd" => money(ledger_worst),
      "rerank_ceiling_usd" => money(rerank),
      "grant_usd" => GRANT_USD,
      "grant_calls" => GRANT_CALLS,
      "window_entries" => window["count"],
      "window_exposure_usd" => money(window["exposure"]),
      "room_usd" => money(room_usd),
      "room_calls" => room_calls,
      "global_after_usd" => money(global),
      "anthropic_key_present" => key_present,
      "pins" => pins,
      "knowledge_base_id" => KB_ID,
      "attempts" => ledger["attempts"],
      "call_cap" => ledger.dig("authorization", "call_cap"),
      "committed" => ledger["committed"],
      "unknown" => ledger["unknown"],
      "system_sha256" => Digest::SHA256.hexdigest(Rag::CompanionDirectAnswer::SYSTEM_PROMPT)
    }
  end

  def manifest
    {
      "at" => Time.now.utc.iso8601,
      "head" => `git -C #{Rails.root} rev-parse HEAD`.strip,
      "baseline_ref" => `git -C #{Rails.root} rev-parse refs/opus55/baseline 2>/dev/null`.strip,
      "files" => HASHED_FILES.to_h { |path|
        full = Rails.root.join(path)
        [ path, full.file? ? Digest::SHA256.file(full).hexdigest : nil ]
      },
      "system_sha256" => Digest::SHA256.hexdigest(Rag::CompanionDirectAnswer::SYSTEM_PROMPT)
    }
  end

  def window_usage(ledger, after)
    rows = Array(ledger["entries"]).select { |entry| entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released" }
    { "count" => rows.size, "exposure" => rows.sum(BigDecimal("0")) { |entry| exposure(entry) } }
  end

  def admit!(spend, io)
    granted = spend.admit_execution!(
      id: EXECUTION_ID, cost_usd: GRANT_USD, calls: GRANT_CALLS,
      bump_call_cap_to: NEXT_CAP, bump_only_if_attempts: FROM_ATTEMPTS
    )
    snap = spend.snapshot
    unless snap.dig("authorization", "call_cap").to_i == NEXT_CAP && granted["after_attempt"].to_i == FROM_ATTEMPTS
      io.puts JSON.generate("status" => "refused", "reason" => "bump_not_applied", "authorization" => snap["authorization"])
      return nil
    end
    granted
  rescue Rag::AssignmentSpend::Stop => error
    io.puts JSON.generate("status" => "refused", "reason" => error.message)
    nil
  end

  def arm!(spend)
    ledger = JSON.parse(File.read(Guion2Direct.spend_path))
    window = window_usage(ledger, FROM_ATTEMPTS)
    ENV["RAG_LOCAL_PASS_GUARD"] = "1"
    ENV["RAG_LOCAL_PASS_CALL_CAP"] = (NEXT_CAP - spend.snapshot["attempts"].to_i).to_s
    ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = money(BigDecimal(GRANT_USD) - window["exposure"])
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    # Only the interpreter and the Haiku 5.5 companion call may be sent; any
    # other generator or route stops before the request.
    ENV["RAG_LOCAL_PASS_ALLOWED_CALLS"] = "converse@#{Rag::TurnInterpreter::MODEL_ID},converse_message@#{Rag::CompanionDirectAnswer.tracking_model_id}"
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
  end

  def run_script(io, root, name, count)
    spec = SCRIPTS.fetch(name)
    directory = root.join(name)
    FileUtils.mkdir_p(directory)
    document = KbDocument.find_by(document_uid: spec["document_uid"])
    return refuse(io, "document:#{name}") unless document

    account = document.account
    user = User.where(account_id: account.id).order(:id).first
    saved = read_json(directory.join("pin.json"))
    session = saved && ConversationSession.find_by(id: saved["session_id"])
    unless session
      session = ConversationSession.create!(
        identifier: "web:opus55-#{name}-#{SecureRandom.hex(4)}",
        channel: "web", expires_at: 1.day.from_now,
        user: user, account: account, conversation_history: []
      )
      return refuse(io, "pin:#{name}") unless session.pin_kb_document!(document)
    end
    pin = Array(session.document_focus).first
    expected = document.display_s3_uri(KbDocument::KB_BUCKET)
    File.write(directory.join("pin.json"), JSON.pretty_generate(
      "session_id" => session.id, "document_uid" => document.document_uid,
      "pinned_uri" => pin && pin["source_uri"], "indexed_uri" => expected,
      "matches_indexed_uri" => pin && pin["source_uri"] == expected, "knowledge_base_id" => KB_ID
    ))
    rows = []
    spec["turns"].first(count).each_with_index do |question, index|
      number = index + 1
      turn_dir = directory.join(format("turn-%d", number))
      status = read_json(turn_dir.join("status.json"))
      if status && status["status"] == "returned" && status["block_reason"].blank?
        rows << status.merge("resumed" => true)
        next
      end
      return refuse(io, "network_unreachable_before_turn_#{number}") unless network_ready?(io)

      FileUtils.mkdir_p(turn_dir)
      File.write(turn_dir.join("before.json"), JSON.pretty_generate(
        "literal_message" => question, "episode_id" => session.reload.live_episode_id, "case_evidence" => session.case_evidence
      ))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      row = Guion2Direct.one_turn(session, user, question, number, directory)
      row["wall_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      reason = block_reason(row, turn_dir, expected)
      row["block_reason"] = reason if reason
      File.write(turn_dir.join("status.json"), JSON.pretty_generate(row))
      File.write(turn_dir.join("trace.json"), JSON.pretty_generate(Haiku55Trace.turn(turn_dir, question, expected)))
      rows << row
      io.puts JSON.generate("script" => name, "turn" => number, "status" => row["status"], "block_reason" => reason, "wall_ms" => row["wall_ms"])
      break if reason
    end
    payload = {
      "status" => rows.size == count && rows.all? { |row| row["status"] == "returned" && row["block_reason"].blank? } ? "executed" : "stopped",
      "script" => name, "session_id" => session.id, "episode_id" => session.reload.live_episode_id,
      "turns" => rows.map { |row| row.slice("turn", "status", "block_reason", "wall_ms", "route_outcome", "resumed") },
      "ledger" => Guion2Direct.read_ledger
    }
    File.write(directory.join("summary.json"), JSON.pretty_generate(payload))
    payload["status"] == "executed" ? 0 : 2
  end

  def block_reason(row, turn_dir, expected_uri)
    return "provider_rejected" if row["provider_rejection"].present?
    return "provider_error:#{row['error_class']}" if row["error_class"].present?
    return row["status"].presence || "failed" if row["status"] != "returned"

    raw = turn_dir.join("raw.txt")
    return "generation_without_text" unless raw.file? && raw.read.strip.present?

    events = Array((read_json(turn_dir.join("capture.json")) || {})["events"])
    request = events.reverse.find { |event| event["kind"] == "converse" && event["provider"] == "anthropic" }
    return "request_not_captured" unless request
    sent_thinking = request.dig("thinking", "type")
    return "request_shape" unless request["model"] == MODEL_ID && request["max_tokens"].to_i == max_tokens &&
      sent_thinking == thinking_mode && !request.key?("output_config") && !request.key?("tools")

    interpreter = events.reverse.find { |event| event["kind"] == "interpreter_request" }
    body = interpreter.is_a?(Hash) ? interpreter["anthropic_body"] : nil
    return "interpreter_shape" unless body.is_a?(Hash) && body["model"] == "claude-haiku-5-5" &&
      body["max_tokens"].to_i == Rag::TurnInterpreter.max_output_tokens &&
      body.dig("output_config", "effort") == Rag::TurnInterpreter::EFFORT &&
      body.dig("tool_choice", "name") == "turn_perception" &&
      !body.key?("temperature") && !body.key?("thinking")

    retrieve = events.reverse.find { |event| event["kind"] == "retrieve" }
    return "retrieve_missing" unless retrieve
    return "retrieve_target" unless retrieve["knowledge_base_id"].to_s == KB_ID &&
      Haiku55Trace.strings(retrieve.dig("retrieval_configuration", "vector_search_configuration", "filter")).include?(expected_uri)

    nil
  end

  def assignment_spend
    Rag::AssignmentSpend.new(path: Guion2Direct.spend_path, call_cap: NEXT_CAP, cost_cap_usd: Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD)
  end

  def exposure(entry)
    case entry["status"]
    when "settled", "kept" then decimal(entry["actual_usd"])
    when "unknown" then decimal(entry["reserved_usd"].presence || entry["ceiling_usd"])
    when "reserved" then decimal(entry["ceiling_usd"])
    else BigDecimal("0")
    end
  end

  def read_json(path)
    path.file? ? JSON.parse(path.read) : nil
  rescue JSON::ParserError
    nil
  end

  def money(value)
    format("%.6f", decimal(value))
  end

  def decimal(value)
    BigDecimal(value.nil? ? "0" : value.to_s)
  end

  # The operator works on an intermittent link. A TLS handshake to each
  # endpoint sends no API request and spends no ledger call, so a dropped
  # link waits here instead of burning a turn on Net::OpenTimeout.
  def network_ready?(io, probes: NETWORK_PROBES, wait: NETWORK_WAIT_SECONDS, reachable: method(:tls_reachable?))
    probes.times do |probe|
      failed = NETWORK_HOSTS.reject { |host| reachable.call(host) }
      return true if failed.empty?

      io.puts JSON.generate("status" => "network_wait", "probe" => probe + 1, "failed" => failed)
      sleep wait
    end
    false
  end

  def tls_reachable?(host)
    http = Net::HTTP.new(host, 443)
    http.use_ssl = true
    http.open_timeout = NETWORK_OPEN_TIMEOUT
    http.start { }
    true
  rescue StandardError
    false
  end

  def refuse(io, reason)
    io.puts JSON.generate("status" => "refused", "reason" => reason, "stopped_before_model" => true)
    2
  end
end

# One trace per turn: literal message to persisted state, with the request
# the next turn will read taken from that turn's own capture.
module Haiku55Trace
  module_function

  def turn(turn_dir, question, expected_uri)
    events = Array((Haiku55Companion.read_json(turn_dir.join("capture.json")) || {})["events"])
    last = ->(kind) { events.reverse.find { |event| event["kind"] == kind } }
    request = events.reverse.find { |event| event["kind"] == "converse" && event["provider"] == "anthropic" }
    direct = events.reverse.find { |event| event["kind"] == "companion_direct" }
    retrieve = last.call("retrieve")
    episode = Haiku55Companion.read_json(turn_dir.join("episode.json")) || {}
    history = last.call("assistant_history") || {}
    {
      "literal_message" => question,
      "user_message" => last.call("user_message")&.slice("original", "transform"),
      "episode_delta" => events.select { |event| event["kind"] == "episode_delta" }.map { |event| event.except("run_id", "account_id", "user_id") },
      "effective_query" => last.call("effective_query")&.slice("effective", "composed", "components", "sent_turn"),
      "case_record_retrieval" => last.call("case_record_retrieval")&.except("run_id", "account_id", "user_id"),
      "retrieve" => retrieve && {
        "knowledge_base_id" => retrieve["knowledge_base_id"],
        "query" => retrieve.dig("retrieval_query", "text"),
        "number_of_results" => retrieve.dig("retrieval_configuration", "vector_search_configuration", "number_of_results"),
        "filter_includes_pin" => strings(retrieve.dig("retrieval_configuration", "vector_search_configuration", "filter")).include?(expected_uri)
      },
      "retries" => events.select { |event| event["kind"] == "retry" }.map { |event| event.except("run_id", "account_id", "user_id") },
      "rerank" => last.call("companion_rerank")&.except("run_id", "account_id", "user_id"),
      "sources" => Array(last.call("case_record_sources")&.dig("sources")),
      "request" => request && {
        "model" => request["model"], "max_tokens" => request["max_tokens"],
        "system_sha256" => Digest::SHA256.hexdigest(request["system"].is_a?(Hash) ? File.read(turn_dir.join(request.dig("system", "path"))) : request["system"].to_s),
        "keys" => request.keys.sort,
        "messages" => Array(request["messages"]).map { |message| { "role" => message["role"], "chars" => message_text(turn_dir, message).length } }
      },
      "raw" => direct && direct.slice("stop_reason", "chars", "input_tokens", "output_tokens", "latency_ms", "block_types").merge(
        "thinking_chars" => direct["thinking"].is_a?(String) ? direct["thinking"].length : direct["thinking"]
      ),
      "thinking" => request && request["thinking"],
      "claim_backing" => last.call("companion_claim_backing")&.except("run_id", "account_id", "user_id"),
      "publication" => last.call("companion_publication")&.slice("accepted", "reasons", "quotes", "stop_reason"),
      "published_chars" => turn_dir.join("published.txt").file? ? turn_dir.join("published.txt").read.length : 0,
      "prompt_reply" => history["prompt_reply"],
      "persisted" => {
        "episode_id" => episode["episode_id"],
        "case_evidence" => episode["case_evidence"].is_a?(Hash) ? episode["case_evidence"].merge("sources" => Array(episode.dig("case_evidence", "sources")).map { |row| row.except("text").merge("chars" => row["text"].to_s.length) }) : nil
      },
      "ledger" => Haiku55Companion.read_json(turn_dir.join("ledger.json"))
    }
  end

  def message_text(turn_dir, message)
    Array(message["content"]).map { |block|
      text = block["text"]
      text.is_a?(Hash) && text["path"] ? File.read(turn_dir.join(text["path"])) : text.to_s
    }.join
  rescue StandardError
    ""
  end

  def strings(value)
    case value
    when String then [ value ]
    when Hash then value.each_value.flat_map { |item| strings(item) }
    when Array then value.flat_map { |item| strings(item) }
    else []
    end
  end
end

if ENV["OPUS55_REQUIRE"] == "1"
  # Loaded by a test.
else
  exit Haiku55Companion.run
end
