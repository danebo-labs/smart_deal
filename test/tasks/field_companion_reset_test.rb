# frozen_string_literal: true

require "test_helper"
require "rake"

class FieldCompanionResetTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("field_companion:reset_active_episode")
    @task = Rake::Task["field_companion:reset_active_episode"]
    @clean = Rake::Task["field_companion:start_clean_case"]
    @account = accounts(:legacy)
    @user = users(:one)
    @user.update!(account: @account)
    @session = ConversationSession.create!(
      account: @account,
      user: @user,
      identifier: "reset-test",
      channel: "web",
      expires_at: 1.day.from_now,
      conversation_history: [ { "role" => "user", "content" => "keep me" } ],
      active_entities: { "manual" => { "source" => "user_pin" } },
      active_episode: { "v" => 1, "episode_id" => "ep_reset_me" }
    )
    @other = ConversationSession.create!(
      account: accounts(:pilot),
      user: users(:two),
      identifier: "other-account",
      channel: "web",
      expires_at: 1.day.from_now,
      active_episode: { "v" => 1, "episode_id" => "ep_keep_me" }
    )
    @original_apply = ENV.delete("APPLY")
    @original_copy_dir = ENV["FIELD_COMPANION_CLEAN_START_COPY_DIR"]
    @copy_dir = Rails.root.join("tmp/field_companion_clean_start_test/#{SecureRandom.hex(4)}")
    ENV["FIELD_COMPANION_CLEAN_START_COPY_DIR"] = @copy_dir.to_s
  end

  teardown do
    @task.reenable
    @clean.reenable
    @original_apply.nil? ? ENV.delete("APPLY") : ENV["APPLY"] = @original_apply
    if @original_copy_dir.nil?
      ENV.delete("FIELD_COMPANION_CLEAN_START_COPY_DIR")
    else
      ENV["FIELD_COMPANION_CLEAN_START_COPY_DIR"] = @original_copy_dir
    end
    FileUtils.rm_rf(@copy_dir)
  end

  test "dry run reports the exact scope and changes nothing" do
    output = capture_io { @task.invoke(@account.slug, @user.email) }.first

    assert_includes output, "DRY RUN"
    assert_equal "ep_reset_me", @session.reload.active_episode["episode_id"]
    assert_equal "ep_keep_me", @other.reload.active_episode["episode_id"]
  end

  test "apply clears only active_episode for the matching account user and is idempotent" do
    history = @session.conversation_history.deep_dup
    entities = @session.active_entities.deep_dup
    expires_at = @session.expires_at
    updated_at = @session.updated_at
    ENV["APPLY"] = "true"

    first = capture_io { @task.invoke(@account.slug, @user.email) }.first
    @task.reenable
    second = capture_io { @task.invoke(@account.slug, @user.email) }.first

    @session.reload
    assert_includes first, "RESET: cleared active_episode in 1 session(s)"
    assert_includes second, "RESET: cleared active_episode in 0 session(s)"
    assert_equal({}, @session.active_episode)
    assert_equal history, @session.conversation_history
    assert_equal entities, @session.active_entities
    assert_equal expires_at, @session.expires_at
    assert_equal updated_at, @session.updated_at
    assert_equal "ep_keep_me", @other.reload.active_episode["episode_id"]
  end

  test "dry run reports the runtime key and leaves every row unchanged" do
    runtime = runtime_session
    output = with_clean_flags { invoke_clean.first }

    assert_includes output, "DRY RUN"
    assert_includes output, "no_comprobado"
    assert_includes output, "flags_scope=este_proceso web_y_workers_no_inspeccionados"
    assert_includes output, "key account_id=#{@account.id} user_id=#{@user.id} identifier=#{@user.id} channel=web"
    assert_includes output, "session_id=#{runtime.id}"
    assert_not_includes output, "session_id=#{@session.id}"
    assert_equal "ep_old_case", runtime.reload.active_episode["episode_id"]
    assert_equal "ep_reset_me", @session.reload.active_episode["episode_id"]
    assert_empty Dir.glob(@copy_dir.join("*.json").to_s)
    assert_not_includes output, ENV["DB_PASSWORD"].to_s if ENV["DB_PASSWORD"].present?
  end

  test "apply backs up the previous case and empties the working context" do
    runtime = runtime_session
    photo_id = runtime.active_episode.dig("active_photo", "field_photo_id")
    expires_at = runtime.expires_at
    created_at = runtime.created_at
    row_id = runtime.id
    ENV["APPLY"] = "true"

    output = with_clean_flags { invoke_clean.first }
    runtime.reload

    assert_includes output, "APPLIED"
    assert_includes output, "cleanliness=limpio"
    assert_includes output, "pending_work=0"
    assert_includes output, "pending_work_reading=puntual no_impide_trabajo_posterior"
    assert_includes output, "cleanliness_scope=fila_y_lectura_de_cola navegador_no_recorrido otros_procesos_no_inspeccionados no_impide_trabajo_posterior"
    assert_includes output, "attribution=consistent"
    assert_includes output, "conversation_history=0"
    assert_includes output, "session_status=procedure_in_progress kept"
    assert_not_equal "ep_old_case", runtime.active_episode["episode_id"]
    assert_equal [], runtime.document_focus
    assert_equal [], runtime.conversation_history
    assert_equal({}, runtime.active_entities)
    assert_equal({}, runtime.current_procedure)
    assert_equal({}, runtime.active_episode["facts"])
    assert_nil runtime.active_episode["active_photo"]
    assert_nil runtime.active_episode["goal"]
    assert_equal "procedure_in_progress", runtime.session_status
    assert_equal row_id, runtime.id
    assert_equal @user.id, runtime.user_id
    assert_equal @user.id.to_s, runtime.identifier
    assert_equal expires_at.to_i, runtime.expires_at.to_i
    assert_equal created_at.to_i, runtime.created_at.to_i
    assert_equal "keep me", @session.reload.conversation_history.dig(0, "content")
    assert_equal "ep_reset_me", @session.active_episode["episode_id"]
    assert_equal "ep_keep_me", @other.reload.active_episode["episode_id"]
    assert_equal "PHOTO_BYTES_ZX9", FieldPhoto.find(photo_id).thumbnail_data

    copy_text = File.read(Dir.glob(@copy_dir.join("*.json")).sole)
    copy = JSON.parse(copy_text)
    assert_equal "ep_old_case", copy.dig("replaced", "active_episode", "episode_id")
    assert_equal MARKER, copy.dig("replaced", "active_episode", "facts", "manufacturer", "value")
    assert_equal "s3://manuals/#{MARKER}.pdf", copy.dig("replaced", "document_focus", 0, "source_uri")
    assert_equal "Donde esta #{MARKER} ?", copy.dig("replaced", "conversation_history", 0, "content")
    assert_equal "query:old", copy.dig("replaced", "conversation_history", 0, "correlation_id")
    assert_equal 0, copy.dig("replaced", "conversation_history", 0, "index")
    assert_equal "s3://manuals/#{MARKER}.pdf", copy.dig("replaced", "active_entities", "manual", "source_uri")
    assert_equal MARKER, copy.dig("replaced", "current_procedure", "step")
    assert_equal "procedure_in_progress", copy.dig("kept", "session_status")
    assert_equal photo_id, copy.dig("photos", 0, "id")
    assert_equal "point_in_time", copy.dig("pending_work", "reading")
    assert_equal 0, copy.dig("pending_work", "count")
    assert_not_includes copy_text, "PHOTO_BYTES_ZX9"
    assert_not_includes copy_text, "super-secret-value"
    assert_not_includes copy_text, "X-Amz-Signature"

    with_clean_flags do
      assert_nil runtime.record_assistant_turn!(
        "STALE_REPLY_ZX9", user_id: @user.id, correlation_id: "query:stale", expected_episode_id: "ep_old_case"
      )
      assert_equal :stale, runtime.record_photo_observation!(
        photo_value: { "manufacturer" => MARKER }, field_photo_id: photo_id, sha256: "b" * 64,
        correlation_id: "photo:stale", expected_episode_id: "ep_old_case"
      )
      assert_equal false, runtime.pin_kb_document_if_episode_owner!(
        kb_documents(:manual_uno), expected_episode_id: "ep_old_case", correlation_id: "query:stale-pin"
      )
    end
    runtime.reload
    assert_not_includes runtime.conversation_history.to_json, "STALE_REPLY_ZX9"
    assert_nil runtime.active_episode["active_photo"]
    assert_equal [], runtime.document_focus
    assert_not_includes runtime.active_episode.to_json, MARKER
  end

  test "the next owner turn route omits the previous case" do
    runtime = runtime_session
    ENV["APPLY"] = "true"
    with_clean_flags { invoke_clean }
    runtime.reload

    turn = nil
    events = with_clean_flags do
      Rag::ValidationCapture.capture do
        turn = runtime.record_user_turn!(
          "la puerta del nivel 4 no cierra",
          user_id: @user.id,
          correlation_id: "query:clean-turn",
          interpreter_client: scripted_interpreter,
          now: Time.current
        )
        context = SessionContextBuilder.build(runtime.reload)
        uris = SessionContextBuilder.entity_s3_uris(runtime)
        received = drive_query(runtime, turn, context, uris)
        assert_includes context, "nivel 4"
        assert_not_includes context, MARKER
        assert_empty uris
        assert_empty Array(received[:kwargs][:entity_s3_uris])
        assert_nil received[:kwargs][:field_photo_id]
        assert_not_includes received[:question].to_s, MARKER
        assert_equal 0, received[:resolver_calls]
      end
    end

    blob = JSON.generate(events)
    kinds = events.pluck("kind")
    assert_includes kinds, "user_message"
    assert_includes kinds, "interpreter_request"
    assert_includes kinds, "effective_query"
    assert_not_includes blob, MARKER
    assert_includes blob, "nivel 4"
    assert turn.decision
    assert_not_includes %i[skipped no_episode], turn.decision
    runtime.reload
    assert_equal [ "la puerta del nivel 4 no cierra" ], runtime.conversation_history.select { |row| row["role"] == "user" }.pluck("content")
    assert_not_includes runtime.conversation_history.to_json, MARKER
  end

  test "empty focus filter and photo continuity are component checks" do
    runtime = runtime_session
    ENV["APPLY"] = "true"
    with_clean_flags { invoke_clean }
    runtime.reload
    context = SessionContextBuilder.build(runtime)
    service = BedrockRagService.new(account: @account, knowledge_base_id: "test-kb")
    filter = service.send(
      :retrieval_filter,
      entity_s3_uris: [], entity_sources: [], question: "la puerta del nivel 4 no cierra", apply_page_filter: false
    )
    prompt = service.send(
      :load_generation_prompt_with_locale,
      "la puerta del nivel 4 no cierra", session_context: context, output_channel: :web
    )
    photo = Rag::PhotoObservationContinuity.decide(
      question: "mira la foto", images: [], field_photo_id: nil, account: @account, session: runtime
    )

    assert_empty service.send(:extract_constrained_uris, filter)
    assert_includes JSON.generate(filter), "account_id"
    assert_includes JSON.generate(filter), Rag::SharedManualCorpus::GENERAL
    assert_not_includes context, MARKER
    assert_not_includes prompt, MARKER
    assert_equal :missing_photo, photo.action
    assert_nil photo.photo
  end

  test "a history row in the current second does not delay the clear" do
    frozen = Time.zone.parse("2026-10-19T18:00:01-03:00")
    runtime = runtime_session(history_ts: frozen.iso8601)
    ENV["APPLY"] = "true"
    io = StringIO.new
    with_clean_flags do
      FieldCompanionCleanStart.call(
        account_slug: @account.slug, user_email: @user.email, apply: true,
        io: io, clock: -> { frozen }
      )
    end

    runtime.reload
    assert_includes io.string, "APPLIED"
    assert_not_includes io.string, "ABORT"
    assert_equal [], runtime.conversation_history
    assert_equal frozen.iso8601, runtime.active_episode["opened_at"]
    assert_equal({}, runtime.active_episode["facts"])
    assert_nil runtime.active_episode["active_photo"]
    assert_not_equal "ep_old_case", runtime.active_episode["episode_id"]
  end

  test "a failed copy write does not change the row" do
    runtime = runtime_session
    blocker = @copy_dir.join("not-a-directory")
    FileUtils.mkdir_p(@copy_dir)
    File.write(blocker, "x")
    ENV["FIELD_COMPANION_CLEAN_START_COPY_DIR"] = blocker.to_s
    ENV["APPLY"] = "true"

    stdout, _stderr = capture_io do
      assert_raises(StandardError) do
        with_clean_flags { @clean.invoke(@account.slug, @user.email) }
      end
    end

    assert_includes stdout, "transition_failed"
    assert_equal "ep_old_case", runtime.reload.active_episode["episode_id"]
    assert_predicate runtime.document_focus, :any?
    assert_includes runtime.conversation_history.to_json, MARKER
    assert_includes runtime.active_entities.to_json, MARKER
    assert_empty Dir.glob(@copy_dir.join("*.json").to_s)
  end

  test "a failed focus clear rolls back the new episode" do
    runtime = runtime_session
    ENV["APPLY"] = "true"
    original = ConversationSession.instance_method(:update!)
    ConversationSession.define_method(:update!) do |attrs = {}|
      raise "focus clear failed" if attrs.key?(:document_focus)

      original.bind_call(self, attrs)
    end

    stdout, _stderr = capture_io do
      assert_raises(RuntimeError) do
        with_clean_flags { @clean.invoke(@account.slug, @user.email) }
      end
    end

    runtime.reload
    assert_includes stdout, "transition_failed"
    assert_equal "ep_old_case", runtime.active_episode["episode_id"]
    assert_predicate runtime.document_focus, :any?
    assert_includes runtime.conversation_history.to_json, MARKER
    assert_includes runtime.active_entities.to_json, MARKER
    assert_includes runtime.current_procedure.to_json, MARKER
    copy = JSON.parse(File.read(Dir.glob(@copy_dir.join("*.json")).sole))
    assert_equal "ep_old_case", copy.dig("replaced", "active_episode", "episode_id")
    assert_equal "Donde esta #{MARKER} ?", copy.dig("replaced", "conversation_history", 0, "content")
  ensure
    ConversationSession.define_method(:update!, original) if original
  end

  test "shared mode zero rows and ambiguity abort without writing" do
    runtime = runtime_session
    stub_shared_enabled(true) do
      stdout, _stderr = capture_io { assert_raises(SystemExit) { @clean.invoke(@account.slug, @user.email) } }
      assert_includes stdout, "ABORT shared_session"
      assert_includes stdout, "identifier=#{@user.id}"
    end
    assert_equal "ep_old_case", runtime.reload.active_episode["episode_id"]

    @clean.reenable
    runtime.destroy!
    stdout, _stderr = capture_io { assert_raises(SystemExit) { @clean.invoke(@account.slug, @user.email) } }
    assert_includes stdout, "ABORT no_row"
    assert_equal "ep_reset_me", @session.reload.active_episode["episode_id"]

    @clean.reenable
    kept = runtime_session
    other = @session
    original_rows = FieldCompanionCleanStart.method(:rows_for)
    FieldCompanionCleanStart.define_singleton_method(:rows_for) { |*_args| [ kept, other ] }
    stdout, _stderr = capture_io { assert_raises(SystemExit) { @clean.invoke(@account.slug, @user.email) } }
    assert_includes stdout, "ABORT ambiguous"
    assert_equal "ep_old_case", kept.reload.active_episode["episode_id"]
  ensure
    if original_rows
      FieldCompanionCleanStart.define_singleton_method(:rows_for) { |*args| original_rows.call(*args) }
    end
  end

  test "an attribution mismatch is reported and the user id is not rewritten" do
    runtime = runtime_session(user_id: users(:two).id)
    ENV["APPLY"] = "true"
    output = with_clean_flags { invoke_clean.first }

    runtime.reload
    assert_includes output, "attribution=mismatch"
    assert_includes output, "not_rewritten"
    assert_equal users(:two).id, runtime.user_id
    assert_equal @user.id.to_s, runtime.identifier
    assert_not_equal "ep_old_case", runtime.active_episode["episode_id"]
    assert_equal [], runtime.conversation_history
    assert_equal({}, runtime.active_entities)
  end

  test "apply refuses when the exclusion flags are off" do
    runtime = runtime_session
    ENV["APPLY"] = "true"
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "false") do
      stdout, _stderr = capture_io { assert_raises(SystemExit) { @clean.invoke(@account.slug, @user.email) } }
      assert_includes stdout, "ABORT exclusion_configuration incomplete"
    end
    assert_equal "ep_old_case", runtime.reload.active_episode["episode_id"]
    assert_predicate runtime.document_focus, :any?
    assert_includes runtime.conversation_history.to_json, MARKER
  end

  test "pending work counts the exact serialized session id past prefix matches" do
    runtime = runtime_session
    job_ids = []
    exact_ids = []
    prefix_ids = []
    limit = FieldCompanionCleanStart::REFERENCE_LIMIT
    limit.times do |index|
      exact_ids << insert_serialized_job(photo_job(runtime.id, index))
    end
    exact_ids << insert_serialized_job(reply_job(runtime.id))
    job_ids.concat(exact_ids)
    51.times do |index|
      prefix_ids << insert_serialized_job(photo_job("#{runtime.id}#{format('%02d', index)}".to_i, "prefix-#{index}"))
    end
    job_ids.concat(prefix_ids)
    finished_id = insert_serialized_job(photo_job(runtime.id, "finished"), finished: true)
    other_id = runtime.id + 1
    decoy_id = insert_serialized_job(decoy_job(runtime.id, other_id))
    job_ids << finished_id << decoy_id
    prefix_text = FieldCompanionCleanStart::QueueJob.find(prefix_ids.first).arguments
    exact_text = FieldCompanionCleanStart::QueueJob.find(exact_ids.first).arguments
    assert_includes prefix_text, "\"conversation_session_id\":#{runtime.id}"
    assert_includes exact_text, "\"conversation_session_id\":#{runtime.id}"
    assert_match(/"conversation_session_id":#{runtime.id}([^0-9]|$)/, exact_text)
    ENV["APPLY"] = "true"

    output = with_clean_flags { invoke_clean.first }
    copy = JSON.parse(File.read(Dir.glob(@copy_dir.join("*.json")).sole))
    shown = copy.dig("pending_work", "jobs").pluck("id")

    assert_includes output, "pending_work=#{exact_ids.size}"
    assert_includes output, "cleanliness=incompleto"
    assert_includes output, "pending_work_reading=puntual no_impide_trabajo_posterior"
    assert_equal exact_ids.size, copy.dig("pending_work", "count")
    assert_equal limit, shown.size
    assert_empty(shown - exact_ids)
    assert_empty(shown & prefix_ids)
    assert_not_includes shown, finished_id
    assert_not_includes shown, decoy_id
    assert shown.all? { |id| copy.dig("pending_work", "jobs").find { |job| job["id"] == id }["class_name"].present? }
    assert_equal job_ids.size, FieldCompanionCleanStart::QueueJob.where(id: job_ids).count
    assert_not_equal "ep_old_case", runtime.reload.active_episode["episode_id"]
  ensure
    FieldCompanionCleanStart::QueueJob.where(id: job_ids).delete_all if job_ids
  end

  test "an unreadable queue reports an incomplete start and still clears the row" do
    runtime = runtime_session
    ENV["APPLY"] = "true"
    original = FieldCompanionCleanStart::QueueJob.method(:where)
    FieldCompanionCleanStart::QueueJob.define_singleton_method(:where) { |*, **| raise "queue down" }
    output = with_clean_flags { invoke_clean.first }

    assert_includes output, "pending_work=unreadable"
    assert_includes output, "cleanliness=incompleto"
    assert_includes output, "no_impide_trabajo_posterior"
    assert_equal [], runtime.reload.conversation_history
    assert_not_equal "ep_old_case", runtime.active_episode["episode_id"]
  ensure
    if original
      FieldCompanionCleanStart::QueueJob.define_singleton_method(:where) { |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      }
    end
  end

  private

  MARKER = "ANTECEDENTE_ZX9"

  def invoke_clean
    @clean.reenable
    capture_io { @clean.invoke(@account.slug, @user.email) }
  end

  def with_clean_flags(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("RAG_EPISODE_SCOPE_ENABLED", "true") do
          isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
        end
      end
    end
  end

  def stub_shared_enabled(enabled)
    original = SharedSession::ENABLED
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, enabled)
    yield
  ensure
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, original)
  end

  def runtime_session(user_id: @user.id, history_ts: 1.hour.ago.iso8601)
    session = ConversationSession.create!(
      account: @account,
      user_id: user_id,
      identifier: @user.id.to_s,
      channel: "web",
      expires_at: 1.day.from_now,
      conversation_history: [
        {
          "role" => "user", "content" => "Donde esta #{MARKER} ?",
          "ts" => history_ts, "correlation_id" => "query:old"
        },
        {
          "role" => "assistant",
          "content" => "Respuesta #{MARKER} https://files.example/photo.jpg?X-Amz-Signature=deadbeef",
          "ts" => history_ts, "correlation_id" => "query:old"
        }
      ],
      active_entities: { "manual" => { "source" => "user_pin", "source_uri" => "s3://manuals/#{MARKER}.pdf" } },
      document_focus: [ {
        "kb_document_id" => kb_documents(:manual_uno).id,
        "source_uri" => "s3://manuals/#{MARKER}.pdf",
        "display_name" => MARKER,
        "added_at" => history_ts
      } ],
      current_procedure: { "password" => "super-secret-value", "step" => MARKER },
      session_status: "procedure_in_progress",
      active_episode: {
        "v" => 1,
        "episode_id" => "ep_old_case",
        "status" => "active",
        "opened_at" => 2.hours.ago.iso8601,
        "updated_at" => 1.hour.ago.iso8601,
        "goal" => { "text" => "#{MARKER} objetivo", "correlation_id" => "query:old", "truncated" => false },
        "facts" => { "manufacturer" => { "value" => MARKER } },
        "identifiers" => [ { "value" => MARKER } ],
        "observations" => [ { "text" => MARKER } ],
        "active_photo" => { "correlation_id" => "photo:old" }
      }
    )
    photo = FieldPhoto.create!(
      account_id: @account.id,
      user_id: @user.id,
      conversation_session_id: session.id,
      sha256: SecureRandom.hex(32),
      s3_key_original: "field_photos/#{@account.id}/#{SecureRandom.hex(8)}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 15,
      thumbnail_data: "PHOTO_BYTES_ZX9"
    )
    episode = session.active_episode.merge(
      "active_photo" => { "field_photo_id" => photo.id, "correlation_id" => "photo:old", "sha256" => photo.sha256 }
    )
    session.update!(active_episode: episode)
    session
  end

  def scripted_interpreter
    CleanStartInterpreter.new([ {
      "move" => "report",
      "assertions" => [],
      "observations" => [ "la puerta del nivel 4 no cierra" ],
      "pending_resolution" => nil,
      "clarification_target" => nil
    } ])
  end

  def drive_query(session, turn, context, uris)
    received = { resolver_calls: 0 }
    orchestrator = Object.new
    orchestrator.define_singleton_method(:execute) do
      { answer: "doblado", citations: [], retrieved_citations: [], correlation_id: "query:clean-turn" }
    end
    original = Rag::EpisodeThreadResolver.method(:call)
    Rag::EpisodeThreadResolver.define_singleton_method(:call) do |**kwargs|
      received[:resolver_calls] += 1
      original.call(**kwargs)
    end
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |question, **kwargs|
      received[:question] = question
      received[:kwargs] = kwargs
      orchestrator
    end
    CleanTurnProbe.new.execute_rag_query(
      "la puerta del nivel 4 no cierra",
      session_context: context,
      conv_session: session,
      entity_s3_uris: uris,
      account: @account,
      user_id: @user.id,
      correlation_id: "query:clean-turn",
      field_photo_id: nil,
      episode_turn: turn
    )
    received
  ensure
    Rag::EpisodeThreadResolver.define_singleton_method(:call) { |**kwargs| original.call(**kwargs) } if original
    if original_new
      QueryOrchestratorService.define_singleton_method(:new) do |*args, **kwargs, &block|
        original_new.call(*args, **kwargs, &block)
      end
    end
  end

  def insert_serialized_job(job, finished: false)
    FieldCompanionCleanStart::QueueJob.create!(
      queue_name: job.queue_name.presence || "default",
      class_name: job.class.name,
      arguments: ActiveSupport::JSON.encode(job.serialize),
      priority: job.priority || 0,
      active_job_id: job.job_id,
      created_at: Time.current,
      updated_at: Time.current,
      finished_at: (Time.current if finished)
    ).id
  end

  def photo_job(session_id, salt)
    FieldPhotoAnalysisJob.new(
      image_token: "tok-#{salt}",
      image_sha256: "a" * 64,
      filename: "a.jpg",
      content_type: "image/jpeg",
      account_id: @account.id,
      conversation_session_id: session_id
    )
  end

  def reply_job(session_id)
    SendWhatsappReplyJob.new(to: "+100", from: "+200", body: "pendiente", conv_session_id: session_id)
  end

  def decoy_job(session_id, other_id)
    TrackBedrockQueryJob.new(
      model_id: "test-model",
      user_query: "conversation_session_id #{session_id} pertenece a otro job",
      latency_ms: 1,
      account_id: session_id,
      conversation_session_id: other_id
    )
  end
end

class CleanTurnProbe
  include RagQueryConcern
  public :execute_rag_query
end

class CleanStartInterpreter
  def initialize(responses)
    @responses = responses.dup
  end

  def converse(_params)
    tool = Struct.new(:name, :input).new("turn_perception", @responses.shift)
    block = Struct.new(:tool_use).new(tool)
    message = Struct.new(:content).new([ block ])
    output = Struct.new(:message).new(message)
    usage = Struct.new(:input_tokens, :output_tokens).new(1, 1)
    Struct.new(:output, :usage).new(output, usage)
  end
end
