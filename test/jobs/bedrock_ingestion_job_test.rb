# frozen_string_literal: true

require "test_helper"

class BedrockIngestionJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper

  def with_mock_ingestion_service(job_status_results)
    call_index = 0
    mock_service = Object.new
    mock_service.define_singleton_method(:job_status) do |_job_id|
      result = job_status_results[call_index] || job_status_results.last
      call_index += 1
      result
    end
    mock_service.define_singleton_method(:clear_when_complete) { |_job_id| true }
    mock_service.define_singleton_method(:failure_reasons) { |_job_id| [] }

    original_new = IngestionStatusService.method(:new)
    IngestionStatusService.define_singleton_method(:new) { |*_args| mock_service }
    yield
  ensure
    IngestionStatusService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  def stub_twilio_client
    sent = []
    messages_resource = Object.new
    messages_resource.define_singleton_method(:create) { |**kwargs| sent << kwargs }
    client = Object.new
    client.define_singleton_method(:messages) { messages_resource }
    original_new = Twilio::REST::Client.method(:new)
    Twilio::REST::Client.define_singleton_method(:new) { |*_a| client }
    yield sent
  ensure
    Twilio::REST::Client.define_singleton_method(:new) { |*a| original_new.call(*a) }
  end

  test "enqueues correctly" do
    assert_enqueued_with(job: BedrockIngestionJob, args: [ "job-123", [ "doc.txt" ] ]) do
      BedrockIngestionJob.perform_later("job-123", [ "doc.txt" ])
    end
  end

  test "broadcasts indexed when job completes successfully" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      assert_equal 1, messages.size
      assert_equal "indexed", messages.first["status"]
      assert_equal [ "doc.txt" ], messages.first["filenames"]
      assert_includes messages.first["message"], "doc.txt"
    end
  end

  test "broadcasts failed when job status is FAILED" do
    with_mock_ingestion_service(%w[FAILED]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      assert_equal 1, messages.size
      assert_equal "failed", messages.first["status"]
    end
  end

  test "skips perform when ingestion_job_id is blank" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      assert_no_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now(nil, [ "doc.txt" ])
      end
    end
  end

  test "polls until COMPLETE" do
    with_mock_ingestion_service(%w[IN_PROGRESS IN_PROGRESS COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      assert_equal 1, messages.size
      assert_equal "indexed", messages.first["status"]
    end
  end

  test "sends generic indexed WhatsApp message per file with filename" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      stub_twilio_client do |sent|
        with_env('TWILIO_ACCOUNT_SID' => 'ACtest', 'TWILIO_AUTH_TOKEN' => 'tok') do
          BedrockIngestionJob.perform_now(
            "job-123", [ "wa_20260323_214702_0.jpeg" ],
            kb_id: "kb-1", whatsapp_from: "whatsapp:+1", whatsapp_to: "whatsapp:+2"
          )
        end

        assert_equal 1, sent.size
        expected = I18n.t("rag.whatsapp_indexed_generic", filename: "wa_20260323_214702_0.jpeg")
        assert_equal expected, sent.first[:body]
      end
    end
  end

  test "sends one WhatsApp message per uploaded filename" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      stub_twilio_client do |sent|
        with_env('TWILIO_ACCOUNT_SID' => 'ACtest', 'TWILIO_AUTH_TOKEN' => 'tok') do
          BedrockIngestionJob.perform_now(
            "job-123", %w[a.pdf b.pdf],
            kb_id: "kb-1", whatsapp_from: "whatsapp:+1", whatsapp_to: "whatsapp:+2"
          )
        end

        assert_equal 2, sent.size
        assert_equal I18n.t("rag.whatsapp_indexed_generic", filename: "a.pdf"), sent[0][:body]
        assert_equal I18n.t("rag.whatsapp_indexed_generic", filename: "b.pdf"), sent[1][:body]
      end
    end
  end

  # ─── Entity registration on ingestion ─────────────────────────────────────────

  test "registers entity with semantic aliases when ChunkAliasExtractor succeeds" do
    session = ConversationSession.create!(
      identifier: "whatsapp:+99900000001",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor({ canonical_name: "Junction Box Car Top", aliases: [ "DRG 6061-05-014", "Car Top Junction Box" ] }) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        stub_twilio_client do |sent|
          with_env('TWILIO_ACCOUNT_SID' => 'ACtest', 'TWILIO_AUTH_TOKEN' => 'tok') do
            BedrockIngestionJob.perform_now(
              "job-123", [ "wa_20260323_214702_0.jpeg" ],
              kb_id: "kb-test", whatsapp_from: "whatsapp:+1", whatsapp_to: "whatsapp:+2",
              conv_session_id: session.id
            )
          end

          session.reload
          entity = session.active_entities["Junction Box Car Top"]
          assert_not_nil entity, "Entity should be registered with semantic key"
          assert_equal "chunk_aliases", entity["extraction_method"]
          assert_equal "Junction Box Car Top", entity["canonical_name"]
          assert_equal "wa_20260323_214702_0.jpeg", entity["wa_filename"]
          assert_includes entity["aliases"], "DRG 6061-05-014"
          assert_includes entity["aliases"], "Car Top Junction Box"
          assert_includes entity["aliases"], "wa_20260323_214702_0.jpeg"
          assert_includes entity["aliases"], "wa_20260323_214702_0"

          assert_includes sent.first[:body], "Junction Box Car Top"
        end
      end
    end
  end

  test "registers placeholder entity when ChunkAliasExtractor returns nil" do
    session = ConversationSession.create!(
      identifier: "whatsapp:+99900000002",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor(nil) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        stub_twilio_client do |sent|
          with_env('TWILIO_ACCOUNT_SID' => 'ACtest', 'TWILIO_AUTH_TOKEN' => 'tok') do
            BedrockIngestionJob.perform_now(
              "job-123", [ "wa_20260323_214702_0.jpeg" ],
              kb_id: "kb-test", whatsapp_from: "whatsapp:+1", whatsapp_to: "whatsapp:+2",
              conv_session_id: session.id
            )
          end

          session.reload
          entity = session.active_entities["wa_20260323_214702_0"]
          assert_not_nil entity
          assert_equal "pending_first_query", entity["extraction_method"]

          expected = I18n.t("rag.whatsapp_indexed_generic", filename: "wa_20260323_214702_0.jpeg")
          assert_equal expected, sent.first[:body]
        end
      end
    end
  end

  private

  def with_mock_chunk_extractor(result)
    mock = Object.new
    mock.define_singleton_method(:call) { |_wa_filename| result }
    original_new = ChunkAliasExtractor.method(:new)
    ChunkAliasExtractor.define_singleton_method(:new) { |**_kwargs| mock }
    yield
  ensure
    ChunkAliasExtractor.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) }
  end

  def with_env(vars)
    original = {}
    vars.each_key { |k| original[k] = ENV[k.to_s] }
    vars.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    vars.each_key { |k| original[k].nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = original[k] }
  end
end
