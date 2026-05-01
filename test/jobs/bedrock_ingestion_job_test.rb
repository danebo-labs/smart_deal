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
      payload = messages.first
      assert_equal "indexed",       payload["status"]
      assert_equal [ "doc.txt" ],   payload["filenames"]
      # New contract: message uses canonical_name (stem without extension);
      # raw filename is preserved in payload["filenames"] for the UI to render.
      assert_equal "doc",           payload["canonical_name"]
      assert_equal [],              payload["aliases"]
      assert_includes payload["message"], "doc"
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
    skip "WA channel disabled for MVP — notify_whatsapp removed from BedrockIngestionJob"
  end

  test "sends one WhatsApp message per uploaded filename" do
    skip "WA channel disabled for MVP — notify_whatsapp removed from BedrockIngestionJob"
  end

  # ─── Auto-pin on ingestion ────────────────────────────────────────────────────

  test "auto-pins kb_doc into session when kb_document_ids provided" do
    wa_filename = "wa_20260323_214702_0.jpeg"
    s3_key      = "uploads/2026-03-23/#{wa_filename}"
    kb_doc      = KbDocument.create!(s3_key: s3_key, display_name: "Junction Box Car Top", aliases: [])
    session     = ConversationSession.create!(
      identifier: "whatsapp:+99900000001",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor({ canonical_name: "Junction Box Car Top", aliases: [ "DRG 6061-05-014" ] }) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        BedrockIngestionJob.perform_now(
          "job-123", [ wa_filename ],
          kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb_doc.id ]
        )
      end
    end

    session.reload
    assert_includes SessionContextBuilder.entity_s3_uris(session), kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
  end

  test "skips register_entity when no kb_document_id provided" do
    session = ConversationSession.create!(
      identifier: "whatsapp:+99900000002",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor(nil) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        BedrockIngestionJob.perform_now(
          "job-123", [ "wa_20260323_214702_0.jpeg" ],
          kb_id: "kb-test", conv_session_id: session.id
          # no kb_document_ids → kb_doc will be nil → register_entity skips
        )
      end
    end

    session.reload
    assert_empty session.active_entities
  end

  # ─── TechnicianDocument insertion on ingestion ────────────────────────────────

  test "inserts TechnicianDocument with canonical_name after successful ingestion with aliases" do
    TechnicianDocument.delete_all
    wa_filename = "wa_20260410_174231_0.jpeg"
    s3_key      = "uploads/2026-04-10/#{wa_filename}"
    kb_doc      = KbDocument.find_or_create_by!(s3_key: s3_key) { |d| d.display_name = "old" }
    session     = ConversationSession.create!(
      identifier: "whatsapp:+99900000003",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor({ canonical_name: "Gearless Traction Machine", aliases: [ "gearless", "sheave assembly" ] }) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        BedrockIngestionJob.perform_now(
          "job-123", [ wa_filename ],
          kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb_doc.id ]
        )
      end
    end

    td = TechnicianDocument.find_by(
      identifier:     session.identifier,
      channel:        session.channel,
      canonical_name: "Gearless Traction Machine"
    )
    assert_not_nil td, "TechnicianDocument should be created immediately after ingestion"
    assert_equal "field_image", td.doc_type
    assert td.source_uri.include?(wa_filename)
  end

  test "notify_indexed auto-pins kb_doc into session" do
    session = ConversationSession.find_or_create_for(identifier: "ing-user", channel: "web")
    kb_doc  = KbDocument.create!(s3_key: "uploads/2026/ing.jpg", display_name: "Ing", aliases: [])

    job = BedrockIngestionJob.new
    job.define_singleton_method(:extract_aliases) { |_, _| nil }
    job.define_singleton_method(:enrich_kb_document) { |*| nil }
    job.define_singleton_method(:broadcast_indexed) { |*| nil }
    job.define_singleton_method(:persist_to_technician_documents) { |*| nil }

    job.send(:notify_indexed, [ "ing.jpg" ], kb_id: nil, conv_session_id: session.id, kb_document_ids: [ kb_doc.id ])
    session.reload

    assert_includes SessionContextBuilder.entity_s3_uris(session), kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
  end

  test "inserts placeholder TechnicianDocument when ChunkAliasExtractor returns nil but kb_doc provided" do
    TechnicianDocument.delete_all
    wa_filename = "wa_20260410_180000_0.jpeg"
    s3_key      = "uploads/2026-04-10/#{wa_filename}"
    kb_doc      = KbDocument.create!(s3_key: s3_key, display_name: "wa 20260410 180000 0", aliases: [])
    session     = ConversationSession.create!(
      identifier: "whatsapp:+99900000004",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor(nil) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        BedrockIngestionJob.perform_now(
          "job-123", [ wa_filename ],
          kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb_doc.id ]
        )
      end
    end

    td = TechnicianDocument.find_by(
      identifier: session.identifier,
      channel:    session.channel,
      canonical_name: "wa_20260410_180000_0"
    )
    assert_not_nil td, "Placeholder TechnicianDocument should be created when kb_doc present"
    assert_equal "field_image", td.doc_type
  end

  test "skips TechnicianDocument insertion when no session" do
    TechnicianDocument.delete_all
    with_mock_ingestion_service(%w[COMPLETE]) do
      BedrockIngestionJob.perform_now("job-123", [ "wa_20260410_190000_0.jpeg" ])
    end
    assert_equal 0, TechnicianDocument.count
  end

  # ─── KbDocument enrichment on ingestion ──────────────────────────────────────

  # ─── upsert_kb_document: creates on first success, updates on re-run ─────────

  test "creates KbDocument with canonical name after successful ingestion" do
    wa_filename = "wa_20260410_174231_0.jpeg"
    s3_key      = "uploads/2026-04-10/#{wa_filename}"
    kb          = KbDocument.create!(s3_key: s3_key, display_name: "wa 20260410 174231 0")

    session = ConversationSession.create!(
      identifier: "whatsapp:+99900000005",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor({ canonical_name: "Gearless Traction Machine", aliases: [ "sheave" ] }) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        assert_no_difference -> { KbDocument.count } do
          BedrockIngestionJob.perform_now(
            "job-123", [ wa_filename ],
            kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb.id ]
          )
        end
      end
    end

    kb.reload
    assert_equal "Gearless Traction Machine", kb.display_name
    assert_includes kb.aliases, "sheave"
  end

  test "upserts KbDocument when row already exists (idempotent re-run)" do
    wa_filename = "wa_20260410_174231_0.jpeg"
    s3_key      = "uploads/2026-04-10/#{wa_filename}"
    kb          = KbDocument.create!(s3_key: s3_key, display_name: "wa 20260410 174231 0", aliases: [])

    session = ConversationSession.create!(
      identifier: "whatsapp:+99900000005b",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor({ canonical_name: "Gearless Traction Machine", aliases: [ "sheave" ] }) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        assert_no_difference -> { KbDocument.count } do
          BedrockIngestionJob.perform_now(
            "job-123", [ wa_filename ],
            kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb.id ]
          )
        end
      end
    end

    kb.reload
    assert_equal "Gearless Traction Machine", kb.display_name
    assert_includes kb.aliases, "sheave"
  end

  test "creates KbDocument with stem name when no session (no alias extraction)" do
    wa_filename = "wa_20260410_190000_0.jpeg"
    s3_key      = "uploads/2026-04-10/#{wa_filename}"

    with_mock_ingestion_service(%w[COMPLETE]) do
      assert_difference -> { KbDocument.count }, +1 do
        BedrockIngestionJob.perform_now("job-123", [ wa_filename ])
      end
    end

    kb = KbDocument.find_by!(s3_key: s3_key)
    assert_equal "wa 20260410 190000 0", kb.display_name
    assert_equal [], kb.aliases
  end

  test "canonical from Opus replaces web-uploaded human stem as display_name; stem becomes alias" do
    web_filename = "Esquema SOPREL.pdf"
    s3_key       = "uploads/#{Date.current.iso8601}/#{web_filename}"
    kb           = KbDocument.create!(s3_key: s3_key, display_name: "Esquema SOPREL", aliases: [])
    session      = ConversationSession.create!(
      identifier: "web:user-web-1",
      channel:    "web",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor({ canonical_name: "Foremcaro 6118/81", aliases: [ "Esquema Eléctrico" ] }) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        BedrockIngestionJob.perform_now(
          "job-web", [ web_filename ],
          kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb.id ]
        )
      end
    end

    kb.reload
    assert_equal "Foremcaro 6118/81", kb.display_name
    assert_includes kb.aliases, "Esquema SOPREL"
    assert_includes kb.aliases, "Esquema Eléctrico"
  end

  test "does not store the machine stem as an alias for wa_* filenames" do
    wa_filename = "wa_20260410_200000_0.jpeg"
    s3_key      = "uploads/2026-04-10/#{wa_filename}"
    kb          = KbDocument.create!(s3_key: s3_key, display_name: "wa 20260410 200000 0")
    session     = ConversationSession.create!(
      identifier: "whatsapp:+99900000009",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    with_mock_chunk_extractor({ canonical_name: "Brake Assembly", aliases: [ "caliper" ] }) do
      with_mock_ingestion_service(%w[COMPLETE]) do
        assert_no_difference -> { KbDocument.count } do
          BedrockIngestionJob.perform_now(
            "job-wa", [ wa_filename ],
            kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb.id ]
          )
        end
      end
    end

    kb.reload
    assert_equal "Brake Assembly", kb.display_name
    assert_includes kb.aliases, "caliper"
    assert_not_includes kb.aliases, "wa 20260410 200000 0",
                        "Machine-generated stems must never be stored as human-searchable aliases"
  end

  # ─── build_indexed_notification fix ─────────────────────────────────────────

  test "sends canonical_only notification when result has no aliases" do
    skip "WA channel disabled for MVP — build_indexed_notification removed from BedrockIngestionJob"
  end

  test "sends with_aliases notification when result has aliases" do
    skip "WA channel disabled for MVP — build_indexed_notification removed from BedrockIngestionJob"
  end

  # ─── Thumbnail responsibility moved to orchestrator ──────────────────────────

  test "job does not touch thumbnails (responsibility moved to orchestrator)" do
    filename = "chat_20260430_000001_0.jpeg"
    s3_key   = "uploads/2026-04-30/#{filename}"
    kb_doc   = KbDocument.create!(s3_key: s3_key, display_name: "test")

    with_mock_ingestion_service(%w[COMPLETE]) do
      assert_no_difference -> { KbDocumentThumbnail.count } do
        BedrockIngestionJob.perform_now("job-x", [ filename ], kb_document_ids: [ kb_doc.id ])
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
