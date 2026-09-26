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

  test "analyzes once, keeps UNKNOWN in the payload and out of the prose, and builds compact context within history limit" do
    client = FakeClient.new(VALID_JSON)
    result = build_service(client: client).call

    # CG-D19: the photo-only reading is prose in the response locale. UNKNOWN,
    # DEGRADED and REQUIRES_FIELD_VERIFICATION stay in parsed/compact_context.
    assert_includes result[:analysis], "Veo un controlador con una etiqueta legible y suciedad superficial."
    assert_includes result[:analysis], "Se leen estos códigos o etiquetas: DO-17, ERR 42."
    assert_includes result[:analysis], "Se aprecia desgaste o deterioro."
    assert_not_includes result[:analysis], "UNKNOWN"
    assert_not_includes result[:analysis], "DEGRADED"
    assert_not_includes result[:analysis], "REQUIRES_FIELD_VERIFICATION"
    assert_not_includes result[:analysis], "Fabricante:"
    assert_not_includes result[:analysis], "Manufacturer:"
    assert_not_includes result[:analysis], "**"
    assert_not_includes result[:analysis], "- ¿"
    assert_includes result[:analysis], I18n.t("rag.photo_guidance", locale: :es)
    assert_includes result[:analysis], "No hay un manual compatible"
    assert_includes result[:compact_context], "Fabricante: UNKNOWN"
    assert_operator result[:compact_context].length, :<=, ConversationSession::MAX_MSG_LENGTH
    assert_equal "visual_query", client.kwargs[:route]
    assert_equal "field_photo_query", client.kwargs[:tracking_prefix]
    # The anti_hallucination_notes value is shown once, as a sentence.
    assert_equal 1, result[:analysis].scan("El fabricante no es visible; requiere verificación en campo.").size
    assert_equal accounts(:legacy).id, client.kwargs.dig(:telemetry, :account_id)
    assert_equal "claude-sonnet-5", result[:model]
    assert_equal({ input_tokens: 120, output_tokens: 80 }, result[:usage])
    assert_operator result[:latency_ms], :>=, 0
    assert_nil result[:target_visible]
    assert_nil result[:relevance_to_goal]
    assert_nil result[:missing_view_or_detail]
    assert_not_includes result[:compact_context], "Objetivo visible"
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

  test "intent fields are parsed only when an intent was sent" do
    intent = { "text" => "RESORTE-UNICO-9981 cómo se ajusta", "source" => "question" }
    payload = JSON.parse(VALID_JSON).merge(
      "target_visible" => false,
      "relevance_to_goal" => "unrelated",
      "missing_view_or_detail" => "  primer plano de la fijación  "
    )
    client = FakeClient.new(JSON.generate(payload))
    log_output = StringIO.new
    capture_logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(capture_logger)

    result = build_service(client: client, photo_intent: intent).call

    assert_equal false, result[:target_visible]
    assert_equal "unrelated", result[:relevance_to_goal]
    assert_equal "primer plano de la fijación", result[:missing_view_or_detail]
    assert_includes result[:compact_context], "Objetivo visible: no"
    intent_block = client.kwargs[:user_content].reverse.find { |block| block[:type] == "text" }[:text]
    assert_includes intent_block, "RESORTE-UNICO-9981"
    line = log_output.string.lines.find { |entry| entry.include?("[IMAGE_ANALYSIS]") }
    assert_not_includes line, "RESORTE-UNICO-9981"
    logged = JSON.parse(line.split("[IMAGE_ANALYSIS] ", 2).last)
    assert_equal "question", logged["intent_source"]
    assert_equal Digest::SHA256.hexdigest(intent["text"].squish), logged["intent_sha256"]
    assert_equal false, logged["target_visible"]
    assert_equal "unrelated", logged["relevance_to_goal"]
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger) if capture_logger
  end

  test "invalid or missing target fields become nil and are ignored without an intent" do
    payload = JSON.parse(VALID_JSON).merge(
      "target_visible" => "maybe",
      "relevance_to_goal" => "sometimes",
      "missing_view_or_detail" => "x" * 250
    )
    with_intent = build_service(client: FakeClient.new(JSON.generate(payload)), photo_intent: "mira la placa").call
    without_intent = build_service(client: FakeClient.new(JSON.generate(payload))).call

    assert_nil with_intent[:target_visible]
    assert_nil with_intent[:relevance_to_goal]
    assert_equal 200, with_intent[:missing_view_or_detail].length
    assert_includes with_intent[:compact_context], "Objetivo visible: sin confirmar"
    assert_nil without_intent[:target_visible]
    assert_nil without_intent[:relevance_to_goal]
    assert_nil without_intent[:missing_view_or_detail]
    assert_not_includes without_intent[:compact_context], "Objetivo visible"
  end

  test "a true target is kept and labeled visible" do
    payload = JSON.parse(VALID_JSON).merge("target_visible" => true, "relevance_to_goal" => "relevant")
    result = build_service(client: FakeClient.new(JSON.generate(payload)), photo_intent: "el resorte").call

    assert_equal true, result[:target_visible]
    assert_equal "relevant", result[:relevance_to_goal]
    assert_includes result[:compact_context], "Objetivo visible: sí"
  end

  private

  def build_service(client:, session: nil, photo_intent: nil)
    FieldPhotoAnalysisService.new(
      binary: "jpeg",
      content_type: "image/jpeg",
      filename: "door.jpg",
      locale: :es,
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conv_session_id: session&.id,
      correlation_id: "photo:test-123",
      client: client,
      photo_intent: photo_intent
    )
  end
end
