# frozen_string_literal: true

require "test_helper"
require_relative "../support/field_case_history_helper"
require_relative "../../script/pilot_metrics_scope"

class FieldCasePhotoHistoryTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper
  include FieldCaseHistoryHelper

  setup do
    enable_history!
    sign_in users(:one)
    @calls = []
    @objects = {}
    @answer_requests = []
    @image = { data: Base64.strict_encode64("offline image"), media_type: "image/jpeg", filename: "placa.jpg" }
  end

  teardown { disable_history! }

  test "the first photo and text turn retrieves within the pinned manual after reopening" do
    manual = KbDocument.create!(account: accounts(:legacy),
                                display_name: "THYSSEN (Manual de Maniobra Universal con MCINV4)",
                                s3_key: "bulk_uploads/3/2026-08-20/THYSSEN (Manual de Maniobra Universal con MCINV4).pdf",
                                aliases: [])
    question = "Estoy con un Thyssen FDN Universal con MCINV4. El ascensor quedó detenido y el display marca EA"
    request = { creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid,
                image: @image.merge(filename: "thyssen MCP7 bornera comando.jpg"), question:,
                kb_document_ids: [ manual.id.to_s ] }
    filters = []
    build_answer = Rag::PhotoQuestionAnswerService.method(:new)
    answer_service = lambda do |**kwargs|
      @answer_requests << kwargs
      build_answer.call(**kwargs)
    end

    with_bedrock_doubles(filters) do
      with_external_doubles(answer_service:, photo_model: "UNKNOWN") do
        post rag_ask_path, params: request, as: :json
        assert_response :accepted
        kase = FieldCase.find(response.parsed_body.fetch("field_case_id"))
        turn = kase.field_turns.sole
        assert_equal [ manual.id ], kase.document_focus.pluck("kb_document_id")

        post rag_ask_path, params: request.except(:kb_document_ids), as: :json
        assert_response :accepted
        assert_equal turn.id, response.parsed_body.dig("field_turn", "id")
        assert_enqueued_jobs 1, only: FieldPhotoAnalysisJob

        perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
        assert_equal [ manual.id ], @answer_requests.sole.fetch(:session_snapshot).focus_document_ids
        assert_equal [ manual.canonical_uri ], @answer_requests.sole.fetch(:entity_s3_uris_snapshot)
        assert_equal "completed", turn.reload.status
        assert_equal question, turn.message
        assert_equal turn.correlation_id, @answer_requests.sole.fetch(:correlation_id)
        assert_pin_filter(filters, manual)

        get field_case_path(kase), as: :json
        assert_response :ok
        focus = response.parsed_body.dig("case", "document_focus").sole
        assert_equal manual.id, focus.fetch("kb_document_id")
        assert_equal manual.document_uid, focus.fetch("document_uid")

        filters.clear
        post rag_ask_path, params: { field_case_id: kase.id, client_submission_id: SecureRandom.uuid,
                                     question: "La puerta del piso no termina de cerrar" }, as: :json
        assert_response :ok
        assert_equal "completed", response.parsed_body.dig("field_turn", "status")
        assert_equal [ manual.id ], kase.reload.document_focus.pluck("kb_document_id")
        assert_pin_filter(filters, manual)
      end
    end
  end

  test "a malformed opening photo pin list is rejected before uploading" do
    with_external_doubles do
      assert_no_difference([ "FieldCase.count", "FieldTurn.count", "FieldPhoto.count" ]) do
        post rag_ask_path, params: { creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid,
                                     image: @image, kb_document_ids: "1" }, as: :json
      end
      assert_response :unprocessable_entity
      assert_equal "pins", response.parsed_body.fetch("error")
      assert_no_enqueued_jobs only: FieldPhotoAnalysisJob
    end
  end

  test "the guarded worker captures a scoped case upload under its stored correlation" do
    Dir.mktmpdir("guarded-case-photo") do |store|
      run_id = "offline-case-photo-#{SecureRandom.hex(4)}"
      env = {
        "RAG_LOCAL_PASS_GUARD" => "1", "RAG_LOCAL_PASS_CALL_CAP" => "1",
        "RAG_LOCAL_PASS_COST_CAP_USD" => "0.1", "AWS_MAX_ATTEMPTS" => "1",
        "RAG_VALIDATION_CAPTURE_RUN" => run_id, "RAG_PHOTO_LOCAL_STORE" => store
      }
      previous = ENV.to_h.slice(*env.keys)
      capture_root = Rails.root.join(Rag::WebRequestCapture::ROOT, run_id)
      ENV.update(env)
      with_external_doubles do
        post rag_ask_path, params: { creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid,
                                     image: @image }, as: :json
        assert_response :accepted
        turn = FieldTurn.find(response.parsed_body.dig("field_turn", "id"))
        assert_empty @objects
        assert_equal "offline image", FieldPhotoStore.fetch_binary(turn.field_photo)

        perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
        assert_equal "completed", turn.reload.status
        capture = capture_root.join("worker-#{turn.correlation_id.tr(':', '-')}", "capture.json")
        event = JSON.parse(capture.read).fetch("events").find { |row| row["kind"] == "photo_worker_input" }
        assert_equal turn.correlation_id, event.fetch("correlation_id")
        assert_equal turn.id, event.fetch("field_turn_id")
        assert_equal turn.field_photo.sha256, event.fetch("sha256")
      end
    ensure
      env.each_key { |key| assign_env(key, previous[key]) }
      FileUtils.rm_rf(capture_root)
    end
  end

  [ false, true ].product([ false, true ]).each do |existing, with_question|
    test "photo #{with_question ? 'with question' : 'alone'} in #{existing ? 'existing' : 'new'} case" do
      kase = open_case if existing
      if kase
        manual = KbDocument.create!(account: accounts(:legacy), display_name: "Panel P1",
                                    s3_key: "uploads/panel-p1.pdf", aliases: [])
        post pinned_documents_path, params: { field_case_id: kase.id, kb_document_id: manual.id }, as: :json
        assert_response :ok
      end
      target = kase ? { field_case_id: kase.id } : { creation_key: SecureRandom.uuid }
      request = {
        **target, image: @image, client_submission_id: SecureRandom.uuid,
        question: ("¿Qué se lee en la placa?" if with_question)
      }.compact

      with_external_doubles do
        assert_difference("FieldTurn.count", 1) do
          assert_difference("FieldCase.count", existing ? 0 : 1) do
            post rag_ask_path, params: request, as: :json
            assert_response :accepted
            @origin = response.parsed_body.fetch("field_case_id")
          end
        end
        turn_id = response.parsed_body.dig("field_turn", "id")
        assert_no_difference([ "FieldCase.count", "FieldTurn.count", "FieldPhoto.count" ]) do
          post rag_ask_path, params: request, as: :json
          assert_response :accepted
          assert_equal turn_id, response.parsed_body.dig("field_turn", "id")
        end
        assert_enqueued_jobs 1, only: FieldPhotoAnalysisJob

        other = open_case
        get field_case_path(other), as: :json
        assert_response :ok
        assert_empty response.parsed_body.fetch("turns")

        perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
        assert_equal 1, @calls.size
        assert_equal(with_question ? 1 : 0, @answer_requests.size)
        assert_equal [ manual.canonical_uri ], @answer_requests.first[:entity_s3_uris_snapshot] if with_question && existing
        get field_case_path(@origin), as: :json
        assert_response :ok
        saved = response.parsed_body
        row = saved.fetch("turns").sole
        assert_equal "completed", row["status"]
        assert_equal "photo", row["kind"]
        assert_equal request[:question].to_s, row["message"]
        assert_match(/P1/, row.dig("response", "published_text"))
        assert_equal row["field_photo_id"], row.dig("checkpoint", "active_photo", "field_photo_id")
        assert_equal(existing ? [ manual.id ] : [], saved.dig("case", "document_focus").pluck("kb_document_id"))
        assert_equal row["correlation_id"], @calls.first[:correlation_id]
        assert_equal(with_question ? [ 8 ] : [], row.dig("response", "citations").pluck("page"))
        get field_case_path(other), as: :json
        assert_empty response.parsed_body.fetch("turns")

        run_text_followup(@origin, row["field_photo_id"])
      end
    end
  end

  test "enqueue and analysis failures can retry the same turn with a fresh execution token" do
    with_external_doubles do
      request = { creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid, image: @image }
      replace_method(FieldPhotoAnalysisJob, :perform_later, ->(**) { false }) do
        post rag_ask_path, params: request, as: :json
      end
      assert_response :ok
      kase = response.parsed_body.fetch("field_case_id")
      turn = FieldTurn.find(response.parsed_body.dig("field_turn", "id"))
      assert_equal "enqueue_failed", turn.failure_code
      retry_url = "/field_cases/#{kase}/turns/#{turn.id}/retry_photo"

      assert_no_difference("FieldTurn.count") do
        post retry_url, as: :json
        assert_response :ok
        post retry_url, as: :json
        assert_response :ok
        assert_enqueued_jobs 1, only: FieldPhotoAnalysisJob

        @vision_failure = true
        perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
        assert_equal "analysis_failed", turn.reload.failure_code
        stale = turn.execution_token

        @vision_failure = false
        post retry_url, as: :json
        assert_response :ok
        old_arguments = { field_case_id: kase, field_turn_id: turn.id, account_id: turn.field_case.account_id,
                          user_id: turn.field_case.user_id, execution_token: stale }
        FieldPhotoAnalysisJob.perform_now(**old_arguments)
        assert_equal 1, @calls.size
        perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
        assert_equal 2, @calls.size
        assert_equal "completed", turn.reload.status
        assert_equal 3, turn.attempt
        FieldPhotoAnalysisJob.perform_now(**old_arguments.merge(execution_token: turn.execution_token))
        assert_equal 2, @calls.size
      end
    end
  end

  test "the worker keeps the original turn when history env is absent or false" do
    assert FieldPhoto.connection.column_exists?(:field_photos, :storage_scope)
    versions = ActiveRecord::SchemaMigration.new(ActiveRecord::Base.connection_pool).integer_versions
    assert_includes versions, 2026_11_17_190000

    [ nil, "false" ].each do |value|
      isolate_env("FIELD_CASE_HISTORY_ENABLED", value) do
        question = value == "false" ? "¿Qué se lee en la placa?" : nil
        with_external_doubles do
          assert_difference("FieldCase.count", 1) do
            assert_difference("FieldTurn.count", 1) do
              post rag_ask_path, params: {
                creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid,
                image: @image, question:
              }.compact, as: :json
            end
          end
          assert_response :accepted
          case_id = response.parsed_body.fetch("field_case_id")
          turn_id = response.parsed_body.dig("field_turn", "id")
          queued = enqueued_jobs.select { |job| job["job_class"] == "FieldPhotoAnalysisJob" }.last
          args = queued.fetch("arguments").first
          assert_equal case_id, args.fetch("field_case_id")
          assert_equal turn_id, args.fetch("field_turn_id")

          perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
          turn = FieldTurn.find(turn_id)
          assert_equal case_id, turn.field_case_id
          assert_equal "completed", turn.status
          assert_equal question.to_s, turn.message
          assert_match(/P1/, turn.response.fetch("published_text"))
          assert_equal(value == "false" ? [ 8 ] : [], turn.response.fetch("citations").pluck("page"))
        end
      end
    end
  end

  test "another technician and another account cannot use the history attachment" do
    with_external_doubles do
      post rag_ask_path, params: { creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid, image: @image }, as: :json
      assert_response :accepted
      turn = FieldTurn.find(response.parsed_body.dig("field_turn", "id"))
      [ colleague, users(:two) ].each do |other|
        sign_out users(:one)
        sign_in other
        host! "climb.danebo.ai" if other == users(:two)
        get field_photo_path(turn.field_photo_id)
        assert_includes [ 403, 404 ], response.status
        get field_case_path(turn.field_case_id)
        assert_includes [ 403, 404 ], response.status
        post rag_ask_path, params: {
          field_case_id: turn.field_case_id, client_submission_id: SecureRandom.uuid, image: @image
        }, as: :json
        assert_includes [ 403, 404 ], response.status
        FieldPhotoAnalysisJob.perform_now(
          field_case_id: turn.field_case_id, field_turn_id: turn.id, account_id: other.account_id,
          user_id: other.id, execution_token: turn.execution_token
        )
        assert_empty @calls
        sign_out other
      end
    end
  end

  test "two account exports isolate events, capture bodies and published photo and text" do
    legacy = accounts(:legacy)
    pilot = accounts(:pilot)
    pilot_user = User.create!(account: pilot, email: "offline-photo-pilot@example.com", password: "password123")
    owners = [ [ legacy, users(:one), "www.example.com" ], [ pilot, pilot_user, "piloto.danebo.ai" ] ]
    turns = {}
    with_external_doubles do
      owners.each do |account, user, host|
        host! host
        sign_in user
        post rag_ask_path, params: {
          question: "¿Qué se lee en la placa?", creation_key: SecureRandom.uuid,
          client_submission_id: SecureRandom.uuid, image: @image
        }, as: :json
        assert_response :accepted
        kase = FieldCase.find(response.parsed_body.fetch("field_case_id"))
        photo_id = response.parsed_body.dig("field_turn", "field_photo_id")
        perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
        run_text_followup(kase.id, photo_id)
        turns[account.id] = kase.field_turns.order(:sequence).to_a
        sign_out user
      end
    end

    Dir.mktmpdir("field-case-exports") do |tmp|
      staged = Pathname(tmp)
      archive = staged.join("captures")
      FileUtils.mkdir_p(archive)
      FieldCompanionTrace.where(kind: "capture", account_id: turns.keys).find_each do |row|
        directory = archive.join(row.id.to_s)
        FileUtils.mkdir_p(directory)
        captured = row.payload.fetch("events")
        directory.join("capture.json").write(JSON.generate(Rag::ValidationCapture.export_capture(captured, directory)))
      end
      logs = staged.join("source.log")
      logs.open("w") do |file|
        turns.each do |account_id, pair|
          pair.each do |turn|
            payload = { account_id:, correlation_id: turn.correlation_id, field_case_id: turn.field_case_id,
                        field_turn_id: turn.id, ts: turn.admitted_at.iso8601, original_query: turn.message }
            file.puts("[TURN_EVIDENCE] #{JSON.generate(payload)}")
          end
        end
        file.puts('[TURN_EVIDENCE] {"correlation_id":"unattributed","original_query":"exclude this"}')
      end
      date = Time.zone.today
      owners.each do |account, user, _host|
        report = PilotMetricsReport.new(date:, account_id: account.id, user_ids: [ user.id ], include_raw_questions: true).as_json.deep_stringify_keys
        package = staged.join(account.slug)
        FileUtils.mkdir_p(package)
        package.join("report.json").write(JSON.pretty_generate(report))
        filter = PilotMetricsScope.new(report, account.id, date.to_s, date.to_s)
        filter.copy_events(logs, package.join("source_events.jsonl"))
        filter.copy_captures(archive, package.join("validation_captures"))
        index = Rag::ValidationCaptureIndex.build(package.join("validation_captures"))
        package.join("validation_capture_index.json").write(JSON.pretty_generate(index))
        thread = report.fetch("field_case_threads").sole
        assert_equal account.id, thread["account_id"]
        assert_equal "web", thread["device_channel"]
        assert_equal %w[photo text], thread.fetch("turns").pluck("kind")
        photo, text = thread["turns"]
        assert_match(/P1/, photo["published_text"])
        assert_match(/P1/, text["published_text"])
        assert_match(%r{\A/field_photos/\d+\z}, photo.dig("attachment", "href"))
        assert photo.dig("trace", "evidence", "photo").any? { |event| event["kind"] == "photo_observation" }
        assert_equal [ 8 ], photo.fetch("citations").pluck("page")
        assert_equal [ account.id ], report.fetch("durable_traces").pluck("account_id").uniq
        photo_trace = report.fetch("durable_traces").find { |row| row["correlation_id"] == photo["correlation_id"] }
        assert_equal "P1", photo_trace.dig("visual_observation", "observation", "model")
        assert_equal account.id, photo_trace["account_id"]
        assert_equal turns[account.id].map(&:correlation_id).sort, index.fetch("turns").pluck("correlation_id").uniq.sort
        assert_empty index.fetch("turns").flat_map { |row| row["unresolved_bodies"] }
        assert_equal [ account.id ], index.fetch("turns").pluck("account_id").uniq
        source = package.join("source_events.jsonl").read
        assert_no_match(/unattributed/, source)
        turns.except(account.id).values.flatten.each { |turn| assert_not_includes source, turn.correlation_id }
      end

      if ENV["DANEBO_OFFLINE_EXPORT_SOURCE"].present?
        destination = Pathname(ENV.fetch("DANEBO_OFFLINE_EXPORT_SOURCE"))
        FileUtils.mkdir_p(destination)
        FileUtils.cp_r(Dir.glob(staged.join("*")), destination)
      end
    end
  end

  private

  def run_text_followup(case_id, photo_id)
    # Isolate the generation boundary, keeping the controller, history restore
    # and real generation context builder in the request.
    capture = []
    double = Module.new do
      define_method(:execute_rag_query) do |question, **args|
        if Thread.current[:field_case_photo_context_probe]
          capture << args[:session_context]
          return RagQueryConcern::RagResult.new(
            success?: true, answer: "En la placa se ve P1.", citations: [], retrieved_citations: [],
            doc_refs: [], response_locale: :es, generation_mode: "offline", effective_question: question
          )
        end
        super(question, **args)
      end
    end
    RagController.prepend(double)
    Thread.current[:field_case_photo_context_probe] = true
    post rag_ask_path, params: {
      field_case_id: case_id, client_submission_id: SecureRandom.uuid, question: "¿Qué se alcanza a leer en la placa?"
    }, as: :json
    assert_response :ok
    assert_match(/Visible text: P1/, capture.sole)
    assert_equal photo_id, response.parsed_body.dig("field_turn", "checkpoint", "active_photo", "field_photo_id")
  ensure
    Thread.current[:field_case_photo_context_probe] = false
    double&.remove_method(:execute_rag_query)
  end

  def assert_pin_filter(filters, manual)
    assert_not_empty filters
    expected = { or_all: %w[x-amz-bedrock-kb-source-uri original_source_uri].map do |key|
      { equals: { key:, value: manual.canonical_uri } }
    end }
    filters.each { |filter| assert_equal expected, filter }
  end

  def with_bedrock_doubles(filters)
    client = Object.new
    client.define_singleton_method(:retrieve) do |params|
      filters << params.dig(:retrieval_configuration, :vector_search_configuration, :filter)
      OpenStruct.new(retrieval_results: [])
    end
    client.define_singleton_method(:invoke_model) do |**|
      body = { content: [ { text: "Revisa el manual fijado." } ], stop_reason: "end_turn" }
      OpenStruct.new(body: StringIO.new(body.to_json))
    end
    isolate_env("BEDROCK_KNOWLEDGE_BASE_ID", "offline-kb") do
      replace_method(Aws::BedrockAgentRuntime::Client, :new, ->(*) { client }) do
        replace_method(Aws::BedrockRuntime::Client, :new, ->(*) { client }) { yield }
      end
    end
  end

  def with_external_doubles(answer_service: nil, photo_model: "P1")
    storage = Object.new
    objects = @objects
    storage.define_singleton_method(:upload_binary) { |key, data, _type| objects[key] = data }
    storage.define_singleton_method(:download) { |key| objects.fetch(key) }
    compression = lambda do |_raw, _type, **|
      { binary: "offline image", media_type: "image/jpeg" }
    end
    vision = lambda do |**kwargs|
      @calls << kwargs
      raise "offline vision failure" if @vision_failure

      OpenStruct.new(call: {
        analysis: "En la imagen se ve P1.", compact_context: "En la placa se lee P1.",
        model: "claude-sonnet-5-5", usage: { input_tokens: 12, output_tokens: 8 },
        parsed: {
          "canonical_component" => "Panel", "model" => photo_model, "condition" => "GOOD", "subsystem" => "CONTROLLER_LOGIC",
          "visible_text" => [ "P1" ], "relevance_to_goal" => "relevant"
        },
        relevance_to_goal: "relevant"
      })
    end
    answer_service ||= lambda do |**kwargs|
      @answer_requests << kwargs
      OpenStruct.new(call: { answer: "La placa dice P1. La guía identifica el panel [1].",
                             citations: [ { "page" => 8, "number" => 1 } ] })
    end
    replace_method(S3DocumentsService, :new, ->(*) { storage }) do
      replace_method(ImageCompressionService, :compress_with_thumbnail, compression) do
        replace_method(FieldPhotoAnalysisService, :new, vision) do
          replace_method(Rag::PhotoQuestionAnswerService, :new, answer_service) { yield }
        end
      end
    end
  end

  def replace_method(klass, name, implementation)
    original = klass.method(name)
    klass.define_singleton_method(name) { |*args, **kwargs| implementation.call(*args, **kwargs) }
    yield
  ensure
    klass.define_singleton_method(name, original)
  end
end
