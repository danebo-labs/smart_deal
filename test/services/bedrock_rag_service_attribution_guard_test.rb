# frozen_string_literal: true

require "test_helper"
require "ostruct"

class BedrockRagServiceAttributionGuardTest < ActiveSupport::TestCase
  class FakeClient
    def initialize(response)
      @response = response
    end

    def retrieve_and_generate(_params)
      @response
    end

    def retrieve(_params)
      refs = Array(@response.citations).flat_map { |citation| Array(citation.retrieved_references) }
      OpenStruct.new(
        retrieval_results: refs.map do |ref|
          OpenStruct.new(content: ref.content, score: 0.4, metadata: ref.metadata, location: ref.location)
        end
      )
    end
  end

  setup do
    @account = accounts(:legacy)
    @original_flag = ENV.fetch("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED", nil)
    ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = "true"
    KbDocument.create!(
      account: @account,
      s3_key: "s3://test-bucket/manual.pdf",
      display_name: "Manual",
      aliases: []
    )
  end

  teardown do
    if @original_flag.nil?
      ENV.delete("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED")
    else
      ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = @original_flag
    end
  end

  test "generic path drops a foreign segment and preserves retrieval transport" do
    raw_answer = "Dato Thyssen.[1] Dato Otis.[2]"
    response = response_with_spans(
      raw_answer,
      [
        { identity: "THYSSEN", content: "Dato Thyssen", span_end: raw_answer.index(".") },
        { identity: "OTIS", content: "Dato Otis", span_end: raw_answer.rindex(".") }
      ]
    )
    off = with_flag("false") do
      query(response, question: "En Thyssen-E, ¿qué indica?", account_id: 101)
    end

    on = capture_quality_log do
      query(response, question: "En Thyssen-E, ¿qué indica?", account_id: 101)
    end
    quality = captured_quality_payload

    assert_equal "Dato Thyssen.", on[:answer]
    assert_empty on[:citations]
    assert_equal off[:retrieved_citations], on[:retrieved_citations]
    assert_equal off[:doc_refs], on[:doc_refs]
    assert_equal 2, on[:retrieved_citations].size
    assert_equal 1, on.dig(:diagnostics, :attribution_dropped).size
    assert_equal 1, quality["attribution_dropped_segments"]
    assert_equal [ "THYSSEN" ], quality["attribution_anchors"]
    assert_equal %w[THYSSEN OTIS], quality["attribution_identities"]
  end

  test "generic path fully abstains when only evidence-sensitive uncited text survives" do
    raw_answer = "Dato de THYSSEN [1]. El indicador queda en estado normal."
    response = response_with_markers(
      raw_answer,
      [
        { identity: "THYSSEN", content: raw_answer },
        { identity: "OTIS", content: "Manual OTIS" }
      ]
    )

    result = query(response, question: "En OTIS, ¿qué indica?", account_id: 101)

    assert_equal I18n.t("rag.data_not_available", locale: :es), result[:answer]
    assert_empty result[:citations]
    assert_equal 1, result.dig(:diagnostics, :attribution_dropped).size
  end

  test "separate account turns do not leak attribution state" do
    first_raw = "Dato Thyssen.[1] Dato Otis.[2]"
    first = query(
      response_with_spans(
        first_raw,
        [
          { identity: "THYSSEN", content: "Dato Thyssen", span_end: first_raw.index(".") },
          { identity: "OTIS", content: "Dato Otis", span_end: first_raw.rindex(".") }
        ]
      ),
      question: "En THYSSEN, ¿qué indica?",
      account_id: 101
    )
    second_raw = "Dato Edel.[1] Dato Orona.[2]"
    second = query(
      response_with_spans(
        second_raw,
        [
          { identity: "EDEL", content: "Dato Edel", span_end: second_raw.index(".") },
          { identity: "ORONA", content: "Dato Orona", span_end: second_raw.rindex(".") }
        ]
      ),
      question: "En EDEL, ¿qué indica?",
      account_id: 202
    )

    assert_equal "Dato Thyssen.", first[:answer]
    assert_equal "Dato Edel.", second[:answer]
    assert_not_includes second[:answer], "Thyssen"
  end

  test "flag off preserves the generic response byte exactly" do
    raw_answer = "Dato Thyssen.[1] Dato Otis.[2]"
    response = response_with_spans(
      raw_answer,
      [
        { identity: "THYSSEN", content: "Dato Thyssen", span_end: raw_answer.index(".") },
        { identity: "OTIS", content: "Dato Otis", span_end: raw_answer.rindex(".") }
      ]
    )

    result = with_flag("false") do
      query(response, question: "En Thyssen-E, ¿qué indica?", account_id: 101)
    end

    assert_equal "Dato Thyssen. Dato Otis.", result[:answer]
    assert_empty result[:citations]
    assert_empty result.dig(:diagnostics, :attribution_dropped)
  end

  private

  def query(response, question:, account_id:)
    service = BedrockRagService.new(knowledge_base_id: "test-kb", account: @account)
    service.instance_variable_set(:@client, FakeClient.new(response))
    text = response.output.text
    generator = Object.new
    generator.define_singleton_method(:query) { |*, **| text }
    service.define_singleton_method(:document_identity_generator) { generator }
    service.query(
      question,
      account_id: account_id,
      response_locale: :es,
      include_diagnostics: true
    )
  end

  def response_with_spans(answer, definitions)
    citations = definitions.map do |definition|
      citation(
        definition[:identity],
        definition[:content],
        span_end: definition[:span_end]
      )
    end
    OpenStruct.new(
      output: OpenStruct.new(text: answer),
      citations: citations,
      session_id: "attribution-test"
    )
  end

  def response_with_markers(answer, definitions)
    citations = definitions.map do |definition|
      citation(definition[:identity], definition[:content], span_end: answer.length)
    end
    OpenStruct.new(
      output: OpenStruct.new(text: answer),
      citations: citations,
      session_id: "attribution-test"
    )
  end

  # span.end is inclusive: it indexes the last character of the cited passage
  # (the sentence-closing "." here), so the marker lands after it.
  def citation(identity, content, span_end:)
    OpenStruct.new(
      generated_response_part: OpenStruct.new(
        text_response_part: OpenStruct.new(
          span: OpenStruct.new(start: 0, end: span_end)
        )
      ),
      retrieved_references: [
        OpenStruct.new(
          content: OpenStruct.new(text: content),
          location: OpenStruct.new(
            s3_location: OpenStruct.new(uri: "s3://test-bucket/chunks/#{identity.downcase}.txt")
          ),
          metadata: {
            "canonical_name" => "Manual SEGURIDADES",
            "original_source_uri" => "s3://test-bucket/manual.pdf",
            "section_identity" => identity,
            "page_number" => identity == "THYSSEN" ? 93 : 67,
            "account_id" => @account.id.to_s
          }
        )
      ]
    )
  end

  def with_flag(value)
    previous = ENV.fetch("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED", nil)
    ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = value
    yield
  ensure
    if previous.nil?
      ENV.delete("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED")
    else
      ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = previous
    end
  end

  def capture_quality_log
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    result = yield
    @quality_log_output = output
    result
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  def captured_quality_payload
    line = @quality_log_output.string.lines.find { |item| item.include?("[RAG_QUALITY]") }
    assert line, "[RAG_QUALITY] must be logged"
    JSON.parse(line.split("[RAG_QUALITY] ", 2).last)
  end
end
