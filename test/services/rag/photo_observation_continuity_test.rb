# frozen_string_literal: true

require "test_helper"

class Rag::PhotoObservationContinuityTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  parallelize(workers: 1)

  POSITIVES = [
    "estos resortes",
    "según la foto",
    "la imagen que te mandé",
    "lo que se ve ahí"
  ].freeze

  NEGATIVES = [
    "según el manual",
    "el borne 24",
    "fotocélula del embarque",
    "mandame el procedimiento"
  ].freeze

  setup do
    clear_enqueued_jobs
    @previous_photo_flag = ENV["PHOTO_QUESTION_RAG_ENABLED"]
    ENV.delete("PHOTO_QUESTION_RAG_ENABLED")
    @anthropic_calls = 0
    @bedrock_calls = 0
    @fetch_calls = 0
    @analysis_new = FieldPhotoAnalysisService.method(:new)
    @claude_new = ClaudeChunkingClient.method(:new)
    @fetch_binary = FieldPhotoStore.method(:fetch_binary)
    @rag_query = BedrockRagService.instance_method(:query)
    analysis_new = @analysis_new
    claude_new = @claude_new
    fetch_binary = @fetch_binary
    counter = self
    FieldPhotoAnalysisService.define_singleton_method(:new) do |*args, **kwargs|
      counter.anthropic_calls += 1
      analysis_new.call(*args, **kwargs)
    end
    ClaudeChunkingClient.define_singleton_method(:new) do |*args, **kwargs|
      counter.anthropic_calls += 1
      claude_new.call(*args, **kwargs)
    end
    FieldPhotoStore.define_singleton_method(:fetch_binary) do |photo|
      counter.fetch_calls += 1
      fetch_binary.call(photo)
    end
    BedrockRagService.define_method(:query) do |*|
      counter.bedrock_calls += 1
      { answer: "respuesta de manual", citations: [], session_id: nil }
    end
  end

  teardown do
    if @previous_photo_flag.nil?
      ENV.delete("PHOTO_QUESTION_RAG_ENABLED")
    else
      ENV["PHOTO_QUESTION_RAG_ENABLED"] = @previous_photo_flag
    end
    analysis_new = @analysis_new
    claude_new = @claude_new
    fetch_binary = @fetch_binary
    rag_query = @rag_query
    FieldPhotoAnalysisService.define_singleton_method(:new) { |*args, **kwargs| analysis_new.call(*args, **kwargs) }
    ClaudeChunkingClient.define_singleton_method(:new) { |*args, **kwargs| claude_new.call(*args, **kwargs) }
    FieldPhotoStore.define_singleton_method(:fetch_binary) { |photo| fetch_binary.call(photo) }
    BedrockRagService.define_method(:query, rag_query)
  end

  attr_accessor :anthropic_calls, :bedrock_calls, :fetch_calls

  test "reference phrases are outside DEICTIC_RE and negatives do not reuse" do
    assert_equal(
      /\b(esa|ese|eso|esta|este|esto|that|this)\s+(placa|foto|imagen|plate|photo)\b/.source,
      Rag::ActiveEpisodeTurn::DEICTIC_RE.source
    )

    POSITIVES.each do |phrase|
      normalized = normalize(phrase)
      assert Rag::PhotoObservationContinuity.visual_reference?(normalized), phrase
      assert_not Rag::ActiveEpisodeTurn::DEICTIC_RE.match?(normalized), phrase
    end

    NEGATIVES.each do |phrase|
      normalized = normalize(phrase)
      assert_not Rag::PhotoObservationContinuity.visual_reference?(normalized), phrase
      assert_not Rag::PhotoObservationContinuity.visual_reread?(normalized), phrase
    end
  end

  test "volve a mirar is an explicit reread and a bare verb is not" do
    assert_equal "volve a mirar", normalize("volvé a mirar")

    [ "volvé a mirar", "volve a mirar", "vuelve a mirar", "volver a mirar" ].each do |phrase|
      assert Rag::PhotoObservationContinuity.visual_reread?(normalize(phrase)), phrase
    end

    [ "revisa otra vez", "mira de nuevo", "analiza nuevamente", "otra vez la foto", "de nuevo la imagen" ].each do |phrase|
      assert Rag::PhotoObservationContinuity.visual_reread?(normalize(phrase)), phrase
    end

    [ "mira", "mirá", "revisa", "analiza" ].each do |phrase|
      assert_not Rag::PhotoObservationContinuity.visual_reread?(normalize(phrase)), phrase
    end
  end

  test "field_photo_id plus volve a mirar rereads with one vision call" do
    photo = create_photo(accounts(:legacy))
    store_observation!(photo, manufacturer: "OTIS")
    vision_calls = 0
    install_vision_stub(lambda {
      vision_calls += 1
      reread_analysis_result
    })

    decision = Rag::PhotoObservationContinuity.decide(
      question: "volvé a mirar",
      images: [],
      field_photo_id: photo.id,
      account: accounts(:legacy),
      session: nil
    )
    assert_equal :reread, decision.action
    assert_equal photo.id, decision.photo.id

    events = capture_events do
      perform_enqueued_jobs do
        QueryOrchestratorService.new(
          "volvé a mirar",
          account: accounts(:legacy),
          field_photo_id: photo.id,
          user_id: users(:one).id,
          correlation_id: "photo:reread-volve"
        ).execute
      end
    end

    assert_equal 1, vision_calls
    assert_equal 0, anthropic_calls
    assert_equal "SCHINDLER", photo.reload.visual_observation["manufacturer"]
    assert_not photo.visual_observation.key?("summary")
    reread = events.find { |event| event["event"] == "photo_observation_reread" }
    assert_equal "reread", reread["cache_status"]
    assert_equal photo.sha256.first(12), reread["image_digest_prefix"]
    assert_equal "photo:reread-volve", reread["correlation_id"]
  end

  test "field_photo_id plus mira is reuse and segun la foto does not call Anthropic" do
    photo = create_photo(accounts(:legacy))
    store_observation!(photo, manufacturer: "KONE")

    bare = Rag::PhotoObservationContinuity.decide(
      question: "mira",
      images: [],
      field_photo_id: photo.id,
      account: accounts(:legacy),
      session: nil
    )
    assert_equal :reuse, bare.action
    assert_not Rag::PhotoObservationContinuity.visual_reread?(normalize("mira"))

    events = capture_events do
      perform_enqueued_jobs do
        QueryOrchestratorService.new(
          "según la foto",
          account: accounts(:legacy),
          field_photo_id: photo.id,
          user_id: users(:one).id,
          correlation_id: "photo:reuse-segun"
        ).execute
      end
    end

    assert_equal 0, anthropic_calls
    assert_equal 0, fetch_calls
    assert_equal "KONE", photo.reload.visual_observation["manufacturer"]
    reused = events.find { |event| event["event"] == "photo_observation_reused" }
    assert_equal "reused", reused["cache_status"]
  end

  test "new image bytes enqueue a fresh analysis and do not reuse the stored observation" do
    photo = create_photo(accounts(:legacy))
    store_observation!(photo, manufacturer: "OTIS")
    image = { data: Base64.strict_encode64("new-bytes"), binary: "new-bytes", media_type: "image/jpeg", filename: "new.jpg" }

    QueryOrchestratorService.new(
      "según la foto",
      images: [ image ],
      account: accounts(:legacy),
      field_photo_id: photo.id
    ).execute

    args = photo_job_args
    assert args["image_token"].present?
    assert_nil args["continuity"]
    assert_not_equal photo.sha256, args["image_sha256"]
    assert_equal 0, anthropic_calls
  end

  test "an explicit photo with a reread phrase enqueues a new analysis" do
    photo = create_photo(accounts(:legacy))
    store_observation!(photo)

    QueryOrchestratorService.new(
      "revisa otra vez la foto",
      account: accounts(:legacy),
      field_photo_id: photo.id
    ).execute

    args = photo_job_args
    assert_nil args["image_token"]
    assert_equal "reread", args["continuity"]
    assert_equal photo.id, args["field_photo_id"]
    assert_equal 0, anthropic_calls
  end

  test "an explicit photo without a reread reuses the observation and does not call Anthropic" do
    photo = create_photo(accounts(:legacy))
    store_observation!(photo, manufacturer: "KONE")

    events = capture_events do
      perform_enqueued_jobs do
        QueryOrchestratorService.new(
          "Qué significa esto?",
          account: accounts(:legacy),
          field_photo_id: photo.id,
          user_id: users(:one).id,
          correlation_id: "photo:reuse-explicit"
        ).execute
      end
    end

    assert_equal 0, anthropic_calls
    assert_equal 0, fetch_calls
    assert_equal "KONE", photo.reload.visual_observation["manufacturer"]
    reused = events.find { |event| event["event"] == "photo_observation_reused" }
    assert_equal "reused", reused["cache_status"]
    assert_equal photo.sha256.first(12), reused["image_digest_prefix"]
    assert_equal "photo:reuse-explicit", reused["correlation_id"]
    assert_not reused.key?("knowledge_scope")
    (reused.keys - %w[event ts]).each do |key|
      assert_includes PilotUsageLog::ALLOWED_FIELDS.map(&:to_s), key
    end
  end

  test "text references reuse only the session active photo and do not call Anthropic" do
    photo = create_photo(accounts(:legacy))
    store_observation!(photo, manufacturer: "KONE")
    session = web_session
    remember_photo(session, photo)

    POSITIVES.each do |phrase|
      clear_enqueued_jobs
      self.anthropic_calls = 0
      self.fetch_calls = 0

      QueryOrchestratorService.new(
        phrase,
        account: accounts(:legacy),
        conv_session: session,
        user_id: users(:one).id
      ).execute

      args = photo_job_args
      assert_equal "reuse", args["continuity"], phrase
      assert_equal photo.id, args["field_photo_id"], phrase
      perform_enqueued_jobs
      assert_equal 0, anthropic_calls, phrase
      assert_equal 0, fetch_calls, phrase
    end
  end

  test "a visual reference without a current photo returns the deterministic message and does not call Anthropic" do
    session = web_session

    result = QueryOrchestratorService.new(
      "según la foto",
      account: accounts(:legacy),
      conv_session: session
    ).execute

    assert_equal Rag::PhotoObservationContinuity::MISSING_PHOTO_MESSAGE, result[:answer]
    assert_empty enqueued_jobs.select { |job| job[:job] == FieldPhotoAnalysisJob }
    assert_equal 0, anthropic_calls
    assert_equal 0, bedrock_calls
  end

  test "negative phrases do not reuse a stored observation" do
    photo = create_photo(accounts(:legacy))
    store_observation!(photo, manufacturer: "KONE")
    session = web_session
    remember_photo(session, photo)

    NEGATIVES.each do |phrase|
      clear_enqueued_jobs
      self.anthropic_calls = 0
      self.bedrock_calls = 0

      result = QueryOrchestratorService.new(
        phrase,
        account: accounts(:legacy),
        conv_session: session
      ).execute

      assert_equal "respuesta de manual", result[:answer], phrase
      assert_empty enqueued_jobs.select { |job| job[:job] == FieldPhotoAnalysisJob }, phrase
      assert_equal 0, anthropic_calls, phrase
      assert_equal 1, bedrock_calls, phrase
      assert_not_includes result[:answer], "KONE"
    end
  end

  test "a foreign field_photo_id is not reused and is not a fallback to active_photo" do
    foreign = create_photo(accounts(:climb), manufacturer: "OTIS-SECRET")
    local = create_photo(accounts(:legacy))
    store_observation!(local, manufacturer: "KONE")
    session = web_session
    remember_photo(session, local)

    referenced = QueryOrchestratorService.new(
      "según la foto",
      account: accounts(:legacy),
      conv_session: session,
      field_photo_id: foreign.id
    ).execute

    assert_equal Rag::PhotoObservationContinuity::MISSING_PHOTO_MESSAGE, referenced[:answer]
    assert_not_includes referenced[:answer], "OTIS-SECRET"
    assert_not_includes referenced[:answer], "KONE"
    assert_empty enqueued_jobs.select { |job| job[:job] == FieldPhotoAnalysisJob }
    assert_equal 0, anthropic_calls
    assert_equal 0, bedrock_calls

    clear_enqueued_jobs
    plain = QueryOrchestratorService.new(
      "What does this mean?",
      account: accounts(:legacy),
      field_photo_id: foreign.id
    ).execute

    assert_equal "respuesta de manual", plain[:answer]
    assert_not_includes plain[:answer], "OTIS-SECRET"
    assert_empty enqueued_jobs.select { |job| job[:job] == FieldPhotoAnalysisJob }
  end

  test "a foreign active_photo is not reused" do
    foreign = create_photo(accounts(:climb), manufacturer: "OTIS-SECRET")
    session = web_session
    remember_photo(session, foreign)

    result = QueryOrchestratorService.new(
      "la imagen que te mandé",
      account: accounts(:legacy),
      conv_session: session
    ).execute

    assert_equal Rag::PhotoObservationContinuity::MISSING_PHOTO_MESSAGE, result[:answer]
    assert_not_includes result[:answer], "OTIS-SECRET"
    assert_equal 0, anthropic_calls
    assert_equal 0, bedrock_calls
    assert_empty enqueued_jobs.select { |job| job[:job] == FieldPhotoAnalysisJob }
  end

  test "an owned photo without a stored observation does not call Anthropic" do
    photo = create_photo(accounts(:legacy))

    result = QueryOrchestratorService.new(
      "Qué significa esto?",
      account: accounts(:legacy),
      field_photo_id: photo.id
    ).execute

    assert_equal "respuesta de manual", result[:answer]
    assert_empty enqueued_jobs.select { |job| job[:job] == FieldPhotoAnalysisJob }
    assert_equal 0, anthropic_calls
    assert_equal 1, bedrock_calls
  end

  test "text-only reread wording reuses active_photo when it also names the photo" do
    photo = create_photo(accounts(:legacy))
    store_observation!(photo)
    session = web_session
    remember_photo(session, photo)

    decision = Rag::PhotoObservationContinuity.decide(
      question: "revisa otra vez la foto",
      images: [],
      field_photo_id: nil,
      account: accounts(:legacy),
      session: session
    )

    assert_equal :reuse, decision.action
    assert_equal photo.id, decision.photo.id
  end

  test "telemetry fields for observation reuse were already allowlisted" do
    %i[cache_status image_digest_prefix correlation_id].each do |key|
      assert_includes PilotUsageLog::ALLOWED_FIELDS, key
    end
  end

  private

  def normalize(text)
    Rag::FollowupQueryRewriter.normalize_label(text)
  end

  def web_session
    ConversationSession.create!(
      identifier: "f5-#{SecureRandom.hex(4)}",
      channel: "web",
      account: accounts(:legacy),
      user: users(:one),
      expires_at: 1.day.from_now
    )
  end

  def create_photo(account, manufacturer: nil)
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: account,
      sha256: sha,
      s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 8
    )
    store_observation!(photo, manufacturer: manufacturer) if manufacturer
    photo
  end

  def store_observation!(photo, manufacturer: "KONE")
    parsed = {
      "canonical_component" => "resortes",
      "manufacturer" => manufacturer,
      "model" => "UNKNOWN",
      "subsystem" => "DOOR_OPERATOR",
      "condition" => "DEGRADED",
      "visible_text" => [ "R1" ],
      "summary" => "no guardar",
      "target_visible" => true,
      "relevance_to_goal" => "relevant"
    }
    FieldPhotoObservation.persist!(
      photo,
      FieldPhotoObservation.from_analysis(
        parsed: parsed,
        model_id: "claude-sonnet-5-5",
        target_visible: parsed["target_visible"],
        relevance_to_goal: parsed["relevance_to_goal"]
      )
    )
    photo.reload
  end

  def remember_photo(session, photo)
    session.update!(active_episode: {
      "v" => 1,
      "episode_id" => "ep_f5_#{photo.id}",
      "status" => "active",
      "opened_at" => Time.current.iso8601,
      "updated_at" => Time.current.iso8601,
      "active_photo" => {
        "field_photo_id" => photo.id,
        "sha256" => photo.sha256,
        "correlation_id" => "photo:old",
        "visual_observation" => { "manufacturer" => "LEAK" },
        "summary" => "prosa"
      }
    })
  end

  def photo_job_args
    enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
  end

  def install_vision_stub(on_call)
    FieldPhotoAnalysisService.define_singleton_method(:new) do |**|
      fake = Object.new
      fake.define_singleton_method(:call) { on_call.call }
      fake
    end
    FieldPhotoStore.define_singleton_method(:fetch_binary) { |_photo| "jpeg-bytes" }
  end

  def reread_analysis_result
    {
      analysis: "lectura",
      compact_context: "lectura",
      canonical_name: "resortes",
      aliases: [],
      model: "claude-sonnet-5-5",
      usage: { input_tokens: 10, output_tokens: 5 },
      latency_ms: 1,
      parsed: {
        "canonical_component" => "resortes",
        "manufacturer" => "SCHINDLER",
        "model" => "UNKNOWN",
        "subsystem" => "DOOR_OPERATOR",
        "condition" => "GOOD",
        "visible_text" => [ "R2" ],
        "summary" => "no guardar",
        "target_visible" => true,
        "relevance_to_goal" => "relevant"
      }
    }
  end

  def capture_events
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
