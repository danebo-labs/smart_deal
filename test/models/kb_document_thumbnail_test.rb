# frozen_string_literal: true

require "test_helper"

class KbDocumentThumbnailTest < ActiveSupport::TestCase
  def build_kb_document
    KbDocument.create!(s3_key: "uploads/2026-04-30/chat_20260430_000000_0.jpg", display_name: "Test Image")
  end

  test "belongs to kb_document" do
    doc   = build_kb_document
    thumb = KbDocumentThumbnail.new(kb_document: doc, data: "fakebytes", content_type: "image/jpeg")
    assert thumb.valid?
  end

  test "requires data" do
    doc   = build_kb_document
    thumb = KbDocumentThumbnail.new(kb_document: doc, content_type: "image/jpeg")
    assert_not thumb.valid?
    assert thumb.errors[:data].any?
  end

  test "requires content_type" do
    doc   = build_kb_document
    thumb = KbDocumentThumbnail.new(kb_document: doc, data: "fakebytes", content_type: nil)
    assert_not thumb.valid?
  end

  test "data_url returns correct format" do
    doc   = build_kb_document
    thumb = KbDocumentThumbnail.new(kb_document: doc, data: "TESTBYTES", content_type: "image/jpeg")
    expected = "data:image/jpeg;base64,#{Base64.strict_encode64('TESTBYTES')}"
    assert_equal expected, thumb.data_url
  end

  test "kb_document has_one thumbnail" do
    doc   = build_kb_document
    KbDocumentThumbnail.create!(kb_document: doc, data: "fakebytes", content_type: "image/jpeg", byte_size: 9)
    assert_equal 1, doc.reload.thumbnail.class.count.tap { doc.reload }
    assert_instance_of KbDocumentThumbnail, doc.thumbnail
  end

  test "thumbnail is destroyed with kb_document" do
    doc   = build_kb_document
    thumb = KbDocumentThumbnail.create!(kb_document: doc, data: "fakebytes", content_type: "image/jpeg", byte_size: 9)
    thumb_id = thumb.id
    doc.destroy
    assert_nil KbDocumentThumbnail.find_by(id: thumb_id)
  end
end
