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

  test "broadcasts indexed includes summary when web_v1_metadata provides it" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      metadata = [ {
        "filename"       => "photo.jpg",
        "canonical_name" => "Schindler 5500 controller",
        "aliases"        => [ "5500", "controller" ],
        "summary"        => "Foto del cuadro de maniobras Schindler 5500."
      } ]
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now(
          "job-123", [ "photo.jpg" ],
          web_v1_metadata: metadata
        )
      end
      payload = messages.first
      assert_equal "indexed", payload["status"]
      assert_match(/Schindler 5500/, payload["summary"])
    end
  end

  test "broadcasts indexed has nil summary when metadata absent (legacy fallback)" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      assert_nil messages.first["summary"]
    end
  end

  test "broadcasts indexed includes companion_offer when web_v1_metadata provides it" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      metadata = [ {
        "filename"        => "photo.jpg",
        "canonical_name"  => "Schindler 5500 controller",
        "aliases"         => [ "5500" ],
        "summary"         => "Parece el cuadro de un Schindler.",
        "companion_offer" => "Pregúntame lo que necesites, aunque sea con pocas palabras."
      } ]
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now(
          "job-123", [ "photo.jpg" ],
          web_v1_metadata: metadata
        )
      end
      payload = messages.first
      assert_equal "indexed", payload["status"]
      assert_match(/Pregúntame/, payload["companion_offer"])
    end
  end

  test "broadcasts urgent page indexed payload and marks urgent ledger complete" do
    filename = "manual.pdf"
    kb_doc = KbDocument.create!(s3_key: "uploads/#{Date.current.iso8601}/#{filename}", display_name: "manual")
    batch = WebManualBatch.create!(
      s3_key: kb_doc.s3_key,
      filename: filename,
      sha256: Digest::SHA256.hexdigest("manual"),
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      status: "submitted",
      urgent_status: "syncing",
      urgent_pages: [ 2, 5 ],
      kb_document_id: kb_doc.id
    )
    metadata = [ {
      "filename" => filename,
      "canonical_name" => "Manual Rescue",
      "aliases" => [ "rescue" ],
      "processing_scope" => "urgent_pages",
      "selected_pages" => [ 2, 5 ],
      "total_pages" => 8,
      "web_manual_batch_id" => batch.id
    } ]

    with_mock_ingestion_service(%w[COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now(
          "job-urgent", [ filename ],
          kb_document_ids: [ kb_doc.id ],
          web_v1_metadata: metadata
        )
      end
      payload = messages.first
      assert_equal "indexed", payload["status"]
      assert_equal "urgent_pages", payload["processing_scope"]
      assert_equal [ 2, 5 ], payload["selected_pages"]
      assert_includes payload["message"], "Páginas urgentes"
    end

    batch.reload
    assert_equal "complete", batch.urgent_status
    assert_not_nil batch.urgent_completed_at
  end

  test "broadcasts indexed has nil companion_offer when metadata absent" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      assert_nil messages.first["companion_offer"]
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

  test "polls until COMPLETE (legacy mode)" do
    # Multi-poll behavior is legacy-mode only. With INGESTION_REENQUEUE=true
    # (production default) a single perform sees IN_PROGRESS → re-enqueues
    # itself; that path is covered by the dedicated re-enqueue tests below.
    with_env(INGESTION_REENQUEUE: "false") do
      with_mock_ingestion_service(%w[IN_PROGRESS IN_PROGRESS COMPLETE]) do
        messages = capture_broadcasts("kb_sync") do
          BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
        end
        assert_equal 1, messages.size
        assert_equal "indexed", messages.first["status"]
      end
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
    filename = "junction_box.jpeg"
    s3_key   = "uploads/#{Date.current.iso8601}/#{filename}"
    kb_doc   = KbDocument.create!(s3_key: s3_key, display_name: "Junction Box Car Top", aliases: [])
    session  = ConversationSession.create!(
      identifier: "whatsapp:+99900000001",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    metadata = [ { "filename" => filename, "canonical_name" => "Junction Box Car Top", "aliases" => [ "DRG 6061-05-014" ] } ]
    with_mock_ingestion_service(%w[COMPLETE]) do
      BedrockIngestionJob.perform_now(
        "job-123", [ filename ],
        kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb_doc.id ],
        web_v1_metadata: metadata
      )
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

    with_mock_ingestion_service(%w[COMPLETE]) do
      BedrockIngestionJob.perform_now(
        "job-123", [ "manual.jpeg" ],
        kb_id: "kb-test", conv_session_id: session.id
        # no kb_document_ids → kb_doc will be nil → register_entity skips
      )
    end

    session.reload
    assert_empty session.active_entities
  end

  # ─── TechnicianDocument insertion on ingestion ────────────────────────────────

  test "inserts TechnicianDocument with canonical_name after successful ingestion with aliases" do
    TechnicianDocument.delete_all
    filename = "gearless_machine.jpeg"
    s3_key   = "uploads/#{Date.current.iso8601}/#{filename}"
    kb_doc   = KbDocument.find_or_create_by!(s3_key: s3_key) { |d| d.display_name = "old" }
    session  = ConversationSession.create!(
      identifier: "whatsapp:+99900000003",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    metadata = [ { "filename" => filename, "canonical_name" => "Gearless Traction Machine", "aliases" => [ "gearless", "sheave assembly" ] } ]
    with_mock_ingestion_service(%w[COMPLETE]) do
      BedrockIngestionJob.perform_now(
        "job-123", [ filename ],
        kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb_doc.id ],
        web_v1_metadata: metadata
      )
    end

    td = TechnicianDocument.find_by(
      identifier:     session.identifier,
      channel:        session.channel,
      canonical_name: "Gearless Traction Machine"
    )
    assert_not_nil td, "TechnicianDocument should be created immediately after ingestion"
    assert_equal "field_image", td.doc_type
    assert td.source_uri.include?(filename)
  end

  test "notify_indexed auto-pins kb_doc into session" do
    session = ConversationSession.find_or_create_for(identifier: "ing-user", channel: "web")
    kb_doc  = KbDocument.create!(s3_key: "uploads/2026/ing.jpg", display_name: "Ing", aliases: [])

    job = BedrockIngestionJob.new
    job.define_singleton_method(:enrich_kb_document) { |*| nil }
    job.define_singleton_method(:broadcast_indexed) { |*| nil }
    job.define_singleton_method(:persist_to_technician_documents) { |*| nil }

    job.send(:notify_indexed, [ "ing.jpg" ], kb_id: nil, conv_session_id: session.id,
             kb_document_ids: [ kb_doc.id ], web_v1_metadata: nil)
    session.reload

    assert_includes SessionContextBuilder.entity_s3_uris(session), kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
  end

  test "skips TechnicianDocument insertion when no session" do
    TechnicianDocument.delete_all
    with_mock_ingestion_service(%w[COMPLETE]) do
      BedrockIngestionJob.perform_now("job-123", [ "manual_20260410_190000.jpeg" ])
    end
    assert_equal 0, TechnicianDocument.count
  end

  # ─── KbDocument enrichment via web_v1_metadata ───────────────────────────────

  test "notify_indexed uses web_v1_metadata to enrich KbDocument — no Bedrock retrieve call" do
    bedrock_invoked = false
    orig_new = defined?(Aws::BedrockAgentRuntime::Client) ? Aws::BedrockAgentRuntime::Client.method(:new) : nil
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*| bedrock_invoked = true } if defined?(Aws::BedrockAgentRuntime::Client)

    filename = "soprel_schema.pdf"
    s3_key   = "uploads/#{Date.current.iso8601}/#{filename}"
    kb_doc   = KbDocument.create!(s3_key: s3_key, display_name: "Esquema SOPREL", aliases: [])
    session  = ConversationSession.create!(
      identifier: "web:user-metadata-1",
      channel:    "web",
      expires_at: 30.minutes.from_now
    )

    metadata = [ { "filename" => filename, "canonical_name" => "Foremcaro 6118/81", "aliases" => [ "Esquema Eléctrico" ] } ]
    with_mock_ingestion_service(%w[COMPLETE]) do
      BedrockIngestionJob.perform_now(
        "job-web", [ filename ],
        kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb_doc.id ],
        web_v1_metadata: metadata
      )
    end

    assert_not bedrock_invoked, "Bedrock retrieve must NOT be called when web_v1_metadata is provided"
    kb_doc.reload
    assert_equal "Foremcaro 6118/81", kb_doc.display_name
    assert_includes kb_doc.aliases, "Esquema Eléctrico"
  ensure
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new, orig_new) if orig_new
  end

  test "notify_indexed handles filename absent from web_v1_metadata (falls back to stem)" do
    filename = "elevator_manual.pdf"
    s3_key   = "uploads/#{Date.current.iso8601}/#{filename}"
    kb_doc   = KbDocument.create!(s3_key: s3_key, display_name: "elevator manual", aliases: [])

    # web_v1_metadata present but does not include this filename (e.g. job from before deploy)
    with_mock_ingestion_service(%w[COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now(
          "job-123", [ filename ],
          kb_document_ids: [ kb_doc.id ],
          web_v1_metadata: [ { "filename" => "other_file.pdf", "canonical_name" => "Other", "aliases" => [] } ]
        )
      end
      payload = messages.first
      # canonical falls back to filename stem
      assert_equal "elevator manual", payload["canonical_name"]
    end
  end

  # ─── upsert_kb_document: creates on first success, updates on re-run ─────────

  test "creates KbDocument with canonical name after successful ingestion" do
    filename = "wa_20260410_174231_0.jpeg"
    s3_key   = "uploads/2026-04-10/#{filename}"
    kb       = KbDocument.create!(s3_key: s3_key, display_name: "wa 20260410 174231 0")
    session  = ConversationSession.create!(
      identifier: "whatsapp:+99900000005",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    metadata = [ { "filename" => filename, "canonical_name" => "Gearless Traction Machine", "aliases" => [ "sheave" ] } ]
    with_mock_ingestion_service(%w[COMPLETE]) do
      assert_no_difference -> { KbDocument.count } do
        BedrockIngestionJob.perform_now(
          "job-123", [ filename ],
          kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb.id ],
          web_v1_metadata: metadata
        )
      end
    end

    kb.reload
    assert_equal "Gearless Traction Machine", kb.display_name
    assert_includes kb.aliases, "sheave"
  end

  test "upserts KbDocument when row already exists (idempotent re-run)" do
    filename = "wa_20260410_174231_0.jpeg"
    s3_key   = "uploads/2026-04-10/#{filename}"
    kb       = KbDocument.create!(s3_key: s3_key, display_name: "wa 20260410 174231 0", aliases: [])
    session  = ConversationSession.create!(
      identifier: "whatsapp:+99900000005b",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )

    metadata = [ { "filename" => filename, "canonical_name" => "Gearless Traction Machine", "aliases" => [ "sheave" ] } ]
    with_mock_ingestion_service(%w[COMPLETE]) do
      assert_no_difference -> { KbDocument.count } do
        BedrockIngestionJob.perform_now(
          "job-123", [ filename ],
          kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb.id ],
          web_v1_metadata: metadata
        )
      end
    end

    kb.reload
    assert_equal "Gearless Traction Machine", kb.display_name
    assert_includes kb.aliases, "sheave"
  end

  test "without web_v1_metadata and no kb_document_ids: broadcast uses filename stem as canonical" do
    filename = "elevator_manual.pdf"
    with_mock_ingestion_service(%w[COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ filename ])
      end
      assert_equal 1, messages.size
      assert_equal "indexed", messages.first["status"]
      assert_equal "elevator manual", messages.first["canonical_name"]
    end
  end

  test "canonical from web_v1_metadata replaces web-uploaded stem as display_name; stem becomes alias" do
    web_filename = "Esquema SOPREL.pdf"
    s3_key       = "uploads/#{Date.current.iso8601}/#{web_filename}"
    kb           = KbDocument.create!(s3_key: s3_key, display_name: "Esquema SOPREL", aliases: [])
    session      = ConversationSession.create!(
      identifier: "web:user-web-1",
      channel:    "web",
      expires_at: 30.minutes.from_now
    )

    metadata = [ { "filename" => web_filename, "canonical_name" => "Foremcaro 6118/81", "aliases" => [ "Esquema Eléctrico" ] } ]
    with_mock_ingestion_service(%w[COMPLETE]) do
      BedrockIngestionJob.perform_now(
        "job-web", [ web_filename ],
        kb_id: "kb-test", conv_session_id: session.id, kb_document_ids: [ kb.id ],
        web_v1_metadata: metadata
      )
    end

    kb.reload
    assert_equal "Foremcaro 6118/81", kb.display_name
    assert_includes kb.aliases, "Esquema SOPREL"
    assert_includes kb.aliases, "Esquema Eléctrico"
  end

  test "send_canonical_only notification when result has no aliases" do
    skip "WA channel disabled for MVP — build_indexed_notification removed from BedrockIngestionJob"
  end

  test "sends with_aliases notification when result has aliases" do
    skip "WA channel disabled for MVP — build_indexed_notification removed from BedrockIngestionJob"
  end

  # ─── INGESTION_REENQUEUE=true: single-shot status check + re-enqueue ────────

  test "re-enqueue mode: COMPLETE finalizes and does NOT re-enqueue" do
    with_env(INGESTION_REENQUEUE: "true") do
      with_mock_ingestion_service(%w[COMPLETE]) do
        messages = capture_broadcasts("kb_sync") do
          assert_no_enqueued_jobs(only: BedrockIngestionJob) do
            BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
          end
        end
        assert_equal 1, messages.size
        assert_equal "indexed", messages.first["status"]
      end
    end
  end

  test "re-enqueue mode: IN_PROGRESS re-enqueues itself with wait 5s and propagates started_at_iso" do
    with_env(INGESTION_REENQUEUE: "true") do
      with_mock_ingestion_service(%w[IN_PROGRESS]) do
        assert_no_broadcasts("kb_sync") do
          assert_enqueued_with(job: BedrockIngestionJob) do
            BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ], kb_id: "kb-x", conv_session_id: nil, kb_document_ids: nil)
          end
        end
        enq = ActiveJob::Base.queue_adapter.enqueued_jobs.last
        kwargs = enq[:args].last
        assert_kind_of Hash, kwargs
        assert_kind_of String, kwargs["started_at_iso"], "must propagate started_at_iso so TIMEOUT spans re-enqueues"
      end
    end
  end

  test "re-enqueue mode: re-enqueue chain finalizes when subsequent perform sees COMPLETE" do
    with_env(INGESTION_REENQUEUE: "true") do
      # First perform: IN_PROGRESS → re-enqueues
      with_mock_ingestion_service(%w[IN_PROGRESS]) do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      enq = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      raw_kwargs = enq[:args].last
      # Strip ActiveJob's keyword serialization markers + map to symbol keys.
      kwargs = raw_kwargs
                 .reject { |k, _| k.to_s.start_with?("_aj_") }
                 .transform_keys(&:to_sym)

      # Second perform (the one re-enqueued): COMPLETE → finalize
      with_mock_ingestion_service(%w[COMPLETE]) do
        messages = capture_broadcasts("kb_sync") do
          BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ], **kwargs)
        end
        assert_equal 1, messages.size
        assert_equal "indexed", messages.first["status"]
      end
    end
  end

  test "re-enqueue mode: raises Timeout when started_at_iso older than TIMEOUT" do
    with_env(INGESTION_REENQUEUE: "true") do
      stale = (Time.current - (BedrockIngestionJob::TIMEOUT + 1.minute)).iso8601
      with_mock_ingestion_service(%w[IN_PROGRESS]) do
        # rescue at the job level converts Timeout::Error into a "failed" broadcast
        messages = capture_broadcasts("kb_sync") do
          BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ], started_at_iso: stale)
        end
        assert_equal "failed", messages.first["status"]
      end
    end
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

  # ─── Locale flow ─────────────────────────────────────────────────────────────

  test "broadcasts failed message in English when locale='en'" do
    with_mock_ingestion_service(%w[FAILED]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-locale-en", [ "doc.txt" ], locale: "en")
      end
      assert_equal "failed", messages.first["status"]
      assert_includes messages.first["message"], I18n.t("rag.document_indexing_failed_message", locale: :en)
    end
  end

  test "broadcasts failed message in Spanish when locale='es'" do
    with_mock_ingestion_service(%w[FAILED]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-locale-es", [ "doc.txt" ], locale: "es")
      end
      assert_equal "failed", messages.first["status"]
      assert_includes messages.first["message"], I18n.t("rag.document_indexing_failed_message", locale: :es)
    end
  end

  test "re-enqueue mode: propagates locale in re-enqueued job args" do
    with_env(INGESTION_REENQUEUE: "true") do
      with_mock_ingestion_service(%w[IN_PROGRESS]) do
        assert_enqueued_with(job: BedrockIngestionJob) do
          BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ], locale: "en")
        end
        enq    = ActiveJob::Base.queue_adapter.enqueued_jobs.last
        kwargs = enq[:args].last
        assert_equal "en", kwargs["locale"], "locale must be forwarded in re-enqueued job"
      end
    end
  end

  private

  def with_env(vars)
    original = {}
    vars.each_key { |k| original[k] = ENV[k.to_s] }
    vars.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    vars.each_key { |k| original[k].nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = original[k] }
  end
end
