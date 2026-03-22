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

  # ─── add_entity ─────────────────────────────────────────────────────────────

  test 'add_entity stores entity and returns true' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+88888888888',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    result = s.add_entity('schema.pdf', [ 'chunk1', 'chunk2' ])
    s.reload

    assert result
    assert s.active_entities.key?('schema.pdf')
    assert_equal [ 'chunk1', 'chunk2' ], s.active_entities['schema.pdf']['chunks']
  end

  test 'add_entity returns false when MAX_ENTITIES reached' do
    s = ConversationSession.create!(
      identifier: 'whatsapp:+99999999999',
      channel:    'whatsapp',
      expires_at: 30.minutes.from_now
    )

    ConversationSession::MAX_ENTITIES.times { |i| s.add_entity("doc_#{i}.pdf", []) }
    result = s.add_entity('overflow.pdf', [])

    assert_not result
    assert_equal ConversationSession::MAX_ENTITIES, s.reload.entity_count
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
end
