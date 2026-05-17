# frozen_string_literal: true

require "test_helper"

class KbDocumentThumbnailPersisterTest < ActiveSupport::TestCase
  setup do
    @kb_doc = KbDocument.create!(
      s3_key:       "uploads/test/thumb-case.jpg",
      display_name: "thumb-case",
      aliases:      []
    )
  end

  test "persists thumbnail from img hash keys" do
    img = {
      thumbnail_binary:       "jpeg-bytes",
      thumbnail_content_type: "image/jpeg",
      thumbnail_width:        88,
      thumbnail_height:       50
    }

    assert_difference -> { KbDocumentThumbnail.count }, +1 do
      KbDocumentThumbnailPersister.call(kb_doc: @kb_doc, img: img)
    end

    @kb_doc.reload
    assert_equal "jpeg-bytes", @kb_doc.thumbnail.data
    assert_equal "image/jpeg", @kb_doc.thumbnail.content_type
    assert_equal 88, @kb_doc.thumbnail.width
    assert_equal 50, @kb_doc.thumbnail.height
    assert_equal "jpeg-bytes".bytesize, @kb_doc.thumbnail.byte_size
  end

  test "supports string keys on img (job payload)" do
    img = {
      "thumbnail_binary"       => "t",
      "thumbnail_content_type" => "image/jpeg",
      "thumbnail_width"        => 10,
      "thumbnail_height"       => 8
    }

    assert_difference -> { KbDocumentThumbnail.count }, +1 do
      KbDocumentThumbnailPersister.call(kb_doc: @kb_doc, img: img)
    end
  end

  test "does nothing when thumbnail_binary is blank" do
    assert_no_difference -> { KbDocumentThumbnail.count } do
      KbDocumentThumbnailPersister.call(kb_doc: @kb_doc, img: {})
    end
    assert_no_difference -> { KbDocumentThumbnail.count } do
      KbDocumentThumbnailPersister.call(kb_doc: @kb_doc, img: { thumbnail_binary: "" })
    end
  end

  test "is idempotent when thumbnail already exists" do
    @kb_doc.create_thumbnail!(
      data:         "existing",
      content_type: "image/jpeg",
      width:        1,
      height:       1,
      byte_size:    "existing".bytesize
    )

    assert_no_difference -> { KbDocumentThumbnail.count } do
      KbDocumentThumbnailPersister.call(kb_doc: @kb_doc, img: { thumbnail_binary: "new" })
    end
    @kb_doc.reload
    assert_equal "existing", @kb_doc.thumbnail.data
  end

  test "swallows persistence errors without raising" do
    begin
      @kb_doc.define_singleton_method(:create_thumbnail!) do |**|
        raise StandardError, "simulated persistence failure"
      end

      assert_nothing_raised do
        KbDocumentThumbnailPersister.call(kb_doc: @kb_doc, img: { thumbnail_binary: "z" })
      end

      assert_equal 0, KbDocumentThumbnail.where(kb_document_id: @kb_doc.id).count
    ensure
      if @kb_doc.singleton_class.method_defined?(:create_thumbnail!, false)
        @kb_doc.singleton_class.remove_method(:create_thumbnail!)
      end
    end
  end
end
