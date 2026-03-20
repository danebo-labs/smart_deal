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

  test 'webhook enqueues job with correct to/from/body params' do
    assert_enqueued_with(
      job: SendWhatsappReplyJob,
      args: [ { to: 'whatsapp:+56912345678', from: 'whatsapp:+14155238886', body: TEST_QUESTION } ]
    ) do
      post twilio_webhook_url, params: text_params(TEST_QUESTION,
                                                   from: 'whatsapp:+56912345678',
                                                   to:   'whatsapp:+14155238886')
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
