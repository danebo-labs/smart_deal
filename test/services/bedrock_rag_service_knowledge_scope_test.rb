# frozen_string_literal: true

require "test_helper"

class BedrockRagServiceKnowledgeScopeTest < ActiveSupport::TestCase
  setup do
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "test-kb-id"
    ENV["AWS_REGION"] = "us-east-1"
    @viewer = accounts(:climb)
    @owner = accounts(:legacy)
    @service = BedrockRagService.new(account: @viewer)
  end

  teardown do
    ENV.delete("BEDROCK_KNOWLEDGE_BASE_ID")
    ENV.delete("AWS_REGION")
  end

  test "open retrieval stays the historical shared corpus" do
    filter = @service.build_vector_search_configuration(question: "What is S3?")[:filter]

    assert_includes account_ids(filter), @viewer.id.to_s
    assert_includes account_ids(filter), accounts(:legacy).id.to_s
    assert_includes account_ids(filter), accounts(:pilot).id.to_s
    assert_includes values_for(filter, "manual_corpus"), "general"
  end

  test "an owned pin is that canonical uri and a denied uri never calls Bedrock" do
    own = KbDocument.create!(account: @viewer, s3_key: "manuals/own.pdf", display_name: "Own", aliases: [])
    foreign = KbDocument.create!(account: @owner, s3_key: "manuals/foreign.pdf", display_name: "Foreign", aliases: [])
    own_filter = filter_for(own.s3_key)

    assert_includes values_for(own_filter, "original_source_uri"), own.canonical_uri
    assert_empty account_ids(own_filter)

    client = FakeClient.new
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        entity_s3_uris: [ foreign.canonical_uri ],
        force_entity_filter: false
      )
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls
    assert_nil client.filter
  end

  test "a denied uri does not open the corpus on a second call" do
    foreign = KbDocument.create!(account: @owner, s3_key: "manuals/retry.pdf", display_name: "Foreign", aliases: [])
    client = FakeClient.new
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        entity_s3_uris: [ foreign.canonical_uri ],
        force_entity_filter: false
      )
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal false, result[:model_invoked]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls
    assert_not_includes result[:answer].to_s, "manual_corpus"
  end

  test "a danebo_general pin is that canonical uri for another account" do
    @owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(account: @owner, s3_key: "manuals/shared.pdf", display_name: "Shared", aliases: [])
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual")

    filter = filter_for(shared.s3_key)

    assert_includes values_for(filter, "original_source_uri"), shared.canonical_uri
    assert_empty account_ids(filter)
  end

  test "approve then pin then revoke denies the next query and leaves the session pin" do
    @owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(account: @owner, s3_key: "manuals/pinned-general.pdf", display_name: "Pinned", aliases: [])
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual")
    session = ConversationSession.find_or_create_for(
      identifier: "scope-pin", channel: "web", user_id: users(:two).id, account_id: @viewer.id
    )
    session.pin_kb_document!(shared)
    pinned = SessionContextBuilder.entity_s3_uris(session)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "tenant_private", actor: "ops", reason: "withdrawn")

    client = FakeClient.new
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        entity_s3_uris: pinned,
        force_entity_filter: true
      )
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls
    assert_equal pinned, SessionContextBuilder.entity_s3_uris(session.reload)
  end

  test "the owner can still retrieve a document after it is revoked from the general library" do
    @owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(account: @owner, s3_key: "manuals/owner-after.pdf", display_name: "Owner", aliases: [])
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual")
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "tenant_private", actor: "ops", reason: "withdrawn")
    client = FakeClient.new
    with_client(client) do
      BedrockRagService.new(account: @owner).query(
        "What is S3?",
        entity_s3_uris: [ shared.canonical_uri ],
        force_entity_filter: true
      )
    end

    assert_equal 1, client.generate_calls
    assert_includes values_for(client.filter, "original_source_uri"), shared.canonical_uri
    assert_empty account_ids(client.filter)

    denied = FakeClient.new
    with_client(denied) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        entity_s3_uris: [ shared.canonical_uri ],
        force_entity_filter: false
      )
      assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    end
    assert_equal 0, denied.generate_calls
    assert_equal 0, denied.retrieve_calls
  end

  test "a partial pin set does not retrieve the remaining authorized uri" do
    own = KbDocument.create!(account: @viewer, s3_key: "manuals/kept.pdf", display_name: "Kept", aliases: [])
    foreign = KbDocument.create!(account: @owner, s3_key: "manuals/revoked-peer.pdf", display_name: "Revoked", aliases: [])
    client = FakeClient.new
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        entity_s3_uris: [ own.canonical_uri, foreign.canonical_uri ],
        force_entity_filter: true
      )
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls
    assert_not_includes client.filter.to_s, own.canonical_uri
  end

  test "two authorized pins are both sent and the open corpus is not" do
    first = KbDocument.create!(account: @viewer, s3_key: "manuals/pin-x.pdf", display_name: "X", aliases: [])
    second = KbDocument.create!(account: @viewer, s3_key: "manuals/pin-y.pdf", display_name: "Y", aliases: [])
    client = FakeClient.new
    with_client(client) do
      BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        entity_s3_uris: [ first.canonical_uri, second.canonical_uri ],
        force_entity_filter: true
      )
    end

    sent = values_for(client.filter, "original_source_uri")
    assert_equal [ first.canonical_uri, second.canonical_uri ].sort, sent.sort
    assert_empty account_ids(client.filter)
    assert_empty values_for(client.filter, "manual_corpus")
  end

  test "an ambiguous canonical uri is not retrieval scope" do
    KbDocument.create!(account: @viewer, s3_key: "s3://bucket/same.pdf", display_name: "Own", aliases: [])
    KbDocument.create!(account: @owner, s3_key: "s3://bucket/same.pdf", display_name: "Other", aliases: [])
    client = FakeClient.new
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        entity_s3_uris: [ "s3://bucket/same.pdf" ],
        force_entity_filter: false
      )
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls
  end

  test "a caller supplied uri filter cannot select another tenant private document" do
    foreign = KbDocument.create!(account: @owner, s3_key: "s3://bucket/injected.pdf", display_name: "Injected", aliases: [])
    client = FakeClient.new
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        custom_config: {
          retrieval_configuration: {
            vector_search_configuration: {
              filter: { equals: { key: "original_source_uri", value: foreign.s3_key } }
            }
          }
        }
      )
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls
    assert_nil client.filter
  end

  test "extract_doc_refs keeps an authorized general uri and drops a foreign private uri" do
    @owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(account: @owner, s3_key: "shared.pdf", display_name: "Shared", aliases: [])
    foreign = KbDocument.create!(account: @owner, s3_key: "foreign.pdf", display_name: "Foreign", aliases: [])
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual")
    answer = <<~ANSWER
      Answer.
      <DOC_REFS>[
        {"source_uri":"#{shared.canonical_uri}","canonical_name":"Shared","aliases":[],"doc_type":"manual"},
        {"source_uri":"#{foreign.canonical_uri}","canonical_name":"Foreign","aliases":[],"doc_type":"manual"}
      ]</DOC_REFS>
    ANSWER

    result = @service.send(:extract_doc_refs, answer)

    assert_equal [ "Shared" ], result[:doc_refs].pluck("canonical_name")
    assert_equal shared.id, KbDocument.find(shared.id).id
    assert_equal "tenant_private", foreign.reload.knowledge_scope
  end

  private

  def filter_for(uri)
    @service.build_vector_search_configuration(question: "What is this manual?", entity_s3_uris: [ uri ])[:filter]
  end

  def account_ids(filter)
    values_for(filter, "account_id")
  end

  def values_for(node, key)
    case node
    when Hash
      equals = node[:equals] || node["equals"]
      included = node[:in] || node["in"]
      found = []
      if equals && (equals[:key] || equals["key"]).to_s == key
        found << (equals[:value] || equals["value"]).to_s
      end
      if included && (included[:key] || included["key"]).to_s == key
        found.concat(Array(included[:value] || included["value"]).map(&:to_s))
      end
      found + node.flat_map { |_k, value| values_for(value, key) }
    when Array
      node.flat_map { |value| values_for(value, key) }
    else
      []
    end
  end

  def with_client(client)
    original = Aws::BedrockAgentRuntime::Client.method(:new)
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*| client }
    yield
  ensure
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  class FakeClient
    attr_reader :filter, :generate_calls, :retrieve_calls

    def initialize
      @generate_calls = 0
      @retrieve_calls = 0
    end

    def retrieve(_params)
      @retrieve_calls += 1
      OpenStruct.new(retrieval_results: [])
    end

    def retrieve_and_generate(params)
      @generate_calls += 1
      @filter = params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :retrieval_configuration,
        :vector_search_configuration,
        :filter
      )
      OpenStruct.new(output: OpenStruct.new(text: "ok"), citations: [], session_id: "sid")
    end
  end
end
