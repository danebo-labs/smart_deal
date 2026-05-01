# frozen_string_literal: true

require "test_helper"

class UploadAndSyncAttachmentsJobTest < ActiveJob::TestCase
  test "enqueues on default queue" do
    assert_enqueued_with(job: UploadAndSyncAttachmentsJob, queue: "default") do
      UploadAndSyncAttachmentsJob.perform_later(
        images_payload: [], documents_payload: [], conv_session_id: nil, tenant_id: nil
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
      images_payload: image_payload, documents_payload: [], conv_session_id: nil, tenant_id: nil
    )

    assert_equal 1, captured_images.size
    img = captured_images.first
    assert_equal "tiny-bytes", img[:thumbnail_binary],  "thumbnail_binary must be base64-decoded back inside the job"
    assert_nil img[:thumbnail_data], "thumbnail_data marker must be cleaned up"
  ensure
    QueryOrchestratorService.define_method(:upload_and_sync_attachments, orig_method)
  end

  test "perform tolerates missing conv_session_id / tenant_id (e.g. early adopters)" do
    captured = nil
    orig_method = QueryOrchestratorService.instance_method(:upload_and_sync_attachments)
    QueryOrchestratorService.define_method(:upload_and_sync_attachments) do
      captured = {
        conv_session: instance_variable_get(:@conv_session),
        tenant:       instance_variable_get(:@tenant)
      }
      []
    end

    UploadAndSyncAttachmentsJob.perform_now(
      images_payload: [], documents_payload: [], conv_session_id: 9_999_999, tenant_id: nil
    )

    assert_nil captured[:conv_session], "non-existent conv_session_id must resolve to nil, not raise"
    assert_nil captured[:tenant]
  ensure
    QueryOrchestratorService.define_method(:upload_and_sync_attachments, orig_method)
  end
end
