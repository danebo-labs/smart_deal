# frozen_string_literal: true

require "test_helper"

class Rag::Phase2RetrievedBodyGateTest < ActiveSupport::TestCase
  KEY = Rag::Phase2RetrievedBodyGate::CHUNK_KEY
  FOREIGN_KEY = "bulk_chunks/3/5b1859a0bfe1c5b11e58214555f8c2fe93e6/chunk_p5_1.txt"
  CANDIDATE_PATH = Rails.root.join("test/fixtures/files/elemont/page5_botonera_branch/chunk_p5_1_candidate.txt")
  PREVIOUS_PATH = Rails.root.join("test/fixtures/files/elemont/page5_safety_note/chunk_p5_1_after.txt")
  MARK = "puente semicircular sin punto de unión"

  setup do
    @candidate = CANDIDATE_PATH.binread.force_encoding(Encoding::UTF_8)
    @previous = PREVIOUS_PATH.binread.force_encoding(Encoding::UTF_8)
    @gate = Rag::Phase2RetrievedBodyGate
    @gate.disarm!
  end

  teardown do
    @gate.disarm!
    Rag::Phase2ModelBudget.disarm! if defined?(Rag::Phase2ModelBudget)
    Rag::Phase2RetrieveLimit.disarm! if defined?(Rag::Phase2RetrieveLimit)
  end

  test "the fixture bytes are the accepted and previous bodies" do
    assert_equal 9193, @candidate.bytesize
    assert_equal @gate::CANDIDATE_SHA256[0], Digest::SHA256.hexdigest(@candidate)
    assert_equal @gate::CANDIDATE_SHA256[1], Digest::SHA256.hexdigest(@candidate + "\n")
    assert_equal 7359, @previous.bytesize
    assert_equal @gate::PREVIOUS_SHA256[0], Digest::SHA256.hexdigest(@previous)
    assert_equal @gate::PREVIOUS_SHA256[1], Digest::SHA256.hexdigest(@previous + "\n")
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_equal 188, Rag::Stage2RunBudget::HISTORICAL_CALLS
    assert_equal BigDecimal("0.423114"), Rag::Stage2RunBudget::HISTORICAL_COST_USD
  end

  test "a disarmed gate does not read the chunks or record a comparison" do
    events = Rag::ValidationCapture.capture do
      assert_nil @gate.check!([ target(@previous) ], correlation_id: "phase2:12:t2:query")
    end

    assert_empty events
    assert_not @gate.armed?
  end

  test "the candidate body is returned and generation is not blocked" do
    [ @candidate, @candidate + "\n" ].each do |body|
      events = Rag::ValidationCapture.capture do
        @gate.arm!
        assert_nil @gate.check!([ target(body), other("pagina 1") ], correlation_id: "phase2:12:t2:query")
      end

      assert_equal %w[prepared attempt_started returned], body_results(events)
      returned = body_event(events, "returned")
      assert_equal "candidate", returned["reason"]
      assert_equal [ Digest::SHA256.hexdigest(body.b) ], returned["sha256"]
      assert_equal false, returned["remote"] if returned.key?("remote")
      assert_nil events.find { |event| event["kind"] == "model_call" }
      prepared = body_event(events, "prepared")
      assert_equal body, prepared["rows"].find { |row| row["target"] }["text"]
      assert_equal "phase2:12:t2:query", prepared["correlation_id"]
      assert_not prepared.key?("attempt")
    end
  end

  test "the previous body blocks before generation" do
    [ @previous, @previous + "\n" ].each do |body|
      events, error = capture_check do
        @gate.arm!
        @gate.check!([ target(body) ], correlation_id: "phase2:12:t2:query")
      end

      assert_equal "retrieved body blocked: previous", error.message
      assert_equal %w[prepared attempt_started blocked], body_results(events)
      assert_equal "previous", body_event(events, "blocked")["reason"]
      assert_equal [ Digest::SHA256.hexdigest(body.b) ], body_event(events, "blocked")["sha256"]
      assert_equal body, body_event(events, "prepared")["rows"].sole["text"]
      assert_equal "blocked", model_boundary(events)
      assert_not events.any? { |event| event["result"] == "attempt_started" && event["operation"] == "generate_text" }
      assert_not events.any? { |event| event["kind"] == "retrieved_body" && event["result"] == "error" }
    end
  end

  test "an altered body blocks and keeps the effective bytes" do
    altered = @candidate.sub("Chapa nivel 2", "Chapa nivel 9")
    directory = Pathname(Dir.mktmpdir)
    events, = capture_check do
      @gate.arm!
      Rag::ValidationCapture.attempt = 2
      @gate.check!([ target(altered) ], correlation_id: "phase2:12:t2:query")
    end

    blocked = body_event(events, "blocked")
    assert_equal "altered", blocked["reason"]
    assert_equal 2, blocked["attempt"]
    assert_equal "phase2:12:t2:query", blocked["correlation_id"]
    assert_equal "blocked", model_boundary(events)
    exported = Rag::ValidationCapture.export_capture(events, directory, run_id: "body")
    prepared = exported["events"].find { |event| event["kind"] == "retrieved_body" && event["result"] == "prepared" }
    evidence = prepared["rows"].sole["text"]
    assert_equal "external", evidence["evidence"]
    stored = directory.join(evidence["path"]).binread
    assert_equal altered.b, stored
    assert_equal Digest::SHA256.hexdigest(altered.b), evidence["sha256"]
    assert_not_equal @gate::CANDIDATE_SHA256[0], Digest::SHA256.hexdigest(stored)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  test "two trailing newlines are altered" do
    events, = capture_check do
      @gate.arm!
      @gate.check!([ target(@candidate + "\n\n") ])
    end

    assert_equal "altered", body_event(events, "blocked")["reason"]
  end

  test "a missing chunk blocks without copying the candidate" do
    events, = capture_check do
      @gate.arm!
      @gate.check!([ other("otra pagina") ], correlation_id: "phase2:12:t2:query")
    end

    blocked = body_event(events, "blocked")
    assert_equal "absent", blocked["reason"]
    assert_equal true, blocked["absent"]
    assert_equal KEY, blocked["expected_key"]
    prepared = body_event(events, "prepared")
    assert prepared["rows"].none? { |row| row["target"] }
    assert_equal "otra pagina", prepared["rows"].sole["text"]
    assert_not_includes JSON.generate(events), MARK
    assert_equal "blocked", model_boundary(events)
  end

  test "the same filename on another key is absent" do
    events, = capture_check do
      @gate.arm!
      @gate.check!([ target(@candidate, key: FOREIGN_KEY) ])
    end

    assert_equal "absent", body_event(events, "blocked")["reason"]
    row = body_event(events, "prepared")["rows"].sole
    assert_equal false, row["target"]
    assert_equal @candidate, row["text"]
    assert_not row.key?("match")
  end

  test "a target without a body is altered and stays absent" do
    events, = capture_check do
      @gate.arm!
      @gate.check!([ { location_uri: "s3://multimodal-source-destination/#{KEY}" } ])
    end

    row = body_event(events, "prepared")["rows"].sole
    assert_equal true, row["target"]
    assert_equal true, row["absent"]
    assert_equal "altered", row["match"]
    assert_not row.key?("text")
    assert_not row.key?("sha256")
    assert_equal "altered", body_event(events, "blocked")["reason"]
    assert_not_includes JSON.generate(events), MARK
  end

  test "a mixed target set is altered" do
    events, = capture_check do
      @gate.arm!
      @gate.check!([ target(@candidate), target(@previous) ])
    end

    assert_equal "altered", body_event(events, "blocked")["reason"]
  end

  test "an unreadable body is an error and does not start generation" do
    broken = Object.new
    broken.define_singleton_method(:text) { raise IOError, "unreadable" }
    events, error = capture_check do
      @gate.arm!
      @gate.check!([ { content: broken, location_uri: "s3://multimodal-source-destination/#{KEY}" } ])
    end

    assert_equal "retrieved body error: IOError", error.message
    assert_equal [ "error" ], body_results(events)
    assert_equal "IOError", body_event(events, "error")["error_class"]
    assert_equal false, body_event(events, "error")["remote"]
    assert_equal "blocked", model_boundary(events)
    assert_not events.any? { |event| event["result"] == "prepared" }
    assert_not events.any? { |event| event["result"] == "attempt_started" && event["kind"] == "retrieved_body" }
    assert_not_includes JSON.generate(events), MARK
  end

  test "the known identity path stops before generation and does not retrieve again" do
    {
      "previous" => @previous,
      "altered" => @candidate.sub("Chapa nivel 2", "Chapa nivel 9"),
      "absent" => nil
    }.each do |reason, body|
      retrievals = { n: 0 }
      generations = 0
      events = Rag::ValidationCapture.capture do
        service = identity_service(
          chunks: body.nil? ? [ other("pagina 1") ] : [ target(body) ],
          retrievals: retrievals
        )
        service.define_singleton_method(:document_identity_generator) do
          generator = Object.new
          generator.define_singleton_method(:query) do |*|
            generations += 1
            flunk "generate"
          end
          generator
        end
        @gate.arm!
        error = assert_raises(@gate::Stop) { run_identity(service) }
        assert_equal "retrieved body blocked: #{reason}", error.message
      end

      assert_equal 1, retrievals[:n], reason
      assert_equal 0, generations, reason
      assert_equal reason, body_event(events, "blocked")["reason"]
      assert_equal "blocked", model_boundary(events)
      assert_not events.any? { |event| event["operation"] == "generate_text" && event["result"] == "attempt_started" }
    end
  end

  test "the candidate continues to the existing generation with one retrieve" do
    retrievals = { n: 0 }
    prompts = []
    service = identity_service(
      chunks: [ target(@candidate, canonical_name: "Elemont MH") ],
      retrievals: retrievals
    )
    service.define_singleton_method(:document_identity_generator) do
      generator = Object.new
      generator.define_singleton_method(:query) do |prompt, **|
        prompts << prompt
        "Respuesta de prueba."
      end
      generator
    end
    @gate.arm!
    result = nil
    events = Rag::ValidationCapture.capture do
      result = run_identity(service)
    end

    assert_equal 1, retrievals[:n]
    assert_equal 1, prompts.size
    text = prompts.first.respond_to?(:user) ? prompts.first.user : prompts.first.to_s
    assert_includes text, MARK
    assert_equal "candidate", body_event(events, "returned")["reason"]
    assert_nil events.find { |event| event["kind"] == "model_call" && event["result"] == "blocked" }
    assert result[:answer].present?
  end

  test "a disarmed gate leaves generation on the previous body" do
    retrievals = { n: 0 }
    generations = 0
    service = identity_service(
      chunks: [ target(@previous, canonical_name: "Elemont MH") ],
      retrievals: retrievals
    )
    service.define_singleton_method(:document_identity_generator) do
      generator = Object.new
      generator.define_singleton_method(:query) do |*|
        generations += 1
        "Respuesta de prueba."
      end
      generator
    end

    result = run_identity(service)

    assert_not @gate.armed?
    assert_equal 1, retrievals[:n]
    assert_equal 1, generations
    assert result[:answer].present?
  end

  test "an absent chunk on the unknown path does not open a second retrieve" do
    retrievals = 0
    generations = 0
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) do |*, **|
      retrievals += 1
      flunk "second retrieve" if retrievals > 1
      { chunks: [], retrieval_trace: {} }
    end
    service.define_singleton_method(:fallback_retrieve) { |*, **| flunk "fallback" }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |*| flunk "retrieve_and_generate" }
    service.define_singleton_method(:document_identity_generator) do
      generator = Object.new
      generator.define_singleton_method(:query) do |*|
        generations += 1
        flunk "generate"
      end
      generator
    end
    @gate.arm!

    assert_raises(@gate::Stop) do
      service.query("pregunta", output_channel: :web)
    end
    assert_equal 1, retrievals
    assert_equal 0, generations
  end

  test "the harness records one body stop and does not call the turn again" do
    ENV["PHASE2_PINNED_TURN_AUTHORIZED"] = "1"
    calls = 0
    armed_during = nil
    executor = Object.new
    executor.define_singleton_method(:execute) do |*|
      calls += 1
      armed_during = Rag::Phase2RetrievedBodyGate.armed?
      raise Rag::Phase2RetrievedBodyGate::Stop, "retrieved body blocked: previous"
    end
    result = Rag::Phase2PinnedTurn.start(
      account: accounts(:legacy), user: users(:one), document: pinned_document,
      connections: Rag::Phase1PinnedTurn.stub_environment, executor: executor,
      interpreter_client: quiet_converse, enforce_capture_uri: false,
      evidence_root: Rails.root.join("tmp/phase2_retrieved_body_gate"), run_id: "body-stop"
    )

    assert_equal "stopped", result.status
    assert_equal "retrieved body blocked: previous", result.reason
    assert_equal 1, calls
    assert_equal true, armed_during
    assert_not Rag::Phase2RetrievedBodyGate.armed?
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  ensure
    ENV.delete("PHASE2_PINNED_TURN_AUTHORIZED")
  end

  private

  def target(body, key: KEY, canonical_name: "Elemont MH")
    {
      content: body,
      location_uri: "s3://multimodal-source-destination/#{key}",
      original_source_uri: "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf",
      metadata: {
        "account_id" => "1",
        "canonical_name" => canonical_name,
        "page_number" => "5",
        "x-amz-bedrock-kb-source-uri" => "s3://multimodal-source-destination/#{key}"
      }
    }
  end

  def other(body)
    {
      content: body,
      location_uri: "s3://multimodal-source-destination/bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p1_1.txt",
      metadata: { "account_id" => "1", "canonical_name" => "Elemont MH", "page_number" => "1" }
    }
  end

  def capture_check
    recorded = nil
    error = nil
    begin
      Rag::ValidationCapture.capture do |bucket|
        recorded = bucket
        yield
      end
    rescue @gate::Stop => raised
      error = raised
    end
    [ recorded, error ]
  end

  def body_results(events)
    events.select { |event| event["kind"] == "retrieved_body" }.pluck("result")
  end

  def body_event(events, result)
    events.find { |event| event["kind"] == "retrieved_body" && event["result"] == result }
  end

  def model_boundary(events)
    events.find { |event| event["kind"] == "model_call" && event["operation"] == "generate_text" }&.dig("result")
  end

  def identity_service(chunks:, retrievals:)
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) do |*, **|
      retrievals[:n] += 1
      flunk "second retrieve" if retrievals[:n] > 1
      { chunks: chunks, retrieval_trace: {} }
    end
    service.define_singleton_method(:fallback_retrieve) { |*, **| flunk "fallback" }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |*| flunk "retrieve_and_generate" }
    service
  end

  def run_identity(service)
    previous = ENV.fetch("DOCUMENT_IDENTITY_SCOPE_ENABLED", nil)
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    service.send(
      :document_identity_scope_result,
      "pregunta",
      episode: {
        "v" => 1,
        "episode_id" => "ep-test",
        "updated_at" => Time.current.iso8601,
        "facts" => {
          "manufacturer" => { "value" => "Elemont", "status" => "known", "source" => "user" }
        },
        "identifiers" => [ { "value" => "MH", "source" => "user" } ]
      },
      response_locale: :es,
      entity_s3_uris: [],
      entity_sources: [],
      force_entity_filter: false,
      account_id: accounts(:legacy).id,
      user_id: nil,
      conversation_session_id: nil,
      correlation_id: "phase2:12:t2:query"
    )
  ensure
    if previous.nil?
      ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    else
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = previous
    end
  end

  def pinned_document
    KbDocument.create!(
      account: accounts(:legacy),
      s3_key: "uploads/phase2-body-#{SecureRandom.hex(4)}.pdf",
      display_name: "Phase 2 body gate",
      knowledge_scope: "tenant_private"
    )
  end

  def quiet_converse
    response = Object.new
    response.define_singleton_method(:usage) { nil }
    response.define_singleton_method(:output) { nil }
    client = Object.new
    client.define_singleton_method(:converse) { |_params| response }
    client
  end
end
