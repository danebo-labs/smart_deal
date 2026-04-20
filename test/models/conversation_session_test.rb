# frozen_string_literal: true

require 'test_helper'

class ConversationSessionTest < ActiveSupport::TestCase
  def build_session(overrides = {})
    ConversationSession.new({
      identifier: 'whatsapp:+56912345678',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    }.merge(overrides))
  end

  # ─── Validations ────────────────────────────────────────────────────────────

  test 'valid with required fields' do
    assert build_session.valid?
  end

  test 'invalid without identifier' do
    assert_not build_session(identifier: nil).valid?
  end

  test 'invalid with unknown channel' do
    assert_not build_session(channel: 'sms').valid?
  end

  test 'invalid without expires_at' do
    assert_not build_session(expires_at: nil).valid?
  end

  # ─── expired? / refresh! ────────────────────────────────────────────────────

  test 'expired? returns false when expires_at is in the future' do
    s = build_session(expires_at: 1.minute.from_now)
    assert_not s.expired?
  end

  test 'expired? returns true when expires_at is in the past' do
    s = build_session(expires_at: 1.second.ago)
    assert s.expired?
  end

  test 'refresh! extends expires_at' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+11111111111',
      channel:    'whatsapp',
      expires_at: 1.minute.from_now
    )
    original = s.expires_at
    travel 5.minutes do
      s.refresh!
    end
    assert s.expires_at > original
  end

  # ─── find_or_create_for ─────────────────────────────────────────────────────

  test 'find_or_create_for creates a new session when none exists' do
    assert_difference 'ConversationSession.count', 1 do
      ConversationSession.find_or_create_for(identifier: 'whatsapp:+22222222222', channel: 'whatsapp')
    end
  end

  test 'find_or_create_for returns existing active session' do
    existing = ConversationSession.create!(
      identifier: 'whatsapp:+33333333333',
      channel:    'whatsapp',
      expires_at: 20.minutes.from_now
    )

    result = nil
    assert_no_difference 'ConversationSession.count' do
      result = ConversationSession.find_or_create_for(identifier: 'whatsapp:+33333333333', channel: 'whatsapp')
    end

    assert_equal existing.id, result.id
  end

  test 'find_or_create_for replaces expired session' do
    ConversationSession.create!(
      identifier: 'whatsapp:+44444444444',
      channel:    'whatsapp',
      expires_at: 1.second.ago
    )

    new_session = nil
    assert_no_difference 'ConversationSession.count' do
      new_session = ConversationSession.find_or_create_for(identifier: 'whatsapp:+44444444444', channel: 'whatsapp')
    end

    assert_not new_session.expired?
  end

  test 'find_or_create_for isolates channels — same identifier, different channel' do
    ConversationSession.find_or_create_for(identifier: 'user_abc', channel: 'whatsapp')

    assert_difference 'ConversationSession.count', 1 do
      ConversationSession.find_or_create_for(identifier: 'user_abc', channel: 'web')
    end
  end

  # ─── add_to_history ─────────────────────────────────────────────────────────

  test 'add_to_history appends messages' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+55555555555',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    s.add_to_history('user',      'Hello')
    s.add_to_history('assistant', 'Hi there')
    s.reload

    assert_equal 2, s.conversation_history.size
    assert_equal 'user',      s.conversation_history.first['role']
    assert_equal 'Hello',     s.conversation_history.first['content']
    assert_equal 'assistant', s.conversation_history.last['role']
  end

  test 'add_to_history caps at MAX_HISTORY, evicting oldest' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+66666666666',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    (ConversationSession::MAX_HISTORY + 5).times do |i|
      s.add_to_history('user', "Message #{i}")
    end
    s.reload

    assert_equal ConversationSession::MAX_HISTORY, s.conversation_history.size
    assert_equal "Message #{ConversationSession::MAX_HISTORY - 1 + 5}", s.conversation_history.last['content']
  end

  test 'history_for_prompt returns role/content pairs without ts' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77777777777',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    s.add_to_history('user', 'Test')
    s.reload

    prompt_history = s.history_for_prompt
    assert_equal 1, prompt_history.size
    assert_equal({ role: 'user', content: 'Test' }, prompt_history.first)
    assert_nil prompt_history.first[:ts]
  end

  # ─── add_to_history truncation ──────────────────────────────────────────────

  test 'add_to_history truncates content to MAX_MSG_LENGTH' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+55500000001',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    long_msg = 'x' * 500
    s.add_to_history('user', long_msg)
    s.reload

    assert s.conversation_history.first['content'].length <= ConversationSession::MAX_MSG_LENGTH
  end

  # ─── recent_history_for_prompt ──────────────────────────────────────────────

  test 'recent_history_for_prompt returns last N turns' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+55500000002',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    10.times { |i| s.add_to_history('user', "msg #{i}") }
    s.reload

    recent = s.recent_history_for_prompt(turns: 3)
    assert_equal 3, recent.size
    assert_equal 'msg 9', recent.last[:content]
  end

  # ─── add_entity (metadata-only + FIFO) ──────────────────────────────────────

  test 'add_entity stores metadata and returns true' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+88888888888',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    result = s.add_entity('schema.pdf', { 'source' => 'retrieve_result' })
    s.reload

    assert result
    assert s.active_entities.key?('schema.pdf')
    assert_equal 'retrieve_result', s.active_entities['schema.pdf']['source']
    assert s.active_entities['schema.pdf']['added_at'].present?
  end

  test 'add_entity does not duplicate an entity already present under same name' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+88800000001',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    s.add_entity('dup.pdf', { 'source' => 'retrieve_result' })
    original_at = s.reload.active_entities['dup.pdf']['added_at']

    s.add_entity('dup.pdf', { 'source' => 'retrieve_result' })
    s.reload

    assert_equal 1, s.entity_count
    assert_equal original_at, s.active_entities['dup.pdf']['added_at']
  end

  test 'add_entity applies FIFO eviction when exceeding MAX_ENTITIES' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+99999999999',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    # Pre-fill MAX_ENTITIES slots with distinct past timestamps directly so
    # the real clock (used when adding overflow.pdf) is always newer.
    base_time = 1.hour.ago
    prefilled = {}
    ConversationSession::MAX_ENTITIES.times do |i|
      prefilled["doc_#{i}.pdf"] = {
        "source"   => "retrieve_result",
        "added_at" => (base_time + i.seconds).iso8601
      }
    end
    s.update!(active_entities: prefilled)
    s.reload

    # doc_0.pdf has the earliest added_at — it must be evicted
    s.add_entity('overflow.pdf', { 'source' => 'retrieve_result' })
    s.reload

    assert_equal ConversationSession::MAX_ENTITIES, s.entity_count
    assert_not s.active_entities.key?('doc_0.pdf'), 'Oldest entity should have been evicted'
    assert s.active_entities.key?('overflow.pdf'), 'New entity should be present'
  end

  # ─── add_entity_with_aliases ────────────────────────────────────────────────

  test 'add_entity_with_aliases stores canonical name, aliases, and wa_filename' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700000001',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    s.add_entity_with_aliases(
      'Junction Box Car Top',
      %w[junction cartop DRG\ 6061-05-014 wa_20260323_214702_0.jpeg],
      'source' => 'image_upload', 'wa_filename' => 'wa_20260323_214702_0.jpeg'
    )
    s.reload

    entity = s.active_entities['Junction Box Car Top']
    assert entity.present?
    assert_equal 'Junction Box Car Top', entity['canonical_name']
    assert_includes entity['aliases'], 'cartop'
    assert_includes entity['aliases'], 'DRG 6061-05-014'
    assert_equal 'image_upload', entity['source']
  end

  test 'add_entity_with_aliases does not create a duplicate when canonical already exists' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700000002',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    s.add_entity_with_aliases('My Doc', %w[alias1], 'source' => 'image_upload')
    s.add_entity_with_aliases('My Doc', %w[alias2], 'source' => 'image_upload')
    s.reload

    assert_equal 1, s.entity_count
    assert_includes s.active_entities['My Doc']['aliases'], 'alias1'
    assert_includes s.active_entities['My Doc']['aliases'], 'alias2'
  end

  test 'add_entity_with_aliases merges when matched by an alias (not canonical key)' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700000003',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    s.add_entity_with_aliases('Junction Box Car Top', %w[cartop sounder], 'source' => 'image_upload')
    # Second call uses an alias that matches the existing entity
    s.add_entity_with_aliases('Junction Box Car Top', %w[DRG\ 05-015], 'source' => 'image_upload')
    s.reload

    assert_equal 1, s.entity_count
    entity = s.active_entities['Junction Box Car Top']
    assert_includes entity['aliases'], 'cartop'
    assert_includes entity['aliases'], 'DRG 05-015'
  end

  # ─── sanitize_aliases ───────────────────────────────────────────────────────

  test 'sanitize_aliases passes normal alias' do
    s = build_session
    assert_equal [ 'enclosure view A' ], s.send(:sanitize_aliases, [ 'enclosure view A' ])
  end

  test 'sanitize_aliases rejects long alias' do
    s = build_session
    long = 'x' * 80
    assert_empty s.send(:sanitize_aliases, [ long ])
  end

  test 'sanitize_aliases rejects pipe' do
    s = build_session
    assert_empty s.send(:sanitize_aliases, [ '| Ref | Component |' ])
  end

  test 'sanitize_aliases rejects markdown bold' do
    s = build_session
    assert_empty s.send(:sanitize_aliases, [ '**Safety Bar 2**' ])
  end

  test 'sanitize_aliases rejects s3 url' do
    s = build_session
    assert_empty s.send(:sanitize_aliases, [ 's3://bucket/file.pdf' ])
  end

  test 'sanitize_aliases rejects too short' do
    s = build_session
    assert_empty s.send(:sanitize_aliases, [ 'A' ])
  end

  test 'sanitize_aliases rejects paragraphs' do
    s = build_session
    paragraph = 'This is a very long sentence with way too many spaces in it here'
    assert_empty s.send(:sanitize_aliases, [ paragraph ])
  end

  test 'sanitize_aliases deduplicates case insensitive' do
    s = build_session
    assert_equal [ 'Box' ], s.send(:sanitize_aliases, %w[Box box BOX])
  end

  test 'sanitize_aliases limits to 15' do
    s = build_session
    twenty = 20.times.map { |i| "alias#{i}" }
    out = s.send(:sanitize_aliases, twenty)
    assert_equal 15, out.size
    assert_equal (0...15).map { |i| "alias#{i}" }, out
  end

  test 'add_entity_with_aliases sanitizes before persisting' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700000008',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    s.add_entity_with_aliases(
      'Sanitize Doc',
      [
        'good_one',
        'good two',
        '**bad**',
        '| pipe row |',
        's3://bad/path',
        'A',
        'x' * 80,
        'This is a very long sentence with way too many spaces in it here',
        'good_three'
      ],
      'source' => 'image_upload'
    )
    s.reload

    aliases = s.active_entities['Sanitize Doc']['aliases']
    assert_equal Set.new([ 'good_one', 'good two', 'good_three' ]), Set.new(aliases)
  end

  # ─── find_entity_by_source_uri ──────────────────────────────────────────────

  test 'find_entity_by_source_uri returns canonical key for matching s3 uri' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700008001',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    uri = 's3://bucket/uploads/2026-04-15/wa_abc.jpeg'
    s.add_entity_with_aliases('Elevator brake', %w[disc\ brake], 'source_uri' => uri)

    assert_equal 'Elevator brake', s.find_entity_by_source_uri(uri)
  end

  test 'find_entity_by_source_uri returns nil for unknown uri' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700008002',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    s.add_entity_with_aliases('Some Doc', [], 'source_uri' => 's3://bucket/a.jpeg')

    assert_nil s.find_entity_by_source_uri('s3://bucket/other.jpeg')
    assert_nil s.find_entity_by_source_uri(nil)
    assert_nil s.find_entity_by_source_uri('')
  end

  # ─── find_entity_by_name_or_alias ───────────────────────────────────────────

  test 'find_entity_by_name_or_alias finds by canonical key (case-insensitive)' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700000004',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    s.add_entity_with_aliases('Junction Box Car Top', %w[cartop], 'source' => 'image_upload')

    assert_equal 'Junction Box Car Top', s.find_entity_by_name_or_alias('junction box car top')
    assert_equal 'Junction Box Car Top', s.find_entity_by_name_or_alias('JUNCTION BOX CAR TOP')
  end

  test 'find_entity_by_name_or_alias finds by alias (case-insensitive)' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700000005',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    s.add_entity_with_aliases('My Doc', %w[DRG\ 05-015 cartop], 'source' => 'image_upload')

    assert_equal 'My Doc', s.find_entity_by_name_or_alias('cartop')
    assert_equal 'My Doc', s.find_entity_by_name_or_alias('drg 05-015')
    assert_equal 'My Doc', s.find_entity_by_name_or_alias('DRG 05-015')
  end

  test 'find_entity_by_name_or_alias finds by wa_filename' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700000006',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    s.add_entity_with_aliases('My Doc', [], 'source' => 'image_upload', 'wa_filename' => 'wa_20260323_214702_0.jpeg')

    assert_equal 'My Doc', s.find_entity_by_name_or_alias('wa_20260323_214702_0.jpeg')
  end

  test 'find_entity_by_name_or_alias returns nil when no match' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+77700000007',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    assert_nil s.find_entity_by_name_or_alias('unknown')
  end

  # ─── helpers ────────────────────────────────────────────────────────────────

  test 'has_active_entities? returns false when empty' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+55500000003',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    assert_not s.has_active_entities?
  end

  test 'has_active_entities? returns true after add_entity' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+55500000004',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    s.add_entity('doc.pdf', { 'source' => 'retrieve_result' })
    assert s.has_active_entities?
  end

  test 'active_document_names returns entity keys' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+55500000005',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    s.add_entity('a.pdf', { 'source' => 'retrieve_result' })
    s.add_entity('b.png', { 'source' => 'image_upload' })
    s.reload

    names = s.active_document_names
    assert_includes names, 'a.pdf'
    assert_includes names, 'b.png'
  end

  # ─── reset_procedure! ───────────────────────────────────────────────────────

  test 'reset_procedure! clears current_procedure and resets status' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+10101010101',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now,
      current_procedure: { 'step' => 3 },
      session_status:    'procedure_in_progress'
    )

    s.reset_procedure!
    s.reload

    assert_equal({}, s.current_procedure)
    assert_equal 'active', s.session_status
  end

  # ─── 3.4 — preload_recent_entities ──────────────────────────────────────────

  test 'find_or_create_for preloads recent TechnicianDocuments into a new session' do
    TechnicianDocument.delete_all
    identifier = "whatsapp:+56900000099"
    channel    = "whatsapp"

    TechnicianDocument.create!(
      identifier:        identifier,
      channel:           channel,
      canonical_name:    "Junction Box Car Top",
      aliases:           [ "junction box" ],
      source_uri:        "s3://bucket/junction_box.pdf",
      doc_type:          "diagram",
      last_used_at:      1.hour.ago,
      interaction_count: 3
    )

    ConversationSession.where(identifier: identifier, channel: channel).destroy_all

    session = ConversationSession.find_or_create_for(identifier: identifier, channel: channel)
    session.reload

    assert session.active_entities.key?("Junction Box Car Top"),
           "Expected preloaded entity from TechnicianDocument"
    entity = session.active_entities["Junction Box Car Top"]
    assert_equal "preloaded_from_history", entity["extraction_method"]
    assert_equal "s3://bucket/junction_box.pdf", entity["source_uri"]
  end

  test 'find_or_create_for does not preload when session already exists and is active' do
    TechnicianDocument.delete_all
    identifier = "whatsapp:+56900000098"
    channel    = "whatsapp"

    existing = ConversationSession.create!(
      identifier: identifier, channel: channel, expires_at: 25.minutes.from_now
    )
    existing.add_entity("existing.pdf", { "source" => "retrieve_result" })

    TechnicianDocument.create!(
      identifier: identifier, channel: channel, canonical_name: "Should Not Load",
      last_used_at: Time.current, interaction_count: 1
    )

    session = ConversationSession.find_or_create_for(identifier: identifier, channel: channel)
    session.reload

    assert_not session.active_entities.key?("Should Not Load"),
               "preload must NOT run for an existing active session"
    assert session.active_entities.key?("existing.pdf")
  end

  test 'preload_recent_entities is no-op when no TechnicianDocuments exist' do
    TechnicianDocument.delete_all
    identifier = "whatsapp:+56900000097"
    channel    = "whatsapp"
    ConversationSession.where(identifier: identifier, channel: channel).destroy_all

    session = ConversationSession.find_or_create_for(identifier: identifier, channel: channel)
    session.reload

    assert_equal({}, session.active_entities)
  end

  test 'preload_recent_entities loads docs from global pool regardless of identifier or channel' do
    TechnicianDocument.delete_all
    my_identifier    = "whatsapp:+56900000090"
    other_identifier = "whatsapp:+56900000091"
    channel          = "whatsapp"

    ConversationSession.where(identifier: my_identifier, channel: channel).destroy_all

    TechnicianDocument.create!(
      identifier: other_identifier, channel: channel,
      canonical_name: "Other Technician Doc",
      last_used_at: 5.minutes.ago, interaction_count: 1
    )
    TechnicianDocument.create!(
      identifier: my_identifier, channel: channel,
      canonical_name: "My Technician Doc",
      last_used_at: 1.minute.ago, interaction_count: 1
    )
    TechnicianDocument.create!(
      identifier: "user:42", channel: "web",
      canonical_name: "Web Uploaded Doc",
      last_used_at: 2.minutes.ago, interaction_count: 1
    )

    session = ConversationSession.find_or_create_for(identifier: my_identifier, channel: channel)
    session.reload

    assert session.active_entities.key?("My Technician Doc"),
           "Should preload own doc"
    assert session.active_entities.key?("Other Technician Doc"),
           "Should preload doc from other WhatsApp user (global pool)"
    assert session.active_entities.key?("Web Uploaded Doc"),
           "Should preload doc uploaded via web (global pool)"
  end
end
