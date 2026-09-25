# frozen_string_literal: true

require 'test_helper'

class ConversationSessionTest < ActiveSupport::TestCase
  def stub_shared_enabled(enabled)
    orig = SharedSession::ENABLED
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, enabled)
    yield
  ensure
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, orig)
  end

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

  test 'add_to_history stores optional user and correlation metadata without changing prompt history' do
    s = ConversationSession.create!(
      identifier: 'history-metadata',
      channel: 'web',
      expires_at: 30.minutes.from_now
    )

    s.add_to_history('user', 'Inspect panel', user_id: users(:one).id, correlation_id: 'photo:abc')
    message = s.reload.conversation_history.last

    assert_equal users(:one).id, message['user_id']
    assert_equal 'photo:abc', message['correlation_id']
    assert_equal({ role: 'user', content: 'Inspect panel' }, s.history_for_prompt.last)
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

  # X-8: the photo job loads the session, vision runs, then a text turn is
  # written on another instance. The job's later write must keep both turns.
  test 'X-8 a stale session copy cannot drop a text turn written while it was loaded' do
    session = ConversationSession.create!(
      identifier: 'web:x8',
      channel:    'web',
      expires_at: 1.day.from_now
    )
    stale = ConversationSession.find(session.id)
    fresh = ConversationSession.find(session.id)

    fresh.add_to_history('user', 'código 8', correlation_id: 'query:text')
    stale.add_to_history('assistant', '[FOTO] Componente: Panel', correlation_id: 'photo:1')

    session.reload
    assert_equal [ 'código 8', '[FOTO] Componente: Panel' ], session.conversation_history.pluck('content')
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

  # ─── add_to_history_and_refresh: single UPDATE for the request hot path ────

  test 'add_to_history_and_refresh appends message AND bumps expires_at in one UPDATE' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+55500009000',
      channel:    'whatsapp',
      expires_at: 1.minute.from_now
    )
    original_exp = s.expires_at

    queries = []
    cb = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /UPDATE.*conversation_sessions/i && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(cb, "sql.active_record") do
      s.add_to_history_and_refresh('user', 'hi')
    end

    s.reload
    assert_equal 1, s.conversation_history.size
    assert_equal 'hi', s.conversation_history.first['content']
    assert s.expires_at > original_exp + 1.day, 'expires_at must be pushed out by EXPIRY_DURATION'
    assert_equal 1, queries.size, 'must run a single UPDATE (not refresh! + add_to_history = 2)'
  end

  test 'add_to_history_and_refresh respects MAX_HISTORY eviction' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+55500009001',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )
    (ConversationSession::MAX_HISTORY + 5).times do |i|
      s.add_to_history_and_refresh('user', "m#{i}")
    end
    s.reload
    assert_equal ConversationSession::MAX_HISTORY, s.conversation_history.size
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

  # ─── SharedSession flag ─────────────────────────────────────────────────────

  test 'find_or_create_for collapses to shared row when ENABLED is true' do
    stub_shared_enabled(true) do
      ConversationSession.where(identifier: SharedSession::IDENTIFIER, channel: SharedSession::CHANNEL).destroy_all

      session_a = ConversationSession.find_or_create_for(identifier: 'whatsapp:+56911110001', channel: 'whatsapp')
      session_b = nil
      assert_no_difference 'ConversationSession.count' do
        session_b = ConversationSession.find_or_create_for(identifier: 'user:42', channel: 'web')
      end

      assert_equal session_a.id, session_b.id
      assert_equal SharedSession::IDENTIFIER, session_a.identifier
      assert_equal SharedSession::CHANNEL,    session_a.channel
    end
  end

  test 'find_or_create_for isolates by identifier+channel when ENABLED is false' do
    stub_shared_enabled(false) do
      session_a = ConversationSession.find_or_create_for(identifier: 'whatsapp:+56911110002', channel: 'whatsapp')
      session_b = nil
      assert_difference 'ConversationSession.count', 1 do
        session_b = ConversationSession.find_or_create_for(identifier: 'user:99', channel: 'web')
      end
      assert_not_equal session_a.id, session_b.id
    end
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

  # ─── TTL (30-day sliding window) ────────────────────────────────────────────

  test 'find_or_create_for sets expires_at to 30 days for new web session' do
    session = ConversationSession.find_or_create_for(identifier: "user-ttl-1", channel: "web")
    assert_in_delta 30.days.from_now.to_i, session.expires_at.to_i, 5
  end

  test 'refresh! extends expires_at by 30 days (sliding window)' do
    session = ConversationSession.find_or_create_for(identifier: "user-ttl-2", channel: "web")
    session.update!(expires_at: 1.day.from_now)
    session.refresh!
    assert_in_delta 30.days.from_now.to_i, session.expires_at.to_i, 5
  end

  test 'find_or_create_for reuses an existing non-expired session' do
    s1 = ConversationSession.find_or_create_for(identifier: "user-ttl-3", channel: "web")
    s2 = ConversationSession.find_or_create_for(identifier: "user-ttl-3", channel: "web")
    assert_equal s1.id, s2.id
  end

  test 'find_or_create_for destroys and recreates on expiry' do
    s1 = ConversationSession.find_or_create_for(identifier: "user-ttl-4", channel: "web")
    s1.update!(expires_at: 1.minute.ago)
    s2 = ConversationSession.find_or_create_for(identifier: "user-ttl-4", channel: "web")
    assert_not_equal s1.id, s2.id
    assert_nil ConversationSession.find_by(id: s1.id)
  end

  test 'find_or_create_for creates new session with empty active_entities (no preload)' do
    ConversationSession.where(identifier: "user-ttl-5", channel: "web").destroy_all
    session = ConversationSession.find_or_create_for(identifier: "user-ttl-5", channel: "web")
    session.reload
    assert_equal({}, session.active_entities)
  end

  # ─── Pin / Unpin ────────────────────────────────────────────────────────────

  test 'pin_kb_document! adds entity with source: user_pin and source_uri' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-1", channel: "web")
    kb_doc  = KbDocument.create!(s3_key: "uploads/2026/test_pin.pdf", display_name: "Test Pin", aliases: [ "TP" ])

    assert session.pin_kb_document!(kb_doc)
    session.reload

    entity = session.active_entities["Test Pin"]
    assert_equal "user_pin", entity["source"]
    assert_equal "document", entity["entity_type"]
    assert_equal "s3://#{KbDocument::KB_BUCKET}/uploads/2026/test_pin.pdf", entity["source_uri"]
    assert_includes entity["aliases"], "TP"
  end

  test 'pin_kb_document! is idempotent by source_uri' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-2", channel: "web")
    kb_doc  = KbDocument.create!(s3_key: "uploads/2026/idem.pdf", display_name: "Idem", aliases: [])

    session.pin_kb_document!(kb_doc)
    session.pin_kb_document!(kb_doc)
    session.reload

    assert_equal 1, session.active_entities.size
  end

  test 'pin_kb_document! keeps documents with a shared alias as separate entities' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-shared-alias", channel: "web")
    image = KbDocument.create!(
      s3_key: "uploads/2026/hydraulic.jpg",
      display_name: "Hydraulic Board",
      aliases: [ "Hoisting Cylinder" ]
    )
    manual = KbDocument.create!(
      s3_key: "uploads/2026/platform-manual.pdf",
      display_name: "Platform Manual",
      aliases: [ "hoisting cylinder" ]
    )

    session.pin_kb_document!(image)
    session.pin_kb_document!(manual)
    session.reload

    assert_equal 2, session.entity_count
    assert_equal "image_upload", session.active_entities["Hydraulic Board"]["entity_type"]
    assert_equal "document", session.active_entities["Platform Manual"]["entity_type"]
    assert_equal(
      [ image, manual ].map { |doc| doc.display_s3_uri(KbDocument::KB_BUCKET) }.sort,
      SessionContextBuilder.entity_s3_uris(session).sort
    )
  end

  test 'pin_kb_document! suffixes the key when different documents share a canonical name' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-shared-name", channel: "web")
    first = KbDocument.create!(
      s3_key: "uploads/2026/controller-a.pdf",
      display_name: "Controller Manual",
      aliases: []
    )
    second = KbDocument.create!(
      s3_key: "uploads/2026/controller-b.pdf",
      display_name: "Controller Manual",
      aliases: []
    )

    session.pin_kb_document!(first)
    session.pin_kb_document!(second)
    session.reload

    assert_equal 2, session.entity_count
    assert session.active_entities.key?("Controller Manual")
    assert session.active_entities.key?("Controller Manual (kb##{second.id})")
  end

  test 'pin_kb_document! merges new aliases when re-pinning the same document' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-refresh", channel: "web")
    kb_doc = KbDocument.create!(
      s3_key: "uploads/2026/refresh.pdf",
      display_name: "Refresh Manual",
      aliases: [ "Original Alias" ]
    )

    session.pin_kb_document!(kb_doc)
    original_added_at = session.reload.active_entities.fetch("Refresh Manual").fetch("added_at")
    kb_doc.update!(aliases: [ "Updated Alias" ])
    session.pin_kb_document!(kb_doc)
    session.reload

    entity = session.active_entities.fetch("Refresh Manual")
    assert_equal 1, session.entity_count
    assert_equal original_added_at, entity["added_at"]
    assert_includes entity["aliases"], "Original Alias"
    assert_includes entity["aliases"], "Updated Alias"
  end

  test 'pin_kb_document! stamps source: user_pin when merging into an auto-extracted entity' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-auto-extracted", channel: "web")
    kb_doc = KbDocument.create!(
      s3_key: "uploads/2026/auto-extracted.pdf",
      display_name: "Auto Extracted Manual",
      aliases: []
    )
    uri = kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
    session.update!(active_entities: {
      "Auto Extracted Manual" => {
        "canonical_name" => "Auto Extracted Manual",
        "kb_document_id" => kb_doc.id,
        "source" => "doc_refs_rule8",
        "source_uri" => uri,
        "aliases" => [],
        "added_at" => 1.minute.ago.iso8601
      }
    })

    assert session.pin_kb_document!(kb_doc)
    session.reload

    assert_equal "user_pin", session.active_entities.fetch("Auto Extracted Manual").fetch("source")
  end

  test 'pin_kb_document! updates source_uri when the same kb_document_id is re-pinned' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-uri-refresh", channel: "web")
    kb_doc = KbDocument.create!(
      s3_key: "uploads/2026/original-location.pdf",
      display_name: "Movable Manual",
      aliases: []
    )

    session.pin_kb_document!(kb_doc)
    kb_doc.update!(s3_key: "uploads/2026/new-location.pdf")
    session.pin_kb_document!(kb_doc)
    session.reload

    assert_equal 1, session.entity_count
    assert_equal(
      [ kb_doc.display_s3_uri(KbDocument::KB_BUCKET) ],
      SessionContextBuilder.entity_s3_uris(session)
    )
    assert_equal "document", session.active_entities.fetch("Movable Manual").fetch("entity_type")
  end

  test 'pin_kb_document! refreshes entity_type when the physical file extension changes' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-type-refresh", channel: "web")
    kb_doc = KbDocument.create!(
      s3_key: "uploads/2026/inspection.pdf",
      display_name: "Inspection",
      aliases: []
    )

    session.pin_kb_document!(kb_doc)
    kb_doc.update!(s3_key: "uploads/2026/inspection.jpg")
    session.pin_kb_document!(kb_doc)

    entity = session.reload.active_entities.fetch("Inspection")
    assert_equal "image_upload", entity["entity_type"]
  end

  test 'unpin_kb_document! removes only the matching uri when aliases overlap' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-selective-unpin", channel: "web")
    first = KbDocument.create!(
      s3_key: "uploads/2026/overlap-a.pdf",
      display_name: "Overlap A",
      aliases: [ "Shared Component" ]
    )
    second = KbDocument.create!(
      s3_key: "uploads/2026/overlap-b.pdf",
      display_name: "Overlap B",
      aliases: [ "shared component" ]
    )

    session.pin_kb_document!(first)
    session.pin_kb_document!(second)
    session.unpin_kb_document!(first)
    session.reload

    assert_equal 1, session.entity_count
    assert_equal(
      [ second.display_s3_uri(KbDocument::KB_BUCKET) ],
      SessionContextBuilder.entity_s3_uris(session)
    )
  end

  test 'pin_kb_document! preserves FIFO eviction at MAX_ENTITIES' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-fifo", channel: "web")
    base_time = 1.hour.ago
    prefilled = {}
    ConversationSession::MAX_ENTITIES.times do |i|
      prefilled["pinned_#{i}"] = {
        "source"     => "user_pin",
        "source_uri" => "s3://bucket/pinned_#{i}.pdf",
        "added_at"   => (base_time + i.seconds).iso8601
      }
    end
    session.update!(active_entities: prefilled)
    newest = KbDocument.create!(
      s3_key: "uploads/2026/newest-pin.pdf",
      display_name: "Newest Pin",
      aliases: []
    )

    session.pin_kb_document!(newest)
    session.reload

    assert_equal ConversationSession::MAX_ENTITIES, session.entity_count
    assert_not session.active_entities.key?("pinned_0")
    assert session.active_entities.key?("Newest Pin")
  end

  test 'shared session keeps distinct pinned documents in the same row' do
    stub_shared_enabled(true) do
      ConversationSession.where(
        identifier: SharedSession::IDENTIFIER,
        channel: SharedSession::CHANNEL
      ).destroy_all
      first = KbDocument.create!(
        s3_key: "uploads/2026/shared-pin-a.pdf",
        display_name: "Shared A",
        aliases: [ "Shared Alias" ]
      )
      second = KbDocument.create!(
        s3_key: "uploads/2026/shared-pin-b.pdf",
        display_name: "Shared B",
        aliases: [ "shared alias" ]
      )

      session_a = ConversationSession.find_or_create_for(identifier: "user-a", channel: "web")
      session_a.pin_kb_document!(first)
      session_b = ConversationSession.find_or_create_for(identifier: "user-b", channel: "web")
      session_b.pin_kb_document!(second)
      session_a.reload

      assert_equal session_a.id, session_b.id
      assert_equal 2, session_a.entity_count
    end
  end

  test 'unpin_kb_document! removes the entity' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-3", channel: "web")
    kb_doc  = KbDocument.create!(s3_key: "uploads/2026/unpin.pdf", display_name: "Unpin", aliases: [])

    session.pin_kb_document!(kb_doc)
    assert session.unpin_kb_document!(kb_doc)
    session.reload

    assert_empty session.active_entities
  end

  test 'unpin_kb_document! returns false if doc was not pinned' do
    session = ConversationSession.find_or_create_for(identifier: "pin-user-4", channel: "web")
    kb_doc  = KbDocument.create!(s3_key: "uploads/2026/never_pinned.pdf", display_name: "X", aliases: [])
    assert_not session.unpin_kb_document!(kb_doc)
  end

  # ─── Episode window ─────────────────────────────────────────────────────────

  def episode_session(history)
    ConversationSession.create!(
      identifier: "web:episode_#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      conversation_history: history
    )
  end

  test 'episode_user_messages keeps user turns inside a 4 hour window' do
    now = Time.zone.parse("2026-09-16T14:00:00-03:00")
    session = episode_session([
      { "role" => "user", "content" => "old", "ts" => (now - 4.hours - 1.second).iso8601 },
      { "role" => "user", "content" => "inside", "ts" => (now - 4.hours + 1.second).iso8601 },
      { "role" => "assistant", "content" => "reply", "ts" => (now - 1.hour).iso8601 },
      { "role" => "user", "content" => "latest", "ts" => now.iso8601 }
    ])

    assert_equal [ "inside", "latest" ], session.episode_user_messages(now: now)
  end

  test 'episode_user_messages excludes the current question' do
    now = Time.zone.parse("2026-09-16T14:00:00-03:00")
    session = episode_session([
      { "role" => "user", "content" => "first", "ts" => (now - 2.minutes).iso8601 },
      { "role" => "user", "content" => "current", "ts" => now.iso8601 }
    ])

    assert_equal [ "first" ], session.episode_user_messages(now: now, exclude: "current")
  end

  test 'episode_user_messages caps at three user messages' do
    now = Time.zone.parse("2026-09-16T14:00:00-03:00")
    history = 4.times.map do |i|
      { "role" => "user", "content" => "q#{i}", "ts" => (now - (4 - i).minutes).iso8601 }
    end
    session = episode_session(history)

    assert_equal [ "q1", "q2", "q3" ], session.episode_user_messages(now: now)
  end

  test 'episode_user_messages ignores missing or invalid timestamps' do
    now = Time.zone.parse("2026-09-16T14:00:00-03:00")
    session = episode_session([
      { "role" => "user", "content" => "no-ts" },
      { "role" => "user", "content" => "bad-ts", "ts" => "not-a-time" },
      { "role" => "user", "content" => "ok", "ts" => now.iso8601 }
    ])

    assert_equal [ "ok" ], session.episode_user_messages(now: now)
  end

  test 'episode_user_messages drops August turns outside the window' do
    now = Time.zone.parse("2026-09-16T10:50:55-03:00")
    session = episode_session([
      { "role" => "user", "content" => "Elemont Montacargas Hidraulico Modelo MH", "ts" => "2026-08-31T17:30:11-04:00" },
      { "role" => "user", "content" => "Hola, tengo una falla eléctrica", "ts" => "2026-09-16T10:49:41-03:00" }
    ])

    assert_equal [ "Hola, tengo una falla eléctrica" ], session.episode_user_messages(now: now)
  end

  test 'last_assistant_message is nil when the last assistant is outside the window' do
    now = Time.zone.parse("2026-09-16T14:00:00-03:00")
    session = episode_session([
      { "role" => "assistant", "content" => "stale reply", "ts" => (now - 4.hours - 1.second).iso8601 },
      { "role" => "user", "content" => "follow-up", "ts" => now.iso8601 }
    ])

    assert_nil session.last_assistant_message(now: now)
  end

  test 'last_assistant_message returns the most recent in-window assistant turn' do
    now = Time.zone.parse("2026-09-16T14:00:00-03:00")
    session = episode_session([
      { "role" => "assistant", "content" => "older", "ts" => (now - 2.hours).iso8601 },
      { "role" => "assistant", "content" => "newer", "ts" => (now - 1.minute).iso8601 }
    ])

    assert_equal "newer", session.last_assistant_message(now: now)
  end

  # ─── active episode shadow writes ───────────────────────────────────────────

  test "record_user_turn! with the flag off matches add_to_history_and_refresh and returns nil" do
    session = web_episode_session
    original_exp = session.expires_at

    result = nil
    queries = []
    count_updates(queries) { result = session.record_user_turn!("Fuji Yida", user_id: users(:one).id, correlation_id: "query:1") }

    session.reload
    assert_nil result
    assert_equal({}, session.active_episode)
    assert_equal "Fuji Yida", session.conversation_history.last["content"]
    assert session.expires_at > original_exp + 1.day
    assert_equal 1, queries.size
  end

  test "record_user_turn! with the flag on writes the episode and keeps the orchestrator text out of the log" do
    session = web_episode_session
    question = "Cómo se ajustan los resortes de la fijación de cables ?"
    result = nil
    events = []

    with_episode_flag("true") do
      events = capture_pilot_events do
        result = session.record_user_turn!(question, user_id: users(:one).id, correlation_id: "query:1")
      end
    end

    session.reload
    assert_equal :opened, result.decision
    assert_equal question, session.active_episode.dig("goal", "text")
    assert_equal question, session.conversation_history.last["content"]
    event = events.find { |row| row["event"] == "field_companion_turn" }
    assert event
    assert_equal "opened", event["episode_decision"]
    assert_equal users(:one).id, event["user_id"]
    assert_equal Digest::SHA256.hexdigest(question), event["original_sha256"]
    assert_equal event["original_sha256"], event["effective_sha256"]
    assert_not_includes JSON.generate(event), question
  end

  test "record_assistant_turn! reads pending_fact from the full reply and stores the truncated history" do
    session = web_episode_session
    question = "Cómo se ajustan los resortes de la fijación de cables ?"
    reply = ("contexto " * 40) + "¿Sabes el modelo del equipo?"
    assert reply.length > ConversationSession::MAX_MSG_LENGTH

    with_episode_flag("true") do
      session.record_user_turn!(question, user_id: users(:one).id, correlation_id: "query:1")
      session.record_assistant_turn!(reply, user_id: users(:one).id, correlation_id: "query:2")
    end

    session.reload
    assert_equal ConversationSession::MAX_MSG_LENGTH, session.conversation_history.last["content"].length
    assert_equal "model", session.active_episode.dig("pending_fact", "subject")
    assert_not_includes session.conversation_history.last["content"], "modelo del equipo"
  end

  test "record_photo_observation! keeps a technician brand and records the photo conflict" do
    session = web_episode_session
    with_episode_flag("true") do
      session.record_user_turn!("Cómo se ajustan los resortes de la fijación de cables ?", user_id: users(:one).id, correlation_id: "query:1")
      session.record_assistant_turn!("… ¿Qué marca y modelo es el equipo?", user_id: users(:one).id, correlation_id: "query:2")
      session.record_user_turn!("Fuji Yida", user_id: users(:one).id, correlation_id: "query:3")
      session.record_photo_observation!(
        photo_value: { manufacturer: "KONE", model_visible: "UNKNOWN" },
        field_photo_id: 42,
        sha256: "abc123",
        correlation_id: "photo:1"
      )
    end

    session.reload
    episode = session.active_episode
    assert_equal "Fuji Yida", episode.dig("facts", "manufacturer", "value")
    assert_equal "user", episode.dig("facts", "manufacturer", "source")
    assert_equal "abc123", episode.dig("active_photo", "sha256")
    assert_equal 42, episode.dig("active_photo", "field_photo_id")
    assert_equal "KONE", episode["conflicts"].first["photo"]
    assert_nil episode.dig("facts", "fault_code")
  end

  test "reset_active_episode! clears the column" do
    session = web_episode_session
    with_episode_flag("true") do
      session.record_user_turn!("Cómo se ajustan los resortes de la fijación de cables ?", user_id: users(:one).id, correlation_id: "query:1")
      session.reset_active_episode!
    end

    assert_equal({}, session.reload.active_episode)
  end

  test "a shared session and a non-web channel do not write the episode" do
    web = web_episode_session
    other = web_episode_session(channel: "whatsapp", identifier: "whatsapp:+15550001111")
    question = "Cómo se ajustan los resortes de la fijación de cables ?"

    with_episode_flag("true") do
      stub_shared_enabled(true) do
        assert_nil web.record_user_turn!(question, user_id: users(:one).id, correlation_id: "query:1")
      end
      assert_nil other.record_user_turn!(question, user_id: users(:one).id, correlation_id: "query:2")
    end

    assert_equal({}, web.reload.active_episode)
    assert_equal({}, other.reload.active_episode)
    assert_equal question, web.conversation_history.last["content"]
  end

  test "X-8 a stale photo-job copy keeps the text turn and the episode fields" do
    session = web_episode_session
    opening = "Elemont MH con placa CEA15, falla en puerta 1: el imán no magnetiza. ¿Qué reviso?"

    with_episode_flag("true") do
      session.record_user_turn!(opening, user_id: users(:one).id, correlation_id: "query:1")
      stale = ConversationSession.find(session.id)
      fresh = ConversationSession.find(session.id)
      fresh.record_user_turn!("código 8", user_id: users(:one).id, correlation_id: "query:2")
      stale.record_assistant_turn!("En el manual KONE, página 12, …", user_id: users(:one).id, correlation_id: "query:3")
    end

    session.reload
    assert_equal [ opening, "código 8", "En el manual KONE, página 12, …" ], session.conversation_history.pluck("content")
    assert_equal "Elemont", session.active_episode.dig("facts", "manufacturer", "value")
    assert_equal "8", session.active_episode.dig("facts", "fault_code", "value")
    assert_includes session.active_episode["identifiers"].pluck("value"), "CEA15"
  end

  test "a hybrid spring follow-up expands only the stored referent" do
    session = web_episode_session
    goal = "Cómo se ajustan los resortes de la fijación de cables?"
    current = "el modelo es MonoSpace, como se ajustan los resortes?"
    result = nil

    travel_to Time.zone.parse("2026-09-23 14:00:00 -03:00") do
      with_episode_flag("true") do
        session.record_user_turn!(goal, user_id: users(:one).id, correlation_id: "query:goal")
        session.record_user_turn!("Fuji Yida", user_id: users(:one).id, correlation_id: "query:fuji")
        result = session.record_user_turn!(current, user_id: users(:one).id, correlation_id: "query:now")
      end
    end

    assert_equal :continued_elliptical, result.decision
    assert_equal goal, result.state.dig("goal", "text")
    assert_equal "MonoSpace", result.state.dig("facts", "model", "value")
    assert_nil result.state.dig("facts", "manufacturer")
    assert_equal "el modelo es MonoSpace, como se ajustan los resortes de la fijación de cables?", result.composed
  end

  test "a hostile semantic analysis cannot change episode facts" do
    hostile = Rag::ConversationalTurnAnalysis.new(
      relation: "switch",
      mentions: [ { "span" => "Nova", "role" => "equipment" } ],
      ambiguous: false
    )
    text = "el modelo es MonoSpace, como se ajustan los resortes?"
    with_episode_flag("true") do
      session = web_episode_session
      assert_raises(ArgumentError) do
        session.record_user_turn!(
          text,
          user_id: users(:one).id,
          correlation_id: "query:hostile",
          conversational_turn_analysis: hostile
        )
      end
      result = session.record_user_turn!(text, user_id: users(:one).id, correlation_id: "query:v4")
      assert_equal "MonoSpace", result.state.dig("facts", "model", "value")
      assert_nil result.state.dig("facts", "manufacturer", "value")
      assert_equal "switch", hostile.relation
    end
    assert_not_includes Rails.root.join("app/services/rag/query_analysis.rb").read, "ConversationalTurnAnalysis"
    assert_not_includes Rails.root.join("app/services/rag/active_episode_turn.rb").read, "ConversationalTurnAnalysis"
  end

  def web_episode_session(channel: "web", identifier: nil)
    ConversationSession.create!(
      identifier: identifier || "web:#{SecureRandom.hex(4)}",
      channel: channel,
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy)
    )
  end

  def with_episode_flag(value)
    previous = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    value.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous
  end

  def count_updates(queries)
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/UPDATE.*conversation_sessions/i) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
  end

  def capture_pilot_events
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    output.string.lines.filter_map do |line|
      JSON.parse(line.split("[PILOT_USAGE] ", 2).last) if line.include?("[PILOT_USAGE]")
    end
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
