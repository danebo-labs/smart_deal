# frozen_string_literal: true

require "test_helper"

class KbDocumentThumbnailFromS3Test < ActiveSupport::TestCase
  setup do
    @kb_doc = KbDocument.create!(
      s3_key:       "bulk_uploads/2026-05-22/field_photo.jpeg",
      display_name: "Field photo"
    )
  end

  test "call succeeds when S3 blob is tagged UTF-8 but contains binary JPEG bytes" do
    # JPEG SOI + bytes that are invalid in UTF-8 — S3 SDK may tag .read as UTF-8.
    jpeg_like = "\xFF\xD8\xFF\xE0".b + ("x" * 100)

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:download) { |_key| jpeg_like.dup.force_encoding(Encoding::UTF_8) }

    original_new = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { |_bucket_name = nil| fake_s3 }

    original_compress = ImageCompressionService.method(:compress_with_thumbnail)
    ImageCompressionService.define_singleton_method(:compress_with_thumbnail) do |_b64, _ct|
      {
        thumbnail_binary:       "jpeg-thumb",
        thumbnail_content_type: "image/jpeg",
        thumbnail_width:        88,
        thumbnail_height:       66
      }
    end

    KbDocumentThumbnailFromS3.call(@kb_doc)
    @kb_doc.reload
    assert @kb_doc.thumbnail.present?
    assert_equal "jpeg-thumb", @kb_doc.thumbnail.data
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
    ImageCompressionService.define_singleton_method(:compress_with_thumbnail) { |*args| original_compress.call(*args) }
  end
end
