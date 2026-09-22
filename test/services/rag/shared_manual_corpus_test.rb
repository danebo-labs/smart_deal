# frozen_string_literal: true

require "test_helper"

class Rag::SharedManualCorpusTest < ActiveSupport::TestCase
  setup { Rag::SharedManualCorpus.reset_account_ids! }
  teardown { Rag::SharedManualCorpus.reset_account_ids! }

  test "legacy and pilot retrieve each other's account ids and general manuals" do
    legacy = accounts(:legacy)
    pilot = accounts(:pilot)

    [ legacy, pilot ].each do |account|
      filter = BedrockRagService.new(account: account).send(:account_filter)
      ids = values_for(filter, "account_id")

      assert_includes ids, legacy.id.to_s
      assert_includes ids, pilot.id.to_s
      assert_equal [ "general" ], values_for(filter, "manual_corpus")
      assert filter.key?(:or_all)
    end
  end

  test "every account retrieves the danebo and pilot manuals plus general manuals" do
    climb = accounts(:climb)
    filter = BedrockRagService.new(account: climb).send(:account_filter)
    ids = values_for(filter, "account_id")

    assert_includes ids, climb.id.to_s
    assert_includes ids, accounts(:legacy).id.to_s
    assert_includes ids, accounts(:pilot).id.to_s
    assert_equal [ "general" ], values_for(filter, "manual_corpus")
    assert_equal [ "field_photo_v1", "field_photo_v1" ], not_equals_values(filter, "ingestion_path")
  end

  test "corpus_scope general tags any account and account keeps a manual private" do
    climb = accounts(:climb)
    pilot = accounts(:pilot)

    assert Rag::SharedManualCorpus.tag?(account_id: climb.id, ingestion_path: "manual_batch_v1", corpus_scope: "general")
    assert_not Rag::SharedManualCorpus.tag?(account_id: pilot.id, ingestion_path: "manual_batch_v1", corpus_scope: "account")
    assert_not Rag::SharedManualCorpus.tag?(account_id: pilot.id, ingestion_path: "field_photo_v1", corpus_scope: "general")
  end

  test "an unknown corpus_scope is rejected before a sidecar is written" do
    error = assert_raises(ArgumentError) { Rag::SharedManualCorpus.validate_scope!("shared") }

    assert_match(/general/, error.message)
  end

  test "an explicit document pin is only those URIs even when the question names a page" do
    climb = accounts(:climb)
    uris = %w[s3://bucket/a.pdf s3://bucket/b.pdf s3://bucket/c.pdf]
    ENV["RAG_PAGE_PIN_ENABLED"] = "true"
    filter = BedrockRagService.new(account: climb).build_vector_search_configuration(
      question: "página 93 del manual",
      entity_s3_uris: uris
    )[:filter]

    assert_bedrock_filter filter
    uri_clauses = uri_key_clauses(filter)
    assert_equal uris.sort, uri_clauses.flat_map { |clause| Array(clause[:value]) }.uniq.sort
    assert_equal BedrockRagService::URI_METADATA_KEYS.sort, uri_clauses.pluck(:key).sort
    assert_empty values_for(filter, "account_id")
    assert_empty values_for(filter, "manual_corpus")
    assert_empty values_for(filter, "page_number")
    assert_empty not_equals_values(filter, "ingestion_path")
  ensure
    ENV.delete("RAG_PAGE_PIN_ENABLED")
  end

  test "a pinned photo is that file alone" do
    filter = BedrockRagService.new(account: accounts(:climb)).build_vector_search_configuration(
      question: "qué muestra esta foto",
      entity_s3_uris: [ "s3://bucket/photo.jpg" ],
      entity_sources: [ "image_upload" ]
    )[:filter]

    assert_bedrock_filter filter
    assert uri_key_clauses(filter).any? { |clause| clause[:value] == "s3://bucket/photo.jpg" }
    assert_empty values_for(filter, "account_id")
    assert_empty not_equals_values(filter, "ingestion_path")
  end

  private

  def not_equals_values(node, key)
    case node
    when Hash
      negated = node[:not_equals] || node["not_equals"]
      found = if negated && (negated[:key] || negated["key"]).to_s == key
        [ (negated[:value] || negated["value"]).to_s ]
      else
        []
      end
      found + node.flat_map { |_k, value| not_equals_values(value, key) }
    when Array
      node.flat_map { |value| not_equals_values(value, key) }
    else
      []
    end
  end

  def uri_key_clauses(filter)
    found = []
    walk = lambda do |node|
      case node
      when Hash
        clause = node[:equals] || node[:in]
        found << clause if clause && BedrockRagService::URI_METADATA_KEYS.include?(clause[:key])
        node.each_value { |value| walk.call(value) }
      when Array
        node.each { |value| walk.call(value) }
      end
    end
    walk.call(filter)
    found
  end

  def assert_bedrock_filter(node, depth: 1)
    list = node[:or_all] || node[:and_all] if node.is_a?(Hash)
    return unless list

    assert_operator depth, :<=, 2, node.inspect
    assert_includes 2..5, list.size, node.inspect
    list.each { |child| assert_bedrock_filter(child, depth: depth + 1) }
  end

  def find_equals(node, key)
    case node
    when Hash
      equals = node[:equals] || node["equals"]
      return equals[:value] || equals["value"] if equals && (equals[:key] || equals["key"]).to_s == key

      node.each_value do |value|
        found = find_equals(value, key)
        return found unless found.nil?
      end
      nil
    when Array
      node.each do |value|
        found = find_equals(value, key)
        return found unless found.nil?
      end
      nil
    end
  end

  def values_for(node, key)
    case node
    when Hash
      equals = node[:equals] || node["equals"]
      if equals && (equals[:key] || equals["key"]).to_s == key
        [ (equals[:value] || equals["value"]).to_s ]
      else
        node.flat_map { |_k, value| values_for(value, key) }
      end
    when Array
      node.flat_map { |value| values_for(value, key) }
    else
      []
    end
  end
end
