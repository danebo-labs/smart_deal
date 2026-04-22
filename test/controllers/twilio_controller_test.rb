# frozen_string_literal: true

require 'test_helper'

class TwilioControllerTest < ActionDispatch::IntegrationTest
  TEST_QUESTION = 'What is S3?'
  TEST_ANSWER   = 'This is a test answer about S3'

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  def with_mock_orchestrator(mock_orchestrator)
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_args, **_kwargs| mock_orchestrator }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  def create_mock_orchestrator(answer:, citations: [], session_id: 'test-session-123',
                               should_raise: false, error_class: StandardError, error_message: nil)
    mock = Object.new
    mock.define_singleton_method(:execute) do
      raise error_class, error_message || 'Service error' if should_raise
      { answer: answer, citations: citations, session_id: session_id }
    end
    mock
  end

  def text_params(body, from: 'whatsapp:+56912345678', to: 'whatsapp:+14155238886')
    { 'Body' => body, 'NumMedia' => '0', 'From' => from, 'To' => to }
  end

  # Temporarily replaces the NullStore (test default) with an in-memory cache
  # so that dedup logic can be exercised within a single test.
  def stub_shared_enabled(enabled)
    orig = SharedSession::ENABLED
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, enabled)
    yield
  ensure
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, orig)
  end

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  # -----------------------------------------------------------------------
  # Authentication
  # -----------------------------------------------------------------------

  test 'webhook does not require authentication' do
    post twilio_webhook_url, params: text_params(TEST_QUESTION)
    assert_response :success
  end

  # -----------------------------------------------------------------------
  # Text-only path: enqueues job + returns empty TwiML immediately
  # -----------------------------------------------------------------------

  test 'webhook returns empty TwiML and enqueues job for text message' do
    assert_enqueued_with(job: SendWhatsappReplyJob) do
      post twilio_webhook_url, params: text_params(TEST_QUESTION)
    end

    assert_response :success
    assert_equal 'application/xml; charset=utf-8', @response.content_type
    assert_includes @response.body, '<?xml'
    assert_includes @response.body, '<Response'
    # Body must NOT contain the answer — it is delivered by the job via REST API
    assert_not_includes @response.body, TEST_ANSWER
  end

  test 'webhook enqueues job with correct to/from/body and a valid conv_session_id' do
    post twilio_webhook_url, params: text_params(TEST_QUESTION,
                                                 from: 'whatsapp:+56912345678',
                                                 to:   'whatsapp:+14155238886')

    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |j| j[:job] == SendWhatsappReplyJob }
    assert enqueued, 'SendWhatsappReplyJob was not enqueued'

    args = enqueued[:args].first
    assert_equal 'whatsapp:+56912345678', args['to']
    assert_equal 'whatsapp:+14155238886', args['from']
    assert_equal TEST_QUESTION,           args['body']

    session = ConversationSession.find_by(identifier: 'whatsapp:+56912345678', channel: 'whatsapp')
    assert session
    assert_equal session.id, args['conv_session_id']
  end

  test 'webhook creates a ConversationSession for the sender' do
    assert_difference 'ConversationSession.count', 1 do
      post twilio_webhook_url, params: text_params(TEST_QUESTION, from: 'whatsapp:+56912345678')
    end

    session = ConversationSession.find_by(identifier: 'whatsapp:+56912345678', channel: 'whatsapp')
    assert session
    assert_not session.expired?
    assert_equal 1, session.conversation_history.size
    assert_equal 'user',        session.conversation_history.first['role']
    assert_equal TEST_QUESTION, session.conversation_history.first['content']
  end

  test 'webhook reuses existing active session for repeat sender' do
    post twilio_webhook_url, params: text_params('First message', from: 'whatsapp:+56912345678')

    assert_no_difference 'ConversationSession.count' do
      post twilio_webhook_url, params: text_params('Second message', from: 'whatsapp:+56912345678')
    end

    session = ConversationSession.find_by(identifier: 'whatsapp:+56912345678', channel: 'whatsapp')
    assert_equal 2, session.conversation_history.size
  end

  # -----------------------------------------------------------------------
  # Idempotency: Twilio retries with the SAME MessageSid are deduplicated.
  # User re-asking the same question (different SID) is NOT blocked — body
  # duplication is handled at the persistence layer (TechnicianDocument).
  # -----------------------------------------------------------------------

  test 'webhook deduplicates Twilio retry with same MessageSid' do
    with_memory_cache do
      assert_enqueued_jobs 1, only: SendWhatsappReplyJob do
        post twilio_webhook_url, params: text_params(
          'que es Electromagnetic disc brake ?',
          from: 'whatsapp:+56999000001'
        ).merge('MessageSid' => 'SMSAMESID')

        post twilio_webhook_url, params: text_params(
          'que es Electromagnetic disc brake ?',
          from: 'whatsapp:+56999000001'
        ).merge('MessageSid' => 'SMSAMESID')
      end
    end
  end

  test 'webhook does NOT block user re-asking identical question (different SIDs)' do
    with_memory_cache do
      assert_enqueued_jobs 2, only: SendWhatsappReplyJob do
        post twilio_webhook_url, params: text_params(
          'que es Electromagnetic disc brake ?',
          from: 'whatsapp:+56999000005'
        ).merge('MessageSid' => 'SMRETRY1')

        post twilio_webhook_url, params: text_params(
          'que es Electromagnetic disc brake ?',
          from: 'whatsapp:+56999000005'
        ).merge('MessageSid' => 'SMRETRY2')
      end
    end
  end

  # -----------------------------------------------------------------------
  # SharedSession: all WhatsApp numbers collapse to one row when ENABLED
  # -----------------------------------------------------------------------

  test 'two WhatsApp webhooks from different numbers share the same conv_session_id in shared mode' do
    stub_shared_enabled(true) do
      ConversationSession.where(identifier: SharedSession::IDENTIFIER, channel: SharedSession::CHANNEL).destroy_all

      before_count = ActiveJob::Base.queue_adapter.enqueued_jobs.size
      post twilio_webhook_url, params: text_params('hello', from: 'whatsapp:+56911110010')
      post twilio_webhook_url, params: text_params('world', from: 'whatsapp:+56922220010')

      new_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs[before_count..].select { |j| j[:job] == SendWhatsappReplyJob }
      assert_equal 2, new_jobs.size
      session_ids = new_jobs.map { |j| j[:args].first['conv_session_id'] }
      assert_equal 1, session_ids.uniq.size, 'Both jobs must reference the same shared conv_session_id'

      assert_equal 1, ConversationSession.where(identifier: SharedSession::IDENTIFIER, channel: SharedSession::CHANNEL).count
    end
  end

  # -----------------------------------------------------------------------
  # Blank / nil / whitespace: job is still enqueued (error handled inside job)
  # -----------------------------------------------------------------------

  test 'webhook enqueues job even for empty message' do
    assert_enqueued_with(job: SendWhatsappReplyJob) do
      post twilio_webhook_url, params: text_params('')
    end
    assert_response :success
    assert_includes @response.body, '<Response'
  end

  test 'webhook enqueues job even for nil body' do
    assert_enqueued_with(job: SendWhatsappReplyJob) do
      post twilio_webhook_url, params: text_params(nil)
    end
    assert_response :success
  end

  test 'webhook enqueues job even for whitespace-only message' do
    assert_enqueued_with(job: SendWhatsappReplyJob) do
      post twilio_webhook_url, params: text_params('   ')
    end
    assert_response :success
  end
end
