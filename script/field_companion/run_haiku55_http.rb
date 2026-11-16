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
  PHASE = ENV.fetch("HTTP55_PHASE", "acceptance")
  SPEND = Rag::AssignmentSpend
  AUDIT_PLAN = %w[audit_thyssen_photo audit_thyssen_engineering].freeze
  CONTINUATION_PLAN = %w[audit_thyssen_photo_ea audit_kone_lwi audit_thyssen_engineering].freeze
  PHOTO_EA_TURNS = 8
  PHOTO_LABEL_LINE_REPLY = "Sí, el cable de los trincos llega a ese borne."
  PHOTO_OPERATOR_REPLY = "Sí, tiene motor de operador."
  PHOTO_OPEN_READING_REPLY = "Marca 0 Vcc."
  PHOTO_NOMINAL_READING_REPLY = "No, marca 0 Vcc."
  CONTINUATION = PHASE == "field_continuation"
  CONTINUATION_RETRY = CONTINUATION && ENV["HTTP55_CONTINUATION_RETRY"] == "1"
  AUDIT_APPROVAL = "HTTP55_THYSSEN_AUTHORIZED_SHA"
  AUDIT_KB_BUCKET = "multimodal-source-destination"
  # Same ids, call counts, and dollar ceilings the spend guard recognizes.
  # Acceptance stays inside the standing cap of 1158. Regression is the step
  # to 1190. CEA completion keeps its own one-shot grant.
  FIELD_GRANTS = {
    "acceptance" => {
      "id" => Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID,
      "calls" => Rag::AssignmentSpend::FIELD_ACCEPTANCE_CALLS,
      "usd" => Rag::AssignmentSpend::FIELD_ACCEPTANCE_USD,
      "next_cap" => 1158,
      "bump" => false
    }.freeze,
    "thyssen_audit" => {
      "id" => SPEND::THYSSEN_AUDIT_ID, "calls" => SPEND::THYSSEN_AUDIT_CALLS,
      "usd" => SPEND::THYSSEN_AUDIT_USD, "next_cap" => SPEND::THYSSEN_AUDIT_CAP
    }.freeze,
    "thyssen_recheck" => {
      "id" => SPEND::THYSSEN_RECHECK_ID, "calls" => SPEND::THYSSEN_AUDIT_CALLS,
      "usd" => SPEND::THYSSEN_AUDIT_USD, "next_cap" => SPEND::THYSSEN_RECHECK_CAP
    }.freeze,
    "field_continuation" => {
      "id" => SPEND::FIELD_CONTINUATION_ID, "calls" => SPEND::FIELD_CONTINUATION_CALLS,
      "usd" => SPEND::FIELD_CONTINUATION_USD, "next_cap" => SPEND::FIELD_CONTINUATION_CAP
    }.freeze,
    "regression" => {
      "id" => Rag::AssignmentSpend::FIELD_REGRESSION_ID,
      "calls" => Rag::AssignmentSpend::FIELD_REGRESSION_CALLS,
      "usd" => Rag::AssignmentSpend::FIELD_REGRESSION_USD,
      "next_cap" => Rag::AssignmentSpend::FIELD_VALIDATION_CALL_CAP,
      "bump" => true
    }.freeze
  }.freeze
  CEA_COMPLETION = PHASE == "regression" && ENV["HTTP55_CEA_COMPLETION"] == "1"
  RECHECK = PHASE == "thyssen_recheck"
  AUDIT = PHASE == "thyssen_audit" || RECHECK || CONTINUATION
  SPEC = FIELD_GRANTS.fetch(PHASE)
  GRANT_CALLS = CEA_COMPLETION ? Rag::AssignmentSpend::CEA_COMPLETION_CALLS : SPEC["calls"]
  NEXT_CAP = CEA_COMPLETION ? 1158 : SPEC["next_cap"]
  GRANT_USD = CEA_COMPLETION ? Rag::AssignmentSpend::CEA_COMPLETION_USD : SPEC["usd"]
  EXECUTION_ID = CEA_COMPLETION ? Rag::AssignmentSpend::CEA_COMPLETION_ID : SPEC["id"]
  ACCEPTANCE_PLAN = %w[kpvs guion3].freeze
  REGRESSION_PLAN = %w[guion2 guion1 elemont cea cea_label_known cea_label_unseen].freeze
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
  # Thyssen FDN Universal MCINV4 pinned, KP-VS. The catalog id 3 is not a
  # local accounts.id: the row is registered in the runner's account.
  FDN_DOCUMENT_UID = "02ae6128-077b-4c00-8029-f0cf80e0f6c4"
  KPVS_MESSAGE = "FDN Universal MCINV4. En viaje hay ruido fuerte en el motor de tracción. En el menú PID, KP-VS está en 2,5."
  KPVS_SCRIPTS = {
    "kpvs" => { "document_uid" => FDN_DOCUMENT_UID, "turns" => [ KPVS_MESSAGE ] },
    "kpvs_paraphrase" => {
      "document_uid" => FDN_DOCUMENT_UID,
      "turns" => [ "Tengo un FDN Universal MCINV4 y en marcha el motor de tracción hace mucho ruido. Veo KP-VS en 2,5 en el menú PID." ]
    },
    "kpvs_exact" => {
      "document_uid" => FDN_DOCUMENT_UID,
      "turns" => [ "FDN Universal MCINV4. En viaje hay ruido fuerte en el motor de tracción. En el menú PID, KP-VS está en 3,0." ]
    },
    "guion3" => {
      "document_uid" => FDN_DOCUMENT_UID,
      "turns" => [
        "Thyssen FDN Universal con MCINV4. En viaje se oye fuerte el motor de tracción. No tengo acceso al TLS.",
        "Ingeniería leyó KP-VS en 2,5. La placa del motor dice 5,5 kW, 380 V y 1.175 rpm. La corriente no se alcanza a leer. ¿Sirven los datos del motor Eberle del manual?",
        "No hemos cambiado nada y el ruido sigue. ¿Le digo a Ingeniería que lo deje en 3,5?"
      ]
    }
  }.freeze
  KONE_LWI_DOCUMENT_UID = "6b37e94e-1d4c-4d59-a33a-66e894116c9a"
  AUDIT_JOURNEYS = JSON.parse(Rails.root.join("test/fixtures/field_companion/audit_20261113/journeys.json").read).freeze
  AUDIT_SCRIPTS = {
    "audit_thyssen_photo" => { "document_uid" => FDN_DOCUMENT_UID, "turns" => AUDIT_JOURNEYS.fetch("photo"), "photo" => true },
    "audit_thyssen_photo_ea" => { "document_uid" => FDN_DOCUMENT_UID, "turns" => AUDIT_JOURNEYS.fetch("photo_ea"), "photo" => true },
    "audit_kone_lwi" => { "document_uid" => KONE_LWI_DOCUMENT_UID, "turns" => AUDIT_JOURNEYS.fetch("kone_lwi") },
    "audit_thyssen_engineering" => { "document_uid" => FDN_DOCUMENT_UID, "turns" => AUDIT_JOURNEYS.fetch("engineering") },
    "audit_thyssen_engineering_plate" => {
      "document_uid" => FDN_DOCUMENT_UID,
      "turns" => AUDIT_JOURNEYS.fetch("engineering").dup.tap { |turns| turns[2] = AUDIT_JOURNEYS.fetch("engineering_variant").first }
    }
  }.freeze
  # Revision journeys: after turn N, the card for one of the listed manuals
  # is confirmed with its own action, and the same question is replayed.
  EXTRA_SCRIPTS = KPVS_SCRIPTS.merge(AUDIT_SCRIPTS).merge(
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
  ).freeze
  SERVER_ENV = {
    "RAILS_ENV" => "development",
    "WEB_CONCURRENCY" => "0",
    "RAILS_MAX_THREADS" => "1",
    "BEDROCK_INFERENCE" => "blocked",
    "BEDROCK_KNOWLEDGE_BASE_ID" => KB_ID,
    "SHOW_RAG_SOURCES" => "true",
    "SHARED_SESSION_ENABLED" => "false",
    "AWS_MAX_ATTEMPTS" => "1",
    "AWS_RETRY_MODE" => "standard",
    "AWS_HTTP_OPEN_TIMEOUT" => "15",
    "RAG_TRANSIENT_ATTEMPT_LIMIT" => "1",
    "RAG_LOCAL_PASS_GUARD" => "1",
    "RAG_LOCAL_PASS_ALLOWED_CALLS" => "converse@#{TRACKING_MODEL_ID},converse_message@#{TRACKING_MODEL_ID}"
  }.freeze
  CLEARED_ENV = %w[
    RAG_ASSIGNMENT_EXECUTION_ID RAG_ASSIGNMENT_RUN_SCOPE RAG_PHOTO_WORKER_QUEUE RAG_PHOTO_LOCAL_STORE
    RAG_PHOTO_VISION_SPEND_PATH PHOTO_QUESTION_RAG_ENABLED
    COMPANION_DIRECT_PROVIDER COMPANION_DIRECT_MODEL_ID COMPANION_DIRECT_MAX_TOKENS COMPANION_DIRECT_EFFORT
    COMPANION_DIRECT_THINKING INTERPRETER_MAX_TOKENS SOLID_QUEUE_IN_PUMA
    RAG_VALIDATION_CAPTURE_ACCOUNT_IDS PHASE4_WEB_CHECK
    FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED DOCUMENT_IDENTITY_SCOPE_ENABLED
    HAIKU_QUERY_ANALYSIS_MODE RAG_EPISODE_SCOPE_ENABLED RAG_COMPANION_TURN RAG_COMPANION_GENERATION
  ].freeze

  module_function

  def run(io: $stdout)
    iteration = ENV["HTTP55_ITERATION"].presence || "live0"
    plan = (ENV["HTTP55_PLAN"].presence || authorized_plan.join(",")).split(",").map(&:strip)
    directory = ROOT.join(iteration)
    if AUDIT && (directory.join("manifest.json").exist? || directory.join("summary.json").exist?)
      return refuse(io, "audit_artifacts_already_exist")
    end
    FileUtils.mkdir_p(directory)
    preflight = preflight_document(plan)
    File.write(directory.join("preflight.json"), JSON.pretty_generate(preflight))
    io.puts JSON.generate(preflight.except("scripts", "vision_preflight"))
    io.puts JSON.generate(preflight["vision_preflight"]) if preflight["vision_preflight"]
    return 0 unless ENV["HTTP55_EXECUTE"] == "1"
    return refuse(io, preflight["decision"]) unless preflight["decision"] == "execute"
    vision_decision = preflight.dig("vision_preflight", "decision")
    return refuse(io, vision_decision) if vision_decision && vision_decision != "not_requested" && vision_decision != "execute"
    return 2 unless admit!(io, directory: directory)

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
      break if !AUDIT && result["status"] != "executed"
    end
    File.write(directory.join("summary.json"), JSON.pretty_generate(
      "head" => head, "results" => results, "ledger" => ledger_view
    ))
    results.size == plan.size && results.all? { |row| row["status"] == "executed" && row["rubric_ok"] } ? 0 : 2
  end

  def authorized_plan
    return [ "audit_thyssen_photo_ea" ] if photo_continuation?
    return ["audit_kone_lwi"] if CONTINUATION_RETRY
    return CONTINUATION_PLAN if CONTINUATION
    return AUDIT_PLAN if AUDIT

    PHASE == "acceptance" ? ACCEPTANCE_PLAN : REGRESSION_PLAN
  end

  def photo_continuation?
    CONTINUATION && ENV["HTTP55_PLAN"].to_s.split(",").map(&:strip) == [ "audit_thyssen_photo_ea" ]
  end

  def audit_photo_path
    ENV["AUDIT_THYSSEN_PHOTO_PATH"].presence
  end

  def audit_photo_input
    path = audit_photo_path
    return unless path && File.file?(path)

    image = Vips::Image.new_from_file(path)
    return unless [image.width, image.height] == [Rag::GuardedPhotoVision::WIDTH, Rag::GuardedPhotoVision::HEIGHT]
    return unless image.get("vips-loader") == "jpegload"

    { "bytes" => File.size(path), "sha256" => Digest::SHA256.file(path).hexdigest,
      "width" => image.width, "height" => image.height }
  rescue Vips::Error
    nil
  end

  # ---- preflight and grant ------------------------------------------------

  def preflight_document(plan)
    ledger = read_ledger
    turn = Haiku55Companion.per_turn_ceiling
    scripts = plan.index_with { |name| reservation(name, turn) }
    room = grant_room(ledger)
    cap = ledger.dig("authorization", "call_cap").to_i
    remaining = cap - ledger["attempts"].to_i
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
    elsif CEA_COMPLETION && (plan != ["cea"] || ENV["HTTP55_GUI"] == "1")
      "outside_cea_completion_plan"
    elsif CEA_COMPLETION && ledger["seq"] != Rag::AssignmentSpend::CEA_COMPLETION_SEQUENCE
      "cea_completion_already_started"
    elsif CEA_COMPLETION && ledger.fetch("executions").any? { |row| row["id"] == EXECUTION_ID }
      "cea_completion_already_admitted"
    elsif AUDIT && (plan != authorized_plan || ENV["HTTP55_GUI"] == "1")
      "outside_thyssen_audit_plan"
    elsif !plan.all? { |name| authorized_plan.include?(name) }
      "outside_authorized_plan"
    elsif PHASE == "regression" && !acceptance_passed?
      "acceptance_missing_for_head"
    elsif pins.values.any?(&:blank?)
      "pin_missing"
    elsif accounts.any? { |id| id.nil? } || plan.any? { |name| AccountHostResolver.host_map.key?(request_host(document_for(name).account)) }
      "host_account_mismatch"
    elsif (photo_choice = photo_decision(ledger, calls, worst, room))
      photo_choice
    elsif kone_lwi_admission?(ledger, calls, worst, scripts, room)
      "execute"
    elsif scripts.values.any? { |row| BigDecimal(row["ceiling_usd"]) > room["usd"] } || calls > room["calls"]
      "grant_does_not_cover_plan"
    elsif AUDIT && KbDocument::KB_BUCKET != AUDIT_KB_BUCKET
      "audit_kb_bucket_mismatch"
    elsif AUDIT && !CONTINUATION_RETRY && !audit_photo_input
      "audit_jpeg_missing_or_invalid"
    elsif AUDIT && !audit_baseline?(ledger)
      "thyssen_ledger_baseline_changed"
    elsif AUDIT && !CONTINUATION_RETRY && !photo_continuation? && worst != BigDecimal(GRANT_USD)
      "thyssen_price_changed"
    elsif AUDIT && ENV[AUDIT_APPROVAL] != head
      "thyssen_grants_pending"
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
      "assignment_call_cap" => cap,
      "assignment_remaining_calls" => remaining,
      "regression_window_usd" => CEA_COMPLETION ? "0.143121" : (GRANT_USD if PHASE == "regression"),
      "cea_completion_admitted" => CEA_COMPLETION && ledger.fetch("executions").any? { |row| row["id"] == EXECUTION_ID },
      "assignment_cap_usd" => ledger["cost_cap_usd"],
      "thyssen_approval_required" => (AUDIT ? {
        "haiku_execution_usd" => money(worst), "haiku_execution_calls" => calls,
        "haiku_required_cumulative_cap" => ledger["attempts"].to_i + calls,
        "haiku_cap_increase" => [ calls - remaining, 0 ].max,
        "vision" => scripts.dig(authorized_plan.first, "vision")
      } : nil),
      "photo_input" => (audit_photo_input if AUDIT),
      "bedrock" => (AUDIT ? { "mode" => "read_only", "rerank_model" => "cohere.rerank-v3-5:0",
        "rerank_estimate_usd" => money(Haiku55Companion::RERANK_USD * scripts.values.sum { |row| row["turns"] }) } : nil),
      "attempts" => ledger["attempts"],
      "committed" => ledger["committed"],
      "unknown" => ledger["unknown"],
      "pins" => pins,
      "knowledge_base_id" => KB_ID,
      "model_id" => MODEL_ID,
      "kb_bucket" => KbDocument::KB_BUCKET,
      "system_sha256" => Digest::SHA256.hexdigest(Rag::CompanionDirectAnswer::SYSTEM_PROMPT),
      "interpreter_prompt_sha256" => Digest::SHA256.hexdigest(Rag::TurnInterpreter::PROMPT),
      "anthropic_key_present" => ENV["ANTHROPIC_API_KEY"].present?,
      "kone_lwi_admission" => (kone_lwi_admission?(ledger, calls, worst, scripts, room) ? "pending" : nil),
      "vision_preflight" => vision_preflight_document(plan)
    }
  end

  # Sonnet has its own one-call ledger. This decision does not spend Haiku
  # room and does not move the US$4 assignment cap.
  def vision_preflight_document(plan)
    return { "status" => "preflight", "lane" => "vision", "decision" => "not_requested" } unless plan.any? { |name| script(name)["photo"] }

    input = audit_photo_input
    {
      "status" => "preflight", "lane" => "vision",
      "decision" => (input ? "execute" : "audit_jpeg_missing_or_invalid"),
      "model_id" => Rag::GuardedPhotoVision::MODEL_ID, "calls" => 1,
      "ceiling_usd" => money(Rag::GuardedPhotoVision.ceiling),
      "photo_input" => input, "ledger" => "separate", "counts_toward_haiku_cap" => false
    }
  end

  # nil lets the shared checks continue. A short window returns execute only
  # when the photo admission can open its own 17-call grant.
  def photo_decision(ledger, calls, worst, room)
    return nil unless photo_continuation?
    return "audit_jpeg_missing_or_invalid" unless audit_photo_input
    return "thyssen_grants_pending" unless ENV[AUDIT_APPROVAL] == head
    return "audit_kb_bucket_mismatch" unless KbDocument::KB_BUCKET == AUDIT_KB_BUCKET

    short = calls > room["calls"] || BigDecimal(worst.to_s) > room["usd"]
    return nil unless short

    SPEND.thyssen_photo_refusal(ledger, calls: calls, cost_usd: money(worst)) || "execute"
  end

  # One script, complete: two calls per turn plus one, priced at the ceiling.
  def reservation(name, turn)
    turns = name == CONTINUATION_PLAN.first ? PHOTO_EA_TURNS : script(name)["turns"].size + script(name).fetch("accept", {}).size
    ceiling = (turn["interpreter"] + turn["generation"]) * turns
    reservation = { "turns" => turns, "calls" => turns * 2 + 1, "ceiling_usd" => money(ceiling + turn["interpreter"]) }
    if script(name)["photo"]
      reservation["vision"] = {
        "calls" => 1, "model_id" => Rag::GuardedPhotoVision::MODEL_ID,
        "ceiling_usd" => money(Rag::GuardedPhotoVision.ceiling), "route" => "field_photo",
        "input_text_bytes_cap" => Rag::GuardedPhotoVision::TEXT_BYTES,
        "image_tokens" => Rag::GuardedPhotoVision::IMAGE_TOKENS,
        "output_tokens" => Rag::GuardedPhotoVision::OUTPUT_TOKENS
      }
    end
    reservation
  end

  def grant_room(ledger, phase: PHASE)
    if phase == "field_continuation"
      last = Array(ledger["executions"]).last
      return kone_live_room(ledger) if SPEND.thyssen_photo_grant?(last) || SPEND.kone_lwi_grant?(last)
    end

    spec = FIELD_GRANTS.fetch(phase)
    cea = phase == "regression" && ENV["HTTP55_CEA_COMPLETION"] == "1"
    execution_id = cea ? Rag::AssignmentSpend::CEA_COMPLETION_ID : spec["id"]
    granted = Array(ledger["executions"]).find { |row| row.is_a?(Hash) && row["id"] == execution_id }
    after = granted ? granted["after_attempt"].to_i : ledger["seq"].to_i
    rows = Array(ledger["entries"]).select { |entry| entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released" }
    exposure = rows.sum(BigDecimal("0")) { |entry| Haiku55Companion.exposure(entry) }
    assignment_room = BigDecimal(ledger["cost_cap_usd"]) - BigDecimal(ledger["committed"]) -
      BigDecimal(ledger["unknown"]) - ledger.fetch("open").values.sum(BigDecimal("0")) { |amount| BigDecimal(amount) }
    cap_usd = cea ? Rag::AssignmentSpend::CEA_COMPLETION_USD : spec["usd"]
    cap_calls = cea ? Rag::AssignmentSpend::CEA_COMPLETION_CALLS : spec["calls"]
    next_cap = cea ? 1158 : spec["next_cap"]
    { "usd" => [ BigDecimal(cap_usd) - exposure, assignment_room ].min,
      "calls" => [ cap_calls - rows.size, next_cap - ledger["attempts"].to_i ].min,
      "exposure" => exposure, "entries" => rows.size, "execution_id" => execution_id,
      "after_attempt" => after, "next_cap" => next_cap }
  end

  def kone_live_room(ledger)
    grant = ledger.fetch("executions").last
    after = grant["after_attempt"].to_i
    rows = Array(ledger["entries"]).select { |entry| entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released" }
    exposure = rows.sum(BigDecimal("0")) { |entry| Haiku55Companion.exposure(entry) }
    assignment_room = BigDecimal(ledger["cost_cap_usd"]) - BigDecimal(ledger["committed"]) -
      BigDecimal(ledger["unknown"]) - ledger.fetch("open", {}).values.sum(BigDecimal("0")) { |amount| BigDecimal(amount) }
    next_cap = ledger.dig("authorization", "call_cap").to_i
    { "usd" => [ BigDecimal(grant["cost_usd"]) - exposure, assignment_room ].min,
      "calls" => [ grant["calls"].to_i - rows.size, next_cap - ledger["attempts"].to_i ].min,
      "exposure" => exposure, "entries" => rows.size, "execution_id" => grant["id"],
      "after_attempt" => after, "next_cap" => next_cap }
  end

  # The SHA authorizes one KONE script when the current window is short and
  # the added run still fits inside 70 calls, US$0.249210, and the US$4 cap.
  def kone_lwi_admission?(ledger, calls, worst, scripts, room)
    short = scripts.values.any? { |row| BigDecimal(row["ceiling_usd"]) > room["usd"] } || calls > room["calls"]
    short && CONTINUATION_RETRY && ENV[AUDIT_APPROVAL] == head &&
      KbDocument::KB_BUCKET == AUDIT_KB_BUCKET &&
      SPEND.kone_lwi_step_admissible?(ledger, calls: calls, cost_usd: worst)
  end

  def acceptance_passed?
    directory = ROOT.join(ENV["HTTP55_ACCEPTANCE"].to_s)
    summary = Haiku55Companion.read_json(directory.join("summary.json"))
    manifest = Haiku55Companion.read_json(directory.join("manifest.json"))
    return false unless summary && manifest
    accepted_head = summary["head"]
    return false unless accepted_head == head || (CEA_COMPLETION &&
      accepted_head == "3217057e7bebd75acae93ef2ff16d6c580e5e9f2" &&
      system("git", "-C", Rails.root.to_s, "merge-base", "--is-ancestor", accepted_head, head))
    return false unless manifest.values_at("system_sha256", "interpreter_prompt_sha256") ==
      self.manifest.values_at("system_sha256", "interpreter_prompt_sha256")

    ACCEPTANCE_PLAN.all? { |name| summary["results"].any? { |row| row["script"] == name && row["rubric_ok"] } }
  end

  def audit_baseline?(ledger)
    if photo_continuation?
      last = ledger.fetch("executions").last
      return SPEND.thyssen_photo_grant?(last) && SPEND.thyssen_photo_chain?(ledger)
    end
    if CONTINUATION_RETRY
      last = ledger.fetch("executions").last
      return true if SPEND.kone_lwi_grant?(last) && SPEND.kone_lwi_chain?(ledger)

      return ledger.dig("authorization", "call_cap") == NEXT_CAP &&
        last&.values_at("id", "after_attempt", "cost_usd", "calls") ==
          [ EXECUTION_ID, SPEND::FIELD_CONTINUATION_SEQUENCE, GRANT_USD, GRANT_CALLS ]
    end
    return SPEND.field_continuation_baseline?(ledger) if CONTINUATION

    SPEND.thyssen_baseline?(ledger, recheck: RECHECK)
  end

  def admit!(io, directory: nil)
    if AUDIT
      return false unless directory && ENV[AUDIT_APPROVAL] == head
      if photo_continuation?
        reserved = reservation("audit_thyssen_photo_ea", Haiku55Companion.per_turn_ceiling)
        return false unless audit_photo_input

        room = grant_room(read_ledger)
        covered = BigDecimal(reserved["ceiling_usd"]) <= room["usd"] && reserved["calls"] <= room["calls"]
        assignment_spend.admit_thyssen_photo_run!(calls: reserved["calls"], cost_usd: reserved["ceiling_usd"]) unless covered
        Rag::GuardedPhotoVision.assignment(directory.join("vision-spend.json")).admit_execution!(
          id: Rag::GuardedPhotoVision::GRANT_ID, calls: 1, cost_usd: Rag::GuardedPhotoVision.ceiling
        )
        refreshed = grant_room(read_ledger)
        return BigDecimal(reserved["ceiling_usd"]) <= refreshed["usd"] && reserved["calls"] <= refreshed["calls"]
      end
      if CONTINUATION_RETRY
        reserved = reservation("audit_kone_lwi", Haiku55Companion.per_turn_ceiling)
        room = grant_room(read_ledger)
        covered = BigDecimal(reserved["ceiling_usd"]) <= room["usd"] && reserved["calls"] <= room["calls"]
        return audit_baseline?(read_ledger) if covered

        assignment_spend.admit_kone_lwi_run!(calls: reserved["calls"], cost_usd: reserved["ceiling_usd"])
        refreshed = grant_room(read_ledger)
        return BigDecimal(reserved["ceiling_usd"]) <= refreshed["usd"] && reserved["calls"] <= refreshed["calls"]
      end

      if CONTINUATION
        assignment_spend.admit_field_continuation!
      else
        assignment_spend.admit_thyssen_audit!(recheck: RECHECK)
      end
      Rag::GuardedPhotoVision.assignment(directory.join("vision-spend.json")).admit_execution!(
        id: Rag::GuardedPhotoVision::GRANT_ID, calls: 1, cost_usd: Rag::GuardedPhotoVision.ceiling
      )
      return true
    end

    return assignment_spend.admit_cea_completion!.present? if CEA_COMPLETION

    admit_field_grant!(io, PHASE)
  rescue Rag::AssignmentSpend::Stop => error
    io.puts JSON.generate("status" => "refused", "reason" => error.message)
    false
  end

  # Writes the phase grant once. Acceptance keeps call cap 1158 and cuts the
  # window at the current sequence. Regression bumps 1158 to 1190 only while
  # the file is still at the attempt count read here.
  def admit_field_grant!(io, phase)
    ledger = read_ledger
    spec = FIELD_GRANTS.fetch(phase)
    existing = Array(ledger["executions"]).find { |row| row.is_a?(Hash) && row["id"] == spec["id"] }
    unless existing || field_baseline?(ledger, phase)
      io.puts JSON.generate("status" => "refused", "reason" => "ledger_baseline_changed")
      return false
    end

    spend = Rag::AssignmentSpend.new(
      path: Guion2Direct.spend_path, call_cap: spec["next_cap"],
      cost_cap_usd: Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD
    )
    spend.admit_execution!(
      id: spec["id"], cost_usd: spec["usd"], calls: spec["calls"],
      bump_call_cap_to: (spec["bump"] ? spec["next_cap"] : nil),
      bump_only_if_attempts: (spec["bump"] ? ledger["attempts"] : nil),
      start_after_sequence: true
    )
    spend.snapshot.dig("authorization", "call_cap") == spec["next_cap"]
  end

  def field_baseline?(ledger, phase)
    return false unless BigDecimal(ledger["cost_cap_usd"].to_s) == BigDecimal("4.0")
    return false unless ledger.dig("authorization", "call_cap").to_i == 1158

    executions = Array(ledger["executions"])
    if phase == "acceptance"
      ledger["attempts"].to_i == 1143 && ledger["seq"].to_i == 1145 &&
        executions.last.is_a?(Hash) && executions.last["id"] == Rag::AssignmentSpend::FIELD_ACCEPTANCE_PREVIOUS_ID
    else
      row = executions.find { |item| item.is_a?(Hash) && item["id"] == Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID }
      return false unless row && row["after_attempt"].to_i == Rag::AssignmentSpend::FIELD_ACCEPTANCE_SEQUENCE &&
        row["calls"].to_i == Rag::AssignmentSpend::FIELD_ACCEPTANCE_CALLS &&
        BigDecimal(row["cost_usd"].to_s) == BigDecimal(Rag::AssignmentSpend::FIELD_ACCEPTANCE_USD)

      used = Array(ledger["entries"]).count { |entry|
        entry.is_a?(Hash) && entry["id"].to_i > row["after_attempt"].to_i && entry["status"] != "released"
      }
      used <= row["calls"].to_i
    end
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
    photo = script(name)["photo"]
    browser = nil
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

      if photo
        require_relative "haiku55_photo_browser"
        browser = PhotoBrowser.new(PORT, request_host(document.account), user, user_password(user))
      end
      questions = script(name)["turns"].dup
      focus = [ document ]
      index = 0
      while index < questions.size
        question = questions[index]
        number = index + 1
        unless Haiku55Companion.network_ready?(io)
          rows << { "turn" => number, "status" => "network_unreachable" }
          break
        end
        row = one_turn(directory, run_id, client, user, focus.first, name, number, question, questions,
          focus: focus, browser: browser, reserved: reserved)
        if name == AUDIT_PLAN.last
          row["block_reason"] ||= engineering_stop(number, row, rows.first&.dig("episode_id"))
        elsif name == AUDIT_PLAN.first
          row["block_reason"] ||= photo_followup_stop(number, row["answer"])
        elsif name == CONTINUATION_PLAN.first
          place_photo_reply!(questions, index, row, limit: reserved.fetch("turns"))
        elsif name == "audit_kone_lwi"
          row["block_reason"] ||= Haiku55JourneyRubric.kone_lwi_followup_stop(number, row["answer"])
        end
        accept = script(name).dig("accept", number)
        if row["block_reason"] == "generator_not_sent" && planned_card?(row["manual_suggestion"], accept)
          row["block_reason"] = nil
          row["abstained_with_card"] = true
        end
        rows << row
        io.puts JSON.generate(row.slice("script", "turn", "status", "block_reason", "abstained_with_card", "rubric", "wall_ms"))
        break if row["block_reason"]
        index += 1

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
    rescue StandardError => error
      raise unless AUDIT

      rows << { "turn" => rows.length + 1, "status" => "runner_error",
        "block_reason" => error.class.name, "rubric" => [] }
      File.write(directory.join("runner_error.txt"), error.full_message)
    ensure
      browser&.close
      stop_server(server)
    end
    session = fresh_session(user)
    episode_ids = rows.map { |row| row["episode_id"] }
    episodes = episode_ids.compact.uniq
    single_episode = episode_ids.none?(&:nil?) && episodes.one?
    episode_ok = !(ACCEPTANCE_PLAN.include?(name) || CEA_COMPLETION || AUDIT) || single_episode
    expected = script(name)["turns"].size + script(name).fetch("accept", {}).size
    complete = if name == CONTINUATION_PLAN.first
      rows.map { |row| row["question"] }.last(2) == AUDIT_JOURNEYS.fetch("photo_ea").last(2)
    else
      rows.size == expected
    end
    status = complete && rows.all? { |row| row["block_reason"].nil? } ? "executed" : "stopped"
    payload = {
      "script" => name, "status" => status, "user_id" => user.id, "session_id" => session&.id,
      "episodes" => episodes, "single_episode" => single_episode,
      "rubric_ok" => status == "executed" && episode_ok && rows.all? { |row| row["rubric"].empty? && row.fetch("scope", {}).fetch("ok", true) },
      "turns" => rows.map { |row| row.slice("turn", "label", "question", "answer", "status", "block_reason", "abstained_with_card", "rubric", "wall_ms", "route_outcome", "episode_id", "focus", "scope", "replayed", "pending_question") },
      "ledger_before" => before, "ledger_after" => ledger_view
    }
    File.write(directory.join("summary.json"), JSON.pretty_generate(payload))
    payload
  end

  def one_turn(directory, run_id, client, user, document, name, number, question, questions,
               payload: { question: question }, label: format("turn-%d", number), focus: [ document ], browser: nil, reserved: nil)
    turn_dir = directory.join(label)
    FileUtils.mkdir_p(turn_dir)
    File.write(turn_dir.join("question.txt"), question)
    session = fresh_session(user)
    File.write(turn_dir.join("before.json"), JSON.pretty_generate(
      "episode_id" => stored_episode_id(session), "case_evidence" => session&.case_evidence,
      "focus_document_ids" => session&.focus_document_ids
    ))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    photo_upload = browser && number == 1
    response = if browser
      browser.send_turn(question, photo: (audit_photo_path if photo_upload))
    else
      client.post_json("/rag/ask", payload)
    end
    wall_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    body = response[:json] || {}
    File.write(turn_dir.join("response.json"), JSON.pretty_generate(
      "status" => response[:status], "request_id" => response[:request_id], "body" => body
    ))
    copy_capture(run_id, response[:request_id], turn_dir)
    events = Array((Haiku55Companion.read_json(turn_dir.join("capture.json")) || {})["events"])
    evidence_dir = turn_dir
    if photo_upload && response[:status] == 200 && body["images_uploaded"].present?
      evidence_dir, delivery = await_photo_worker(browser, directory, turn_dir, run_id, reserved, document.account, body.fetch("correlation_id"))
      events += Array((Haiku55Companion.read_json(evidence_dir.join("capture.json")) || {})["events"])
      body = body.merge("answer" => delivery["answer"] || delivery["message"] || delivery["summary"],
        "citations" => delivery["citations"], "photo_status" => delivery["status"])
    end
    browser&.save_turn(turn_dir)
    wall_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round if photo_upload
    answer = body["answer"].to_s
    File.write(turn_dir.join("published.txt"), answer)
    direct = events.reverse.find { |event| event["kind"] == "companion_direct" }
    File.write(turn_dir.join("raw.txt"), Haiku55JourneyFixtures.text(evidence_dir.to_s, direct&.fetch("text", nil)))
    session = fresh_session(user)
    reply = Array(session&.conversation_history).reverse.find { |message| message["role"] == "assistant" }
    delta = events.reverse.find { |event| event["kind"] == "episode_delta" }
    episode_id = stored_episode_id(session) || delta&.dig("episode_after", "episode_id") || delta&.dig("episode_id")
    File.write(turn_dir.join("episode.json"), JSON.pretty_generate(
      "episode_id" => episode_id,
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
    if photo_upload
      trace["answer"] = answer
      trace["worker_capture"] = "worker/capture.json" if evidence_dir != turn_dir
    end
    trace["gates"] = events.select { |event| %w[companion_turn route_decision route_exit companion_claim_backing companion_publication].include?(event["kind"]) }
      .map { |event| event.except("run_id", "account_id", "user_id", "linkage") }
    trace["case_write"] = events.select { |event| event["kind"].to_s.start_with?("case_") || event["kind"] == "assistant_history" }
      .map { |event| event.except("run_id", "account_id", "user_id") }
    File.write(turn_dir.join("trace.json"), JSON.pretty_generate(trace))
    rubric = Haiku55JourneyRubric.reasons(name, number, answer, questions)
    if CEA_COMPLETION
      rubric += Haiku55JourneyRubric.cea_completion_reasons(number, answer, body.fetch("citations", []))
    end
    reason = block_reason(name, response, body, events, focus, replay: payload.key?(:replay_correlation_id))
    if photo_upload
      delivery_event = events.reverse.find { |event| event["kind"] == "photo_answer_delivery" }
      reason = "photo_#{body["photo_status"] || "missing_ack"}" if body["photo_status"] != "photo_question_answered"
      reason ||= "photo_worker_capture_missing" unless delivery_event && delivery_event["correlation_id"] == body["correlation_id"]
      reason ||= "photo_rag_failed" if delivery_event&.dig("outcome") == "failed"
    end
    if name == AUDIT_PLAN.last
      rubric += engineering_checks(number, answer, session)
    elsif script(name)["photo"]
      rubric += photo_checks(number, answer, events, session, evidence_dir, question, persistent_ea: name == CONTINUATION_PLAN.first)
    end
    scope = scope_view(events, body, focus)
    File.write(turn_dir.join("scope.json"), JSON.pretty_generate(scope))
    {
      "script" => name, "turn" => number, "label" => label, "status" => body["status"] || response[:status].to_s,
      "answer" => answer,
      "question" => question,
      "block_reason" => reason, "rubric" => rubric, "wall_ms" => wall_ms,
      "route_outcome" => events.reverse.find { |event| event["kind"] == "published_answer" }&.dig("route_outcome"),
      "episode_id" => episode_id, "focus" => session&.focus_document_ids, "scope" => scope,
      "replayed" => body["replayed"],
      "manual_suggestion" => body["manual_suggestion"],
      "pending_question" => (session&.active_episode.is_a?(Hash) ? session.active_episode["pending_question"] : nil)
    }
  end

  # The next technician line has to answer the question the episode stored.
  # A line that names another component stays where it is. With no stored
  # question, the prepared line still has to match the published request.
  def place_photo_reply!(questions, index, row, limit: PHOTO_EA_TURNS)
    rest = questions[(index + 1)..].to_a
    return if rest.empty?

    if index + 1 >= limit
      row["block_reason"] ||= "photo_turn_reservation_exhausted"
      return
    end

    opening, display, firm, latch, misaligned, aligned, reading, how = AUDIT_JOURNEYS.fetch("photo_ea")
    sent = questions.first(index + 1)
    repaired = sent.include?(aligned)
    misalignment_reported = sent.include?(misaligned)
    latch_reported = sent.include?(latch)
    request = Haiku55JourneyRubric.requested_observation(row["answer"].to_s)
    pending = row["pending_question"]
    # Match the question that reached the technician. The persisted question
    # can still be the previous one when Danebo published a field instruction.
    visible = published_pending(row["answer"])
    if visible
      pending = visible unless pending&.dig("question")&.include?(visible["question"])
      row["pending_question"] = pending
    end
    pending = nil unless visible

    reply = if sent.last == opening
      display if request.match?(/codigo|display|pantalla|visor/)
    elsif photo_reading_turn?(sent.last) && request.match?(/operador/) && request.match?(/motor|tiene|cuenta|equipad/)
      # The documented reading applies to doors with an operator motor; the
      # simulated installation has one.
      PHOTO_OPERATOR_REPLY
    elsif photo_reading_turn?(sent.last) || sent.last == PHOTO_OPERATOR_REPLY
      how if request.present? || row["answer"].to_s.present?
    elsif misalignment_reported && !repaired && photo_repair_requested?(I18n.transliterate(row["answer"].to_s).downcase)
      aligned
    elsif pending
      asked = pending["question"]
      if (code = display_followup_reply(asked, sent, repaired: repaired))
        code
      elsif repaired
        # A visual check of the line's connection is a valid field question
        # after the repair; the technician reports it firm once.
        if request.match?(/firme|suelt|floj|apretad|conexion/) && !sent.include?(firm)
          firm
        elsif (line = photo_case_reading(pending, request))
          line
        end
      elsif latch_reported && request.match?(/alin|descentr|desplaz|fuera de posicion|no coincide/)
        misaligned
      elsif !latch_reported && photo_label_line_check?(request)
        # Confirming in the field that the photographed terminal is the latch
        # line is valid; the simulated installation is wired that way.
        PHOTO_LABEL_LINE_REPLY
      else
        candidates = [firm, latch].select { |line| rest.include?(line) }
        candidates.find { |line| Rag::WorkContextReducer.open_reply?(pending, line) } || door_closure_reply(pending)
      end
    elsif repaired && (line = photo_case_reading(nil, request))
      line
    elsif latch_reported && !misalignment_reported && request.match?(/alin|descentr|desplaz|fuera de posicion|no coincide/)
      misaligned
    elsif !latch_reported && request.match?(/trinco|cerrojo|pestillo|enclavamiento/) && request.match?(/engancha|enganchar|traba|enclava|encaja/)
      latch
    end

    if reply.nil? || sent.include?(reply)
      row["block_reason"] ||= "pending_question_unanswered"
      return
    end

    rest.delete(reply)
    rest.delete(reading) if [ PHOTO_OPEN_READING_REPLY, PHOTO_NOMINAL_READING_REPLY ].include?(reply)
    # A firm connection is optional, and the question after the electrical
    # reading ends the script regardless of any earlier optional checks.
    rest.delete(firm) if [ latch, misaligned, aligned, reading, PHOTO_OPEN_READING_REPLY, PHOTO_NOMINAL_READING_REPLY ].include?(reply)
    rest.clear if reply == how
    questions[(index + 1)..] = [reply, *rest]
  end

  # The fixture reading affirms 0 Vcc. open_reply? rejects that affirmation
  # when the question asks whether the reading is +110 Vcc, and accepts an
  # open request for the reading. The nominal question gets the negation.
  def photo_case_reading(pending, request)
    return nil unless request.match?(/ra\s*-?53|\bp28\b/)

    if nominal_voltage_check?(pending&.dig("question"))
      PHOTO_NOMINAL_READING_REPLY
    elsif pending.nil?
      PHOTO_OPEN_READING_REPLY if request.match?(/lectura|tension|voltaje|mide|medir|valor|vcc/)
    elsif Rag::WorkContextReducer.open_reply?(pending, PHOTO_OPEN_READING_REPLY)
      PHOTO_OPEN_READING_REPLY
    end
  end

  def nominal_voltage_check?(question)
    text = I18n.transliterate(question.to_s).downcase
    return false if text.match?(/\b(?:que|cuanto|cual)\b/)

    text.match?(/\bmides?\b/) && text.match?(/\b110\b/) && text.match?(/\bvcc\b|\bvdc\b|\bvolt/)
  end

  def photo_reading_turn?(line)
    [ AUDIT_JOURNEYS.fetch("photo_ea")[6], PHOTO_OPEN_READING_REPLY, PHOTO_NOMINAL_READING_REPLY ].include?(line)
  end

  def photo_label_line_check?(request)
    request.match?(/trinco|cerrojo|pestillo/) && request.match?(/borne|cable|linea|rotul/) &&
      request.match?(/llega|viene|corresponde|conecta/) && !request.match?(/engancha|traba|enclava|encaja/)
  end

  def photo_repair_requested?(request)
    request.match?(/alin/) && request.match?(/corrig|correg|ajust|realin|aline[ae]/) &&
      request.match?(/cierr|cerr|trab|engan|ea/)
  end

  # The episode did not keep the one question the answer published.
  def published_pending(answer)
    body = Haiku55JourneyRubric.kpvs_without_quotes(answer)
    questions = body.scan(/(?:^|[.!?\n]\s*)([^?\n]+\?)/).flatten
    return nil unless questions.one?

    {
      "type" => "documented_context",
      "question" => questions.first.squish.delete_prefix("**").delete_suffix("**"),
      "targets" => [ { "item" => "manual", "document_key" => "", "filename" => "", "page" => "" } ]
    }
  end

  # The reported symptom is that the floor door does not close. A brake
  # question is not that door.
  def door_closure_reply(pending)
    question = pending["question"].to_s
    return nil if question.match?(/freno|motor|variador|contactor/i)
    return nil unless question.match?(/puerta/i)

    parts = question.split(/\s+o\s+/i)
    return nil unless parts.size == 2
    return nil unless parts.any? { |part| part.match?(/abiert/i) }
    return nil unless parts.any? { |part| part.match?(/cierr|cerrar/i) }

    "La puerta de piso no cierra del todo."
  end

  # The simulation can report only the code already read by the technician
  # and the mechanical state reached in this run.
  def display_followup_reply(question, sent, repaired:)
    return nil if question.match?(/freno|motor|variador|contactor/i)

    code = sent.filter_map { |line| line[/\b(?:display|pantalla|visor) (?:marca|muestra) ([A-Z]{2,3}|\d{2})\b/, 1] }.last
    return nil unless code

    if question.match?(/solo aparece|solo muestra|solamente|[uú]nicamente|c[oó]digo de estado/i)
      "Solo aparece #{code}."
    elsif question.match?(/sigue|continu|permanec/i) && question.match?(/display|pantalla|visor|c[oó]digo/i)
      if question.match?(/a mano|cerrad|trabada|trincada/i)
        repaired ? "Sí, cierra y traba bien. El display sigue marcando #{code}." :
          "Todavía no cierra ni traba. Solo aparece #{code}."
      else
        "Sí, el display sigue marcando #{code}."
      end
    end
  end

  def await_photo_worker(browser, directory, turn_dir, run_id, reserved, account, correlation)
    raise "invalid photo acknowledgment" unless correlation.match?(/\Aphoto:[a-f0-9-]+\z/)

    browser.photo_acknowledged?(correlation)
    key = "worker-#{correlation.tr(':', '-')}"
    env = server_env(directory, run_id, reserved, account)
    config = directory.join("photo-queue.yml")
    File.write(config, { "development" => { "workers" => [
      { "queues" => [env.fetch("RAG_PHOTO_WORKER_QUEUE")], "threads" => 1, "polling_interval" => 0.1 }
    ] } }.to_yaml)
    log = directory.join("worker.log").to_s
    worker = Process.spawn(env, "bundle", "exec", "bin/jobs", "--config-file=#{config}", "--skip-recurring",
      chdir: Rails.root.to_s, out: log, err: log, pgroup: true)
    delivery = browser.photo_delivery
    File.write(turn_dir.join("delivery.json"), JSON.pretty_generate(delivery))
    [turn_dir.join("worker"), delivery]
  rescue Selenium::WebDriver::Error::TimeoutError
    browser.save_timeout(turn_dir)
    raise
  ensure
    stop_server(worker)
    if key
      worker_dir = turn_dir.join("worker")
      FileUtils.mkdir_p(worker_dir)
      copy_capture(run_id, key, worker_dir)
      events = Array((Haiku55Companion.read_json(worker_dir.join("capture.json")) || {})["events"])
      if (vision = events.find { |event| event["kind"] == "photo_vision_raw" })
        File.write(turn_dir.join("vision-raw.txt"), body_text(worker_dir, vision["text"]))
      end
      if (reading = events.find { |event| event["kind"] == "photo_vision_reading" })
        File.write(turn_dir.join("vision-reading.json"), JSON.pretty_generate(reading["reading"]))
        findings = %w[P26 P27 P28].index_with { |terminal| reading["reading"].to_json.match?(/\b#{terminal}\b/i) }
        File.write(turn_dir.join("vision-terminals.json"), JSON.pretty_generate(findings))
      end
    end
  end

  def engineering_checks(number, answer, session)
    folded = answer.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
    case number
    when 1
      questions = folded.scan(/(?:¿|^|[.!]\s+)[^?¿]*\?/)
      return ["did_not_ask_kp_vs"] unless questions.any? { |part| part.match?(/kp[ -]vs/) && part.match?(/valor|lectura|cuanto|marca|indica|leer|medir|reporta/) }
    when 2
      return ["did_not_defer_kp_vs_to_engineering"] unless folded.match?(/kp[ -]vs/) && folded.include?("ingenieria") &&
        folded.match?(/pendiente|que lo (?:lea|revise|verifique)|debe (?:leer|verificar)|verificacion|lectura por/)
    when 3
      episode = session&.active_episode.to_h
      reported = Array(episode["observations"]).pluck("text")
      return ["engineering_reading_not_incorporated"] unless (reported.any? { |text| text.to_s.match?(/(?:kp[ -]vs).*2[,.]5/i) } ||
        Array(episode["checks"]).any? { |check| check["subject"].to_s.match?(/kp[ -]vs/i) && check["result"].to_s.match?(/2[,.]5/) }) &&
        folded.match?(/2[,.]5/) && folded.match?(/3[,.]0/) && folded.match?(/debajo|inferior|menor/)
    when 4
      prose = Haiku55JourneyRubric.kpvs_without_quotes(answer)
      if Haiku55JourneyRubric.kpvs_set_order?(prose) ||
          Haiku55JourneyRubric.kpvs_order?(prose, Haiku55JourneyRubric::RESOLVES_NOISE)
        return ["proposed_adjustment_as_noise_fix"]
      end
      return ["commissioning_value_not_distinguished"] unless folded.match?(/3[,.]5/) &&
        folded.match?(/puesta en marcha|instalacion|comisionamiento/) && folded.match?(/2[,.]5/) &&
        folded.match?(/no (?:le |lo |se )?(?:pidas|dejes|ajustes|subas|justifica|indica|recomiendo|recomienda|es)|no (?:hay|da) (?:base|motivo|indicacion)/)
    end
    []
  end

  def engineering_stop(number, row, first_episode)
    return "engineering_episode_changed" if number > 1 && (first_episode.blank? || first_episode != row["episode_id"])

    row["rubric"].first
  end

  def photo_followup_stop(number, answer)
    body = Haiku55JourneyRubric.kpvs_without_quotes(answer).unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
    case number
    when 1
      return "photo_code_not_requested" unless body.match?(/(?:codigo|display)[^?¿]*\?/)
    when 2
      checks = body.split(/[.!?\n]+/)
      asked_reading = checks.any? do |line|
        line.match?(/\bp2[678]\b|trinco|enclavamiento/) && line.match?(/lectura|tension|voltaje|mide|medir|comprueba|verifica/)
      end
      return "photo_readings_not_requested" unless asked_reading
    end
    nil
  end

  def photo_checks(number, answer, events, session, evidence_dir, question, persistent_ea:)
    reasons = []
    ask = events.reverse.find { |event| event["kind"] == "converse" && event["provider"] == "anthropic" }
    prompt = Array(ask&.dig("messages", -1, "content")).filter_map { |block| body_text(evidence_dir, block["text"]) }.join
    visual = Rag::ActivePhotoContext.generation_evidence(prompt)
    reasons << "photo_evidence_missing_from_generation" if (number <= 2 || !persistent_ea) && !visual
    reasons << "literal_question_missing_from_generation" unless prompt.start_with?("Mensaje de este turno:\n#{question}")
    if persistent_ea && visual
      reasons << "visual_labels_missing_from_generation" unless visual.match?(/\bP2[678]\b/)
    end
    if number == 1
      input = events.find { |event| event["kind"] == "photo_worker_input" }
      reasons << "worker_jpeg_digest_missing_or_different" unless input && input["sha256"] == input["declared_sha256"]
      reasons << "vision_reading_missing" unless events.any? { |event| event["kind"] == "photo_vision_reading" }
    end
    reasons << "active_photo_missing" if session&.active_episode.to_h.dig("active_photo", "field_photo_id").blank?
    return reasons if persistent_ea

    expected = case number
    when 1 then /display|codigo|p28|trincos|cerradur|enclavamiento/
    when 2 then /trincos|p28/
    when 3 then /p28|trincos/
    when 4 then /tls|parametro/
    end
    reasons << "technical_question_unanswered" unless I18n.transliterate(answer).downcase.match?(expected)
    reasons
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

    session = fresh_session(user)
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
        session = fresh_session(user)
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
    return if key.blank?

    source = base.join(key)
    source = base.glob("#{key}*").max_by { |path| path.mtime } unless source.directory?
    return unless source&.directory?

    FileUtils.cp_r("#{source}/.", turn_dir, preserve: true)
  end

  # ---- server --------------------------------------------------------------

  # The manuals belong to an account without a development host. The
  # development fallback slug resolves an unmapped Host to that account,
  # the same way a phone tunnel does; production ignores it.
  def request_host(account)
    "#{account.slug}.haiku55.test"
  end

  def server_execution_id
    last = read_ledger.fetch("executions").last
    return SPEND::THYSSEN_PHOTO_LIVE_ID if photo_continuation? && SPEND.thyssen_photo_grant?(last)
    return SPEND::KONE_LWI_LIVE_ID if CONTINUATION_RETRY && SPEND.kone_lwi_grant?(last)

    EXECUTION_ID
  end

  def server_env(directory, run_id, reserved, account)
    env = SERVER_ENV.merge(
      "DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG" => account.slug,
      "RAG_VALIDATION_CAPTURE_RUN" => run_id,
      "RAG_ASSIGNMENT_SPEND_PATH" => Guion2Direct.spend_path,
      "RAG_LOCAL_PASS_CALL_CAP" => reserved["calls"].to_s,
      "RAG_LOCAL_PASS_COST_CAP_USD" => reserved["ceiling_usd"],
      "PORT" => PORT.to_s
    )
    CLEARED_ENV.each { |key| env[key] = nil }
    if AUDIT
      env["KNOWLEDGE_BASE_S3_BUCKET"] = AUDIT_KB_BUCKET
      scope = CONTINUATION ? run_id : directory.basename
      execution_id = server_execution_id
      env.merge!("RAG_ASSIGNMENT_EXECUTION_ID" => execution_id, "RAG_ASSIGNMENT_RUN_SCOPE" => "#{execution_id}/#{scope}")
    end
    if reserved["vision"]
      env.merge!(
        "PHOTO_QUESTION_RAG_ENABLED" => "true",
        "RAG_PHOTO_WORKER_QUEUE" => "audit_photo_#{Digest::SHA256.hexdigest(run_id).first(16)}",
        "RAG_PHOTO_VISION_SPEND_PATH" => directory.parent.join("vision-spend.json").to_s,
        "RAG_PHOTO_LOCAL_STORE" => Rails.root.join("tmp/field_companion/local_field_photos").to_s
      )
      env["RAG_LOCAL_PASS_ALLOWED_CALLS"] += ",#{Rag::GuardedPhotoVision::OPERATION}@#{Rag::GuardedPhotoVision::TRACKING_MODEL}"
    end
    env
  end

  def start_server(directory, run_id, reserved, account)
    env = server_env(directory, run_id, reserved, account)
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
  rescue StandardError
    stop_server(pid)
    raise
  end

  def stop_server(pid)
    return unless pid

    Process.kill("TERM", -Process.getpgid(pid))
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # ---- helpers -------------------------------------------------------------

  def fresh_session(user)
    ConversationSession.uncached do
      ConversationSession.find_by(identifier: user.id.to_s, channel: "web", account_id: user.account_id)
    end
  end

  # The runner process does not carry the server's episode settings, so it
  # reads the persisted id instead of parsing the live window.
  def stored_episode_id(session)
    episode = session&.active_episode
    episode = JSON.parse(episode) if episode.is_a?(String)
    episode["episode_id"] if episode.is_a?(Hash)
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
