# frozen_string_literal: true

require "test_helper"

class Rag::CompanionCandidateOrderTest < ActiveSupport::TestCase
  Row = Struct.new(:index, :relevance_score, :document)
  Response = Struct.new(:results, :next_token)

  test "orders by relevance, keeps the original body, and does not read an echoed document" do
    first = chunk("CUERPO_ORIGINAL_A", "sha-a", "s3://bucket/a.txt")
    second = chunk("CUERPO_ORIGINAL_B", "sha-b", "s3://bucket/b.txt")
    echoed = Row.new(0, 0.2, "REESCRITO")
    response = Response.new([ Row.new(1, 0.9, "TAMBIEN_REESCRITO"), echoed ], nil)
    payload = nil
    client = Object.new
    client.define_singleton_method(:rerank) do |request|
      payload = request
      response
    end

    ordered = Rag::CompanionCandidateOrder.call(
      [ first, second ],
      question: "la puerta abrió despacio",
      client: client,
      region: "us-east-1"
    )

    assert_equal [ "CUERPO_ORIGINAL_B", "CUERPO_ORIGINAL_A" ], ordered.pluck(:content)
    assert_equal [ 0.9, 0.2 ], ordered.pluck(:score)
    assert_equal [ "sha-b", "sha-a" ], ordered.pluck(:chunk_sha256)
    assert_equal [ "s3://bucket/b.txt", "s3://bucket/a.txt" ], ordered.pluck(:location_uri)
    assert_equal "la puerta abrió despacio", payload.dig(:queries, 0, :text_query, :text)
    assert_equal [ "CUERPO_ORIGINAL_A", "CUERPO_ORIGINAL_B" ], payload[:sources].map { |source|
      source.dig(:inline_document_source, :text_document, :text)
    }
    assert_equal 2, payload.dig(:reranking_configuration, :bedrock_reranking_configuration, :number_of_results)
    assert_equal(
      "arn:aws:bedrock:us-east-1::foundation-model/cohere.rerank-v3-5:0",
      payload.dig(:reranking_configuration, :bedrock_reranking_configuration, :model_configuration, :model_arn)
    )
    assert_not_includes JSON.generate(payload), "page"
    assert_not_includes JSON.generate(payload), "sha-"
  end

  test "equal scores keep the earlier hybrid index first" do
    ordered = Rag::CompanionCandidateOrder.call(
      [ chunk("UNO", "sha-1", "s3://bucket/1"), chunk("DOS", "sha-2", "s3://bucket/2") ],
      question: "consulta",
      client: client_returning([ Row.new(1, 0.4, nil), Row.new(0, 0.4, nil) ]),
      region: "us-east-1"
    )

    assert_equal [ "UNO", "DOS" ], ordered.pluck(:content)
  end

  test "a further rerank page is an error and is not requested" do
    calls = 0
    client = Object.new
    client.define_singleton_method(:rerank) do |_request|
      calls += 1
      Response.new([ Row.new(0, 0.5, nil) ], "next")
    end

    error = assert_raises(Rag::CompanionCandidateOrder::Error) do
      Rag::CompanionCandidateOrder.call(
        [ chunk("UNO", "sha-1", "s3://bucket/1"), chunk("DOS", "sha-2", "s3://bucket/2") ],
        question: "consulta",
        client: client,
        region: "us-east-1"
      )
    end

    assert_equal 1, calls
    assert_match(/another page/, error.message)
  end

  private

  def chunk(content, sha, uri)
    {
      content: content,
      score: 0.01,
      chunk_sha256: sha,
      location_uri: uri,
      metadata: { "canonical_name" => "VF5.pdf", "page_number" => "8" }
    }
  end

  def client_returning(rows)
    response = Response.new(rows, nil)
    client = Object.new
    client.define_singleton_method(:rerank) { |_request| response }
    client
  end
end
