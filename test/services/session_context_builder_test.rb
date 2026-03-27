# frozen_string_literal: true

require 'test_helper'

class SessionContextBuilderTest < ActiveSupport::TestCase
  def build_session
    ConversationSession.create!(
      identifier: "web:builder_test_#{SecureRandom.hex(4)}",
      channel:    "web",
      expires_at: 30.minutes.from_now
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
end
