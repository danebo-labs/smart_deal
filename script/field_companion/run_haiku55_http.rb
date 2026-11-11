# frozen_string_literal: true

# Live G2 → G1 → Elemont over authenticated HTTP against a local Puma.
# Local database, production knowledge base Y7RZWMFJSR read-only, Haiku 5.5
# by Anthropic in both roles, Bedrock limited to Retrieve and rerank.
#
#   HTTP55_ITERATION=live1 HTTP55_PLAN=guion2,guion1,elemont \
#     bin/rails runner script/field_companion/run_haiku55_http.rb          # preflight only
#   HTTP55_EXECUTE=1 ...                                                   # admit and call
#
# Each script gets a new user (so a new web session and episode), a Puma
# started with that script's reservation as its process caps, the pin by
# POST /pinned_documents, and one POST /rag/ask per turn. The server writes
# the capture of each request; this runner copies it next to the published
# answer and the persisted state.

require "net/http"
require "uri"
require "json"
require "digest"
require "fileutils"
require "securerandom"
require "open3"

ENV["OPUS55_REQUIRE"] = "1"
load Rails.root.join("script/field_companion/run_haiku55_companion.rb") unless defined?(Haiku55Companion)
require Rails.root.join("test/support/haiku55_journey_rubric").to_s

module Haiku55Http
  EXECUTION_ID = "haiku55-http-20261110"
  FROM_ATTEMPTS = 326
  NEXT_CAP = 1000
  GRANT_CALLS = 676
  GRANT_USD = "2.296091"
  KB_ID = "Y7RZWMFJSR"
  MODEL_ID = "claude-haiku-5-5"
  TRACKING_MODEL_ID = "claude-haiku-5-5-direct"
  PORT = Integer(ENV["HTTP55_PORT"].presence || "3155")
  HOST = "localhost"
  ROOT = Rails.root.join("tmp/field_companion/haiku55_http")
  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
  PROFILES = {
    "guion2" => { "number_of_results" => 16, "rerank" => true },
    "guion1" => { "number_of_results" => 16, "rerank" => true },
    "elemont" => { "number_of_results" => 5, "rerank" => false }
  }.freeze
  # Functional variants of a journey: the same manual and profile, with the
  # history changed where a correction depends on it.
  VARIANTS = {
    "guion1_photocell_active" => {
      "base" => "guion1", "last" => 4,
      "replace" => { 3 => "Revisé la fotocélula y sí se activa durante el cierre." }
    },
    "guion1_can_measure" => {
      "base" => "guion1", "last" => 5,
      "replace" => { 5 => "Tengo multímetro y sé medir en los bornes #21 y #23. ¿Qué compruebo para orientar el caso?" }
    }
  }.freeze
  # CEA15+ pinned, plate unknown. "cea" is the original seven-turn script; the
  # two label variants continue T1 with the reply to the nameplate question.
  CEA_DOCUMENT_UID = "9a4fa817-b9e8-4a9e-ae83-526c0731e603"
  CEA_TURNS = [
    "La puerta de piso no traba. Hay patín retráctil. ¿Qué tiene que cumplirse para que la seguridad automática SA quede en 1?",
    "¿Qué son los terminales SM, SPC y SA en la serie de seguridad de puertas?",
    "Si mido un terminal de la serie de seguridad, ¿qué tensión es un 1 y qué tensión es un 0?",
    "No hay contactos que cierren por el patín retráctil. ¿Cómo se conecta SA?",
    "La puerta de cabina es manual y la de piso es manual, con doble contacto y traba por patín. ¿Qué contactos van en SM y cuáles en SA?",
    "La bobina del patín retráctil mete interferencia. ¿Qué hay que instalar en paralelo con esa bobina?",
    "¿El contacto del operador de puerta automática entra en la serie SM?"
  ].freeze
  ELEMONT_DOCUMENT_UID = "dcc8e046-037d-48a6-8913-1992aed28507"
  VF5_DOCUMENT_UID = "126cda62-64ad-4469-8674-a29f12e38d48"
  FALLAS_DOCUMENT_UID = "85590ab2-d2b2-49b2-a36d-0c8c50f9bd76"
  MONARCH_DOCUMENT_UID = "6e578b57-0f5e-42f0-91d6-4dd908e0eba2"
  MONARCH_TURNS = [
    "Estoy con un controlador Monarch NICE3000new. Después de varias maniobras apareció Err14. Todavía no he revisado el filtro ni el ventilador. ¿Qué me conviene comprobar primero?",
    "Medí 26 °C en el ambiente junto al gabinete. Miré el filtro desde fuera y está cubierto de polvo, casi no se ve la malla. Todavía no lo he limpiado ni he revisado el ventilador. ¿Sigo por el filtro?"
  ].freeze
  # Revision journeys: after turn N, the card for one of the listed manuals
  # is confirmed with its own action, and the same question is replayed.
  EXTRA_SCRIPTS = {
    "cea" => { "document_uid" => CEA_DOCUMENT_UID, "turns" => CEA_TURNS },
    "cea_label_known" => { "document_uid" => CEA_DOCUMENT_UID, "turns" => [ CEA_TURNS.first, "Leo CEA15+ en el rótulo de la placa." ] },
    "cea_label_unseen" => { "document_uid" => CEA_DOCUMENT_UID, "turns" => [ CEA_TURNS.first, "No puedo ver el rótulo." ] },
    "jesus" => {
      "document_uid" => ELEMONT_DOCUMENT_UID,
      "turns" => [ "Hola, tengo una falla eléctrica en un elevador hidráulico Elemont, con imanes y tarjeta Cea15", "Leo CEA15+ en el rótulo de la placa." ],
      "accept" => { 2 => { "document_uids" => [ CEA_DOCUMENT_UID ], "action" => "add" } }
    },
    "monarch_add" => {
      "document_uid" => FALLAS_DOCUMENT_UID, "turns" => MONARCH_TURNS,
      "accept" => { 1 => { "document_uids" => [ MONARCH_DOCUMENT_UID ], "action" => "add" } }
    },
    "monarch_replace" => {
      "document_uid" => VF5_DOCUMENT_UID, "turns" => MONARCH_TURNS.first(1),
      "accept" => { 1 => { "document_uids" => [ MONARCH_DOCUMENT_UID, FALLAS_DOCUMENT_UID ], "action" => "replace" } }
    }
  }.freeze
  SERVER_ENV = {
    "RAILS_ENV" => "development",
    "WEB_CONCURRENCY" => "0",
    "RAILS_MAX_THREADS" => "1",
    "BEDROCK_INFERENCE" => "blocked",
    "BEDROCK_KNOWLEDGE_BASE_ID" => KB_ID,
    "SHOW_RAG_SOURCES" => "true",
    "AWS_MAX_ATTEMPTS" => "1",
    "AWS_RETRY_MODE" => "standard",
    "AWS_HTTP_OPEN_TIMEOUT" => "15",
    "RAG_TRANSIENT_ATTEMPT_LIMIT" => "1",
    "RAG_LOCAL_PASS_GUARD" => "1",
    "RAG_LOCAL_PASS_ALLOWED_CALLS" => "converse@#{TRACKING_MODEL_ID},converse_message@#{TRACKING_MODEL_ID}"
  }.freeze
  CLEARED_ENV = %w[
    COMPANION_DIRECT_PROVIDER COMPANION_DIRECT_MODEL_ID COMPANION_DIRECT_MAX_TOKENS COMPANION_DIRECT_EFFORT
    COMPANION_DIRECT_THINKING INTERPRETER_MAX_TOKENS SOLID_QUEUE_IN_PUMA SHARED_SESSION_ENABLED
    RAG_VALIDATION_CAPTURE_ACCOUNT_IDS PHASE4_WEB_CHECK
    FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED DOCUMENT_IDENTITY_SCOPE_ENABLED
    HAIKU_QUERY_ANALYSIS_MODE RAG_EPISODE_SCOPE_ENABLED RAG_COMPANION_TURN RAG_COMPANION_GENERATION
  ].freeze

  module_function

  def run(io: $stdout)
    iteration = ENV["HTTP55_ITERATION"].presence || "live0"
    plan = (ENV["HTTP55_PLAN"].presence || "guion2,guion1,elemont").split(",").map(&:strip)
    directory = ROOT.join(iteration)
    FileUtils.mkdir_p(directory)
    preflight = preflight_document(plan)
    File.write(directory.join("preflight.json"), JSON.pretty_generate(preflight))
    io.puts JSON.generate(preflight.except("scripts"))
    return 0 unless ENV["HTTP55_EXECUTE"] == "1"
    return refuse(io, preflight["decision"]) unless preflight["decision"] == "execute"
    return 2 unless admit!(io)

    File.write(directory.join("manifest.json"), JSON.pretty_generate(manifest))
    if ENV["HTTP55_GUI"] == "1"
      return refuse(io, "gui_takes_one_script") unless plan.size == 1

      result = gui_session(io, directory, plan.first)
      return result["status"] == "executed" && result["checks"].all? { |check| check["ok"] } ? 0 : 2
    end
    results = []
    plan.each do |name|
      result = run_script(io, directory, name)
      results << result
      break unless result["status"] == "executed"
    end
    File.write(directory.join("summary.json"), JSON.pretty_generate(
      "head" => head, "results" => results, "ledger" => ledger_view
    ))
    results.size == plan.size && results.all? { |row| row["status"] == "executed" && row["rubric_ok"] } ? 0 : 2
  end

  # ---- preflight and grant ------------------------------------------------

  def preflight_document(plan)
    ledger = read_ledger
    turn = Haiku55Companion.per_turn_ceiling
    scripts = plan.index_with { |name| reservation(name, turn) }
    room = grant_room(ledger)
    worst = scripts.values.sum(BigDecimal("0")) { |row| BigDecimal(row["ceiling_usd"]) }
    calls = scripts.values.sum { |row| row["calls"] }
    pins = plan.index_with { |name| document_for(name)&.display_s3_uri(KbDocument::KB_BUCKET) }
    accounts = plan.map { |name| document_for(name)&.account_id }.uniq
    decision = if !Rag::LocalPassLedger.local_process?
      "not_local_databases"
    elsif dirty_tree?
      "dirty_tree"
    elsif ENV["ANTHROPIC_API_KEY"].blank?
      "anthropic_api_key_missing"
    elsif pins.values.any?(&:blank?)
      "pin_missing"
    elsif accounts.size != 1 || AccountHostResolver.host_map.key?(request_host(document_for(plan.first).account))
      "host_account_mismatch"
    elsif worst > room["usd"] || calls > room["calls"]
      "grant_does_not_cover_plan"
    else
      "execute"
    end
    {
      "status" => "preflight",
      "decision" => decision,
      "head" => head,
      "dirty" => dirty_tree?,
      "execution_id" => EXECUTION_ID,
      "plan" => plan,
      "scripts" => scripts,
      "plan_ceiling_usd" => money(worst),
      "plan_calls" => calls,
      "room_usd" => money(room["usd"]),
      "room_calls" => room["calls"],
      "attempts" => ledger["attempts"],
      "committed" => ledger["committed"],
      "unknown" => ledger["unknown"],
      "pins" => pins,
      "knowledge_base_id" => KB_ID,
      "system_sha256" => Digest::SHA256.hexdigest(Rag::CompanionDirectAnswer::SYSTEM_PROMPT),
      "interpreter_prompt_sha256" => Digest::SHA256.hexdigest(Rag::TurnInterpreter::PROMPT),
      "anthropic_key_present" => ENV["ANTHROPIC_API_KEY"].present?
    }
  end

  # One script, complete: two calls per turn plus one, priced at the ceiling.
  def reservation(name, turn)
    turns = script(name)["turns"].size + script(name).fetch("accept", {}).size
    ceiling = (turn["interpreter"] + turn["generation"]) * turns
    { "turns" => turns, "calls" => turns * 2 + 1, "ceiling_usd" => money(ceiling + turn["interpreter"]) }
  end

  def grant_room(ledger)
    granted = Array(ledger["executions"]).find { |row| row.is_a?(Hash) && row["id"] == EXECUTION_ID }
    after = granted ? granted["after_attempt"].to_i : FROM_ATTEMPTS
    rows = Array(ledger["entries"]).select { |entry| entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released" }
    exposure = rows.sum(BigDecimal("0")) { |entry| Haiku55Companion.exposure(entry) }
    { "usd" => BigDecimal(GRANT_USD) - exposure, "calls" => GRANT_CALLS - rows.size, "exposure" => exposure, "entries" => rows.size }
  end

  def admit!(io)
    spend = assignment_spend
    granted = spend.admit_execution!(
      id: EXECUTION_ID, cost_usd: GRANT_USD, calls: GRANT_CALLS,
      bump_call_cap_to: NEXT_CAP, bump_only_if_attempts: FROM_ATTEMPTS
    )
    snap = spend.snapshot
    unless snap["call_cap"].to_i == NEXT_CAP && granted["after_attempt"].to_i == FROM_ATTEMPTS
      io.puts JSON.generate("status" => "refused", "reason" => "bump_not_applied", "authorization" => snap["authorization"])
      return false
    end
    true
  rescue Rag::AssignmentSpend::Stop => error
    io.puts JSON.generate("status" => "refused", "reason" => error.message)
    false
  end

  # ---- one script ---------------------------------------------------------

  def run_script(io, root, name)
    directory = root.join(name)
    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory)
    turn_ceiling = Haiku55Companion.per_turn_ceiling
    reserved = reservation(name, turn_ceiling)
    room = grant_room(read_ledger)
    if BigDecimal(reserved["ceiling_usd"]) > room["usd"] || reserved["calls"] > room["calls"]
      return { "script" => name, "status" => "refused", "reason" => "grant_does_not_cover_script", "room" => money(room["usd"]) }
    end

    before = ledger_view
    File.write(directory.join("reservation.json"), JSON.pretty_generate(reserved.merge("room_before" => money(room["usd"]), "ledger_before" => before)))
    document = document_for(name)
    user = new_user(document.account, name)
    run_id = "#{root.basename}-#{name}"
    server = start_server(directory, run_id, reserved, document.account)
    rows = []
    begin
      client = Client.new(PORT, request_host(document.account))
      client.sign_in!(user.email, user_password(user))
      pin = client.post_json("/pinned_documents", { kb_document_id: document.id })
      File.write(directory.join("pin.json"), JSON.pretty_generate(
        "status" => pin[:status], "body" => pin[:json], "request_id" => pin[:request_id],
        "document_uid" => document.document_uid, "indexed_uri" => document.display_s3_uri(KbDocument::KB_BUCKET)
      ))
      raise "pin failed #{pin[:status]}" unless [ 200, 204 ].include?(pin[:status])

      questions = script(name)["turns"]
      focus = [ document ]
      questions.each_with_index do |question, index|
        number = index + 1
        unless Haiku55Companion.network_ready?(io)
          rows << { "turn" => number, "status" => "network_unreachable" }
          break
        end
        row = one_turn(directory, run_id, client, user, focus.first, name, number, question, questions, focus: focus)
        accept = script(name).dig("accept", number)
        if row["block_reason"] == "generator_not_sent" && planned_card?(row["manual_suggestion"], accept)
          row["block_reason"] = nil
          row["abstained_with_card"] = true
        end
        rows << row
        io.puts JSON.generate(row.slice("script", "turn", "status", "block_reason", "abstained_with_card", "rubric", "wall_ms"))
        break if row["block_reason"]

        card = row.delete("manual_suggestion")
        if accept
          rows << accept_card!(directory, run_id, client, user, name, number, card, accept, questions)
          io.puts JSON.generate(rows.last.slice("script", "label", "status", "block_reason", "focus", "scope", "wall_ms"))
          break if rows.last["block_reason"]

          focus = KbDocument.where(id: rows.last["focus"]).to_a
        elsif card
          confirm_card!(client, directory, number, card, document)
        end
      end
    ensure
      stop_server(server)
    end
    session = ConversationSession.find_by(identifier: user.id.to_s, channel: "web")
    episodes = rows.filter_map { |row| row["episode_id"] }.uniq
    expected = script(name)["turns"].size + script(name).fetch("accept", {}).size
    status = rows.size == expected && rows.all? { |row| row["block_reason"].nil? } ? "executed" : "stopped"
    payload = {
      "script" => name, "status" => status, "user_id" => user.id, "session_id" => session&.id,
      "episodes" => episodes, "single_episode" => episodes.size == 1,
      "rubric_ok" => status == "executed" && rows.all? { |row| row["rubric"].empty? && row.fetch("scope", {}).fetch("ok", true) },
      "turns" => rows.map { |row| row.slice("turn", "label", "status", "block_reason", "abstained_with_card", "rubric", "wall_ms", "route_outcome", "focus", "scope", "replayed") },
      "ledger_before" => before, "ledger_after" => ledger_view
    }
    File.write(directory.join("summary.json"), JSON.pretty_generate(payload))
    payload
  end

  def one_turn(directory, run_id, client, user, document, name, number, question, questions,
               payload: { question: question }, label: format("turn-%d", number), focus: [ document ])
    turn_dir = directory.join(label)
    FileUtils.mkdir_p(turn_dir)
    File.write(turn_dir.join("question.txt"), question)
    session = ConversationSession.find_by(identifier: user.id.to_s, channel: "web")
    File.write(turn_dir.join("before.json"), JSON.pretty_generate(
      "episode_id" => stored_episode_id(session), "case_evidence" => session&.case_evidence,
      "focus_document_ids" => session&.focus_document_ids
    ))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = client.post_json("/rag/ask", payload)
    wall_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    body = response[:json] || {}
    File.write(turn_dir.join("response.json"), JSON.pretty_generate(
      "status" => response[:status], "request_id" => response[:request_id], "body" => body
    ))
    copy_capture(run_id, response[:request_id], turn_dir)
    answer = body["answer"].to_s
    File.write(turn_dir.join("published.txt"), answer)
    events = Array((Haiku55Companion.read_json(turn_dir.join("capture.json")) || {})["events"])
    direct = events.reverse.find { |event| event["kind"] == "companion_direct" }
    File.write(turn_dir.join("raw.txt"), Haiku55JourneyFixtures.text(turn_dir.to_s, direct&.fetch("text", nil)))
    session = ConversationSession.find_by(identifier: user.id.to_s, channel: "web")
    reply = Array(session&.conversation_history).reverse.find { |message| message["role"] == "assistant" }
    delta = events.reverse.find { |event| event["kind"] == "episode_delta" }
    File.write(turn_dir.join("episode.json"), JSON.pretty_generate(
      "episode_id" => stored_episode_id(session),
      "active_episode" => delta&.dig("episode_after"),
      "stored_active_episode" => session&.active_episode,
      "focus_document_ids" => session&.focus_document_ids,
      "case_evidence" => session&.case_evidence,
      "last_assistant" => reply&.slice("content", "prompt_reply", "correlation_id")
    ))
    File.write(turn_dir.join("ledger.json"), JSON.pretty_generate(ledger_view))
    trace = Haiku55Trace.turn(turn_dir, question, document.display_s3_uri(KbDocument::KB_BUCKET))
    trace["http"] = { "status" => response[:status], "request_id" => response[:request_id], "wall_ms" => wall_ms }
    trace["effective_config"] = effective_config(events)
    trace["interpreter"] = interpreter_view(events)
    trace["gates"] = events.select { |event| %w[companion_turn route_decision route_exit companion_claim_backing companion_publication].include?(event["kind"]) }
      .map { |event| event.except("run_id", "account_id", "user_id", "linkage") }
    trace["case_write"] = events.select { |event| event["kind"].to_s.start_with?("case_") || event["kind"] == "assistant_history" }
      .map { |event| event.except("run_id", "account_id", "user_id") }
    File.write(turn_dir.join("trace.json"), JSON.pretty_generate(trace))
    rubric = Haiku55JourneyRubric.reasons(name, number, answer, questions)
    reason = block_reason(name, response, body, events, focus, replay: payload.key?(:replay_correlation_id))
    scope = scope_view(events, body, focus)
    File.write(turn_dir.join("scope.json"), JSON.pretty_generate(scope))
    {
      "script" => name, "turn" => number, "label" => label, "status" => body["status"] || response[:status].to_s,
      "block_reason" => reason, "rubric" => rubric, "wall_ms" => wall_ms,
      "route_outcome" => events.reverse.find { |event| event["kind"] == "published_answer" }&.dig("route_outcome"),
      "episode_id" => stored_episode_id(session), "focus" => session&.focus_document_ids, "scope" => scope,
      "replayed" => body["replayed"],
      "manual_suggestion" => body["manual_suggestion"]
    }
  end

  # Retrieve filter and published citations against the focus of this turn.
  def scope_view(events, body, focus)
    filters = generation_retrieves(events).map { |retrieve| filter_uris(retrieve) }
    expected = focus.map { |item| item.display_s3_uri(KbDocument::KB_BUCKET) }.sort
    cited = Array(body["citations"]).filter_map { |citation| citation.dig("metadata", "original_source_uri") }.uniq.sort
    {
      "expected" => expected, "filter" => filters.flatten.uniq.sort, "cited" => cited,
      "ok" => filters.any? && filters.all?(expected) && (cited - expected).empty?
    }
  end

  # DocumentDiscovery retrieves after an abstention to suggest manuals; only
  # the Retrieves before the generator request fed this answer.
  def generation_retrieves(events)
    generator = events.rindex { |event| event["kind"] == "converse" } || events.size
    events.first(generator).select { |event| event["kind"] == "retrieve" }
  end

  def filter_uris(retrieve)
    Haiku55Trace.strings(retrieve&.dig("retrieval_configuration", "vector_search_configuration", "filter"))
      .select { |value| value.start_with?("s3://") }.uniq.sort
  end

  # A pinned manual of other equipment abstains without the generator; the
  # card that changes the focus is that turn's answer.
  def planned_card?(suggestion, accept)
    return false unless accept

    Array(suggestion && suggestion["cards"]).any? do |item|
      accept["document_uids"].include?(item["document_uid"]) && (item["action"] || "add") == accept["action"]
    end
  end

  # The browser's card click: POST /pinned_documents with the card's action,
  # episode and correlation, then the replay the controller asks for.
  def accept_card!(directory, run_id, client, user, name, number, suggestion, accept, questions)
    label = format("turn-%d-accept", number)
    FileUtils.mkdir_p(directory.join(label))
    File.write(directory.join(label, "manual_suggestion.json"), JSON.pretty_generate(suggestion))
    card = Array(suggestion && suggestion["cards"]).find do |item|
      accept["document_uids"].include?(item["document_uid"]) && (item["action"] || "add") == accept["action"]
    end
    blocked = { "script" => name, "turn" => number, "label" => label, "rubric" => [] }
    return blocked.merge("block_reason" => "card_missing", "cards" => Array(suggestion && suggestion["cards"]).map { |item| item.slice("document_uid", "action") }) unless card

    session = ConversationSession.find_by(identifier: user.id.to_s, channel: "web")
    before = session.focus_document_ids
    pin = client.post_json("/pinned_documents", {
      kb_document_id: card["kb_document_id"], document_uid: card["document_uid"], focus_mode: card["action"] || "add",
      episode_id: suggestion["episode_id"], correlation_id: suggestion["correlation_id"]
    }.compact)
    after = session.reload.focus_document_ids
    File.write(directory.join(label, "card_confirm.json"), JSON.pretty_generate(
      "status" => pin[:status], "body" => pin[:json], "request_id" => pin[:request_id],
      "focus_before" => before, "focus_after" => after, "card" => card.slice("kb_document_id", "document_uid", "action")
    ))
    return blocked.merge("block_reason" => "pin_#{pin[:status]}") unless pin[:status] == 200
    return blocked.merge("block_reason" => "no_replay", "focus" => after) unless pin.dig(:json, "replay") == true

    focus = KbDocument.where(id: after).to_a
    replay_label = format("turn-%d-replay", number)
    row = one_turn(directory, run_id, client, user, focus.first, name, number, questions[number - 1], questions,
      payload: { replay_correlation_id: suggestion["correlation_id"] }, label: replay_label, focus: focus)
    row["block_reason"] ||= "not_replayed" unless row["replayed"] == true
    events = Array((Haiku55Companion.read_json(directory.join(replay_label, "capture.json")) || {})["events"])
    replayed = answered_question(directory.join(replay_label), events)
    row["rubric"] += replay_reasons(accept["action"], before, after, card["kb_document_id"].to_i,
      same_question: replayed == questions[number - 1], same_episode: row["episode_id"] == suggestion["episode_id"],
      cited: row.dig("scope", "cited"))
    row
  end

  # A replay records no user_message; the generator's turn line is the
  # stored question the controller re-ran.
  def answered_question(turn_dir, events)
    original = events.find { |event| event["kind"] == "user_message" }&.dig("original")
    return original if original

    converse = events.reverse.find { |event| event["kind"] == "converse" }
    text = Array(Array(converse&.dig("messages")).last&.dig("content")).filter_map { |block| body_text(turn_dir, block["text"]) }.join("\n")
    text[/\AMensaje de este turno:\n(.+)$/, 1]
  end

  def body_text(turn_dir, value)
    return value if value.is_a?(String)

    path = value.is_a?(Hash) ? value["path"].to_s : ""
    file = turn_dir.join(path)
    path.present? && file.file? ? File.read(file) : nil
  end

  def replay_reasons(action, before, after, accepted, same_question:, same_episode:, cited:)
    expected = action == "replace" ? [ accepted ] : (before + [ accepted ]).uniq
    reasons = []
    reasons << "replay:focus_#{action}" unless after.sort == expected.sort
    reasons << "replay:other_question" unless same_question
    reasons << "replay:other_episode" unless same_episode
    reasons << "replay:no_focus_evidence" if Array(cited).empty?
    reasons
  end

  # ---- GUI -------------------------------------------------------------------

  GUI_TIMEOUT_SECONDS = 45 * 60

  # Real clicks in a browser against the same Puma, caps and capture. The
  # runner prepares the user and the pin, waits for the stop file, and
  # rebuilds each request from the server capture. The credentials file is
  # 0600, deleted at teardown, and the password is rotated.
  def gui_session(io, root, name)
    directory = root.join("#{name}-gui")
    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory)
    reserved = reservation(name, Haiku55Companion.per_turn_ceiling)
    room = grant_room(read_ledger)
    if BigDecimal(reserved["ceiling_usd"]) > room["usd"] || reserved["calls"] > room["calls"]
      return { "script" => name, "status" => "refused", "reason" => "grant_does_not_cover_script", "checks" => [] }
    end

    before = ledger_view
    document = document_for(name)
    user = new_user(document.account, name)
    run_id = "#{root.basename}-#{name}-gui"
    FileUtils.rm_rf(Rails.root.join(Rag::WebRequestCapture::ROOT, run_id))
    credentials = Pathname("/tmp/haiku55-gui-#{name}.json")
    stop = directory.join("gui.stop")
    timeline = []
    server = start_server(directory, run_id, reserved, document.account)
    begin
      client = Client.new(PORT, request_host(document.account))
      client.sign_in!(user.email, user_password(user))
      pin = client.post_json("/pinned_documents", { kb_document_id: document.id })
      raise "pin failed #{pin[:status]}" unless [ 200, 204 ].include?(pin[:status])

      File.open(credentials, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate("url" => "http://#{document.account.slug}.haiku55.localhost:#{PORT}/", "email" => user.email, "password" => user_password(user)))
      end
      io.puts JSON.generate("status" => "gui_ready", "credentials" => credentials.to_s, "stop_file" => stop.to_s, "turns" => script(name)["turns"])
      io.flush
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GUI_TIMEOUT_SECONDS
      last = nil
      until stop.exist? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        session = ConversationSession.find_by(identifier: user.id.to_s, channel: "web")
        state = { "focus" => session&.focus_document_ids, "episode_id" => stored_episode_id(session) }
        timeline << state.merge("at" => Time.now.utc.iso8601(3)) unless state == last
        last = state
        sleep 1
      end
    ensure
      stop_server(server)
      FileUtils.rm_f(credentials)
      password = SecureRandom.hex(16)
      user.update!(password: password, password_confirmation: password)
    end
    requests = gui_requests(run_id, directory)
    payload = {
      "script" => name, "status" => stop.exist? ? "executed" : "timed_out", "user_id" => user.id, "run_id" => run_id,
      "head" => head, "requests" => requests, "timeline" => timeline, "checks" => gui_checks(name, requests),
      "ledger_before" => before, "ledger_after" => ledger_view
    }
    File.write(directory.join("gui_trace.json"), JSON.pretty_generate(payload))
    io.puts JSON.generate(payload.slice("script", "status", "checks", "ledger_after"))
    payload
  end

  def gui_requests(run_id, directory)
    base = Rails.root.join(Rag::WebRequestCapture::ROOT, run_id)
    base.glob("*/capture.json").sort_by(&:mtime).each_with_index.map do |file, index|
      events = Array((Haiku55Companion.read_json(file) || {})["events"])
      meta = events.find { |event| event["kind"] == "web_request" } || {}
      label = format("%02d-%s-%s", index + 1, meta["controller"].to_s.tr("/", "_"), meta["action"])
      target = directory.join("gui", label)
      FileUtils.mkdir_p(target)
      FileUtils.cp_r("#{file.dirname}/.", target)
      published = events.reverse.find { |event| event["kind"] == "published_answer" }
      File.write(target.join("published.txt"), published["answer"].to_s) if published
      focus = events.find { |event| event["kind"] == "document_focus" }
      filters = generation_retrieves(events).map { |retrieve| filter_uris(retrieve) }
      citations = Array(published&.dig("citations"))
      {
        "label" => label,
        "request" => meta.slice("controller", "action", "question", "replay_correlation_id", "correlation_id", "episode_id", "kb_document_id", "document_uid", "focus_mode"),
        "question" => answered_question(target, events),
        "episode_id" => events.filter_map { |event| event["episode_id"] }.last,
        "focus_before" => Array(focus&.dig("before")).pluck("kb_document_id"),
        "focus_after" => Array(focus&.dig("after")).pluck("kb_document_id"),
        "filter" => filters.flatten.uniq.sort,
        "filters" => filters,
        "route_outcome" => published&.dig("route_outcome"),
        "cited" => citations.filter_map { |citation| citation.dig("metadata", "original_source_uri") }.uniq.sort,
        "pages" => citations.map { |citation| "#{citation['filename']} p. #{citation['page']}" }
      }
    end
  end

  # One check per planned card: the click sent the card's action, the focus
  # changed as that action says, and the same question was replayed in the
  # same episode with Retrieve and citations inside the resulting focus.
  def gui_checks(name, requests)
    script(name).fetch("accept", {}).map do |number, spec|
      index = requests.index do |row|
        row.dig("request", "controller") == "pinned_documents" && spec["document_uids"].include?(row.dig("request", "document_uid"))
      end
      next { "turn" => number, "action" => spec["action"], "ok" => false, "reason" => "no_click" } unless index

      pin = requests[index]
      prior = requests.first(index).reverse.find { |row| row.dig("request", "controller") == "rag" }
      replay = requests.drop(index + 1).find do |row|
        row.dig("request", "replay_correlation_id").present? && row.dig("request", "replay_correlation_id") == pin.dig("request", "correlation_id")
      end
      before = Array(prior&.dig("focus_after"))
      after = Array(replay&.dig("focus_before"))
      accepted = KbDocument.find_by(document_uid: pin.dig("request", "document_uid"))
      expected = KbDocument.where(id: after).map { |item| item.display_s3_uri(KbDocument::KB_BUCKET) }.sort
      reasons = pin.dig("request", "focus_mode") == spec["action"] ? [] : [ "click:mode_#{pin.dig('request', 'focus_mode')}" ]
      if replay
        reasons += replay_reasons(spec["action"], before, after, accepted.id,
          same_question: replay["question"].present? && replay["question"] == prior&.dig("question"),
          same_episode: replay["episode_id"].present? && [ prior&.dig("episode_id"), pin.dig("request", "episode_id") ].all?(replay["episode_id"]),
          cited: replay["cited"])
        reasons << "replay:filter_outside_focus" unless replay["filters"].any? && replay["filters"].all?(expected)
        reasons << "replay:cited_outside_focus" unless (replay["cited"] - expected).empty?
      else
        reasons << "replay:missing"
      end
      {
        "turn" => number, "action" => spec["action"], "click" => pin["label"], "asked" => prior&.dig("label"), "replay" => replay&.dig("label"),
        "focus_before" => before, "focus_after" => after, "accepted" => accepted&.id,
        "episode_id" => replay&.dig("episode_id"), "filter" => replay&.dig("filter"), "cited" => replay&.dig("cited"),
        "reasons" => reasons, "ok" => reasons.empty?
      }
    end
  end

  # A hard stop: the turn did not reach a Haiku 5.5 answer through the
  # planned route. A rubric miss is recorded and the script continues.
  # A replay reuses the stored retrieval string and must not reinterpret the turn.
  def block_reason(name, response, body, events, focus, replay: false)
    return "http_#{response[:status]}" unless response[:status] == 200
    return "status_#{body['status']}" unless body["status"] == "success"

    answer = body["answer"].to_s
    return "service_unavailable" if answer == I18n.t("rag.service_unavailable", locale: :es)
    return "interpreter_failure" if answer == I18n.t("rag.interpreter_service_failure", locale: :es)
    return "data_not_available" if answer == I18n.t("rag.data_not_available", locale: :es)

    interpreter = events.reverse.find { |event| event["kind"] == "interpreter_request" }
    sent = interpreter && interpreter["anthropic_body"]
    if replay
      return "replay_reinterpreted" if interpreter
    elsif !sent.is_a?(Hash)
      return "interpreter_not_sent"
    elsif !(sent["model"] == MODEL_ID && sent.dig("output_config", "effort") == Rag::TurnInterpreter::EFFORT &&
      sent["max_tokens"].to_i == Rag::TurnInterpreter.max_output_tokens && sent.dig("tool_choice", "name") == "turn_perception" &&
      !sent.key?("temperature") && !sent.key?("thinking"))
      return "interpreter_shape"
    end

    request = events.reverse.find { |event| event["kind"] == "converse" && event["provider"] == "anthropic" }
    return "generator_not_sent" unless request
    return "generator_shape" unless request["model"] == MODEL_ID &&
      request["max_tokens"].to_i == Rag::CompanionDirectAnswer.generation_max_tokens &&
      request.dig("thinking", "type") == Rag::CompanionDirectAnswer.thinking_mode &&
      (request.key?("output_config") ? request.dig("output_config", "effort") == Rag::CompanionDirectAnswer.effort : Rag::CompanionDirectAnswer.effort.nil?) &&
      !request.key?("tools")

    direct = events.reverse.find { |event| event["kind"] == "companion_direct" }
    return "generator_stop_#{direct && direct['stop_reason']}" unless direct && direct["stop_reason"] == "end_turn"

    retrieves = generation_retrieves(events)
    return "retrieve_missing" if retrieves.empty?
    uris = focus.map { |item| item.display_s3_uri(KbDocument::KB_BUCKET) }
    return "retrieve_target" unless retrieves.all? { |retrieve|
      retrieve["knowledge_base_id"].to_s == KB_ID && (uris - filter_uris(retrieve)).empty?
    }
    config = retrieves.first.dig("retrieval_configuration", "vector_search_configuration") || {}

    expected = profile(name)
    return nil unless expected
    return "retrieve_profile_#{config['number_of_results']}" unless config["number_of_results"].to_i == expected["number_of_results"]

    rerank = events.reverse.find { |event| event["kind"] == "companion_rerank" }
    applied = rerank.present? && rerank["result"] == "applied"
    return "rerank_profile" unless applied == expected["rerank"]

    nil
  end

  def effective_config(events)
    contract = events.find { |event| event["kind"] == "process_contract" } || {}
    interpreter = events.reverse.find { |event| event["kind"] == "interpreter_request" }
    sent = (interpreter && interpreter["anthropic_body"]) || {}
    request = events.reverse.find { |event| event["kind"] == "converse" && event["provider"] == "anthropic" } || {}
    system = request["system"]
    {
      "process" => contract.slice(
        "pid", "interpreter_model_id", "interpreter_effort", "interpreter_max_tokens", "companion_generation",
        "companion_direct_model_id", "companion_direct_max_tokens", "companion_direct_thinking", "companion_direct_effort",
        "bedrock_inference", "knowledge_base_id", "haiku_mode", "ledger"
      ),
      "interpreter" => sent.slice("model", "max_tokens", "output_config", "tool_choice").merge(
        "keys" => sent.keys.sort, "system_sha256" => interpreter && interpreter["prompt_version"]
      ),
      "generator" => request.slice("model", "max_tokens", "thinking", "output_config").merge(
        "keys" => request.keys.sort - %w[kind run_id session_id correlation_root account_id user_id episode_id attempt sequence provenance stage result operation provider model_id],
        "system_sha256" => system.is_a?(Hash) ? system["sha256"] : (system && Digest::SHA256.hexdigest(system.to_s))
      )
    }
  end

  def interpreter_view(events)
    pick = ->(kind) { events.reverse.find { |event| event["kind"] == kind }&.except("run_id", "account_id", "user_id") }
    {
      "response" => pick.call("interpreter_response")&.slice("result", "response", "native", "stop_reason"),
      "raw" => pick.call("interpreter_raw")&.dig("tool_input"),
      "applied" => pick.call("perception_applied"),
      "failures" => events.select { |event| event["kind"] == "interpreter_failure" }.map { |event| event.except("run_id", "account_id", "user_id") }
    }
  end

  # The pinned journey does not expect a card. If one is shown for the
  # pinned manual, the card's own confirmation is sent, as the browser would.
  def confirm_card!(client, directory, number, card, document)
    target = Array(card["cards"]).find { |item| item["kb_document_id"].to_i == document.id }
    File.write(directory.join(format("turn-%d", number), "manual_suggestion.json"), JSON.pretty_generate(card))
    return unless target && !target["focused"]

    confirm = client.post_json("/pinned_documents", {
      kb_document_id: target["kb_document_id"], document_uid: target["document_uid"], episode_id: target["episode_id"]
    }.compact)
    File.write(directory.join(format("turn-%d", number), "card_confirm.json"), JSON.pretty_generate(
      "status" => confirm[:status], "body" => confirm[:json]
    ))
  end

  def copy_capture(run_id, request_id, turn_dir)
    key = request_id.to_s.gsub(/[^A-Za-z0-9_-]/, "")
    base = Rails.root.join(Rag::WebRequestCapture::ROOT, run_id)
    source = base.join(key)
    source = base.glob("#{key}*").max_by { |path| path.mtime } unless source.directory?
    return unless source&.directory?

    FileUtils.cp_r("#{source}/.", turn_dir)
  end

  # ---- server --------------------------------------------------------------

  # The manuals belong to an account without a development host. The
  # development fallback slug resolves an unmapped Host to that account,
  # the same way a phone tunnel does; production ignores it.
  def request_host(account)
    "#{account.slug}.haiku55.test"
  end

  def start_server(directory, run_id, reserved, account)
    env = SERVER_ENV.merge(
      "DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG" => account.slug,
      "RAG_VALIDATION_CAPTURE_RUN" => run_id,
      "RAG_ASSIGNMENT_SPEND_PATH" => Guion2Direct.spend_path,
      "RAG_LOCAL_PASS_CALL_CAP" => reserved["calls"].to_s,
      "RAG_LOCAL_PASS_COST_CAP_USD" => reserved["ceiling_usd"],
      "PORT" => PORT.to_s
    )
    CLEARED_ENV.each { |key| env[key] = nil }
    log = directory.join("server.log").to_s
    pid = Process.spawn(env, "bundle", "exec", "puma", "-b", "tcp://127.0.0.1:#{PORT}", "-t", "1:1", "-w", "0",
      "-e", "development", chdir: Rails.root.to_s, out: log, err: log, pgroup: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
    loop do
      begin
        return pid if Net::HTTP.get_response(URI("http://#{HOST}:#{PORT}/up")).code == "200"
      rescue StandardError
        nil
      end
      raise "server did not start; see #{log}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 1
    end
  end

  def stop_server(pid)
    return unless pid

    Process.kill("TERM", -Process.getpgid(pid))
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # ---- helpers -------------------------------------------------------------

  # The runner process does not carry the server's episode settings, so it
  # reads the persisted id instead of parsing the live window.
  def stored_episode_id(session)
    episode = session&.active_episode
    episode.is_a?(Hash) ? episode["episode_id"] : nil
  end

  def new_user(account, name)
    email = "haiku55-http-#{name}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}@danebo.local"
    password = SecureRandom.hex(16)
    user = User.create!(email: email, password: password, password_confirmation: password, account: account)
    passwords[user.id] = password
    user
  end

  def passwords
    @passwords ||= {}
  end

  def user_password(user)
    passwords.fetch(user.id)
  end

  def script(name)
    return EXTRA_SCRIPTS.fetch(name) if EXTRA_SCRIPTS.key?(name)

    variant = VARIANTS[name]
    return Haiku55Companion::SCRIPTS.fetch(name) unless variant

    base = Haiku55Companion::SCRIPTS.fetch(variant["base"])
    turns = base["turns"].first(variant["last"]).each_with_index.map { |text, index| variant["replace"].fetch(index + 1, text) }
    base.merge("turns" => turns)
  end

  # No fixed profile for the unknown-identity scripts: the trace records the
  # effective top_k and rerank instead of stopping on them.
  def profile(name)
    return nil if EXTRA_SCRIPTS.key?(name)

    PROFILES[name] || PROFILES.fetch(VARIANTS.fetch(name)["base"])
  end

  def document_for(name)
    KbDocument.find_by(document_uid: script(name)["document_uid"])
  end

  def assignment_spend
    Rag::AssignmentSpend.new(path: Guion2Direct.spend_path, call_cap: NEXT_CAP, cost_cap_usd: Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD)
  end

  def read_ledger
    JSON.parse(File.read(Guion2Direct.spend_path))
  end

  def ledger_view
    ledger = read_ledger
    room = grant_room(ledger)
    {
      "attempts" => ledger["attempts"], "call_cap" => ledger.dig("authorization", "call_cap"),
      "committed" => ledger["committed"], "unknown" => ledger["unknown"],
      "open" => ledger["open"], "grant_entries" => room["entries"], "grant_exposure" => money(room["exposure"]),
      "grant_room_usd" => money(room["usd"]), "grant_room_calls" => room["calls"]
    }
  end

  def manifest
    {
      "at" => Time.now.utc.iso8601, "head" => head, "dirty" => dirty_tree?,
      "system_sha256" => Digest::SHA256.hexdigest(Rag::CompanionDirectAnswer::SYSTEM_PROMPT),
      "interpreter_prompt_sha256" => Digest::SHA256.hexdigest(Rag::TurnInterpreter::PROMPT),
      "server_env" => SERVER_ENV, "cleared_env" => CLEARED_ENV
    }
  end

  def head
    `git -C #{Rails.root} rev-parse HEAD`.strip
  end

  def dirty_tree?
    !`git -C #{Rails.root} status --porcelain`.strip.empty?
  end

  def money(value)
    format("%.6f", BigDecimal(value.to_s))
  end

  def refuse(io, reason)
    io.puts JSON.generate("status" => "refused", "reason" => reason, "stopped_before_model" => true)
    2
  end

  # Cookie jar, CSRF token, and JSON posts against the local Puma.
  class Client
    def initialize(port, host_header)
      @host_header = host_header
      @http = Net::HTTP.new(HOST, port)
      @http.read_timeout = 180
      @cookies = {}
      @csrf = nil
    end

    def sign_in!(email, password)
      page = get("/users/sign_in")
      token = page.body[/name="authenticity_token" value="([^"]+)"/, 1]
      raise "sign-in form without token" unless token

      form = URI.encode_www_form("authenticity_token" => token, "user[email]" => email, "user[password]" => password)
      response = request(Net::HTTP::Post.new("/users/sign_in"), form, "application/x-www-form-urlencoded")
      raise "sign-in failed #{response.code}" unless response.code == "303" || response.code == "302"

      home = get("/")
      @csrf = home.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
      raise "home without csrf token (#{home.code})" unless @csrf
    end

    def post_json(path, payload)
      response = request(Net::HTTP::Post.new(path), JSON.generate(payload), "application/json")
      json = begin
        response.body.to_s.empty? ? nil : JSON.parse(response.body)
      rescue JSON::ParserError
        nil
      end
      { status: response.code.to_i, json: json, request_id: response["X-Request-Id"], body: response.body }
    end

    def get(path)
      request(Net::HTTP::Get.new(path), nil, nil)
    end

    private

    def request(req, body, type)
      req["Host"] = @host_header
      req["User-Agent"] = USER_AGENT
      req["Accept"] = type == "application/json" ? "application/json" : "text/html"
      req["Cookie"] = @cookies.map { |key, value| "#{key}=#{value}" }.join("; ") if @cookies.any?
      req["X-CSRF-Token"] = @csrf if @csrf && req.is_a?(Net::HTTP::Post)
      if body
        req["Content-Type"] = type
        req.body = body
      end
      response = @http.request(req)
      Array(response.get_fields("Set-Cookie")).each do |line|
        pair = line.split(";", 2).first
        key, value = pair.split("=", 2)
        @cookies[key] = value
      end
      response
    end
  end
end

require Rails.root.join("script/field_companion/haiku55_journey_fixtures").to_s

exit Haiku55Http.run unless ENV["HTTP55_REQUIRE"] == "1"
