# frozen_string_literal: true

require "test_helper"

class QueryOrchestratorServiceTest < ActiveSupport::TestCase
  test "upload_and_sync_attachments creates KbDocument + thumbnail synchronously" do
    image = {
      data:                   Base64.strict_encode64("fake-jpeg-bytes"),
      media_type:             "image/jpeg",
      filename:               "test.jpg",
      binary:                 "fake-jpeg-bytes",
      thumbnail_binary:       "thumb-bytes",
      thumbnail_content_type: "image/jpeg",
      thumbnail_width:        88,
      thumbnail_height:       66
    }

    stub_s3_upload("uploads/2026-04-30/test.jpg") do
      stub_kb_sync_service do
        svc = QueryOrchestratorService.new("", images: [ image ])
        assert_difference -> { KbDocument.count }, +1 do
          assert_difference -> { KbDocumentThumbnail.count }, +1 do
            svc.send(:upload_and_sync_attachments)
          end
        end
      end
    end

    kb = KbDocument.find_by!(s3_key: "uploads/2026-04-30/test.jpg")
    assert_equal "thumb-bytes", kb.thumbnail.data
    assert_equal 88, kb.thumbnail.width
  end

  test "upload_and_sync_attachments is idempotent (re-upload same key)" do
    KbDocument.create!(s3_key: "uploads/2026-04-30/test.jpg", display_name: "test")
    image = {
      data:             Base64.strict_encode64("x"),
      media_type:       "image/jpeg",
      filename:         "test.jpg",
      binary:           "x",
      thumbnail_binary: "tb"
    }

    stub_s3_upload("uploads/2026-04-30/test.jpg") do
      stub_kb_sync_service do
        svc = QueryOrchestratorService.new("", images: [ image ])
        assert_no_difference -> { KbDocument.count } do
          svc.send(:upload_and_sync_attachments)
        end
      end
    end
  end

  private

  def stub_s3_upload(returned_key)
    original = S3DocumentsService.instance_method(:upload_file)
    S3DocumentsService.define_method(:upload_file) { |*_a| returned_key }
    yield
  ensure
    S3DocumentsService.define_method(:upload_file, original)
  end

  def stub_kb_sync_service
    original = KbSyncService.instance_method(:sync!)
    KbSyncService.define_method(:sync!) { |**_a| nil }
    yield
  ensure
    KbSyncService.define_method(:sync!, original)
  end
end
