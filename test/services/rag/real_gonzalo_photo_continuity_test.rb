# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Rag::RealGonzaloPhotoContinuityTest < ActiveJob::TestCase
  include ActionCable::TestHelper
  parallelize(workers: 1)

  FIXTURE = Rails.root.join("test/fixtures/real_gonzalo/photo_81515_episode.json")
  VISION = {
    "canonical_component" => "conjunto de cabina y puerta",
    "manufacturer" => "UNKNOWN",
    "model" => "UNKNOWN",
    "subsystem" => "UNKNOWN",
    "condition" => "UNKNOWN",
    "aliases" => [],
    "summary" => "Se ve un conjunto de cabina y puerta.",
    "visible_text" => [],
    "documented_functions" => [],
    "documented_connections" => [],
    "documented_values" => [],
    "documented_warnings" => [],
    "anti_hallucination_notes" => "La lectura se limita a lo visible.",
    "target_visible" => false,
    "relevance_to_goal" => "unrelated",
    "missing_view_or_detail" => "primer plano de las fijaciones de cables con sus resortes y de la placa"
  }.freeze

  class RecordingClient
    attr_reader :calls

    def initialize(text)
      @text = text
      @calls = []
    end

    def call(**kwargs)
      @calls << kwargs
      {
        text: @text,
        usage: OpenStruct.new(input_tokens: 120, output_tokens: 40),
        model: "claude-sonnet-5"
      }
    end
  end

  class FakeS3
    def upload_binary(*) = "stored"
    def download(*) = "jpeg"
  end

  setup do
    @fixture = JSON.parse(File.read(FIXTURE))
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @session = ConversationSession.create!(
      identifier: "gonzalo-photo-#{SecureRandom.hex(4)}",
      channel: "web",
      account: accounts(:legacy),
      user: users(:one),
      expires_at: 1.day.from_now,
      conversation_history: @fixture.fetch("history"),
      active_episode: @fixture.fetch("active_episode")
    )
    @orig_s3 = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { FakeS3.new }
    @photo_now = Time.zone.parse(@fixture.fetch("photo_now"))
  end

  teardown do
    Rails.cache = @previous_cache
    orig = @orig_s3
    S3DocumentsService.define_singleton_method(:new) { |*args, **kwargs| orig.call(*args, **kwargs) }
    ENV.delete("PHOTO_QUESTION_RAG_ENABLED")
  end

  test "the blank 81515 photo sends the spring sentence to one fresh vision call" do
    @fixture.fetch("history").each do |message|
      content = message["content"].to_s
      next if content.empty?

      assert_equal message["original_sha256"], Digest::SHA256.hexdigest(content), message["correlation_id"]
    end

    ENV["PHOTO_QUESTION_RAG_ENABLED"] = "true"
    service_calls = 0
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| service_calls += 1 }

    messages = nil
    with_client do |client|
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        travel_to(@photo_now) { FieldPhotoAnalysisJob.perform_now(**job_args) }
      end

      assert_equal 1, client.calls.size
      intent = intent_text(client.calls.first)
      assert_includes intent, "resortes"
      assert_includes intent, "fijación"
      assert_not_includes intent, "transformador"
      assert_not_includes intent, "otra imagen"
    end

    assert_equal 0, service_calls
    summary = messages.last["summary"]
    missing = VISION.fetch("missing_view_or_detail")
    assert summary.start_with?(I18n.t("rag.photo_intent.target_hidden", missing: missing, locale: :es))
    assert_includes summary, "primer plano"
    assert_equal "photo_analyzed", messages.last["status"]
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
  end

  test "the e9cea question reaches vision again for the same spring-photo sha" do
    ENV["PHOTO_QUESTION_RAG_ENABLED"] = "true"
    question = @fixture.fetch("e9cea_question")
    service_calls = 0
    answer = Object.new
    answer.define_singleton_method(:call) do
      service_calls += 1
      { answer: "Respuesta", citations: [], generation_mode: "test" }
    end
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| answer }

    messages = nil
    with_client do |client|
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        travel_to(@photo_now) do
          FieldPhotoAnalysisJob.perform_now(**job_args(question: question))
          FieldPhotoAnalysisJob.perform_now(**job_args(question: question, image_token: fresh_token))
        end
      end

      assert_equal 2, client.calls.size
      client.calls.each do |call|
        intent = intent_text(call)
        assert_includes intent, question
        assert_not_includes intent, "otra imagen"
        assert_not_includes intent, "poregunat"
        assert_not_includes intent, "transformador"
      end
    end

    assert_equal 2, service_calls
    assert_equal [ "photo_question_answered", "photo_question_answered" ], messages.pluck("status")
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
  end

  private

  def with_client
    client = RecordingClient.new(JSON.generate(VISION))
    original = ClaudeChunkingClient.method(:new)
    ClaudeChunkingClient.define_singleton_method(:new) { |**_| client }
    yield client
  ensure
    ClaudeChunkingClient.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) } if original
  end

  def intent_text(call)
    call[:user_content].reverse.find { |block| block[:type] == "text" }[:text]
  end

  def spring_sha
    prefix = @fixture.fetch("image_digest_prefix")
    prefix + ("ab" * ((64 - prefix.length) / 2))
  end

  def fresh_token
    FieldPhotoPendingImageStore.write(
      binary: "jpeg", content_type: "image/jpeg", filename: "springs.jpg",
      account_id: accounts(:legacy).id
    )
  end

  def job_args(question: nil, image_token: nil)
    {
      image_token: image_token || fresh_token,
      image_sha256: spring_sha,
      filename: "springs.jpg",
      content_type: "image/jpeg",
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conversation_session_id: @session.id,
      locale: "es",
      correlation_id: "photo:gonzalo-replay",
      question: question
    }
  end
end
