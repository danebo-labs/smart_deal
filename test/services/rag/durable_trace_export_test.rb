# frozen_string_literal: true

require "test_helper"
require "rake"

# Offline acceptance for the durable dialogue. No model calls.
# The same set runs for danebo-legacy and danebo-pilot-elevator.
# The old account lists stay set to "1" and must not gate either account.
class Rag::DurableTraceExportTest < ActiveSupport::TestCase
  ENV_KEYS = %w[
    PILOT_AUDIT_CAPTURE
    PILOT_AUDIT_CAPTURE_ACCOUNT_IDS
    RAG_VALIDATION_CAPTURE_RUN
    RAG_VALIDATION_CAPTURE_ACCOUNT_IDS
    APPLY
    FIELD_COMPANION_WEB_TRIAL_CONFIRM
    FIELD_COMPANION_WEB_TRIAL_COPY_DIR
    KAMAL_VERSION
  ].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("field_companion:isolate_web_trial")
    @isolate = Rake::Task["field_companion:isolate_web_trial"]
    @env = ENV_KEYS.index_with { |key| ENV[key] }
    @local_process = Rag::LocalPassLedger.instance_variable_get(:@local_process)
    @trial_dir = Rails.root.join("tmp/field_companion_web_trial_test/#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@trial_dir)
    ENV["PILOT_AUDIT_CAPTURE_ACCOUNT_IDS"] = "1"
    ENV["RAG_VALIDATION_CAPTURE_ACCOUNT_IDS"] = "1"
    ENV.delete("PILOT_AUDIT_CAPTURE")
    ENV.delete("RAG_VALIDATION_CAPTURE_RUN")
    ENV["FIELD_COMPANION_WEB_TRIAL_COPY_DIR"] = @trial_dir.to_s
    ENV["KAMAL_VERSION"] = "offline-trazabilidad"
  end

  teardown do
    @isolate.reenable
    @env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rag::LocalPassLedger.instance_variable_set(:@local_process, @local_process)
    FileUtils.rm_rf(@trial_dir)
    Thread.current[:rag_validation_capture] = nil
    Thread.current[:rag_validation_scope] = nil
    Thread.current[:rag_validation_correlation] = nil
    Thread.current[:durable_trace_context] = nil
  end

  test "both accounts export the full dialogue after the live history is cleared" do
    assert_not Rag::WebRequestCapture.enabled_for(accounts(:legacy).id)
    assert_not Rag::WebRequestCapture.enabled_for(accounts(:pilot).id)
    Rag::LocalPassLedger.instance_variable_set(:@local_process, false)
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = "offline-all-accounts"
    assert Rag::WebRequestCapture.enabled_for(accounts(:legacy).id)
    assert Rag::WebRequestCapture.enabled_for(accounts(:pilot).id)
    assert_not Rag::WebRequestCapture.enabled_for(nil)
    ENV.delete("RAG_VALIDATION_CAPTURE_RUN")

    legacy = workspace(accounts(:legacy), "LEGACY")
    pilot = workspace(accounts(:pilot), "PILOT")
    assert_equal "danebo-legacy", legacy.account.slug
    assert_equal "danebo-pilot-elevator", pilot.account.slug
    assert_not_equal legacy.account.id, pilot.account.id

    [ legacy, pilot ].each do |item|
      record_text(item)
      record_photo(item)
      record_historical(item)
    end

    legacy_rows = trace_count(legacy)
    pilot_rows = trace_count(pilot)
    isolate_output = isolate!(legacy)
    open_new_case!(pilot)
    assert_equal legacy_rows, trace_count(legacy)
    assert_equal pilot_rows, trace_count(pilot)
    assert_empty legacy.session.conversation_history
    assert_empty pilot.session.conversation_history

    copy_path = isolate_output[/APPLIED copy=(\S+)/, 1]
    assert copy_path
    assert File.file?(copy_path)
    snapshot = JSON.parse(File.read(copy_path))
    assert_not_includes File.read(copy_path), "AKIA"
    imported = Rag::DurableTrace.import_recovered!(snapshot, source: copy_path)
    assert imported.any?
    again = Rag::DurableTrace.import_recovered!(snapshot, source: copy_path)
    assert_equal imported.size, again.size
    legacy.isolate_source = copy_path

    [ legacy, pilot ].each do |item|
      import_divergent!(item)
      assert_no_second_publication!(item)
      record_secret(item)
      item.session.update!(conversation_history: [])
      item.session.reload
    end

    legacy_report = report_for(legacy)
    pilot_report = report_for(pilot)
    assert_package(legacy, legacy_report, pilot)
    assert_package(pilot, pilot_report, legacy)
    write_example(legacy, legacy_report)
    write_example(pilot, pilot_report)
  end

  private

  Workspace = Struct.new(
    :account, :user, :session, :token, :episode_id, :question, :answer,
    :text_correlation, :photo_question, :card, :unavailable, :published,
    :photo_correlation, :photo, :observation, :missing_question, :missing_answer,
    :historical_correlation, :recovered_only, :recovered_source, :secret_correlation,
    :job_id, :isolate_source,
    keyword_init: true
  )

  def workspace(account, label)
    token = "MARK-#{label}-#{SecureRandom.hex(3)}"
    user = User.create!(
      email: "trace-#{label.downcase}-#{SecureRandom.hex(3)}@example.com",
      password: "password123",
      account: account
    )
    session = ConversationSession.create!(
      account: account,
      user: user,
      identifier: user.id.to_s,
      channel: "web",
      expires_at: 1.day.from_now,
      conversation_history: []
    )
    Workspace.new(
      account: account,
      user: user,
      session: session,
      token: token,
      episode_id: "ep-#{token}",
      question: ("El variador KP-VS #{token} marca 2,5 y hay ruido en tracción. " + ("detalle #{token} " * 40)),
      answer: "El valor 2,5 de #{token} está por debajo del mínimo de 3,0 [1].",
      text_correlation: "query:text-#{token}",
      photo_question: "Qué terminal usa #{token} en la bornera de la foto",
      card: "[FOTO] Componente: Esquema de bornera | Cuenta: #{token}",
      published: "La señal de #{token} está en el terminal 53 [1].",
      photo_correlation: "photo:#{token}",
      observation: {
        "component" => "Esquema de bornera de conectores de comando",
        "manufacturer" => "UNKNOWN",
        "account_token" => token
      },
      missing_question: "pregunta historica no capturada #{token}",
      missing_answer: "respuesta historica no capturada #{token}",
      historical_correlation: "query:historical-#{token}",
      recovered_only: "texto solo en la copia recuperada #{token}",
      recovered_source: @trial_dir.join("recovered-#{token}.json").to_s,
      secret_correlation: "query:secret-#{token}",
      job_id: "job-#{token}"
    )
  end

  def record_text(item)
    write_episode(item)
    assert item.question.length > ConversationSession::MAX_MSG_LENGTH
    prompt = "PROMPT #{item.question}"
    raw = "RAW #{item.answer}"
    Rag::WebRequestCapture.wrap(controller: controller_for(item, item.question)) do
      Rag::ValidationCapture.correlation = item.text_correlation
      item.session.add_to_history("user", item.question, user_id: item.user.id, correlation_id: item.text_correlation)
      item.session.add_to_history(
        "assistant", item.answer, user_id: item.user.id, correlation_id: item.text_correlation, prompt_reply: item.answer
      )
      Rag::ValidationCapture.record("perception_applied", "move" => "report", "correlation_id" => item.text_correlation)
      Rag::ValidationCapture.record("episode_delta", "before_sha256" => "aaa", "after_sha256" => "bbb")
      Rag::ValidationCapture.record("document_focus", "after" => [ { "kb_document_id" => 9, "title" => "MCINV4" } ])
      Rag::ValidationCapture.record("effective_query", "effective" => item.question)
      Rag::ValidationCapture.record("retrieval_results", "order" => [ "chunk-a", "chunk-b" ])
      Rag::ValidationCapture.record("companion_rerank", "order" => [ "chunk-b", "chunk-a" ])
      Rag::ValidationCapture.record(
        "generator_evidence",
        "delivered_to_generator" => true,
        "chunks" => [ "chunk-b" ]
      )
      Rag::ValidationCapture.record(
        "model_call",
        "input" => prompt,
        "output" => raw,
        "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
        "prompt_version" => "field-companion-test-1"
      )
      Rag::DurableTrace.record_presentation!(
        account_id: item.account.id,
        user_id: item.user.id,
        conversation_session_id: item.session.id,
        episode_id: item.episode_id,
        correlation_id: item.text_correlation,
        cards: [ { "document_uid" => "uid-#{item.token}", "title" => "MCINV4", "focused" => false } ],
        notices: [ "aviso de foco #{item.token}" ],
        response_type: "answer",
        final_state: "answered"
      )
      Rag::DurableTrace.record_click!(
        account_id: item.account.id,
        user_id: item.user.id,
        conversation_session_id: item.session.id,
        correlation_id: item.text_correlation,
        action: "manual_focus_confirmed",
        document_uid: "uid-#{item.token}",
        source_uri: "s3://manuals/#{item.token}.pdf"
      )
      Rag::DurableTrace.record_terminal!(
        account_id: item.account.id,
        user_id: item.user.id,
        conversation_session_id: item.session.id,
        episode_id: item.episode_id,
        correlation_id: item.text_correlation,
        outcome: "answered",
        original_query: item.question,
        answer: item.answer,
        citations: [ { "number" => 1, "title" => "MCINV4", "page" => 12 } ],
        sources: [ { "title" => "MCINV4", "page" => 12 } ],
        generation_mode: "retrieve_and_generate"
      )
    end

    stored = item.session.reload.conversation_history.find { |message|
      message["role"] == "user" && message["correlation_id"] == item.text_correlation
    }
    assert stored["content"].length < item.question.length
    assert_equal item.question, stored["full_content"]
  end

  def record_photo(item)
    item.photo = FieldPhoto.create!(
      account: item.account,
      user_id: item.user.id,
      conversation_session_id: item.session.id,
      sha256: Digest::SHA256.hexdigest("photo-#{item.token}"),
      s3_key_original: "field_photos/#{item.account.id}/#{item.token}.jpg",
      content_type: "image/jpeg",
      byte_size: 128,
      visual_observation: item.observation
    )
    write_episode(item, photo: item.photo)
    item.session.add_to_history("user", item.photo_question, user_id: item.user.id, correlation_id: item.photo_correlation)
    item.session.add_to_history("assistant", item.card, user_id: item.user.id, correlation_id: item.photo_correlation)

    job = FieldPhotoAnalysisJob.new
    raiser = Object.new
    raiser.define_singleton_method(:call) { raise RuntimeError, "service_unavailable" }
    with_photo_service(raiser) do
      with_attempt(item, 1) do
        result = job.send(
          :answer_photo_question,
          question: item.photo_question,
          evidence_value: { compact_context: item.card },
          session: item.session,
          account_id: item.account.id,
          user_id: item.user.id,
          correlation_id: item.photo_correlation,
          locale: :es
        )
        assert result[:failed]
        item.unavailable = result[:answer]
        job.send(
          :emit_interaction_completed,
          account_id: item.account.id,
          user_id: item.user.id,
          conversation_session_id: item.session.id,
          correlation_id: item.photo_correlation,
          outcome: "failed",
          latency_ms: 12,
          stage: "rag",
          error_class: "RuntimeError",
          original_query: item.photo_question,
          answer: item.unavailable,
          generation_mode: "service_unavailable"
        )
      end
      with_attempt(item, 2) do
        assert_equal :not_recording, item.session.record_assistant_turn!(
          item.published, user_id: item.user.id, correlation_id: item.photo_correlation, writer: "photo_assistant"
        )
        assert_equal :applied, item.session.record_assistant_turn!(
          item.published, user_id: item.user.id, correlation_id: item.photo_correlation, writer: "photo_assistant"
        )
        job.send(
          :emit_interaction_completed,
          account_id: item.account.id,
          user_id: item.user.id,
          conversation_session_id: item.session.id,
          correlation_id: item.photo_correlation,
          outcome: "answered",
          latency_ms: 20,
          original_query: item.photo_question,
          answer: item.published,
          citations: [ { "number" => 1, "title" => "MCINV4", "page" => 4 } ],
          generation_mode: "photo_question"
        )
      end
    end

    published = item.session.reload.conversation_history.select { |message|
      message["role"] == "assistant" && message["correlation_id"] == item.photo_correlation &&
        (message["full_content"].presence || message["content"]) == item.published
    }
    assert_equal 1, published.size
    assert_not_includes item.session.conversation_history.to_json, item.unavailable
    assert_equal 1, FieldCompanionTrace.where(
      account_id: item.account.id, correlation_id: item.photo_correlation, kind: "assistant_message"
    ).count
    assert_equal 1, FieldCompanionTrace.where(
      account_id: item.account.id, correlation_id: item.photo_correlation, kind: "visual_card"
    ).count
  end

  def record_historical(item)
    FieldCompanionTrace.create!(
      account_id: item.account.id,
      user_id: item.user.id,
      conversation_session_id: item.session.id,
      correlation_id: item.historical_correlation,
      kind: "terminal",
      provenance: "uncaptured",
      idempotency_key: "terminal:historical:#{item.account.id}:#{item.token}",
      occurred_at: Time.current,
      deployed_version: "historical-hash-only",
      payload: {
        "outcome" => "answered",
        "original_query_sha256" => Digest::SHA256.hexdigest(item.missing_question),
        "answer_sha256" => Digest::SHA256.hexdigest(item.missing_answer)
      }
    )
  end

  def record_secret(item)
    Rag::WebRequestCapture.wrap(controller: controller_for(item, "secreto")) do
      Rag::ValidationCapture.correlation = item.secret_correlation
      item.session.add_to_history(
        "user",
        "token AKIAIOSFODNN7EXAMPLE en el mensaje #{item.token}",
        user_id: item.user.id,
        correlation_id: item.secret_correlation
      )
      Rag::ValidationCapture.record(
        "model_call",
        "input" => "AKIAIOSFODNN7EXAMPLE",
        "headers" => { "Authorization" => "Bearer abc", "Cookie" => "session=1" },
        "authorization" => "Bearer abc",
        "password" => "secret-password"
      )
    end
  end

  def import_divergent!(item)
    snapshot = {
      "kind" => "field_companion_clean_start_copy",
      "written_at" => Time.current.iso8601,
      "workspace" => {
        "account_id" => item.account.id,
        "conversation_session_id" => item.session.id,
        "session_user_id" => item.user.id
      },
      "replaced" => {
        "conversation_history" => [
          {
            "role" => "user",
            "content" => "copia recuperada distinta #{item.token}",
            "correlation_id" => item.text_correlation,
            "ts" => Time.current.iso8601
          },
          {
            "role" => "user",
            "content" => item.recovered_only,
            "full_content" => item.recovered_only,
            "correlation_id" => "query:recovered-only-#{item.token}",
            "ts" => Time.current.iso8601
          }
        ]
      }
    }
    File.write(item.recovered_source, JSON.generate(snapshot))
    first = Rag::DurableTrace.import_recovered!(snapshot, source: item.recovered_source)
    second = Rag::DurableTrace.import_recovered!(snapshot, source: item.recovered_source)
    assert_equal first.size, second.size
    assert_equal 1, FieldCompanionTrace.where(
      account_id: item.account.id,
      correlation_id: "query:recovered-only-#{item.token}",
      provenance: "recovered"
    ).count
  end

  def assert_no_second_publication!(item)
    item.session.reload
    assert_empty item.session.conversation_history
    before = FieldCompanionTrace.where(
      account_id: item.account.id, correlation_id: item.photo_correlation, kind: "assistant_message"
    ).count
    assert_equal :applied, item.session.record_assistant_turn!(
      item.published, user_id: item.user.id, correlation_id: item.photo_correlation, writer: "photo_assistant"
    )
    assert_empty item.session.reload.conversation_history
    assert_equal before, FieldCompanionTrace.where(
      account_id: item.account.id, correlation_id: item.photo_correlation, kind: "assistant_message"
    ).count
  end

  def assert_package(item, package, other)
    blob = JSON.generate(package)
    assert_not_includes blob, other.token
    assert_not_includes blob, "AKIA"
    assert_not_includes blob, "Bearer abc"
    assert_not_includes blob, "session=1"
    assert_not_includes blob, "secret-password"
    assert_not_includes blob, item.missing_question
    assert_not_includes blob, item.missing_answer

    text = turn(package, item.text_correlation)
    assert_equal item.account.id, text[:account_id]
    assert_equal item.user.id, text[:user_id]
    assert_equal item.session.id, text[:conversation_session_id]
    assert_equal item.episode_id, text[:episode_id]
    assert text[:request_id].present?
    assert_equal "offline-trazabilidad", text[:deployed_version]
    assert_equal Rag::TurnPerception::PROMPT_VERSION, text.dig(:versions, "code", "turn_perception_prompt")
    assert_equal "mixed", text[:provenance]
    assert_includes text[:recovered_from], item.recovered_source
    assert_includes text[:recovered_from], item.isolate_source if item.isolate_source
    assert_equal item.question, text.dig(:technician_message, :text)
    assert_equal "observed", text.dig(:technician_message, :provenance)
    assert_equal Digest::SHA256.hexdigest(item.question), text.dig(:technician_message, :sha256)
    assert_equal item.answer, text.dig(:technical_response, :text)
    assert_equal true, text.dig(:technical_response, :published_to_history)
    assert_equal "marked_citations", text.dig(:technical_response, :format)
    assert_equal 1, text.dig(:technical_response, :citations).first["number"]
    assert_equal "MCINV4", text.dig(:technical_response, :citations).first["title"]
    assert_equal "PROMPT #{item.question}", text.dig(:model, :input)
    assert_equal "RAW #{item.answer}", text.dig(:model, :output)
    assert_equal "observed", text.dig(:model, :input_provenance)
    assert_equal [ "chunk-a", "chunk-b" ], text.dig(:retrieval, :candidates).first["order"]
    assert_equal [ "chunk-b", "chunk-a" ], text.dig(:retrieval, :rerank).first["order"]
    assert_equal true, text.dig(:retrieval, :generator_evidence).first["delivered_to_generator"]
    assert_equal "report", text.dig(:interpretation, :events).first["move"]
    assert_equal "bbb", text.dig(:state_change, :events).first["after_sha256"]
    assert_equal "observed", text.dig(:focus, :provenance)
    assert_equal "MCINV4", text.dig(:presentation, :cards).first["title"]
    assert_includes text.dig(:presentation, :notices), "aviso de foco #{item.token}"
    assert_equal "manual_focus_confirmed", text.dig(:presentation, :clicks).first["action"]
    assert_equal "uncaptured", text[:browser_render]
    assert_includes text[:uncaptured_fields], "browser_render"
    assert_not_includes text[:uncaptured_fields], "technician_message"
    assert_not_includes text[:uncaptured_fields], "final_answer"
    assert_equal true, text.dig(:integrity, :match)
    prompts = Array(text.dig(:versions, "sent_prompts"))
    assert prompts.any? { |prompt| prompt["version"] == "field-companion-test-1" }
    assert prompts.any? { |prompt| prompt["sha256"] == Digest::SHA256.hexdigest("PROMPT #{item.question}") }

    photo = turn(package, item.photo_correlation)
    assert_equal item.photo_question, photo.dig(:technician_message, :text)
    assert_equal item.card, photo.dig(:visual_card, :text)
    assert_equal "observed", photo.dig(:visual_card, :provenance)
    assert_equal item.published, photo.dig(:technical_response, :text)
    assert_equal true, photo.dig(:technical_response, :published_to_history)
    assert_equal item.observation, photo.dig(:visual_observation, :observation)
    assert_equal item.photo.sha256, photo.dig(:visual_observation, :sha256)
    assert_equal true, photo.dig(:visual_observation, :episode_linked)
    assert_equal item.episode_id, photo[:episode_id]
    assert_equal item.photo.id, photo[:attachments].first["field_photo_id"]
    assert_equal item.photo.sha256, photo[:attachments].first["sha256"]
    assert_equal item.job_id, photo[:job_id]
    failed = photo[:attempts].find { |row| row[:attempt] == 1 && row[:kind] == "terminal" }
    published = photo[:attempts].find { |row| row[:attempt] == 2 && row[:kind] == "terminal" }
    failure = photo[:attempts].find { |row| row[:kind] == "failure" && row[:attempt] == 1 }
    assert_equal item.unavailable, failed[:answer]
    assert_equal "failed", failed[:outcome]
    assert_equal item.published, published[:answer]
    assert_equal "answered", published[:outcome]
    assert_equal "rag", failure[:stage]
    assert_equal "RuntimeError", failure[:error_class]
    assert_equal "service_unavailable", failure[:error_message]
    assert_equal "observed", failure[:stack_provenance]
    assert failure[:stack].any? { |line| line.start_with?(Rails.root.to_s) }
    assert_equal item.job_id, failure[:job_id]
    assert_not_equal item.card, failed[:answer]
    assert_not_equal item.card, photo.dig(:technical_response, :text)
    assert_equal "answered", photo.dig(:presentation, :final_state)
    assert_equal "photo_question", photo.dig(:presentation, :response_type)
    assert_equal "observed", photo.dig(:presentation, :provenance)
    assert_empty photo.dig(:presentation, :cards)
    assert_includes photo[:uncaptured_fields], "browser_render"
    assert_not_includes photo[:uncaptured_fields], "failure_stack"
    assert_not_includes photo[:uncaptured_fields], "presentation"
    assert_not_includes photo[:uncaptured_fields], "visual_observation"
    if item.isolate_source
      assert_equal "mixed", photo[:provenance]
      assert_includes photo[:recovered_from], item.isolate_source
    else
      assert_equal "observed", photo[:provenance]
      assert_empty photo[:recovered_from]
    end

    historical = turn(package, item.historical_correlation)
    assert_equal "uncaptured", historical[:provenance]
    assert_equal "uncaptured", historical.dig(:technician_message, :provenance)
    assert_nil historical.dig(:technician_message, :text)
    assert_nil historical.dig(:technical_response, :text)
    assert_equal Digest::SHA256.hexdigest(item.missing_question), historical.dig(:integrity, :question_sha256)
    assert_equal Digest::SHA256.hexdigest(item.missing_answer), historical.dig(:integrity, :answer_sha256)
    assert_includes historical[:uncaptured_fields], "technician_message"
    assert_includes historical[:uncaptured_fields], "final_answer"
    assert_includes historical[:uncaptured_fields], "browser_render"
    assert_equal "historical-hash-only", historical[:deployed_version]

    recovered = turn(package, "query:recovered-only-#{item.token}")
    assert_equal "recovered", recovered[:provenance]
    assert_equal item.recovered_only, recovered.dig(:technician_message, :text)
    assert_equal "recovered", recovered.dig(:technician_message, :provenance)
    assert_equal [ item.recovered_source ], recovered[:recovered_from]

    secret = turn(package, item.secret_correlation)
    assert_includes secret.dig(:technician_message, :text), "[redacted]"
    assert_not_includes secret.dig(:technician_message, :text), "AKIA"
    assert_not_includes secret.dig(:model, :input).to_s, "AKIA"

    archived = package[:session_archive].find { |row|
      row[:correlation_id] == item.text_correlation && row[:role] == "user"
    }
    assert_equal item.question, archived[:full_content]
    assert_empty item.session.reload.conversation_history

    readable = PilotMetricsHumanFormatter.new(package).to_s
    assert_includes readable, "question=#{item.question}"
    assert_includes readable, "answer=#{item.answer}"
    assert_includes readable, "visual_card=#{item.card}"
    assert_includes readable, "answer=#{item.published}"
    assert_includes readable, "browser_render=uncaptured"
    assert_includes readable, "recovered_from="
    assert_includes readable, "uncaptured="
  end

  def turn(package, correlation_id)
    found = package[:durable_traces].find { |row| row[:correlation_id] == correlation_id }
    assert found, "missing turn #{correlation_id}"
    found
  end

  def report_for(item)
    PilotMetricsReport.new(
      from: Date.current,
      to: Date.current,
      user_ids: [ item.user.id ],
      include_raw_questions: true
    ).as_json
  end

  def write_example(item, package)
    directory = Rails.root.join("tmp/pilot_exports/trazabilidad-offline")
    FileUtils.mkdir_p(directory)
    body = {
      "account_slug" => item.account.slug,
      "account_id" => item.account.id,
      "user_id" => item.user.id,
      "conversation_session_id" => item.session.id,
      "conversation_history_at_export" => item.session.conversation_history,
      "browser_render" => "uncaptured",
      "note" => "Reconstruido desde field_companion_traces con el historial activo vacío. browser_render no tiene evento del navegador.",
      "durable_traces" => package[:durable_traces],
      "session_archive" => package[:session_archive].select { |row| row[:account_id] == item.account.id }
    }
    File.write(directory.join("#{item.account.slug}.json"), JSON.pretty_generate(body))
  end

  def isolate!(item)
    ENV["APPLY"] = "true"
    ENV["FIELD_COMPANION_WEB_TRIAL_CONFIRM"] = item.user.email
    output = capture_io { @isolate.invoke(item.account.slug, item.user.email) }.first
    @isolate.reenable
    assert_includes output, "APPLIED"
    item.session.reload
    output
  end

  def open_new_case!(item)
    item.session.update!(conversation_history: [])
    item.session.start_new_case!(reason: "new_case", correlation_id: "case:#{item.token}")
    item.session.reload
  end

  def write_episode(item, photo: nil)
    now = Time.current.iso8601
    episode = {
      "v" => 1,
      "episode_id" => item.episode_id,
      "status" => "active",
      "opened_at" => now,
      "updated_at" => now
    }
    episode["active_photo"] = { "field_photo_id" => photo.id, "sha256" => photo.sha256 } if photo
    item.session.update!(active_episode: episode)
  end

  def with_photo_service(service)
    singleton = Rag::PhotoQuestionAnswerService.singleton_class
    had_own = singleton.instance_methods(false).include?(:new)
    previous = Rag::PhotoQuestionAnswerService.method(:new)
    singleton.define_method(:new) { |*_args, **_kwargs| service }
    yield
  ensure
    singleton.remove_method(:new)
    singleton.define_method(:new, previous) if had_own
  end

  def with_attempt(item, attempt)
    ctx = Rag::DurableTrace.start_job(
      account_id: item.account.id,
      user_id: item.user.id,
      conversation_session_id: item.session.id,
      correlation_id: item.photo_correlation,
      job_id: item.job_id,
      attempt: attempt
    )
    yield
  ensure
    Rag::DurableTrace.finish_job(ctx)
  end

  def controller_for(item, question)
    request = Struct.new(:request_id).new(SecureRandom.uuid)
    params = ActionController::Parameters.new("question" => question)
    controller = Object.new
    account = item.account
    user = item.user
    controller.define_singleton_method(:request) { request }
    controller.define_singleton_method(:params) { params }
    controller.define_singleton_method(:controller_path) { "rag" }
    controller.define_singleton_method(:action_name) { "ask" }
    controller.define_singleton_method(:current_user) { user }
    controller.define_singleton_method(:current_account) { account }
    controller
  end

  def trace_count(item)
    FieldCompanionTrace.where(account_id: item.account.id).count
  end
end
