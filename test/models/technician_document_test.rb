# frozen_string_literal: true

require 'test_helper'

class TechnicianDocumentTest < ActiveSupport::TestCase
  IDENTIFIER = "whatsapp:+56900000001"
  CHANNEL    = "whatsapp"

  setup do
    TechnicianDocument.delete_all
  end

  # ─── upsert_from_entity ──────────────────────────────────────────────────────

  test 'creates a new record on first upsert' do
    doc = TechnicianDocument.upsert_from_entity(
      identifier:     IDENTIFIER,
      channel:        CHANNEL,
      canonical_name: "Junction Box Car Top",
      metadata: {
        "aliases"    => [ "junction box", "car top" ],
        "source_uri" => "s3://bucket/junction_box.pdf",
        "doc_type"   => "diagram"
      }
    )

    assert doc.persisted?
    assert_equal "Junction Box Car Top", doc.canonical_name
    assert_includes doc.aliases, "junction box"
    assert_equal "s3://bucket/junction_box.pdf", doc.source_uri
    assert_equal 1, doc.interaction_count
  end

  test 'increments interaction_count and merges aliases on subsequent upsert' do
    TechnicianDocument.upsert_from_entity(
      identifier: IDENTIFIER, channel: CHANNEL, canonical_name: "Doc A",
      metadata: { "aliases" => [ "alias one" ] }
    )

    doc = TechnicianDocument.upsert_from_entity(
      identifier: IDENTIFIER, channel: CHANNEL, canonical_name: "Doc A",
      metadata: { "aliases" => [ "alias two" ] }
    )

    assert_equal 2, doc.interaction_count
    assert_includes doc.aliases, "alias one"
    assert_includes doc.aliases, "alias two"
  end

  test 'updates source_uri and wa_filename when provided' do
    TechnicianDocument.upsert_from_entity(
      identifier: IDENTIFIER, channel: CHANNEL, canonical_name: "Doc A",
      metadata: {}
    )
    doc = TechnicianDocument.upsert_from_entity(
      identifier: IDENTIFIER, channel: CHANNEL, canonical_name: "Doc A",
      metadata: { "source_uri" => "s3://bucket/doc_a.pdf", "wa_filename" => "doc_a.pdf" }
    )

    assert_equal "s3://bucket/doc_a.pdf", doc.source_uri
    assert_equal "doc_a.pdf", doc.wa_filename
  end

  test 'aliases capped at 15 entries' do
    many_aliases = (1..20).map { |i| "alias #{i}" }
    doc = TechnicianDocument.upsert_from_entity(
      identifier: IDENTIFIER, channel: CHANNEL, canonical_name: "Verbose Doc",
      metadata: { "aliases" => many_aliases }
    )

    assert doc.aliases.size <= 15
  end

  # ─── evict_oldest ────────────────────────────────────────────────────────────

  test 'evicts oldest records beyond MAX_PER_TECHNICIAN' do
    (TechnicianDocument::MAX_PER_TECHNICIAN + 3).times do |i|
      TechnicianDocument.create!(
        identifier:        IDENTIFIER,
        channel:           CHANNEL,
        canonical_name:    "Doc #{i}",
        last_used_at:      i.minutes.ago,
        interaction_count: 1
      )
    end

    TechnicianDocument.evict_oldest(IDENTIFIER, CHANNEL)

    assert_equal TechnicianDocument::MAX_PER_TECHNICIAN,
                 TechnicianDocument.for_identifier(IDENTIFIER, CHANNEL).count
  end

  # ─── recent_for ──────────────────────────────────────────────────────────────

  test 'recent_for returns documents ordered by last_used_at desc, limited' do
    3.times do |i|
      TechnicianDocument.create!(
        identifier:        IDENTIFIER,
        channel:           CHANNEL,
        canonical_name:    "Doc #{i}",
        last_used_at:      i.hours.ago,
        interaction_count: 1
      )
    end

    docs = TechnicianDocument.recent_for(IDENTIFIER, CHANNEL, limit: 2)

    assert_equal 2, docs.size
    assert_equal "Doc 0", docs.first.canonical_name
  end

  test 'recent_for scopes to identifier and channel' do
    TechnicianDocument.create!(
      identifier: IDENTIFIER, channel: CHANNEL, canonical_name: "Mine",
      last_used_at: Time.current, interaction_count: 1
    )
    TechnicianDocument.create!(
      identifier: "other:+999", channel: CHANNEL, canonical_name: "Not Mine",
      last_used_at: Time.current, interaction_count: 1
    )

    docs = TechnicianDocument.recent_for(IDENTIFIER, CHANNEL)

    assert_equal 1, docs.size
    assert_equal "Mine", docs.first.canonical_name
  end
end
