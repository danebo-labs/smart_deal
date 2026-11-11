# frozen_string_literal: true

# First case-record pass: Guion 2 then Guion 1, each in a clean local
# session. Retrieve uses the production knowledge base. Generation uses
# Bedrock global Haiku 5.5. The historical ledger is appended, not replaced.
#
# Default is the ceiling only. CASE_RECORD_EXECUTE=1 admits the recorded
# step and runs. A provider rejection stops the pass. A published abstention
# is a result and the next turn still runs.

require "digest"
require "json"
require "fileutils"

ENV["GUION2_DIRECT_REQUIRE"] = "1"
load Rails.root.join("script/field_companion/run_guion2.rb")

module CaseRecordLive
  EXECUTION_ID = "case-record-pasada1-20261107"
  CALLS = 16
  NEXT_CAP = 229
  FROM_ATTEMPTS = 213
  MODEL_ID = "global.anthropic.claude-haiku-5-5"
  PIN_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
  KB_ID = "Y7RZWMFJSR"
  # Cohere Rerank 3.5 on Bedrock: $2 per 1,000 searches. One search per turn
  # that actually calls the model. Retrieve has no token price in this code.
  RERANK_USD = BigDecimal("0.002")
  ROOT = Rails.root.join("tmp/field_companion/case_record/pasada1")
  REPORT = Rails.root.join("tmp/field_companion/case_record/INFORME_PASADA1.md")
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
    return 0 unless ENV["CASE_RECORD_EXECUTE"] == "1"
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
    ENV["COMPANION_DIRECT_MAX_TOKENS"] = "16000"
    ENV["COMPANION_DIRECT_EFFORT"] = "high"
    ENV["COMPANION_DIRECT_THINKING"] = "adaptive"
    ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = "1"
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    ENV["AWS_RETRY_MODE"] = "standard"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = KB_ID
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = EXECUTION_ID
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = Guion2Direct.spend_path
  end

  def ceiling_document
    room = authorization_room
    inherited = inherited_window
    interpreter_in = Rag::TurnInterpreter::PROMPT.length + 4_096
    generation_in = Rag::CompanionDirectAnswer::SYSTEM_PROMPT.length +
      Rag::CompanionDirectAnswer::HISTORY_MAX_CHARS +
      Rag::CompanionPlan::STATEMENTS_MAX_CHARS + 12_000 + 2_000
    interpreter = Rag::LocalPassLedger.price(Rag::TurnInterpreter::MODEL_ID, interpreter_in, Rag::TurnInterpreter::MAX_TOKENS)
    generation = Rag::LocalPassLedger.price(MODEL_ID, generation_in, 16_000)
    peak = [ interpreter, generation ].max
    turns = SCRIPTS.sum { |_name, questions| questions.size }
    rerank = RERANK_USD * turns
    full = (interpreter + generation) * turns + rerank
    ledger = Guion2Direct.read_ledger
    raw_ledger = JSON.parse(File.read(Guion2Direct.spend_path))
    granted = Array(raw_ledger["executions"]).any? { |row| row.is_a?(Hash) && row["id"] == EXECUTION_ID }
    document = KbDocument.find_by(document_uid: GUION2_DOCUMENT_UID)
    pin_uri = document&.display_s3_uri(KbDocument::KB_BUCKET)
    account = document&.account
    user = account && User.where(account_id: account.id).order(:id).first
    decision = if !Guion2Direct.send(:local_databases?)
      "not_local_databases"
    elsif !ConversationSession.column_names.include?("case_evidence")
      "case_evidence_column_missing"
    elsif SharedSession::ENABLED
      "shared_session"
    elsif pin_uri != PIN_URI
      "pin_uri_mismatch"
    elsif user.nil?
      "account"
    elsif granted && ledger["call_cap"] == NEXT_CAP
      peak > room ? "peak_reserve_above_authorization_room" : "resume"
    elsif ledger["attempts"] != FROM_ATTEMPTS || ledger["call_cap"] != FROM_ATTEMPTS
      "ledger_not_at_213"
    elsif peak > room
      "peak_reserve_above_authorization_room"
    else
      "execute"
    end
    {
      "status" => "ceiling",
      "stopped_before_model" => true,
      "decision" => decision,
      "execution_id" => EXECUTION_ID,
      "calls" => CALLS,
      "grant_calls" => CALLS + inherited["count"],
      "inherited_entries" => inherited["count"],
      "inherited_exposure_usd" => money(inherited["exposure_usd"]),
      "grant_cost_usd" => money(room + inherited["exposure_usd"]),
      "turns" => turns,
      "model_id" => MODEL_ID,
      "interpreter_model_id" => Rag::TurnInterpreter::MODEL_ID,
      "max_tokens" => 16_000,
      "effort" => "high",
      "thinking" => "adaptive",
      "retries" => 1,
      "interpreter_reserve_usd" => money(interpreter),
      "generation_reserve_usd" => money(generation),
      "peak_reserve_usd" => money(peak),
      "rerank_ceiling_usd" => money(rerank),
      "rerank_price" => "0.002 USD per search, Cohere Rerank 3.5 at $2 per 1,000 searches",
      "retrieve_price" => "no token price in this codebase",
      "full_output_ceiling_usd" => money(full),
      "authorization_room_usd" => money(room),
      "user_authorized_usd" => "1.000000",
      "enforceable_usd" => money(room),
      "authorization_note" => "f2f3-joint-after-134 stays at US$0.75 after attempt 134. A new execution cannot raise that dollar window.",
      "pinned_uri" => pin_uri,
      "pinned_uri_matches" => pin_uri == PIN_URI,
      "ledger" => ledger,
      "system_sha256" => Digest::SHA256.hexdigest(Rag::CompanionDirectAnswer::SYSTEM_PROMPT)
    }
  end

  def admit!(spend, io)
    snap = spend.snapshot
    existing = Array(snap["executions"]).find { |row| row.is_a?(Hash) && row["id"] == EXECUTION_ID }
    return existing if existing

    inherited = inherited_window(spend)
    granted = spend.admit_execution!(
      id: EXECUTION_ID,
      cost_usd: authorization_room(spend) + inherited["exposure_usd"],
      calls: CALLS + inherited["count"],
      bump_call_cap_to: NEXT_CAP,
      bump_only_if_attempts: FROM_ATTEMPTS
    )
    after = spend.snapshot
    unless after.dig("authorization", "id") == "f2f3-joint-after-134" &&
        after.dig("authorization", "call_cap").to_i == NEXT_CAP &&
        after.dig("authorization", "cost_usd") == "0.750000"
      io.puts JSON.generate("status" => "refused", "reason" => "authorization_not_preserved", "stopped_before_model" => true)
      return nil
    end
    granted
  rescue Rag::AssignmentSpend::Stop => error
    io.puts JSON.generate("status" => "refused", "reason" => error.message, "stopped_before_model" => true)
    nil
  end

  def arm!(spend)
    room = authorization_room(spend)
    ENV["RAG_LOCAL_PASS_GUARD"] = "1"
    ENV["RAG_LOCAL_PASS_CALL_CAP"] = CALLS.to_s
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
    return 2 unless Guion2Direct.send(:local_databases?)

    document = KbDocument.find_by(document_uid: GUION2_DOCUMENT_UID)
    return refuse(io, "document") unless document

    account = document.account
    user = User.where(account_id: account.id).order(:id).first if account
    return refuse(io, "account") unless account && user

    saved_pin = read_json(directory.join("pin.json"))
    session = saved_pin && ConversationSession.find_by(id: saved_pin["session_id"])
    unless session
      session = ConversationSession.create!(
        identifier: "web:case-record-#{name}-#{SecureRandom.hex(4)}",
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
      if saved && saved["status"] == "returned"
        rows << saved.merge("resumed" => true)
        next
      end
      if turn_dir.join("capture.json").file?
        rows << { "turn" => number, "status" => "partial", "evidence" => "captured_incomplete" }
        break
      end
      File.write(turn_dir.join("before.json"), JSON.generate(before_state(session, question)))
      row = Guion2Direct.one_turn(session, user, question, number, directory)
      File.write(turn_dir.join("status.json"), JSON.generate(row))
      trace_turn(directory, number, question)
      rows << row
      write_report
      break if row["status"] != "returned"
      break if number == 1 && !manual_matches?(turn_dir)
    end
    payload = {
      "status" => rows.size == turns.size && rows.all? { |row| row["status"] == "returned" } ? "executed" : "stopped",
      "script" => name,
      "session_id" => session.id,
      "episode_id" => session.reload.live_episode_id,
      "turns" => rows,
      "ledger" => Guion2Direct.read_ledger,
      "resume_at" => resume_at(name, rows, turns.size)
    }
    File.write(directory.join("summary.json"), JSON.generate(payload))
    snapshot_ledger("#{name}_ledger_after.json")
    io.puts JSON.generate(payload)
    write_report
    payload["status"] == "executed" ? 0 : 2
  end

  def before_state(session, question)
    {
      "evidence" => "captured",
      "literal_message" => question,
      "episode_id" => session.live_episode_id,
      "history" => session.conversation_history,
      "case_evidence" => session.case_evidence,
      "active_episode" => session.active_episode
    }
  end

  def manual_matches?(turn_dir)
    capture = read_json(turn_dir.join("capture.json"))
    rows = Array(capture["events"]).flat_map { |event|
      next [] unless event["kind"] == "retrieval_results"

      Array(resolve(event["rows"], turn_dir))
    }
    uris = rows.filter_map { |row| row.is_a?(Hash) ? row["uri"].to_s : nil }
    match = uris.any? { |uri| uri.include?("VF5.pdf") || uri.include?("bulk_chunks/1/") }
    File.write(turn_dir.join("manual_check.json"), JSON.generate(
      "uris" => uris.uniq,
      "matches_vf5" => match,
      "evidence" => uris.empty? ? "sin evidencia" : "captured"
    ))
    match
  end

  def trace_turn(directory, number, question)
    turn_dir = directory.join(format("turn-%d", number))
    capture = read_json(turn_dir.join("capture.json"))
    events = Array(capture["events"])
    trace = {
      "evidence" => "captured",
      "script" => directory.basename.to_s,
      "turn" => number,
      "correlation_id" => events.filter_map { |event| event["correlation_id"] }.first,
      "capture" => turn_dir.join("capture.json").to_s,
      "literal_message" => question,
      "stages" => stage_index(events, turn_dir)
    }
    File.write(turn_dir.join("trace.json"), JSON.generate(trace))
  end

  def stage_index(events, turn_dir)
    events.map { |event|
      {
        "sequence" => event["sequence"],
        "kind" => event["kind"],
        "stage" => event["stage"],
        "operation" => event["operation"],
        "result" => event["result"],
        "file" => "app capture via Rag::ValidationCapture.record",
        "method" => event["kind"]
      }
    }
  end

  def write_report
    head = `git -C #{Rails.root} rev-parse --short HEAD`.strip
    lines = []
    lines << "# Pasada 1 del expediente — #{Time.now.utc.iso8601}"
    lines << ""
    lines << "Worktree `/Users/lahirisan/smart_deal-case-record`, HEAD `#{head}`. El checkout original no se modifica. Sin push ni deploy."
    lines << ""
    lines << "Fallo heredado, fuera de esta corrida: `CompanionDirectCaptureReplayTest` compara posiciones de cita. La compuerta staged mide el offset en el manual completo; la captura de la sesión 269 guardó 0. Con la compuerta de HEAD esa prueba pasa. El archivo restaurado conserva el hash `283f0cb09043c25d50f15f751a725a23c985e378a186ed8e44ef302845b43ed8`."
    lines << ""
    ceiling = read_json(ROOT.join("ceiling.json"))
    if ceiling
      lines << "## Techo"
      lines << ""
      lines << "Decisión: `#{ceiling["decision"]}`."
      lines << "Reserva máxima de una llamada: #{ceiling["peak_reserve_usd"]} USD. Intérprete #{ceiling["interpreter_reserve_usd"]}. Generación #{ceiling["generation_reserve_usd"]}."
      lines << "Techo si las ocho generaciones agotan 16.000 tokens de salida, más el intérprete y el rerank: #{ceiling["full_output_ceiling_usd"]} USD."
      lines << "Saldo exigible de `f2f3-joint-after-134`: #{ceiling["authorization_room_usd"]} USD. La autorización de US$1,00 no puede rebasar esa ventana; el mecanismo rechaza cambiar el costo histórico."
      lines << "Entradas ya asentadas que caen en la ventana nueva: #{ceiling["inherited_entries"]} por #{ceiling["inherited_exposure_usd"]} USD. El grant las incluye para no restarlas dos veces. Llamadas nuevas: #{ceiling["calls"]}. Grant: #{ceiling["grant_calls"]} llamadas y #{ceiling["grant_cost_usd"]} USD."
      lines << "Retrieve no tiene precio por token en este código. Rerank: #{ceiling["rerank_price"]}."
      lines << "System SHA `#{ceiling["system_sha256"]}`."
      lines << ""
    end
    ledger = Guion2Direct.read_ledger
    lines << "## Ledger"
    lines << ""
    lines << "Intentos #{ledger["attempts"]} / tope #{ledger["call_cap"]}. Comprometido #{ledger["committed"]} USD. Desconocido #{ledger["unknown"]} USD."
    lines << ""
    SCRIPTS.each do |name, turns|
      summary = read_json(ROOT.join(name, "summary.json"))
      lines << "## #{name}"
      lines << ""
      lines << (summary ? "Estado: `#{summary["status"]}`. Sesión #{summary["session_id"]}. Episodio `#{summary["episode_id"]}`." : "Sin evidencia: este guion no arrancó.")
      lines << "Reanudar: #{summary ? summary["resume_at"] : "turno 1"}."
      turns.each_with_index do |question, index|
        number = index + 1
        turn_dir = ROOT.join(name, format("turn-%d", number))
        published = turn_dir.join("published.txt")
        lines << ""
        lines << "### #{name} T#{number}"
        lines << ""
        lines << "Mensaje literal: #{question}"
        status = read_json(turn_dir.join("status.json"))
        if status
          lines << "Estado: `#{status["status"]}` #{status["error_class"]} #{status["error_message"]}".strip
          lines << "correlation en el resultado: `#{status["route_outcome"]}` escritura `#{status["case_write"]}`."
        end
        if published.file?
          lines << ""
          lines << "Publicado:"
          lines << ""
          lines << "```"
          lines << published.read
          lines << "```"
          lines << ""
          lines << "Captura: `#{turn_dir.join("capture.json")}`."
          check = read_json(turn_dir.join("manual_check.json"))
          lines << "Manual VF5 en Retrieve: #{check ? check["matches_vf5"] : "sin evidencia"}." if number == 1
        else
          lines << ""
          lines << "Sin evidencia de publicación."
        end
      end
      lines << ""
    end
    lines << "## Siguiente paso"
    lines << ""
    lines << next_step
    File.write(REPORT, lines.join("\n"))
  end

  def next_step
    guion2 = read_json(ROOT.join("guion2/summary.json"))
    guion1 = read_json(ROOT.join("guion1/summary.json"))
    return "Ejecutar `CASE_RECORD_EXECUTE=1 bin/rails runner script/field_companion/run_case_record_live.rb` desde el worktree. Empieza en G2 T1." unless guion2
    return "Reanudar G2 en #{guion2["resume_at"]}." unless guion2["status"] == "executed"
    return "G2 está completo. Reanudar G1 en #{guion1["resume_at"]}." if guion1 && guion1["status"] != "executed"
    return "G2 está completo. Ejecutar de nuevo el runner para abrir G1; los turnos de G2 no se repiten si su summary está executed." unless guion1

    "Pasada 1 completa. La segunda repetición y el otro manual siguen fuera de este informe."
  end

  def resume_at(name, rows, total)
    done = rows.count { |row| row["status"] == "returned" }
    return "#{name} completo" if done == total

    "#{name} turno #{done + 1}"
  end

  def snapshot_ledger(name)
    source = Pathname(Guion2Direct.spend_path)
    return unless source.file?

    FileUtils.mkdir_p(ROOT)
    FileUtils.cp(source, ROOT.join(name))
  end

  # Entries whose id is above the attempt counter already belong to an
  # earlier bill. admit_execution! stamps after_attempt from attempts, so
  # those rows fall into the new window. The grant includes them. The sixteen
  # new calls stay inside the parent dollar room.
  def inherited_window(spend = nil)
    snap = spend ? spend.snapshot : JSON.parse(File.read(Guion2Direct.spend_path))
    attempts = snap["attempts"].to_i
    rows = Array(snap["entries"]).select { |entry|
      entry.is_a?(Hash) && entry["id"].to_i > attempts && entry["status"] != "released"
    }
    exposure = rows.sum(BigDecimal("0")) { |entry| entry_exposure(entry) }
    { "count" => rows.size, "exposure_usd" => exposure }
  end

  def entry_exposure(entry)
    case entry["status"]
    when "settled", "kept" then BigDecimal(entry["actual_usd"].to_s)
    when "unknown" then BigDecimal((entry["reserved_usd"].presence || entry["ceiling_usd"]).to_s)
    when "reserved" then BigDecimal(entry["ceiling_usd"].to_s)
    else BigDecimal("0")
    end
  end

  def authorization_room(spend = nil)
    snap = spend ? spend.snapshot : JSON.parse(File.read(Guion2Direct.spend_path))
    auth = snap["authorization"]
    return BigDecimal("0") unless auth.is_a?(Hash)

    after = auth["after_attempt"].to_i
    limit = BigDecimal(auth["cost_usd"].to_s)
    exposure = Array(snap["entries"]).sum(BigDecimal("0")) do |entry|
      next BigDecimal("0") unless entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released"

      case entry["status"]
      when "settled", "kept" then BigDecimal(entry["actual_usd"].to_s)
      when "unknown" then BigDecimal((entry["reserved_usd"].presence || entry["ceiling_usd"]).to_s)
      when "reserved" then BigDecimal(entry["ceiling_usd"].to_s)
      else BigDecimal("0")
      end
    end
    limit - exposure
  end

  def assignment_spend
    Rag::AssignmentSpend.new(
      path: Guion2Direct.spend_path,
      call_cap: NEXT_CAP,
      cost_cap_usd: Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD
    )
  end

  def read_json(path)
    return nil unless path.file?

    JSON.parse(path.read)
  rescue JSON::ParserError
    nil
  end

  def resolve(value, turn_dir)
    return value unless value.is_a?(Hash) && value["path"].present?

    file = turn_dir.join(value["path"])
    return value unless file.file?

    file.read
  end

  def money(value)
    format("%.6f", BigDecimal(value.to_s))
  end

  def refuse(io, reason)
    io.puts JSON.generate("status" => "refused", "reason" => reason, "stopped_before_model" => true)
    write_report
    2
  end
end

if ENV["CASE_RECORD_LIVE_REQUIRE"] == "1"
  # Loaded by a test.
else
  exit CaseRecordLive.run
end
