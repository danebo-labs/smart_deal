# frozen_string_literal: true

require 'test_helper'

class KbDocumentTest < ActiveSupport::TestCase
  test 'ensure_for_s3_key! creates once with display_name from stem' do
    key = 'uploads/2026-04-01/manual_otis.pdf'

    assert_difference -> { KbDocument.count }, +1 do
      KbDocument.ensure_for_s3_key!(key)
    end

    doc = KbDocument.find_by!(s3_key: key)
    assert_equal 'manual otis', doc.display_name
    assert_equal [], doc.aliases
  end

  test 'ensure_for_s3_key! is idempotent' do
    key = 'uploads/2026-04-01/x.pdf'
    KbDocument.ensure_for_s3_key!(key)
    KbDocument.find_by!(s3_key: key).update!(aliases: [ 'alias one' ])

    assert_no_difference -> { KbDocument.count } do
      KbDocument.ensure_for_s3_key!(key)
    end

    assert_equal [ 'alias one' ], KbDocument.find_by!(s3_key: key).aliases
  end

  test 'ensure_for_s3_key! no-op for blank key' do
    assert_no_difference -> { KbDocument.count } do
      KbDocument.ensure_for_s3_key!('')
      KbDocument.ensure_for_s3_key!(nil)
    end
  end

  test 'object_key_for_match strips s3 URI prefix' do
    assert_equal "uploads/2026/a.pdf", KbDocument.object_key_for_match("s3://my-bucket/uploads/2026/a.pdf")
    assert_equal "uploads/x.png", KbDocument.object_key_for_match("uploads/x.png")
  end

  test 'display_s3_uri builds URI from bucket when key is plain' do
    kb = KbDocument.new(s3_key: "uploads/2026/z.pdf")
    assert_equal "s3://kb-bucket/uploads/2026/z.pdf", kb.display_s3_uri("kb-bucket")
  end

  test 'display_s3_uri returns stored URI when already full s3 URL' do
    uri = "s3://multimodal-source-destination/uploads/2026-03-27/f.pdf"
    kb = KbDocument.new(s3_key: uri)
    assert_equal uri, kb.display_s3_uri("other-bucket")
  end

  test 'sort_s3_documents_by_kb_created_at puts newest kb first and unpaired keys last' do
    KbDocument.create!(
      s3_key: "uploads/2026/sort-old.pdf", display_name: "O", aliases: [],
      created_at: 2.days.ago
    )
    KbDocument.create!(
      s3_key: "uploads/2026/sort-new.pdf", display_name: "N", aliases: [],
      created_at: 1.day.ago
    )

    idx = KbDocument.all.index_by { |k| KbDocument.object_key_for_match(k.s3_key) }
    docs = [
      { full_path: "uploads/2026/sort-old.pdf", name: "sort-old.pdf" },
      { full_path: "uploads/2026/no-kb.bin", name: "no-kb.bin" },
      { full_path: "uploads/2026/sort-new.pdf", name: "sort-new.pdf" }
    ]
    sorted = KbDocument.sort_s3_documents_by_kb_created_at(docs, idx)
    assert_equal %w[sort-new.pdf sort-old.pdf no-kb.bin], sorted.pluck(:name)
  end

  test 'simplest_display_aliases picks fewest words then shortest, max two' do
    kb = KbDocument.new(aliases: [
      'manual largo de campo varias palabras',
      'U150',
      'otro alias medio',
      'A'
    ])
    assert_equal %w[A U150], kb.simplest_display_aliases(2)
  end

  test 'simplest_display_aliases dedupes and strips blanks' do
    kb = KbDocument.new(aliases: [ '  x  ', 'x', '', nil, 'y z' ])
    assert_equal [ 'x', 'y z' ], kb.simplest_display_aliases(5)
  end

  test 'aliases round-trip as jsonb string array' do
    list = [ "Planta U150", "Esquema Eléctrico" ]
    kb = KbDocument.create!(s3_key: "uploads/2026-04-09/alias_test.pdf", display_name: "T", aliases: list)
    kb.reload
    assert_equal list, kb.aliases
    assert_instance_of Array, kb.aliases
  end

  test 'ensure_for_s3_key! stores size_bytes when provided' do
    key = 'uploads/2026-04-10/sized_doc.pdf'
    KbDocument.ensure_for_s3_key!(key, size_bytes: 98_765)
    doc = KbDocument.find_by!(s3_key: key)
    assert_equal 98_765, doc.size_bytes
  end

  test 'ensure_for_s3_key! size_bytes is nil when not provided' do
    key = 'uploads/2026-04-10/no_size_doc.pdf'
    KbDocument.ensure_for_s3_key!(key)
    doc = KbDocument.find_by!(s3_key: key)
    assert_nil doc.size_bytes
  end

  test 'ensure_for_s3_key! does not overwrite size_bytes on existing record' do
    key = 'uploads/2026-04-10/idempotent_size.pdf'
    KbDocument.ensure_for_s3_key!(key, size_bytes: 111)
    KbDocument.ensure_for_s3_key!(key, size_bytes: 999)
    doc = KbDocument.find_by!(s3_key: key)
    assert_equal 111, doc.size_bytes
  end
end
