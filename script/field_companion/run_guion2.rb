# frozen_string_literal: true

# Guion 2 on the product route with RAG_COMPANION_GENERATION=direct.
# The default is preflight: it prints the branch and the ledger, then
# returns before any model call.
#
# GUION2_DIRECT_EXECUTE=1 records the authorized 196 -> 211 step when the
# file is still at 195/196, probes one reserve, releases it, and then runs
# the three turns. The grant is sixteen calls: six for this guion and ten
# for guion 1. A retry is not an extra call. GUION1_DIRECT_EXECUTE=1 uses
# the same grant and does not bump again.

GUION2_TURNS = [
  "Estoy con un Fermator VF5+. Después de un corte de alimentación, al volver la corriente la puerta abrió muy despacio. ¿Por dónde empiezo?",
  "Fue solo la primera apertura. Después volvió a abrir y cerrar como antes.",
  "No he cambiado la configuración ni conectado o desconectado la fotocélula. Con lo que te conté, ¿hace falta repetir el autoajuste?"
].freeze

GUION1_TURNS = [
  "Estoy revisando un operador de puerta Fermator VF5+. La puerta se reabre sola durante el cierre. El LED está apagado y no veo obstrucción. Todavía no he revisado el ajuste de #54 ni he hecho mediciones. ¿Cómo seguimos?",
  "Corrijo un dato: el LED está encendido, no apagado.",
  "Revisé la fotocélula y no está activada.",
  "¿Qué sigue?",
  "No sé cómo identificar si está activada la entrada #21 ni cómo saber si hay un contacto cerrado entre #21 y #23. ¿Qué información necesitas de mí para orientar el caso?"
].freeze

GUION2_DOCUMENT_UID = "126cda62-64ad-4469-8674-a29f12e38d48"
GUION2_CALLS = 6
GUION2_GUION1_CALLS = 10
GUION_DIRECT_CALLS = GUION2_CALLS + GUION2_GUION1_CALLS
GUION_DIRECT_CAP = 211
GUION_DIRECT_EXECUTION = "vf5-direct-guiones-20261104"
GUION_DIRECT_KB = "Y7RZWMFJSR"

class Guion2DirectHost
  include RagQueryConcern

  def initialize(account, user)
    @current_account = account
    @current_user = user
  end

  attr_reader :current_account, :current_user

  def execute(question, **)
    execute_rag_query(question, **)
  end
end

module Guion2Direct
  module_function

  def spend_path
    ENV["VF5_ASSIGNMENT_SPEND"].presence ||
      Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json").to_s
  end

  def evidence_root
    Rails.root.join("tmp/field_companion/vf5_direct_guiones")
  end

  def preflight(io: $stdout)
    return refuse(io, "generation") unless ENV["RAG_COMPANION_GENERATION"].to_s.strip == "direct"
    return refuse(io, "shared_session") if SharedSession::ENABLED

    service = BedrockRagService.allocate
    direct = service.send(:companion_generation_direct?)
    return refuse(io, "direct_branch") unless direct

    ledger = read_ledger
    ceilings = call_ceilings
    io.puts JSON.generate(
      "status" => "preflight",
      "stopped_before_model" => true,
      "companion_generation_direct" => direct,
      "shared_session" => SharedSession::ENABLED,
      "shared_session_identifier" => SharedSession::IDENTIFIER,
      "isolated_session" => true,
      "turns" => GUION2_TURNS.size,
      "guion2_calls_without_retry" => GUION2_CALLS,
      "guion1_calls_without_retry" => GUION2_GUION1_CALLS,
      "transient_attempt_limit" => Rag::TransientBackoff.limit,
      "direct_retry" => "asleep",
      "ledger_sha256" => ledger["sha256"],
      "attempts" => ledger["attempts"],
      "call_cap" => ledger["call_cap"],
      "remaining_calls" => ledger["remaining_calls"],
      "committed" => ledger["committed"],
      "unknown" => ledger["unknown"],
      "direct_ceiling_usd" => ceilings["direct"],
      "interpreter_ceiling_usd" => ceilings["interpreter"],
      "guion2_ceiling_usd" => ceilings["guion2"],
      "guion1_ceiling_usd" => ceilings["guion1"],
      "paid_run" => "not_executed",
      "additional_call_quota" => "authorized"
    )
    0
  end

  def execute(io: $stdout)
    run_script(io, name: "guion2", turns: GUION2_TURNS, needed_calls: GUION2_CALLS, record_grant: true)
  end

  def execute_guion1(io: $stdout)
    run_script(io, name: "guion1", turns: GUION1_TURNS, needed_calls: GUION2_GUION1_CALLS, record_grant: false)
  end

  def run_script(io, name:, turns:, needed_calls:, record_grant:)
    return refuse(io, "generation") unless ENV["RAG_COMPANION_GENERATION"].to_s.strip == "direct"
    return refuse(io, "shared_session") if SharedSession::ENABLED
    return refuse(io, "not_local") unless Rails.env.local?
    return refuse(io, "database") unless local_databases?

    spend = assignment_spend
    grant = record_grant ? admit_direct_quota!(spend, io) : existing_grant(spend, io)
    return 2 unless grant

    room = authorization_room(spend)
    ceilings = call_ceilings
    script_ceiling = BigDecimal(name == "guion1" ? ceilings["guion1"] : ceilings["guion2"])
    if room < script_ceiling
      io.puts JSON.generate(
        "status" => "refused",
        "reason" => "authorization_dollars",
        "authorization_room_usd" => format("%.6f", room),
        "script_ceiling_usd" => format("%.6f", script_ceiling),
        "shortfall_usd" => format("%.6f", script_ceiling - room),
        "stopped_before_model" => true
      )
      return 2
    end

    remaining = remaining_calls(spend)
    if remaining < needed_calls
      io.puts JSON.generate(
        "status" => "refused",
        "reason" => "assignment_calls",
        "remaining_calls" => remaining,
        "needed_calls" => needed_calls,
        "stopped_before_model" => true
      )
      return 2
    end

    probe = probe_reserve!(spend, BigDecimal(ceilings["direct"]))
    unless probe == :released
      io.puts JSON.generate("status" => "refused", "reason" => "reserve_probe", "probe" => probe.to_s, "stopped_before_model" => true)
      return 2
    end

    planned = record_grant ? GUION_DIRECT_CALLS : needed_calls
    margin = remaining_calls(spend) - planned
    arm_ledger!(spend, needed_calls, margin)
    unless Rag::LocalPassLedger.armed?
      io.puts JSON.generate(
        "status" => "refused", "reason" => "ledger",
        "missing" => Rag::LocalPassLedger.missing_requirements,
        "stopped_before_model" => true
      )
      return 2
    end

    document = KbDocument.find_by(document_uid: GUION2_DOCUMENT_UID)
    return refuse(io, "document") unless document

    account = document.account
    user = User.where(account_id: account.id).order(:id).first if account
    return refuse(io, "account") unless account && user

    session = ConversationSession.create!(
      identifier: "web:#{name}-direct-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.day.from_now,
      user: user,
      account: account,
      conversation_history: []
    )
    return refuse(io, "shared_identifier") if session.identifier == SharedSession::IDENTIFIER
    return refuse(io, "pin") unless session.pin_kb_document!(document)

    before = read_ledger
    io.puts JSON.generate(
      "status" => "admitted",
      "script" => name,
      "stopped_before_model" => false,
      "execution" => GUION_DIRECT_EXECUTION,
      "attempts" => before["attempts"],
      "call_cap" => before["call_cap"],
      "remaining_calls" => before["remaining_calls"],
      "authorization_room_usd" => format("%.6f", authorization_room(spend)),
      "retry_limit" => Rag::TransientBackoff.limit,
      "retry_margin" => margin,
      "session_id" => session.id
    )

    directory = evidence_root.join(name)
    FileUtils.mkdir_p(directory)
    rows = []
    turns.each_with_index do |question, index|
      row = one_turn(session, user, question, index + 1, directory)
      rows << row
      break if row["status"] != "returned"
    end
    payload = {
      "status" => rows.size == turns.size && rows.all? { |row| row["status"] == "returned" } ? "executed" : "stopped",
      "script" => name,
      "episode_id" => session.reload.live_episode_id,
      "session_id" => session.id,
      "turns" => rows,
      "ledger" => read_ledger,
      "side_calls" => side_call_counts(directory)
    }
    File.write(directory.join("summary.json"), JSON.generate(payload))
    io.puts JSON.generate(payload)
    payload["status"] == "executed" ? 0 : 2
  end

  def turn_status(result, error, written)
    return "failed" if error
    return written.status if Rag::CompanionCaseWrite.conflict?(written)
    return "provider_rejected" if result.respond_to?(:provider_rejection) && result.provider_rejection.to_s == "access_denied"
    return "returned" if result.respond_to?(:success?) && result.success?

    "failed"
  end

  def one_turn(session, user, question, number, directory)
    correlation_id = "query:#{SecureRandom.uuid}"
    turn_dir = directory.join(format("turn-%d", number))
    FileUtils.mkdir_p(turn_dir)
    File.write(turn_dir.join("question.txt"), question)
    events = []
    result = nil
    error = nil
    written = nil
    Rag::ValidationCapture.capture do |bucket|
      Rag::ValidationCapture.bind(run_id: "vf5-direct-#{directory.basename}", session_id: session.id, correlation_root: correlation_id)
      events = bucket
      episode_turn = session.record_user_turn!(question, user_id: user.id, correlation_id: correlation_id, locale: :es)
      session.reload
      host = Guion2DirectHost.new(session.account, user)
      result = host.execute(
        question,
        session_context: SessionContextBuilder.build(session),
        conv_session: session,
        entity_s3_uris: SessionContextBuilder.entity_s3_uris(session),
        account: session.account,
        user_id: user.id,
        correlation_id: correlation_id,
        episode_turn: episode_turn,
        output_channel: :web
      )
      if result.respond_to?(:success?) && result.success?
        written = Rag::CompanionCaseWrite.persist!(
          session, result,
          user_id: user.id,
          expected_episode_id: session.live_episode_id,
          focus_ids: session.focus_document_ids
        )
      end
    rescue StandardError, Rag::LocalPassLedger::Stop, Rag::AssignmentSpend::Stop => raised
      error = raised
    end
    document = Rag::ValidationCapture.export_capture(events, turn_dir, run_id: directory.basename.to_s)
    File.write(turn_dir.join("capture.json"), JSON.generate(document))
    session.reload
    File.write(turn_dir.join("episode.json"), JSON.generate(
      "episode_id" => session.live_episode_id,
      "active_episode" => session.active_episode,
      "focus_document_ids" => session.focus_document_ids,
      "case_evidence" => session.case_evidence
    ))
    model_answer = result.respond_to?(:answer) ? result.answer.to_s : ""
    conflict = Rag::CompanionCaseWrite.conflict?(written)
    published = conflict ? Rag::CompanionCaseWrite.conflict_answer(:es) : model_answer
    File.write(turn_dir.join("published.txt"), published)
    raw = events.reverse.find { |event| event["kind"] == "companion_direct" && event["text"].present? }
    File.write(turn_dir.join("raw.txt"), raw ? raw["text"].to_s : "")
    File.write(turn_dir.join("ledger.json"), JSON.generate(read_ledger))
    {
      "turn" => number,
      "status" => turn_status(result, error, written),
      "error_class" => error&.class&.name || (result.respond_to?(:provider_error_class) ? result.provider_error_class : nil),
      "error_message" => error&.message.to_s.presence || (result.respond_to?(:provider_error_message) ? result.provider_error_message.to_s : ""),
      "provider_rejection" => result.respond_to?(:provider_rejection) ? result.provider_rejection : nil,
      "route_outcome" => result.respond_to?(:route_outcome) ? result.route_outcome.to_s : nil,
      "companion_turn" => result.respond_to?(:companion_turn) ? result.companion_turn : nil,
      "case_write" => conflict ? written.status : (written ? "applied" : "skipped"),
      "model_answer" => model_answer,
      "answer" => published,
      "evidence" => turn_dir.to_s
    }
  end

  def admit_direct_quota!(spend, io)
    snap = spend.snapshot
    existing = Array(snap["executions"]).find { |row| row.is_a?(Hash) && row["id"] == GUION_DIRECT_EXECUTION }
    return existing if existing && snap.dig("authorization", "call_cap").to_i == GUION_DIRECT_CAP

    authorized = snap.dig("authorization", "call_cap").to_i
    unless snap["attempts"].to_i == 195 && authorized == 196 && Rag::AssignmentSpend::CALL_CAP_BUMPS[196] == GUION_DIRECT_CAP
      io.puts JSON.generate(
        "status" => "refused", "reason" => "bump_state",
        "attempts" => snap["attempts"], "call_cap" => authorized,
        "stopped_before_model" => true
      )
      return nil
    end

    room = authorization_room(spend)
    granted = spend.admit_execution!(
      id: GUION_DIRECT_EXECUTION,
      cost_usd: format("%.6f", room),
      calls: GUION_DIRECT_CALLS,
      bump_call_cap_to: GUION_DIRECT_CAP,
      bump_only_if_attempts: 195
    )
    after = spend.snapshot
    unless after.dig("authorization", "call_cap").to_i == GUION_DIRECT_CAP && granted["calls"].to_i == GUION_DIRECT_CALLS
      io.puts JSON.generate("status" => "refused", "reason" => "bump_not_applied", "stopped_before_model" => true)
      return nil
    end

    granted
  end

  def existing_grant(spend, io)
    snap = spend.snapshot
    granted = Array(snap["executions"]).find { |row| row.is_a?(Hash) && row["id"] == GUION_DIRECT_EXECUTION }
    unless granted && snap.dig("authorization", "call_cap").to_i == GUION_DIRECT_CAP
      io.puts JSON.generate("status" => "refused", "reason" => "grant_missing", "stopped_before_model" => true)
      return nil
    end

    granted
  end

  def probe_reserve!(spend, ceiling)
    id = spend.reserve!(ceiling_usd: ceiling, model_id: BedrockClient::QUERY_MODEL_ID, turn: "quota_probe")
    return :release_failed unless spend.release!(id)

    :released
  rescue Rag::AssignmentSpend::Stop
    :blocked
  end

  def arm_ledger!(spend, needed_calls, margin)
    remaining = remaining_calls(spend)
    room = authorization_room(spend)
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = spend_path
    ENV["RAG_LOCAL_PASS_GUARD"] = "1"
    ENV["RAG_LOCAL_PASS_CALL_CAP"] = remaining.to_s
    ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = format("%.6f", room)
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    ENV["AWS_RETRY_MODE"] = "standard"
    ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = [ 1 + [ margin, 0 ].max, Rag::TransientBackoff::DEFAULT_LIMIT ].min.to_s
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = GUION_DIRECT_KB
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = "vf5-direct-guiones"
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
    needed_calls
  end

  def assignment_spend
    Rag::AssignmentSpend.new(
      path: spend_path,
      call_cap: GUION_DIRECT_CAP,
      cost_cap_usd: Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD
    )
  end

  def authorization_room(spend)
    snap = spend.snapshot
    auth = snap["authorization"]
    return BigDecimal("0") unless auth.is_a?(Hash)

    after = auth["after_attempt"].to_i
    limit = BigDecimal(auth["cost_usd"].to_s)
    exposure = Array(snap["entries"]).sum(BigDecimal("0")) do |entry|
      next BigDecimal("0") unless entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released"

      case entry["status"]
      when "settled", "kept"
        BigDecimal(entry["actual_usd"].to_s)
      when "unknown"
        BigDecimal((entry["reserved_usd"].presence || entry["ceiling_usd"]).to_s)
      when "reserved"
        BigDecimal(entry["ceiling_usd"].to_s)
      else
        BigDecimal("0")
      end
    end
    limit - exposure
  end

  def remaining_calls(spend)
    snap = spend.snapshot
    snap.dig("authorization", "call_cap").to_i - snap["attempts"].to_i
  end

  def side_call_counts(directory)
    counts = Hash.new(0)
    Dir.glob(directory.join("turn-*", "capture.json").to_s).each do |path|
      document = JSON.parse(File.read(path))
      Array(document["events"]).each do |event|
        kind = event["kind"].to_s
        counts["retrieve"] += 1 if kind == "retrieve"
        counts["cohere_rerank"] += 1 if kind == "companion_rerank"
        counts["converse"] += 1 if kind == "model_call" && event["result"] == "attempt_started"
      end
    end
    counts
  end

  def read_ledger
    path = spend_path
    raw = File.file?(path) ? File.binread(path) : ""
    state = raw.empty? ? {} : JSON.parse(raw)
    attempts = state["attempts"].to_i
    cap = state["call_cap"].to_i
    cap = state.dig("authorization", "call_cap").to_i if cap.zero?
    {
      "sha256" => Digest::SHA256.hexdigest(raw),
      "attempts" => attempts,
      "call_cap" => cap,
      "remaining_calls" => cap - attempts,
      "committed" => state["committed"],
      "unknown" => state["unknown"],
      "authorization_call_cap" => state.dig("authorization", "call_cap")
    }
  end

  def call_ceilings
    model = BedrockClient::QUERY_MODEL_ID
    direct_in = Rag::CompanionDirectAnswer::SYSTEM_PROMPT.length + Rag::CompanionDirectAnswer::HISTORY_MAX_CHARS + Rag::CompanionPlan::STATEMENTS_MAX_CHARS + 2_000
    interpreter_in = Rag::TurnInterpreter::PROMPT.length + 4_000
    direct = Rag::LocalPassLedger.price(model, direct_in, Rag::CompanionDirectAnswer::MAX_TOKENS)
    interpreter = Rag::LocalPassLedger.price(model, interpreter_in, Rag::TurnInterpreter::MAX_TOKENS)
    per_turn = direct + interpreter
    {
      "direct" => format("%.6f", direct),
      "interpreter" => format("%.6f", interpreter),
      "guion2" => format("%.6f", per_turn * GUION2_TURNS.size),
      "guion1" => format("%.6f", per_turn * 5)
    }
  end

  def local_databases?
    return false unless Rails.env.development?

    rows = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
    expected = %w[
      smart_deal_development
      smart_deal_development_cache
      smart_deal_development_queue
      smart_deal_development_cable
    ]
    names = rows.map { |config| config.database.to_s }.sort
    hosts = rows.map { |config| config.host.to_s }
    names == expected.sort && hosts.all? { |host| Rag::LocalPassLedger::LOCAL_HOSTS.include?(host) }
  end

  def refuse(io, reason)
    io.puts JSON.generate("status" => "refused", "reason" => reason, "stopped_before_model" => true)
    2
  end
end

if ENV["GUION2_DIRECT_REQUIRE"] == "1"
  # Loaded by a test. Nothing runs.
elsif ENV["GUION2_DIRECT_EXECUTE"] == "1"
  exit Guion2Direct.execute
elsif ENV["GUION1_DIRECT_EXECUTE"] == "1"
  exit Guion2Direct.execute_guion1
else
  exit Guion2Direct.preflight
end
