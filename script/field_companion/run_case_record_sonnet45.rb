# frozen_string_literal: true

# Sonnet 4.5 case-record pass. Guion 2, then Guion 1, each in a new local
# session. Retrieve uses the production knowledge base and the existing VF5
# pin. Generation is one Bedrock converse per turn: temperature 0, 700
# output tokens, no effort and no thinking. The historical authorization
# stays at US$0.75. This pass is the recorded 229 -> 245 step and the
# dollar successor at attempt 229.
#
# Default is the ceiling. CASE_RECORD_SONNET_EXECUTE=1 admits that grant
# and runs. An access rejection or a request shape that would repeat stops
# the pass. A content failure does not: a turn with raw model text continues.

require "digest"
require "json"
require "fileutils"

ENV["GUION2_DIRECT_REQUIRE"] = "1"
load Rails.root.join("script/field_companion/run_guion2.rb")

module CaseRecordSonnet
  EXECUTION_ID = "case-record-sonnet45-20261107"
  NEW_CALLS = 16
  NEXT_CAP = 245
  FROM_ATTEMPTS = 229
  MODEL_ID = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
  PIN_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
  KB_ID = "Y7RZWMFJSR"
  USER_COST = BigDecimal("1.17")
  RERANK_USD = BigDecimal("0.002")
  ROOT = Rails.root.join("tmp/field_companion/case_record/sonnet45_live")
  REPORT = Rails.root.join("tmp/field_companion/case_record/INFORME_SONNET45_PASADA.md")
  SCRIPTS = [
    [ "guion2", GUION2_TURNS ],
    [ "guion1", GUION1_TURNS ]
  ].freeze

  module_function

  def run(io: $stdout)
    prepare_environment
    ceiling = ceiling_document
    FileUtils.mkdir_p(ROOT)
    File.write(ROOT.join("ceiling.json"), JSON.generate(ceiling))
    File.write(ROOT.join("ceiling_before.json"), JSON.generate(ceiling)) unless ROOT.join("ceiling_before.json").file?
    io.puts JSON.generate(ceiling)
    write_report
    return 0 unless ENV["CASE_RECORD_SONNET_EXECUTE"] == "1"
    return refuse(io, ceiling["decision"]) unless %w[execute resume].include?(ceiling["decision"])

    spend = assignment_spend
    snapshot_ledger("ledger_before.json") unless ROOT.join("ledger_before.json").file?
    grant = admit!(spend, io)
    return 2 unless grant

    arm!(spend)
    return refuse(io, "ledger_not_armed") unless Rag::LocalPassLedger.armed?

    codes = []
    SCRIPTS.each do |name, turns|
      code = run_script(io, name, turns)
      codes << code
      break unless code.zero?
    end
    write_report
    codes.all?(&:zero?) ? 0 : 2
  end

  def prepare_environment
    ENV["RAG_COMPANION_GENERATION"] = "direct"
    ENV["COMPANION_DIRECT_PROVIDER"] = "bedrock"
    ENV["COMPANION_DIRECT_MODEL_ID"] = MODEL_ID
    ENV["COMPANION_DIRECT_MAX_TOKENS"] = "700"
    ENV.delete("COMPANION_DIRECT_EFFORT")
    ENV.delete("COMPANION_DIRECT_THINKING")
    ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = "1"
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    ENV["AWS_RETRY_MODE"] = "standard"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = KB_ID
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = EXECUTION_ID
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = Guion2Direct.spend_path
    ENV.delete("CASE_RECORD_EXECUTE")
  end

  def ceiling_document
    ledger = JSON.parse(File.read(Guion2Direct.spend_path))
    spec = Rag::AssignmentSpend::DOLLAR_SUCCESSORS[FROM_ATTEMPTS]
    tail = countable(ledger, FROM_ATTEMPTS)
    parent = countable_through(ledger, 134, FROM_ATTEMPTS)
    since = countable(ledger, 134)
    interpreter_in = Rag::TurnInterpreter::PROMPT.length + 4_096
    generation_in = Rag::CompanionDirectAnswer::SYSTEM_PROMPT.length +
      Rag::CompanionDirectAnswer::HISTORY_MAX_CHARS +
      Rag::CompanionPlan::STATEMENTS_MAX_CHARS + 12_000 + 2_000
    interpreter = Rag::LocalPassLedger.price(Rag::TurnInterpreter::MODEL_ID, interpreter_in, Rag::TurnInterpreter::MAX_TOKENS)
    generation = Rag::LocalPassLedger.price(MODEL_ID, generation_in, 700)
    turns = SCRIPTS.sum { |_name, questions| questions.size }
    ledger_worst = (interpreter + generation) * turns
    rerank = RERANK_USD * turns
    full = ledger_worst + rerank
    successor_cost = BigDecimal(spec["cost_usd"])
    file_room = successor_cost - tail["exposure"]
    user_ledger_room = USER_COST - rerank
    enforceable = [ file_room, user_ledger_room ].min
    granted = Array(ledger["executions"]).find { |row| row.is_a?(Hash) && row["id"] == EXECUTION_ID }
    document = KbDocument.find_by(document_uid: GUION2_DOCUMENT_UID)
    pin_uri = document&.display_s3_uri(KbDocument::KB_BUCKET)
    account = document&.account
    user = account && User.where(account_id: account.id).order(:id).first
    shape_ok = Rag::CompanionDirectAnswer.generation_max_tokens == 700 &&
      Rag::CompanionDirectAnswer.effort.nil? &&
      !Rag::CompanionDirectAnswer.adaptive_thinking? &&
      Rag::CompanionDirectAnswer.configured_model_id == MODEL_ID &&
      Rag::CompanionDirectAnswer.provider == "bedrock" &&
      Rag::TransientBackoff.limit == 1
    windows_ok = closed_windows_hold?(ledger)
    calls_ok = spec["calls"].to_i == NEW_CALLS + tail["count"] &&
      since["count"] + NEW_CALLS <= NEXT_CAP - 134 &&
      ledger["attempts"].to_i + NEW_CALLS <= NEXT_CAP &&
      ledger["seq"].to_i > FROM_ATTEMPTS
    dollars_ok = ledger_worst <= enforceable && full <= USER_COST && generation <= enforceable
    global_ok = decimal(ledger["committed"]) + decimal(ledger["unknown"]) + ledger_worst <= BigDecimal(Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD)
    plan_ok = shape_ok && windows_ok && calls_ok && dollars_ok && global_ok && tail["count"] == 2
    decision = if !Guion2Direct.local_databases?
      "not_local_databases"
    elsif ConversationSession.column_names.exclude?("case_evidence")
      "case_evidence_column_missing"
    elsif SharedSession::ENABLED
      "shared_session"
    elsif pin_uri != PIN_URI
      "pin_uri_mismatch"
    elsif user.nil?
      "account"
    elsif !plan_ok
      "plan_does_not_fit"
    elsif granted
      "resume"
    elsif ledger["attempts"].to_i != FROM_ATTEMPTS || ledger.dig("authorization", "call_cap").to_i != FROM_ATTEMPTS
      "ledger_not_at_229"
    else
      "execute"
    end
    {
      "status" => "ceiling",
      "stopped_before_model" => true,
      "decision" => decision,
      "execution_id" => EXECUTION_ID,
      "new_calls" => NEW_CALLS,
      "execution_calls" => spec["calls"],
      "inherited_entries" => tail["count"],
      "inherited_exposure_usd" => money(tail["exposure"]),
      "historical_authorization_usd" => ledger.dig("authorization", "cost_usd"),
      "historical_exposure_through_229_usd" => money(parent["exposure"]),
      "successor_cost_usd" => spec["cost_usd"],
      "file_room_usd" => money(file_room),
      "user_authorized_usd" => money(USER_COST),
      "enforceable_ledger_usd" => money(enforceable),
      "turns" => turns,
      "model_id" => MODEL_ID,
      "provider" => "bedrock",
      "api" => "converse",
      "inference_config" => { "temperature" => 0, "max_tokens" => 700 },
      "additional_model_request_fields" => nil,
      "interpreter_model_id" => Rag::TurnInterpreter::MODEL_ID,
      "interpreter_inference_config" => { "temperature" => 0, "max_tokens" => Rag::TurnInterpreter::MAX_TOKENS },
      "retries" => 1,
      "interpreter_input_chars" => interpreter_in,
      "generation_input_chars" => generation_in,
      "interpreter_reserve_usd" => money(interpreter),
      "generation_reserve_usd" => money(generation),
      "ledger_ceiling_usd" => money(ledger_worst),
      "rerank_ceiling_usd" => money(rerank),
      "full_ceiling_usd" => money(full),
      "shape_ok" => shape_ok,
      "windows_ok" => windows_ok,
      "calls_ok" => calls_ok,
      "dollars_ok" => dollars_ok,
      "global_ok" => global_ok,
      "pinned_uri" => pin_uri,
      "pinned_uri_matches" => pin_uri == PIN_URI,
      "knowledge_base_id" => KB_ID,
      "attempts" => ledger["attempts"],
      "call_cap" => ledger.dig("authorization", "call_cap"),
      "seq" => ledger["seq"],
      "committed" => ledger["committed"],
      "unknown" => ledger["unknown"],
      "system_sha256" => Digest::SHA256.hexdigest(Rag::CompanionDirectAnswer::SYSTEM_PROMPT)
    }
  end

  def admit!(spend, io)
    snap = spend.snapshot
    existing = Array(snap["executions"]).find { |row| row.is_a?(Hash) && row["id"] == EXECUTION_ID }
    return existing if existing && existing["calls"].to_i == 18 && existing["cost_usd"] == "1.170000"

    granted = spend.admit_execution!(
      id: EXECUTION_ID,
      cost_usd: "1.170000",
      calls: 18,
      bump_call_cap_to: NEXT_CAP,
      bump_only_if_attempts: FROM_ATTEMPTS
    )
    after = spend.snapshot
    auth = after["authorization"] || {}
    unless auth["id"] == "f2f3-joint-after-134" && auth["after_attempt"].to_i == 134 &&
        auth["cost_usd"] == "0.750000" && auth["call_cap"].to_i == NEXT_CAP &&
        granted["after_attempt"].to_i == FROM_ATTEMPTS && granted["calls"].to_i == 18 &&
        granted["cost_usd"] == "1.170000"
      io.puts JSON.generate("status" => "refused", "reason" => "authorization_not_preserved", "stopped_before_model" => true)
      return nil
    end
    granted
  rescue Rag::AssignmentSpend::Stop => error
    io.puts JSON.generate("status" => "refused", "reason" => error.message, "stopped_before_model" => true)
    nil
  end

  def arm!(spend)
    snap = spend.snapshot
    tail = countable(snap, FROM_ATTEMPTS)
    remaining_calls = NEXT_CAP - snap["attempts"].to_i
    file_room = BigDecimal("1.170000") - tail["exposure"]
    user_ledger_room = USER_COST - (RERANK_USD * 8)
    room = [ file_room, user_ledger_room ].min
    ENV["RAG_LOCAL_PASS_GUARD"] = "1"
    ENV["RAG_LOCAL_PASS_CALL_CAP"] = remaining_calls.to_s
    ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = money(room)
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
  end

  def run_script(io, name, turns)
    directory = ROOT.join(name)
    FileUtils.mkdir_p(directory)
    prior = read_json(directory.join("summary.json"))
    return 0 if prior && prior["status"] == "executed"
    return 2 unless Guion2Direct.local_databases?

    document = KbDocument.find_by(document_uid: GUION2_DOCUMENT_UID)
    return refuse(io, "document") unless document

    account = document.account
    user = User.where(account_id: account.id).order(:id).first if account
    return refuse(io, "account") unless account && user

    saved_pin = read_json(directory.join("pin.json"))
    session = saved_pin && ConversationSession.find_by(id: saved_pin["session_id"])
    unless session
      session = ConversationSession.create!(
        identifier: "web:case-record-sonnet45-#{name}-#{SecureRandom.hex(4)}",
        channel: "web",
        expires_at: 1.day.from_now,
        user: user,
        account: account,
        conversation_history: []
      )
      return refuse(io, "pin") unless session.pin_kb_document!(document)
    end

    pin = Array(session.document_focus).first
    File.write(directory.join("pin.json"), JSON.generate(
      "session_id" => session.id,
      "document_uid" => document.document_uid,
      "pinned_uri" => pin && pin["source_uri"],
      "expected_uri" => PIN_URI,
      "matches_indexed_uri" => pin && pin["source_uri"] == PIN_URI,
      "knowledge_base_id" => KB_ID
    ))
    rows = []
    turns.each_with_index do |question, index|
      number = index + 1
      turn_dir = directory.join(format("turn-%d", number))
      FileUtils.mkdir_p(turn_dir)
      saved = read_json(turn_dir.join("status.json"))
      if saved && saved["status"] == "returned" && turn_dir.join("raw.txt").file? && !turn_dir.join("raw.txt").read.strip.empty?
        rows << saved.merge("resumed" => true)
        next
      end
      if saved || turn_dir.join("capture.json").file?
        rows << (saved || { "turn" => number, "status" => "partial" })
        break
      end
      File.write(turn_dir.join("before.json"), JSON.generate(before_state(session, question)))
      row = Guion2Direct.one_turn(session, user, question, number, directory)
      reason = block_reason(row, turn_dir)
      row["block_reason"] = reason if reason
      File.write(turn_dir.join("status.json"), JSON.generate(row))
      trace_turn(directory, number, question)
      rows << row
      write_report
      break if reason
    end
    payload = {
      "status" => rows.size == turns.size && rows.all? { |row| row["status"] == "returned" && row["block_reason"].blank? } ? "executed" : "stopped",
      "script" => name,
      "session_id" => session.id,
      "episode_id" => session.reload.live_episode_id,
      "turns" => rows,
      "ledger" => Guion2Direct.read_ledger
    }
    File.write(directory.join("summary.json"), JSON.generate(payload))
    snapshot_ledger("#{name}_ledger_after.json")
    io.puts JSON.generate(payload.except("turns"))
    write_report
    payload["status"] == "executed" ? 0 : 2
  end

  def before_state(session, question)
    {
      "evidence" => "captured",
      "literal_message" => question,
      "episode_id" => session.live_episode_id,
      "case_evidence" => session.case_evidence
    }
  end

  def block_reason(row, turn_dir)
    return row["status"].presence || "failed" if row["status"] != "returned"
    return "provider_rejected" if row["provider_rejection"].present?
    return "provider_error" if row["error_class"].present?

    raw = turn_dir.join("raw.txt")
    return "generation_without_text" unless raw.file? && raw.read.strip.present?

    capture = read_json(turn_dir.join("capture.json")) || {}
    return "repeating_config" unless request_matches?(capture, turn_dir)
    return "retrieve_target" unless retrieve_matches?(capture, turn_dir)

    nil
  end

  def request_matches?(capture, turn_dir)
    event = events(capture).reverse.find { |item| item["kind"] == "converse" && item["operation"] == "converse_message" }
    return false unless event

    config = event["inference_config"].is_a?(Hash) ? event["inference_config"] : {}
    extra = event["additional_model_request_fields"]
    event["model_id"].to_s == MODEL_ID &&
      config["max_tokens"].to_i == 700 &&
      config.key?("temperature") && config["temperature"].to_f.zero? &&
      (extra.nil? || extra == {}) &&
      event["tool_config"].nil?
  end

  def retrieve_matches?(capture, turn_dir)
    event = events(capture).reverse.find { |item| item["kind"] == "retrieve" }
    return false unless event
    return false unless event["knowledge_base_id"].to_s == KB_ID

    filter = event.dig("retrieval_configuration", "vector_search_configuration", "filter")
    strings(filter).include?(PIN_URI)
  end

  def trace_turn(directory, number, question)
    turn_dir = directory.join(format("turn-%d", number))
    capture = read_json(turn_dir.join("capture.json")) || {}
    list = events(capture)
    trace = {
      "evidence" => "captured",
      "script" => directory.basename.to_s,
      "turn" => number,
      "literal_message" => question,
      "capture" => turn_dir.join("capture.json").to_s,
      "effective_query" => compact_event(list, "effective_query"),
      "case_record_retrieval" => compact_event(list, "case_record_retrieval"),
      "retrieve" => retrieve_summary(list),
      "sources" => source_summary(list),
      "retrieval_rows" => retrieval_summary(list),
      "request" => request_summary(list),
      "raw_chars" => turn_dir.join("raw.txt").file? ? turn_dir.join("raw.txt").read.length : 0,
      "publication" => compact_event(list, "companion_publication"),
      "published" => published_summary(list),
      "persisted" => read_json(turn_dir.join("episode.json")),
      "retries" => list.count { |item| item["kind"] == "retry" },
      "ledger_entries" => ledger_entries_for(list)
    }
    File.write(turn_dir.join("trace.json"), JSON.generate(trace))
  end

  def events(capture)
    Array(capture["events"])
  end

  def compact_event(list, kind)
    event = list.reverse.find { |item| item["kind"] == kind }
    return nil unless event

    event.except("run_id", "account_id", "user_id")
  end

  def retrieve_summary(list)
    event = list.reverse.find { |item| item["kind"] == "retrieve" }
    return nil unless event

    {
      "knowledge_base_id" => event["knowledge_base_id"],
      "query" => event.dig("retrieval_query", "text"),
      "number_of_results" => event.dig("retrieval_configuration", "vector_search_configuration", "number_of_results"),
      "search_type" => event.dig("retrieval_configuration", "vector_search_configuration", "override_search_type"),
      "filter_includes_pin" => strings(event.dig("retrieval_configuration", "vector_search_configuration", "filter")).include?(PIN_URI)
    }
  end

  def source_summary(list)
    event = list.reverse.find { |item| item["kind"] == "case_record_sources" }
    Array(event && event["sources"]).map { |row|
      row.slice("n", "sha256", "origin", "location_uri", "page")
    }
  end

  def retrieval_summary(list)
    event = list.reverse.find { |item| item["kind"] == "retrieval_results" }
    Array(event && event["rows"]).map { |row|
      next row unless row.is_a?(Hash)

      text = row["text"].to_s
      {
        "document" => row["document"],
        "page" => row["page"],
        "uri" => row["uri"],
        "score" => row["score"],
        "decision" => row["decision"],
        "reason" => row["reason"],
        "chars" => text.length,
        "sha256" => Digest::SHA256.hexdigest(text)
      }
    }
  end

  def request_summary(list)
    event = list.reverse.find { |item| item["kind"] == "converse" && item["operation"] == "converse_message" }
    return nil unless event

    {
      "model_id" => event["model_id"],
      "inference_config" => event["inference_config"],
      "additional_model_request_fields" => event["additional_model_request_fields"],
      "tool_config" => event["tool_config"],
      "system_sha256" => Digest::SHA256.hexdigest(Array(event["system"]).map { |block| block.is_a?(Hash) ? block["text"].to_s : block.to_s }.join)
    }
  end

  def published_summary(list)
    event = list.reverse.find { |item| item["kind"] == "published_answer" && event_text(item, "answer") }
    event ||= list.reverse.find { |item| item["kind"] == "published_answer" }
    return nil unless event

    {
      "result" => event["result"],
      "route_outcome" => event["route_outcome"],
      "error_class" => event["error_class"],
      "provider_rejection" => event["provider_rejection"],
      "generation_mode" => event["generation_mode"]
    }
  end

  def event_text(event, key)
    event[key].is_a?(String) && event[key].present?
  end

  def ledger_entries_for(list)
    ids = list.filter_map { |item|
      item.dig("open") ? nil : nil
      item["kind"] == "local_pass_ledger" ? item["seq"] : nil
    }
    rows = Array(JSON.parse(File.read(Guion2Direct.spend_path))["entries"])
    wanted = list.filter_map { |item| item["kind"] == "local_pass_ledger" ? item["attempts"] : nil }
    return [] if wanted.empty?

    ceiling = wanted.max.to_i
    floor = wanted.min.to_i - 2
    rows.select { |row| row.is_a?(Hash) && row["id"].to_i.between?(floor, ceiling + 2) }.map { |row|
      row.slice("id", "status", "ceiling_usd", "actual_usd", "reserved_usd", "model_id", "turn")
    }
  rescue JSON::ParserError
    ids
  end

  def write_report
    ceiling = read_json(ROOT.join("ceiling.json")) || {}
    lines = []
    lines << "# Sonnet 4.5 — pasada G2 y G1"
    lines << ""
    lines << "Worktree `smart_deal-case-record`. Sin despliegue ni reindexación. La pasada 1 y su informe no se reescriben."
    lines << ""
    lines << "## Autorización"
    lines << ""
    lines << "Decisión del techo: `#{ceiling["decision"]}`."
    lines << "Modelo `#{ceiling["model_id"]}`, Bedrock converse, temperatura 0, max_tokens 700, sin effort y sin thinking. Intérprete `#{ceiling["interpreter_model_id"]}`, temperatura 0, max_tokens 512. Un intento por llamada."
    lines << "System SHA `#{ceiling["system_sha256"]}`."
    lines << "Autorización histórica `f2f3-joint-after-134`: US$#{ceiling["historical_authorization_usd"]} después del intento 134. Exposición de entradas con id hasta 229: US$#{ceiling["historical_exposure_through_229_usd"]}."
    lines << "Grant de esta pasada: ejecución `#{ceiling["execution_id"]}`, US$#{ceiling["successor_cost_usd"]} y #{ceiling["execution_calls"]} entradas. De esas, #{ceiling["inherited_entries"]} ya estaban guardadas (US$#{ceiling["inherited_exposure_usd"]}). Llamadas nuevas: #{ceiling["new_calls"]}. Tope de intentos: #{FROM_ATTEMPTS} → #{NEXT_CAP}."
    lines << "Reserva de ledger si cada llamada agota el tope de caracteres: US$#{ceiling["ledger_ceiling_usd"]}. Rerank, fuera del ledger: US$#{ceiling["rerank_ceiling_usd"]}. Total: US$#{ceiling["full_ceiling_usd"]}. Tope exigible del ledger: US$#{ceiling["enforceable_ledger_usd"]}. Autorización del usuario: US$#{ceiling["user_authorized_usd"]}."
    lines << "KB `#{ceiling["knowledge_base_id"]}`. Pin `#{ceiling["pinned_uri"]}`. Coincide: #{ceiling["pinned_uri_matches"]}."
    lines << ""
    ledger = Guion2Direct.read_ledger
    lines << "## Gasto"
    lines << ""
    lines << "Intentos #{ledger["attempts"]} / tope #{ledger["call_cap"]}. Comprometido #{ledger["committed"]} USD. Desconocido #{ledger["unknown"]} USD."
    lines << ""
    SCRIPTS.each do |name, turns|
      summary = read_json(ROOT.join(name, "summary.json"))
      lines << "## #{name}"
      lines << ""
      lines << (summary ? "Estado `#{summary["status"]}`. Sesión #{summary["session_id"]}. Episodio `#{summary["episode_id"]}`." : "Este guion no arrancó.")
      turns.each_with_index do |question, index|
        number = index + 1
        turn_dir = ROOT.join(name, format("turn-%d", number))
        lines << ""
        lines << "### #{name} T#{number}"
        lines << ""
        lines.concat(turn_lines(turn_dir, question))
      end
      lines << ""
    end
    File.write(REPORT, lines.join("\n"))
  end

  def turn_lines(turn_dir, question)
    lines = [ "Mensaje: #{question}" ]
    return lines + [ "", "Sin evidencia de este turno." ] unless turn_dir.join("status.json").file? || turn_dir.join("capture.json").file?

    status = read_json(turn_dir.join("status.json")) || {}
    trace = read_json(turn_dir.join("trace.json")) || {}
    lines << "Estado: `#{status["status"]}` #{status["block_reason"]} #{status["error_class"]} #{status["error_message"]}".strip
    query = trace["effective_query"] || {}
    lines << "Consulta efectiva: #{query["effective"]}"
    lines << "Transformaciones: sent_turn igual al mensaje: #{query["sent_turn"] == question}. Componentes: #{Array(query["components"]).join(", ")}."
    retrieval = trace["case_record_retrieval"] || {}
    lines << "Retrieve del expediente: pregunta `#{retrieval["retrieve_question"]}`. Incluidos #{Array(retrieval["included"]).size}. Omitidos #{Array(retrieval["omitted"]).size}. current_truncated #{retrieval["current_truncated"]}."
    retrieve = trace["retrieve"] || {}
    lines << "Retrieve: KB #{retrieve["knowledge_base_id"]}, #{retrieve["search_type"]}, top #{retrieve["number_of_results"]}, pin en el filtro: #{retrieve["filter_includes_pin"]}."
    lines << "Fuentes enviadas:"
    Array(trace["sources"]).each do |source|
      lines << "- [#{source["n"]}] p.#{source["page"]} #{source["origin"]} `#{source["sha256"]}` #{source["location_uri"]}"
    end
    lines << "Fragmentos de Retrieve:"
    Array(trace["retrieval_rows"]).each do |row|
      lines << "- p.#{row["page"]} #{row["decision"]} #{row["reason"]} chars #{row["chars"]} `#{row["sha256"]}` #{row["uri"]}"
    end
    request = trace["request"] || {}
    lines << "Request: modelo `#{request["model_id"]}`, inference `#{request["inference_config"]}`, campos extra `#{request["additional_model_request_fields"].inspect}`, tools `#{request["tool_config"].inspect}`."
    raw = turn_dir.join("raw.txt")
    lines << ""
    lines << "Crudo:"
    lines << ""
    lines << "```"
    lines << (raw.file? ? raw.read : "")
    lines << "```"
    publication = trace["publication"] || {}
    lines << ""
    lines << "Compuerta: accepted `#{publication["accepted"]}`, stop `#{publication["stop_reason"]}`, outcome publicado `#{trace.dig("published", "route_outcome")}`."
    published = turn_dir.join("published.txt")
    lines << ""
    lines << "Publicado:"
    lines << ""
    lines << "```"
    lines << (published.file? ? published.read : "")
    lines << "```"
    persisted = trace["persisted"] || {}
    evidence = persisted["case_evidence"].is_a?(Hash) ? persisted["case_evidence"] : {}
    lines << ""
    lines << "Estado persistido: episodio `#{persisted["episode_id"]}`, revisión #{evidence["revision"]}, fuentes #{Array(evidence["sources"]).size}, ledger_full #{evidence["ledger_full"]}."
    lines << "Reintentos de transporte en la captura: #{trace["retries"]}."
    lines << "Captura: `#{turn_dir.join("capture.json")}`."
    lines
  end

  def countable(ledger, after)
    rows = Array(ledger["entries"]).select { |entry| counts?(entry, after) }
    { "count" => rows.size, "exposure" => rows.sum(BigDecimal("0")) { |entry| entry_exposure(entry) } }
  end

  def countable_through(ledger, after, boundary)
    rows = Array(ledger["entries"]).select { |entry|
      counts?(entry, after) && entry["id"].to_i <= boundary
    }
    { "count" => rows.size, "exposure" => rows.sum(BigDecimal("0")) { |entry| entry_exposure(entry) } }
  end

  def counts?(entry, after)
    entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released"
  end

  def closed_windows_hold?(ledger)
    grants = Array(ledger["executions"]).select { |row| row.is_a?(Hash) }.sort_by { |row| row["after_attempt"].to_i }
    grants.each_with_index.all? do |grant, index|
      after = grant["after_attempt"].to_i
      boundary = grants[index + 1]&.fetch("after_attempt", nil)&.to_i || FROM_ATTEMPTS
      rows = Array(ledger["entries"]).select { |entry|
        counts?(entry, after) && entry["id"].to_i <= boundary
      }
      exposure = rows.sum(BigDecimal("0")) { |entry| entry_exposure(entry) }
      rows.size <= grant["calls"].to_i && exposure <= decimal(grant["cost_usd"])
    end
  end

  def entry_exposure(entry)
    case entry["status"]
    when "settled", "kept" then decimal(entry["actual_usd"])
    when "unknown" then decimal(entry["reserved_usd"].presence || entry["ceiling_usd"])
    when "reserved" then decimal(entry["ceiling_usd"])
    else BigDecimal("0")
    end
  end

  def strings(value)
    case value
    when String then [ value ]
    when Hash then value.each_value.flat_map { |item| strings(item) }
    when Array then value.flat_map { |item| strings(item) }
    else []
    end
  end

  def assignment_spend
    Rag::AssignmentSpend.new(
      path: Guion2Direct.spend_path,
      call_cap: NEXT_CAP,
      cost_cap_usd: Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD
    )
  end

  def snapshot_ledger(name)
    source = Pathname(Guion2Direct.spend_path)
    return unless source.file?

    FileUtils.mkdir_p(ROOT)
    FileUtils.cp(source, ROOT.join(name))
  end

  def read_json(path)
    return nil unless path.file?

    JSON.parse(path.read)
  rescue JSON::ParserError
    nil
  end

  def money(value)
    format("%.6f", decimal(value))
  end

  def decimal(value)
    BigDecimal(value.nil? ? "0" : value.to_s)
  end

  def refuse(io, reason)
    io.puts JSON.generate("status" => "refused", "reason" => reason, "stopped_before_model" => true)
    write_report
    2
  end
end

if ENV["CASE_RECORD_SONNET_REQUIRE"] == "1"
  # Loaded by a test.
else
  exit CaseRecordSonnet.run
end
