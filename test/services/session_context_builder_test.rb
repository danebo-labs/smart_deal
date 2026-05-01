# frozen_string_literal: true

require 'test_helper'

class SessionContextBuilderTest < ActiveSupport::TestCase
  setup do
    TechnicianDocument.delete_all
  end

  def build_session(channel: "web")
    ConversationSession.create!(
      identifier: "#{channel}:builder_test_#{SecureRandom.hex(4)}",
      channel:    channel,
      expires_at: 30.minutes.from_now
    )
  end

  def create_tech_doc(canonical_name:, source_uri:, channel: "whatsapp", identifier: "whatsapp:+34600000001")
    TechnicianDocument.create!(
      identifier:        identifier,
      channel:           channel,
      canonical_name:    canonical_name,
      source_uri:        source_uri,
      last_used_at:      Time.current,
      interaction_count: 1
    )
  end

  test 'returns empty string for nil session' do
    assert_equal '', SessionContextBuilder.build(nil)
  end

  test 'returns empty string when session has no entities or history' do
    session = build_session
    assert_equal '', SessionContextBuilder.build(session)
  end

  test 'includes Session Focus block when active_entities present' do
    session = build_session
    session.add_entity('manual.pdf', { 'source' => 'retrieve_result' })

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Session Focus'
    assert_includes context, '[document] manual.pdf'
  end

  test 'labels image_upload entities as [image]' do
    session = build_session
    session.add_entity('wa_photo.jpg', { 'source' => 'image_upload' })

    context = SessionContextBuilder.build(session)

    assert_includes context, '[image] wa_photo.jpg'
  end

  test 'includes both retrieve_result and image_upload entities' do
    session = build_session
    session.add_entity('doc.pdf',    { 'source' => 'retrieve_result' })
    session.add_entity('photo.jpg',  { 'source' => 'image_upload' })

    context = SessionContextBuilder.build(session)

    assert_includes context, '[document] doc.pdf'
    assert_includes context, '[image] photo.jpg'
  end

  test 'includes Recent Conversation block when history present' do
    session = build_session
    session.add_to_history('user', 'Hello')
    session.add_to_history('assistant', 'Hi there')

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Recent Conversation'
    assert_includes context, 'User: Hello'
    assert_includes context, 'Assistant: Hi there'
  end

  test 'only includes last 3 history turns' do
    session = build_session
    6.times { |i| session.add_to_history('user', "msg #{i}") }

    context = SessionContextBuilder.build(session)

    assert_not_includes context, 'msg 0'
    assert_includes context, 'msg 5'
  end

  test 'includes both blocks when session has entities and history' do
    session = build_session
    session.add_entity('doc.pdf', { 'source' => 'retrieve_result' })
    session.add_to_history('user', 'What is this?')

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Session Focus'
    assert_includes context, 'Recent Conversation'
  end

  # ============================================
  # 3.1 — entity_s3_uris
  # ============================================

  test 'entity_s3_uris returns empty array for nil session' do
    assert_equal [], SessionContextBuilder.entity_s3_uris(nil)
  end

  test 'entity_s3_uris returns empty array when no entities have source_uri' do
    session = build_session
    session.add_entity('doc.pdf', { 'source' => 'retrieve_result' })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris extracts s3:// URIs from active entities' do
    session = build_session
    session.add_entity('Junction Box Car Top', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://my-bucket/junction_box.pdf'
    })
    session.add_entity('Motor Controller', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://my-bucket/motor_ctrl.pdf'
    })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_equal 2, uris.size
    assert_includes uris, 's3://my-bucket/junction_box.pdf'
    assert_includes uris, 's3://my-bucket/motor_ctrl.pdf'
  end

  test 'entity_s3_uris ignores non-s3 URIs' do
    session = build_session
    session.add_entity('doc.pdf', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 'https://example.com/doc.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris rejects fabricated unknown-bucket URIs' do
    session = build_session
    session.add_entity('Junction Box', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://unknown-bucket/unknown-path/junction_box.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris rejects placeholder-bucket URIs' do
    session = build_session
    session.add_entity('Doc', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://placeholder/doc.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris keeps real URIs alongside fabricated ones' do
    session = build_session
    session.add_entity('Real Doc', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://multimodal-source-destination/uploads/2026-03-27/wa_file.jpeg'
    })
    session.add_entity('Fake Doc', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://unknown-bucket/unknown-path/fake.pdf'
    })

    uris = SessionContextBuilder.entity_s3_uris(session)
    assert_equal 1, uris.size
    assert_includes uris, 's3://multimodal-source-destination/uploads/2026-03-27/wa_file.jpeg'
  end

  test 'entity_s3_uris deduplicates identical URIs' do
    session = build_session
    session.add_entity('Doc A', { 'source' => 'doc_refs_rule8', 'source_uri' => 's3://bucket/same.pdf' })
    session.add_entity_with_aliases('Doc A alias', [], { 'source' => 'doc_refs_rule8', 'source_uri' => 's3://bucket/same.pdf' })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_equal 1, uris.size
  end

  # ============================================
  # 3.3 — first_answer_summary in Session Focus
  # ============================================

  test 'includes summary note when entity has first_answer_summary' do
    session = build_session
    session.add_entity('Junction Box Car Top', {
      'source'               => 'doc_refs_rule8',
      'first_answer_summary' => 'Contains safety chain relay and door zone contacts.'
    })

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Summary: Contains safety chain relay'
  end

  test 'omits summary note when entity has no first_answer_summary' do
    session = build_session
    session.add_entity('manual.pdf', { 'source' => 'retrieve_result' })

    context = SessionContextBuilder.build(session)

    assert_not_includes context, 'Summary:'
  end

  # ============================================
  # Session-scoped filtering (TechnicianDocument NO longer auto-merged)
  #
  # Rationale: the KB retrieval filter must mirror what the user (and Haiku,
  # via Session Focus) actually see in the current conversation. Historical
  # TechnicianDocument rows that are not active in the session would pollute
  # retrieval with unrelated docs. Queries that legitimately target a doc
  # outside the session are caught by BedrockRagService#query_names_different_document?
  # (explicit name match) and the retry-without-filter fallback.
  # ============================================

  test 'entity_s3_uris EXCLUDES TechnicianDocuments not present in session' do
    create_tech_doc(
      canonical_name: "Junction Box Manual",
      source_uri:     "s3://bucket/junction_box.pdf",
      channel:        "whatsapp"
    )

    session = build_session(channel: "whatsapp")

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_not_includes uris, "s3://bucket/junction_box.pdf"
    assert_equal [], uris
  end

  test 'entity_s3_uris returns ONLY session active_entities even when TechnicianDocuments exist' do
    create_tech_doc(
      canonical_name: "WA Doc",
      source_uri:     "s3://bucket/wa_doc.pdf",
      channel:        "whatsapp"
    )

    session = build_session(channel: "whatsapp")
    session.add_entity("Web Doc", {
      "source"     => "doc_refs_rule8",
      "source_uri" => "s3://bucket/web_doc.pdf"
    })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_not_includes uris, "s3://bucket/wa_doc.pdf"
    assert_includes uris, "s3://bucket/web_doc.pdf"
    assert_equal 1, uris.size
  end

  test 'entity_s3_uris returns session URI even if same URI exists as TechnicianDocument' do
    create_tech_doc(
      canonical_name: "Shared Doc",
      source_uri:     "s3://bucket/shared.pdf",
      channel:        "whatsapp"
    )

    session = build_session
    session.add_entity("Shared Doc", {
      "source"     => "doc_refs_rule8",
      "source_uri" => "s3://bucket/shared.pdf"
    })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_equal [ "s3://bucket/shared.pdf" ], uris
  end

  # ============================================
  # 4 — Recency ordering in Session Focus
  # ============================================

  test 'Session Focus orders entities most-recent first by added_at' do
    session = build_session
    older = (10.minutes.ago).iso8601
    newer = Time.current.iso8601
    session.update!(active_entities: {
      "Old Doc"   => { "source" => "retrieve_result", "added_at" => older },
      "Fresh Doc" => { "source" => "retrieve_result", "added_at" => newer }
    })

    context = SessionContextBuilder.build(session)
    fresh_idx = context.index("Fresh Doc")
    old_idx   = context.index("Old Doc")

    assert fresh_idx < old_idx, "most-recent entity must appear first in Session Focus"
  end

  # ============================================
  # 5 — Session Discipline directive
  # ============================================

  test 'Session Discipline block emitted when both pins and history present' do
    session = ConversationSession.find_or_create_for(identifier: "scb-1", channel: "web")
    kb = KbDocument.create!(s3_key: "uploads/2026/scb.pdf", display_name: "Scb", aliases: [])
    session.pin_kb_document!(kb)
    session.add_to_history("user", "hola")

    out = SessionContextBuilder.build(session)
    assert_match(/## Session Discipline/, out)
  end

  test 'Session Discipline omitted when no history' do
    session = ConversationSession.find_or_create_for(identifier: "scb-2", channel: "web")
    kb = KbDocument.create!(s3_key: "uploads/2026/no_hist.pdf", display_name: "NH", aliases: [])
    session.pin_kb_document!(kb)

    out = SessionContextBuilder.build(session)
    assert_no_match(/## Session Discipline/, out)
  end

  test 'Session Discipline omitted when no pins' do
    session = ConversationSession.find_or_create_for(identifier: "scb-3", channel: "web")
    session.add_to_history("user", "hola")

    out = SessionContextBuilder.build(session)
    assert_no_match(/## Session Discipline/, out)
  end
end
