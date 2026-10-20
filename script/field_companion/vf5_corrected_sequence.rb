# frozen_string_literal: true

# Three-message VF5 sequence on the loaded product path: owner turn,
# pinned retrieve, and Haiku generation. VF5_CORRECTED_SEQUENCE=1 sends it.
# Without that variable this refuses before a model call. It does not edit
# .env, the PDF, or the corpus. The assignment file is the same 48-call and
# US$4 ceiling as the generator benchmark. This process does not reset it.

TURNS = [
  "Prueba simulada. Estoy con un operador Fermator VF5+: en funcionamiento normal la puerta empieza a cerrar y vuelve a abrirse sola. El LED de fotocélula está encendido, no observo una obstrucción mecánica y no he revisado la sensibilidad de reapertura. SW4 está en OFF, modo esclavo. No hice mediciones ni reparaciones. Según el manual, ¿cómo me orientas y qué falta comprobar?",
  "Corrijo solo un dato de la simulación: el LED está apagado, no encendido. SW4 sigue en OFF y lo demás se mantiene. ¿Qué cambia en tu orientación?",
  "Resume el caso con los datos vigentes, distingue lo que dice el manual de lo que yo reporté y señala qué falta confirmar. No se ha realizado ninguna reparación."
].freeze

class Vf5CorrectedSequenceHost
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

module Vf5InlineQueryTracking
  def perform_later(...)
    perform_now(...)
  end
end

def vf5_corrected_sequence_main
  return 0 unless ENV["VF5_CORRECTED_SEQUENCE"] == "1"

  spend_path = ENV["VF5_ASSIGNMENT_SPEND"].presence ||
    Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json").to_s
  return vf5_sequence_refuse("spend_file_missing") unless File.file?(spend_path)
  return vf5_sequence_refuse("not_local") unless Rails.env.local?
  return vf5_sequence_refuse("shared_session") if SharedSession::ENABLED
  return vf5_sequence_refuse("generation_model") unless BedrockClient::QUERY_MODEL_ID.include?("claude-haiku-4-5")
  return vf5_sequence_refuse("knowledge_base_bucket") unless KbDocument::KB_BUCKET == "multimodal-source-destination"

  vf5_sequence_env!(spend_path)
  spend = Rag::AssignmentSpend.new(path: spend_path, call_cap: 48, cost_cap_usd: "4")
  return vf5_sequence_refuse("assignment_spend") unless vf5_arm_sequence_ledger!(spend)
  return vf5_sequence_refuse("preflight") unless vf5_sequence_preflight(spend)

  require "rake"
  load Rails.root.join("lib/tasks/field_companion.rake")
  session = ConversationSession.find(198)
  account = session.account
  user = User.find(session.user_id)
  return vf5_sequence_refuse("account") unless account.slug == "index-account-1"

  document = KbDocument.find(122)
  return vf5_sequence_refuse("document") unless document.document_uid == "126cda62-64ad-4469-8674-a29f12e38d48"

  TrackBedrockQueryJob.singleton_class.prepend(Vf5InlineQueryTracking)
  FieldCompanionCleanStart.call(account_slug: account.slug, user_email: user.email, apply: true, io: $stdout)
  session.reload
  return vf5_sequence_refuse("pin") unless session.pin_kb_document!(document)

  run_id = ENV["RAG_VALIDATION_CAPTURE_RUN"]
  host = Vf5CorrectedSequenceHost.new(account, user)
  rows = []
  TURNS.each_with_index do |question, index|
    row = vf5_sequence_turn(host, session, user, question, index + 1, run_id)
    rows << row
    break unless row["status"] == "returned"
  end
  summary = {
    "run_id" => run_id,
    "episode_id" => session.reload.live_episode_id,
    "generation_model_id" => BedrockClient::QUERY_MODEL_ID,
    "turns" => rows,
    "spend" => spend.snapshot.except("entries")
  }
  directory = Rails.root.join("tmp/field_companion/vf5_corrected_sequence", run_id)
  FileUtils.mkdir_p(directory)
  File.write(directory.join("summary.json"), JSON.generate(summary))
  puts JSON.generate(summary)
  rows.size == 3 && rows.all? { |row| row["status"] == "returned" } ? 0 : 2
rescue Rag::AssignmentSpend::Stop, Rag::LocalPassLedger::Stop => error
  vf5_sequence_refuse(error.message)
end

def vf5_sequence_env!(spend_path)
  ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
  ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
  ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
  ENV["RAG_EPISODE_SCOPE_ENABLED"] = "true"
  ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
  ENV["AWS_MAX_ATTEMPTS"] = "1"
  ENV["AWS_RETRY_MODE"] = "standard"
  ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "Y7RZWMFJSR"
  ENV["RAG_ASSIGNMENT_SPEND_PATH"] = spend_path
  ENV["RAG_VALIDATION_CAPTURE_RUN"] = "vf5-corrected-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
end

def vf5_arm_sequence_ledger!(spend)
  snap = spend.snapshot
  remaining_calls = 48 - snap["attempts"].to_i
  remaining = BigDecimal("4") - BigDecimal(snap["committed_usd"]) - BigDecimal(snap["held_usd"])
  return false if remaining_calls < 6 || remaining <= 0

  ENV["RAG_LOCAL_PASS_GUARD"] = "1"
  ENV["RAG_LOCAL_PASS_CALL_CAP"] = remaining_calls.to_s
  ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = format("%.6f", remaining)
  Rag::LocalPassLedger.reset!
  Rag::LocalPassLedger.reset_local_process!
  Rag::LocalPassLedger.armed?
end

def vf5_sequence_preflight(spend)
  snap = spend.snapshot
  remaining = BigDecimal("4") - BigDecimal(snap["committed_usd"]) - BigDecimal(snap["held_usd"])
  ceiling = Rag::LocalPassLedger.price(BedrockClient::QUERY_MODEL_ID, 40_000, 3_000) * 6
  puts JSON.generate(
    "status" => "preflight",
    "ceiling_usd" => format("%.6f", ceiling),
    "remaining_usd" => format("%.6f", remaining),
    "attempts" => snap["attempts"]
  )
  ceiling <= remaining
end

def vf5_sequence_turn(host, session, user, question, number, run_id)
  correlation_id = "query:#{SecureRandom.uuid}"
  request = Struct.new(:request_id).new(SecureRandom.uuid)
  controller = Struct.new(
    :current_user, :current_account, :request, :params, :controller_path, :action_name
  ).new(
    user, session.account, request,
    { question: question },
    "field_companion/vf5_corrected_sequence",
    "turn"
  )
  captured = nil
  Rag::WebRequestCapture.wrap(controller: controller) do
    episode_turn = session.record_user_turn!(
      question, user_id: user.id, correlation_id: correlation_id, locale: :es
    )
    session.reload
    understanding = episode_turn.respond_to?(:understanding) ? episode_turn.understanding : nil
    focus_uris = understanding.respond_to?(:focus_uris) ? understanding.focus_uris : nil
    result = host.execute(
      question,
      session_context: SessionContextBuilder.build(session),
      conv_session: session,
      entity_s3_uris: focus_uris || SessionContextBuilder.entity_s3_uris(session),
      account: session.account,
      user_id: user.id,
      correlation_id: correlation_id,
      episode_turn: episode_turn,
      output_channel: :web
    )
    if result.respond_to?(:success?) && result.success?
      session.record_assistant_turn!(
        result.answer.to_s,
        user_id: user.id,
        correlation_id: result.correlation_id,
        pending_question: result.pending_question,
        expected_episode_id: session.live_episode_id,
        focus_ids: session.focus_document_ids
      )
    end
    episode = Rag::ActiveEpisode.parse(session.reload.active_episode)
    captured = {
      "turn" => number,
      "status" => result.respond_to?(:success?) && result.success? ? "returned" : "failed",
      "correlation_id" => correlation_id,
      "request_id" => request.request_id,
      "run_id" => run_id,
      "episode_id" => episode.episode_id,
      "goal" => episode.goal.is_a?(Hash) ? episode.goal["text"] : nil,
      "observations" => episode.observations.pluck("text"),
      "answer" => result.respond_to?(:answer) ? result.answer.to_s : nil,
      "error_type" => result.respond_to?(:error_type) ? result.error_type.to_s : nil
    }
  end
  captured || { "turn" => number, "status" => "failed", "run_id" => run_id }
end

def vf5_sequence_refuse(reason)
  puts JSON.generate("status" => "refused", "reason" => reason)
  2
end

unless ENV["VF5_CORRECTED_SEQUENCE_REQUIRE"] == "1"
  code = vf5_corrected_sequence_main
  exit code unless code.zero?
end
