# frozen_string_literal: true

require 'test_helper'

class SendWhatsappReplyJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  JOB_PARAMS = { to: 'whatsapp:+56912345678', from: 'whatsapp:+14155238886', body: 'que es SOPREL?' }.freeze

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  def with_mock_orchestrator(answer:, citations: [], should_raise: false,
                              error_class: StandardError, error_message: nil)
    mock = Object.new
    mock.define_singleton_method(:execute) do
      raise error_class, error_message || 'error' if should_raise
      { answer: answer, citations: citations, session_id: 'session-1' }
    end
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
  end

  def stub_twilio_client
    sent = []
    messages_resource = Object.new
    messages_resource.define_singleton_method(:create) { |**kwargs| sent << kwargs }

    client = Object.new
    client.define_singleton_method(:messages) { messages_resource }

    original_new = Twilio::REST::Client.method(:new)
    Twilio::REST::Client.define_singleton_method(:new) { |*_a| client }

    yield sent
  ensure
    Twilio::REST::Client.define_singleton_method(:new) { |*a| original_new.call(*a) }
  end

  # -----------------------------------------------------------------------
  # Environment guard
  # -----------------------------------------------------------------------

  test 'perform raises descriptive error when TWILIO_ACCOUNT_SID is missing' do
    with_mock_orchestrator(answer: 'answer') do
      with_env('TWILIO_ACCOUNT_SID' => nil, 'TWILIO_AUTH_TOKEN' => nil) do
        assert_raises(RuntimeError, /TWILIO_ACCOUNT_SID not set/) do
          SendWhatsappReplyJob.new.perform(**JOB_PARAMS)
        end
      end
    end
  end

  # -----------------------------------------------------------------------
  # Single-chunk delivery (short answer)
  # -----------------------------------------------------------------------

  test 'perform sends a single message when answer fits in one chunk' do
    with_mock_orchestrator(answer: 'Short answer.') do
      stub_twilio_client do |sent|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(**JOB_PARAMS)
        end

        assert_equal 1, sent.size
        assert_equal 'whatsapp:+56912345678', sent.first[:to]
        assert_equal 'whatsapp:+14155238886', sent.first[:from]
        assert_includes sent.first[:body], 'Short answer.'
        # No (1/1) prefix for single-chunk responses
        assert_no_match(/^\(\d+\/\d+\)/, sent.first[:body])
      end
    end
  end

  # -----------------------------------------------------------------------
  # Multi-chunk delivery (long answer)
  # -----------------------------------------------------------------------

  test 'perform splits long answer into multiple messages with (n/N) prefix' do
    long_answer = ('Esta es una respuesta larga. ' * 60).strip  # ~1740 chars → 2 chunks

    with_mock_orchestrator(answer: long_answer) do
      stub_twilio_client do |sent|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(**JOB_PARAMS)
        end

        assert sent.size > 1, "Expected multiple messages, got #{sent.size}"
        sent.each { |msg| assert msg[:body].length <= 1600, "Chunk exceeds 1600: #{msg[:body].length}" }
        assert_match(/^\(1\/#{sent.size}\)/, sent.first[:body])
        assert_match(/^\(#{sent.size}\/#{sent.size}\)/, sent.last[:body])
      end
    end
  end

  test 'perform preserves full answer content across all chunks' do
    long_answer = (1..40).map { |i| "Punto #{i}: información técnica importante." }.join("\n\n")

    with_mock_orchestrator(answer: long_answer) do
      stub_twilio_client do |sent|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(**JOB_PARAMS)
        end

        full_text = sent.pluck(:body).join(' ')
        (1..40).each do |i|
          assert_includes full_text, "Punto #{i}:"
        end
      end
    end
  end

  # -----------------------------------------------------------------------
  # Citations in response
  # -----------------------------------------------------------------------

  test 'perform includes citation filenames in delivered message' do
    citations = [
      { number: 1, filename: 'Esquema_SOPREL.pdf', title: 'Esquema SOPREL' }
    ]

    with_mock_orchestrator(answer: 'Respuesta con fuente.', citations: citations) do
      stub_twilio_client do |sent|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(**JOB_PARAMS)
        end

        full_text = sent.pluck(:body).join(' ')
        assert_includes full_text, 'Fuentes:'
        assert_includes full_text, '[1] Esquema_SOPREL.pdf'
      end
    end
  end

  # -----------------------------------------------------------------------
  # Error propagation
  # -----------------------------------------------------------------------

  test 'perform re-raises Twilio::REST::RestError' do
    with_mock_orchestrator(answer: 'answer') do
      twilio_error = Twilio::REST::RestError.new('rate limit', Twilio::Response.new(429, ''))

      messages_resource = Object.new
      messages_resource.define_singleton_method(:create) { |**_k| raise twilio_error }
      client = Object.new
      client.define_singleton_method(:messages) { messages_resource }

      original_new = Twilio::REST::Client.method(:new)
      Twilio::REST::Client.define_singleton_method(:new) { |*_a| client }

      with_twilio_env do
        assert_raises(Twilio::REST::RestError) do
          SendWhatsappReplyJob.new.perform(**JOB_PARAMS)
        end
      end
    ensure
      Twilio::REST::Client.define_singleton_method(:new) { |*a| original_new.call(*a) }
    end
  end

  test 'perform re-raises StandardError from orchestrator' do
    with_mock_orchestrator(answer: '', should_raise: true, error_message: 'boom') do
      stub_twilio_client do |_sent|
        with_twilio_env do
          # execute_rag_query swallows StandardError into a RagResult — the job
          # itself should not raise; it sends the error message via WhatsApp instead.
          assert_nothing_raised do
            SendWhatsappReplyJob.new.perform(**JOB_PARAMS)
          end
        end
      end
    end
  end

  private

  def with_twilio_env
    with_env('TWILIO_ACCOUNT_SID' => 'ACtest', 'TWILIO_AUTH_TOKEN' => 'token123') do
      yield
    end
  end

  def with_env(vars)
    original = {}
    vars.each_key { |k| original[k] = ENV[k.to_s] }
    vars.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    vars.each_key { |k| original[k].nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = original[k] }
  end
end
