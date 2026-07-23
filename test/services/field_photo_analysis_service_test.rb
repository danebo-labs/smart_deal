# frozen_string_literal: true

require "test_helper"
require "ostruct"

class FieldPhotoAnalysisServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  VALID_JSON = JSON.generate(
    "canonical_component" => "Door operator controller",
    "manufacturer" => "UNKNOWN",
    "model" => "DO-17",
    "subsystem" => "DOOR_OPERATOR",
    "condition" => "DEGRADED",
    "aliases" => [ "DO-17" ],
    "summary" => "Veo un controlador con una etiqueta legible y suciedad superficial.",
    "visible_text" => [ "DO-17", "ERR 42" ],
    "documented_functions" => [],
    "documented_connections" => [],
    "documented_values" => [],
    "documented_warnings" => [],
    "anti_hallucination_notes" => "El fabricante no es visible; requiere verificación en campo."
  ).freeze

  class FakeClient
    attr_reader :kwargs

    def initialize(text)
      @text = text
    end

    def call(**kwargs)
      @kwargs = kwargs
      {
        text: @text,
        usage: OpenStruct.new(input_tokens: 120, output_tokens: 80),
        model: BatchChunkingPrompt::MODEL_TEXT
      }
    end
  end

  test "analyzes once, preserves UNKNOWN and builds compact context within history limit" do
    client = FakeClient.new(VALID_JSON)
    result = build_service(client: client).call

    assert_includes result[:analysis], "Observado en la imagen"
    assert_includes result[:analysis], "Manufacturer: UNKNOWN"
    assert_includes result[:analysis], "Orientación"
    assert_includes result[:analysis], "No hay un manual compatible"
    assert_includes result[:compact_context], "Fabricante: UNKNOWN"
    assert_operator result[:compact_context].length, :<=, ConversationSession::MAX_MSG_LENGTH
    assert_equal "visual_query", client.kwargs[:route]
    assert_equal "field_photo_query", client.kwargs[:tracking_prefix]
    assert_equal accounts(:legacy).id, client.kwargs.dig(:telemetry, :account_id)
    assert_equal BatchChunkingPrompt::MODEL_TEXT, result[:model]
    assert_equal({ input_tokens: 120, output_tokens: 80 }, result[:usage])
    assert_operator result[:latency_ms], :>=, 0
  end

  test "omits the absent-manual warning when the session has a pinned document" do
    session = ConversationSession.create!(
      identifier: "photo-manual",
      channel: "web",
      account: accounts(:legacy),
      user: users(:one),
      expires_at: 1.day.from_now,
      active_entities: {
        "Door manual" => { "entity_type" => "document", "source_uri" => "s3://bucket/door.pdf" }
      }
    )

    result = build_service(client: FakeClient.new(VALID_JSON), session: session).call

    assert_not_includes result[:analysis], "No hay un manual compatible"
  end

  test "invalid JSON raises ParseError and emits an error IMAGE_ANALYSIS log" do
    log_output = StringIO.new
    capture_logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(capture_logger)

    assert_raises(FieldPhotoAnalysisService::ParseError) do
      build_service(client: FakeClient.new("not-json")).call
    end

    line = log_output.string.lines.find { |entry| entry.include?("[IMAGE_ANALYSIS]") }
    assert line
    payload = JSON.parse(line.split("[IMAGE_ANALYSIS] ", 2).last)
    assert_equal "error", payload["result"]
    assert_equal "FieldPhotoAnalysisService::ParseError", payload["error_class"]
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger) if capture_logger
  end

  test "successful analysis emits structured telemetry without image data" do
    log_output = StringIO.new
    capture_logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(capture_logger)

    build_service(client: FakeClient.new(VALID_JSON)).call

    line = log_output.string.lines.find { |entry| entry.include?("[IMAGE_ANALYSIS]") }
    payload = JSON.parse(line.split("[IMAGE_ANALYSIS] ", 2).last)
    assert_equal "ok", payload["result"]
    assert_equal "UNKNOWN", payload["manufacturer"]
    assert_equal [ "DO-17", "ERR 42" ], payload["visible_codes"]
    assert_equal 120, payload["input_tokens"]
    assert_not_includes line, Base64.strict_encode64("jpeg")
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger) if capture_logger
  end

  private

  def build_service(client:, session: nil)
    FieldPhotoAnalysisService.new(
      binary: "jpeg",
      content_type: "image/jpeg",
      filename: "door.jpg",
      locale: :es,
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conv_session_id: session&.id,
      correlation_id: "photo:test-123",
      client: client
    )
  end
end
