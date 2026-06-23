# frozen_string_literal: true

require "test_helper"

class UploadAndSyncAttachmentsJobTest < ActiveJob::TestCase
  setup do
    @account = Account.create!(slug: "upload-job-test-#{SecureRandom.hex(4)}")
    @document_uid = SecureRandom.uuid
  end

  test "enqueues on default queue" do
    assert_enqueued_with(job: UploadAndSyncAttachmentsJob, queue: "default") do
      UploadAndSyncAttachmentsJob.perform_later(
        images_payload: [], documents_payload: [], conv_session_id: nil,
        account_id: @account.id, document_uid: @document_uid
      )
    end
  end

  test "prepare_images_for_async strips :binary and base64-wraps :thumbnail_binary" do
    img = {
      data:                   Base64.strict_encode64("compressed-jpeg"),
      media_type:             "image/jpeg",
      filename:               "field.jpg",
      binary:                 "compressed-jpeg",
      thumbnail_binary:       "tiny-bytes",
      thumbnail_content_type: "image/jpeg",
      thumbnail_width:        88,
      thumbnail_height:       66
    }

    sanitized = UploadAndSyncAttachmentsJob.prepare_images_for_async([ img ]).first

    assert_nil sanitized[:binary],            ":binary must be stripped (re-derivable from :data)"
    assert_nil sanitized[:thumbnail_binary],  ":thumbnail_binary must be removed in favor of :thumbnail_data"
    assert_equal Base64.strict_encode64("tiny-bytes"), sanitized[:thumbnail_data]
    assert_equal "field.jpg",  sanitized[:filename]
    assert_equal "image/jpeg", sanitized[:thumbnail_content_type]
  end

  test "perform reconstructs binary fields and delegates to upload_and_sync_attachments" do
    image_payload = UploadAndSyncAttachmentsJob.prepare_images_for_async([ {
      data:                   Base64.strict_encode64("compressed-jpeg"),
      media_type:             "image/jpeg",
      filename:               "field.jpg",
      binary:                 "compressed-jpeg",
      thumbnail_binary:       "tiny-bytes",
      thumbnail_content_type: "image/jpeg",
      thumbnail_width:        88,
      thumbnail_height:       66
    } ])

    captured_images = nil
    orig_method = QueryOrchestratorService.instance_method(:upload_and_sync_attachments)
    QueryOrchestratorService.define_method(:upload_and_sync_attachments) do
      captured_images = instance_variable_get(:@images)
      []
    end

    UploadAndSyncAttachmentsJob.perform_now(
      images_payload: image_payload, documents_payload: [], conv_session_id: nil,
      account_id: @account.id, document_uid: @document_uid
    )

    assert_equal 1, captured_images.size
    img = captured_images.first
    assert_equal "tiny-bytes", img[:thumbnail_binary],  "thumbnail_binary must be base64-decoded back inside the job"
    assert_nil img[:thumbnail_data], "thumbnail_data marker must be cleaned up"
  ensure
    QueryOrchestratorService.define_method(:upload_and_sync_attachments, orig_method)
  end

  test "broadcasts failed when upload raises and re-raises for retry" do
    orig_method = QueryOrchestratorService.instance_method(:upload_and_sync_attachments)
    QueryOrchestratorService.define_method(:upload_and_sync_attachments) do
      raise RuntimeError, "boom"
    end

    broadcasts = []
    orig_broadcast = ActionCable.server.method(:broadcast)
    ActionCable.server.define_singleton_method(:broadcast) do |channel, payload|
      broadcasts << payload if channel == "kb_sync"
    end

    images_payload = UploadAndSyncAttachmentsJob.prepare_images_for_async([
      { data: Base64.strict_encode64("x"), media_type: "image/jpeg", filename: "a.jpg", binary: "x" }
    ])
    docs_payload = [ { filename: "b.pdf", data: Base64.strict_encode64("y"), media_type: "application/pdf" } ]

    assert_raises(RuntimeError) do
      UploadAndSyncAttachmentsJob.perform_now(
        images_payload: images_payload, documents_payload: docs_payload, conv_session_id: nil,
        account_id: @account.id, document_uid: @document_uid
      )
    end

    failed = broadcasts.find { |b| b[:status] == "failed" }
    assert failed, "expected a failed broadcast"
    assert_includes failed[:filenames], "a.jpg"
    assert_includes failed[:filenames], "b.pdf"
    assert_equal "upload_error", failed[:reason]
  ensure
    QueryOrchestratorService.define_method(:upload_and_sync_attachments, orig_method)
    ActionCable.server.define_singleton_method(:broadcast, orig_broadcast)
  end

  test "perform tolerates missing conv_session_id" do
    captured = nil
    orig_method = QueryOrchestratorService.instance_method(:upload_and_sync_attachments)
    QueryOrchestratorService.define_method(:upload_and_sync_attachments) do
      captured = {
        conv_session: instance_variable_get(:@conv_session),
        account:      instance_variable_get(:@account)
      }
      []
    end

    UploadAndSyncAttachmentsJob.perform_now(
      images_payload: [], documents_payload: [], conv_session_id: 9_999_999,
      account_id: @account.id, document_uid: @document_uid
    )

    assert_nil captured[:conv_session], "non-existent conv_session_id must resolve to nil, not raise"
    assert_equal @account, captured[:account]
  ensure
    QueryOrchestratorService.define_method(:upload_and_sync_attachments, orig_method)
  end

  test "bad account_id raises so Solid Queue can mark retry/failure" do
    assert_raises(ActiveRecord::RecordNotFound) do
      UploadAndSyncAttachmentsJob.perform_now(
        images_payload: [], documents_payload: [], conv_session_id: nil,
        account_id: 9_999_999, document_uid: @document_uid
      )
    end
  end

  test "perform forwards locale into QueryOrchestratorService" do
    captured_locale = nil
    orig_init   = QueryOrchestratorService.instance_method(:initialize)
    orig_upload = QueryOrchestratorService.instance_method(:upload_and_sync_attachments)

    QueryOrchestratorService.define_method(:initialize) do |question, **kwargs|
      captured_locale = kwargs[:locale]
      orig_init.bind(self).call(question, **kwargs)
    end
    QueryOrchestratorService.define_method(:upload_and_sync_attachments) { [] }

    UploadAndSyncAttachmentsJob.perform_now(
      images_payload: [], documents_payload: [], conv_session_id: nil,
      account_id: @account.id, document_uid: @document_uid, locale: "es"
    )

    assert_equal "es", captured_locale
  ensure
    QueryOrchestratorService.define_method(:initialize, orig_init)
    QueryOrchestratorService.define_method(:upload_and_sync_attachments, orig_upload)
  end

  test "perform forwards original query into QueryOrchestratorService" do
    captured_query = nil
    orig_init   = QueryOrchestratorService.instance_method(:initialize)
    orig_upload = QueryOrchestratorService.instance_method(:upload_and_sync_attachments)

    QueryOrchestratorService.define_method(:initialize) do |question, **kwargs|
      captured_query = question
      orig_init.bind(self).call(question, **kwargs)
    end
    QueryOrchestratorService.define_method(:upload_and_sync_attachments) { [] }

    UploadAndSyncAttachmentsJob.perform_now(
      images_payload: [],
      documents_payload: [],
      conv_session_id: nil,
      account_id: @account.id,
      document_uid: @document_uid,
      locale: "es",
      query: "Necesito revisar el freno"
    )

    assert_equal "Necesito revisar el freno", captured_query
  ensure
    QueryOrchestratorService.define_method(:initialize, orig_init)
    QueryOrchestratorService.define_method(:upload_and_sync_attachments, orig_upload)
  end

  # P-13: session belonging to a different account raises AccountOwnershipError (no SQ retry)
  test "P-13: session owned by another account raises AccountOwnershipError and does not re-raise" do
    other_account = Account.create!(slug: "upload-p13-other-#{SecureRandom.hex(4)}")
    session = ConversationSession.create!(
      identifier:  "p13-session",
      channel:     "web",
      account_id:  other_account.id,
      expires_at:  30.days.from_now
    )

    broadcasts = []
    orig_broadcast = ActionCable.server.method(:broadcast)
    ActionCable.server.define_singleton_method(:broadcast) { |ch, pl| broadcasts << pl }

    # Must NOT raise (AccountOwnershipError is swallowed + broadcast)
    assert_nothing_raised do
      UploadAndSyncAttachmentsJob.perform_now(
        images_payload:    [],
        documents_payload: [],
        conv_session_id:   session.id,
        account_id:        @account.id,
        document_uid:      @document_uid
      )
    end

    failed = broadcasts.find { |b| b[:status] == "failed" }
    assert failed, "expected a failed broadcast when session account mismatches"
  ensure
    ActionCable.server.define_singleton_method(:broadcast, orig_broadcast)
  end

  # P-18: document_uid from the same request is stable across retries
  test "P-18: same document_uid + account produce the same S3 key on retry" do
    uid = SecureRandom.uuid
    keys_seen = []

    orig_init   = QueryOrchestratorService.instance_method(:initialize)
    orig_upload = QueryOrchestratorService.instance_method(:upload_and_sync_attachments)

    QueryOrchestratorService.define_method(:initialize) do |question, **kwargs|
      orig_init.bind(self).call(question, **kwargs)
    end
    QueryOrchestratorService.define_method(:upload_and_sync_attachments) do
      pipeline = instance_variable_get(:@documents).first
      keys_seen << "uploads/#{instance_variable_get(:@account).id}/#{instance_variable_get(:@document_uids)&.first}"
      []
    end

    2.times do
      UploadAndSyncAttachmentsJob.perform_now(
        images_payload: [], documents_payload: [], conv_session_id: nil,
        account_id: @account.id, document_uid: uid
      )
    end

    assert_equal 2, keys_seen.size
    assert_equal 1, keys_seen.uniq.size, "same uid retried must produce same S3 path"
  ensure
    QueryOrchestratorService.define_method(:initialize, orig_init)
    QueryOrchestratorService.define_method(:upload_and_sync_attachments, orig_upload)
  end
end
