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
end
