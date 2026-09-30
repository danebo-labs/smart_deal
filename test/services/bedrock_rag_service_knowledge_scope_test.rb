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

  test "open retrieval is the viewer account and not legacy pilot or manual_corpus" do
    filter = @service.build_vector_search_configuration(question: "What is S3?")[:filter]

    assert_equal [ @viewer.id.to_s ], account_ids(filter)
    assert_not_includes account_ids(filter), accounts(:legacy).id.to_s
    assert_not_includes account_ids(filter), accounts(:pilot).id.to_s
    assert_empty values_for(filter, "manual_corpus")
  end

  test "open retrieval includes an explicit general and excludes private legacy pilot and manual_corpus rows" do
    own = KbDocument.create!(account: @viewer, s3_key: "manuals/own-open.pdf", display_name: "Own", aliases: [])
    legacy = KbDocument.create!(account: accounts(:legacy), s3_key: "manuals/legacy-private.pdf", display_name: "Legacy", aliases: [])
    pilot = KbDocument.create!(account: accounts(:pilot), s3_key: "manuals/pilot-private.pdf", display_name: "Pilot", aliases: [])
    tagged = KbDocument.create!(account: @owner, s3_key: "manuals/tagged-private.pdf", display_name: "Tagged", aliases: [])
    @owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(account: @owner, s3_key: "manuals/approved.pdf", display_name: "Approved", aliases: [])
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual")

    filter = @service.build_vector_search_configuration(question: "What is S3?")[:filter]

    assert_includes account_ids(filter), @viewer.id.to_s
    assert_not_includes account_ids(filter), accounts(:legacy).id.to_s
    assert_not_includes account_ids(filter), accounts(:pilot).id.to_s
    assert_empty values_for(filter, "manual_corpus")
    assert_includes values_for(filter, "original_source_uri"), shared.canonical_uri
    assert_includes values_for(filter, "x-amz-bedrock-kb-source-uri"), shared.canonical_uri
    [ own, legacy, pilot, tagged ].each do |document|
      assert_not_includes values_for(filter, "original_source_uri"), document.canonical_uri
    end
  end

  test "revoking a general removes it from the next open retrieve and the owner keeps it" do
    @owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(account: @owner, s3_key: "manuals/revocable.pdf", display_name: "Revocable", aliases: [])
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual")

    before = @service.build_vector_search_configuration(question: "What is S3?")[:filter]
    assert_includes values_for(before, "original_source_uri"), shared.canonical_uri

    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "tenant_private", actor: "ops", reason: "withdrawn")
    after = BedrockRagService.new(account: @viewer).build_vector_search_configuration(question: "What is S3?")[:filter]
    owner = BedrockRagService.new(account: @owner).build_vector_search_configuration(question: "What is S3?")[:filter]

    assert_not_includes values_for(after, "original_source_uri"), shared.canonical_uri
    assert_equal [ @viewer.id.to_s ], account_ids(after)
    assert_includes account_ids(owner), @owner.id.to_s
    assert_not_includes values_for(owner, "original_source_uri"), shared.canonical_uri
  end

  test "a mocked foreign private citation is dropped before it is published" do
    foreign = KbDocument.create!(account: @owner, s3_key: "manuals/leaked.pdf", display_name: "Leaked", aliases: [])
    response = cited_response(
      "FOREIGN_PRIVATE_BODY should not ship",
      foreign,
      "FOREIGN_PRIVATE_BODY"
    )
    client = FakeClient.new
    client.generate_response = response
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query("What is S3?")
    end

    assert_equal 1, client.generate_calls
    assert_not_includes result[:answer].to_s, "FOREIGN_PRIVATE_BODY"
    assert_empty result[:citations]
    assert_empty result[:retrieved_citations]
    assert_equal 0, client.retrieve_calls
  end

  test "an authorized general citation is kept and a foreign private citation is not evidence" do
    @owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(account: @owner, s3_key: "manuals/kept-general.pdf", display_name: "Kept", aliases: [])
    foreign = KbDocument.create!(account: @owner, s3_key: "manuals/dropped-private.pdf", display_name: "Dropped", aliases: [])
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual")
    response = OpenStruct.new(
      output: OpenStruct.new(text: "Authorized answer."),
      session_id: "sid",
      citations: [
        citation_for(shared, "GENERAL_BODY"),
        citation_for(foreign, "FOREIGN_PRIVATE_BODY")
      ]
    )
    client = FakeClient.new
    client.generate_response = response
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query("What is S3?")
    end

    bodies = Array(result[:retrieved_citations]).map { |chunk| chunk[:content].to_s }
    assert_includes bodies, "GENERAL_BODY"
    assert_not_includes bodies.join, "FOREIGN_PRIVATE_BODY"
    assert_not_includes result[:answer].to_s, "FOREIGN_PRIVATE_BODY"
  end

  test "an ambiguous or unmapped result is not evidence" do
    KbDocument.create!(account: @viewer, s3_key: "s3://bucket/same.pdf", display_name: "Own", aliases: [])
    KbDocument.create!(account: @owner, s3_key: "s3://bucket/same.pdf", display_name: "Other", aliases: [])
    chunks = [
      { content: "AMBIGUOUS_BODY", metadata: { "original_source_uri" => "s3://bucket/same.pdf" } },
      { content: "UNMAPPED_BODY", metadata: { "original_source_uri" => "s3://bucket/missing.pdf" } }
    ]

    decisions = Rag::KnowledgeScopePolicy.partition_evidence(chunks, viewer_account: @viewer)

    assert_equal [ :ambiguous, :unmapped ], decisions.map(&:status)
    assert decisions.none?(&:authorized?)
  end

  test "generation context receives only the authorized retrieve chunks" do
    own = KbDocument.create!(account: @viewer, s3_key: "manuals/prompt-own.pdf", display_name: "Own", aliases: [])
    foreign = KbDocument.create!(account: @owner, s3_key: "manuals/prompt-foreign.pdf", display_name: "Foreign", aliases: [])
    client = FakeClient.new
    client.retrieve_results = [
      retrieve_result(own, "OWN_BODY"),
      retrieve_result(foreign, "FOREIGN_PRIVATE_BODY")
    ]
    chunks = nil
    with_client(client) do
      chunks = BedrockRagService.new(account: @viewer).retrieve_chunks("torque").fetch(:chunks)
    end
    prompt = BedrockRagService.new(account: @viewer).send(
      :document_identity_generation_prompt,
      "torque",
      chunks,
      response_locale: :es,
      session_context: nil,
      output_channel: :web
    )

    assert_includes prompt, "OWN_BODY"
    assert_not_includes prompt, "FOREIGN_PRIVATE_BODY"
  end

  test "a caller filter that ors the current account with another account is denied" do
    client = FakeClient.new
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        custom_config: {
          retrieval_configuration: {
            vector_search_configuration: {
              filter: {
                or_all: [
                  { equals: { key: "account_id", value: @viewer.id.to_s } },
                  { equals: { key: "account_id", value: @owner.id.to_s } }
                ]
              }
            }
          }
        }
      )
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls
  end

  test "a caller filter that ors manual_corpus is denied" do
    client = FakeClient.new
    result = nil
    with_client(client) do
      result = BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        custom_config: {
          retrieval_configuration: {
            vector_search_configuration: {
              filter: {
                or_all: [
                  { equals: { key: "account_id", value: @viewer.id.to_s } },
                  { equals: { key: "manual_corpus", value: "general" } }
                ]
              }
            }
          }
        }
      )
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
  end

  test "a technical caller filter stays inside the authorized corpus" do
    client = FakeClient.new
    with_client(client) do
      BedrockRagService.new(account: @viewer).query(
        "What is S3?",
        custom_config: {
          retrieval_configuration: {
            vector_search_configuration: {
              filter: { equals: { key: "page_number", value: 12 } }
            }
          }
        }
      )
    end

    assert_equal 1, client.generate_calls
    assert_includes account_ids(client.filter), @viewer.id.to_s
    assert_not_includes account_ids(client.filter), @owner.id.to_s
    assert_empty values_for(client.filter, "manual_corpus")
    assert_includes values_for(client.filter, "page_number"), "12"
  end

  test "an unforced pin retry stays inside the authorized corpus" do
    own = KbDocument.create!(account: @viewer, s3_key: "manuals/retry-pin.pdf", display_name: "Pin", aliases: [])
    client = FakeClient.new
    client.sorry_first = true
    with_client(client) do
      BedrockRagService.new(account: @viewer).query(
        "torque del freno",
        entity_s3_uris: [ own.canonical_uri ],
        force_entity_filter: false
      )
    end

    assert_equal 2, client.filters.size
    assert_includes values_for(client.filters.first, "original_source_uri"), own.canonical_uri
    assert_equal [ @viewer.id.to_s ], account_ids(client.filters.second)
    assert_empty values_for(client.filters.second, "manual_corpus")
    assert_not_includes account_ids(client.filters.second), accounts(:legacy).id.to_s
    assert_not_includes account_ids(client.filters.second), accounts(:pilot).id.to_s
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

  def citation_for(document, body)
    OpenStruct.new(
      retrieved_references: [
        OpenStruct.new(
          content: OpenStruct.new(text: body),
          location: OpenStruct.new(s3_location: OpenStruct.new(uri: "s3://bucket/chunks/#{document.id}.txt")),
          metadata: {
            "original_source_uri" => document.canonical_uri,
            "account_id" => document.account_id.to_s,
            "document_id" => document.document_uid
          }
        )
      ]
    )
  end

  def cited_response(answer, document, body)
    OpenStruct.new(
      output: OpenStruct.new(text: answer),
      session_id: "sid",
      citations: [ citation_for(document, body) ]
    )
  end

  def retrieve_result(document, body)
    OpenStruct.new(
      content: OpenStruct.new(text: body),
      score: 0.9,
      metadata: {
        "original_source_uri" => document.canonical_uri,
        "account_id" => document.account_id.to_s,
        "document_id" => document.document_uid
      },
      location: OpenStruct.new(s3_location: OpenStruct.new(uri: "s3://bucket/chunks/#{document.id}.txt"))
    )
  end

  class FakeClient
    attr_reader :filter, :filters, :generate_calls, :retrieve_calls
    attr_accessor :generate_response, :retrieve_results, :sorry_first

    def initialize
      @generate_calls = 0
      @retrieve_calls = 0
      @filters = []
    end

    def retrieve(_params)
      @retrieve_calls += 1
      OpenStruct.new(retrieval_results: Array(@retrieve_results))
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
      @filters << @filter
      if @sorry_first && @generate_calls == 1
        return OpenStruct.new(
          output: OpenStruct.new(text: "Sorry, I am unable to assist you with this request."),
          citations: [],
          session_id: "sid"
        )
      end

      @generate_response || OpenStruct.new(output: OpenStruct.new(text: "ok"), citations: [], session_id: "sid")
    end
  end
end
