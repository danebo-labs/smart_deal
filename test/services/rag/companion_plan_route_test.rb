# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../support/local_chunk_directory"
require_relative "../../support/local_knowledge_base"

# The companion turn through the real retrieve_chunks, identity scope,
# definition source, plan check, render, and publication. Only the AWS SDK
# boundary is replaced: Retrieve and S3 read a local chunk directory, and
# converse returns a scripted tool call.
class Rag::CompanionPlanRouteTest < ActiveSupport::TestCase
  BUCKET = "local-kb"
  STEPS = <<~TEXT
    [DOCUMENT: bomba.pdf]
    [PDF_PAGE: 3]
    6.1 Averías
    • El motor se para solo.
    – Comprobar el ajuste del regulador de caudal (#9).
    – Comprobar que el sensor de nivel no esté activado.
  TEXT
  DEFINITION = "[DOCUMENT: bomba.pdf]\n[PDF_PAGE: 5]\n4.2 Regulador (9)\nFija el caudal de agua que recibe la bomba.\n"
  OTHER = "[DOCUMENT: otra.pdf]\n6.1 Averías\n• El motor se para solo.\n– Puentear el contactor K4.\n"

  setup do
    @root = Pathname.new(Dir.mktmpdir("companion-route"))
    @store = LocalChunkDirectory.new(@root)
    write_chunk("doc-bomba", "chunk_p3_1.txt", STEPS, page: 3, account: accounts(:legacy).id, name: "Bomba Hidra P2")
    write_chunk("doc-bomba", "chunk_p5_1.txt", DEFINITION, page: 5, account: accounts(:legacy).id, name: "Bomba Hidra P2")
    write_chunk("doc-otra", "chunk_p3_1.txt", OTHER, page: 3, account: 999_999, name: "Bomba ajena")
    @kb = LocalKnowledgeBase.new(@root, bucket: BUCKET)
    @plans = []
    @saved = Aws.config.slice(:s3).compact
    store = @store
    Aws.config[:s3] = {
      stub_responses: {
        list_objects_v2: ->(context) { { contents: store.list_keys(prefix: context.params[:prefix]).map { |key| { key: key } }, is_truncated: false } },
        get_object: ->(context) { { body: store.download(context.params[:key]).to_s } },
        put_object: "AccessDenied",
        delete_objects: "AccessDenied"
      }
    }
  end

  teardown do
    Aws.config.delete(:s3)
    Aws.config.merge!(@saved.to_h)
    FileUtils.remove_entry(@root) if @root
  end

  test "retrieval, definitions, plan, publication, and capture run on the product path" do
    session = session_with_history
    result = nil
    events = with_flags do
      Rag::ValidationCapture.capture do
        Rag::ValidationCapture.correlation = "query:t2"
        result = ask(session)
      end
    end

    assert_equal 1, @kb.calls.size
    assert_equal [ "bulk_chunks/#{accounts(:legacy).id}/doc-bomba/chunk_p3_1.txt" ], @kb.calls.first["keys"]
    assert_equal 2, @kb.calls.first["filtered"], "the other account's chunk stays out of the filter"
    assert_equal :answered, result[:route_outcome], result[:companion_publication].inspect
    assert_equal 1, @plans.size
    prompt = @plans.first[:messages].first[:content].first[:text]
    assert_includes prompt, "definición añadida de #9"
    assert_includes prompt, "Fija el caudal de agua que recibe la bomba."
    assert_not_includes prompt, "Puentear el contactor K4"
    assert_includes result[:answer], "- «Comprobar el ajuste del regulador de caudal (#9)» [1]; dijiste «No he comprobado el #9», así que sigue pendiente."
    assert_not_includes result[:answer], "ajustar el regulador a"

    dir = @root.join("calls")
    folders = Rag::CallEvidence.materialize(dir, events, contexts: { "companion_plan" => { presented: result[:answer] } })
    plan_folder = Array(folders).map { |item| Pathname(item.to_s) }.find { |path| path.basename.to_s.include?("companion_plan") }
    assert plan_folder, Dir.children(dir).inspect
    assert_includes plan_folder.join("request.txt").read, Rag::CompanionPlan::TOOL_NAME
    assert_includes plan_folder.join("raw_response.txt").read, "\"steps\""
    consumption = JSON.parse(plan_folder.join("consumption.json").read)
    assert_equal 1500, consumption["input_tokens"]
    assert_equal "calculated", consumption["cost_kind"]
  end

  test "a diagram chunk does not leave the companion and an explicit plan request does" do
    with_flags do
      [ 0, 7 ].each do |position|
        @plans.clear
        invoked = []
        result = ask(session_with_history, chunks: diagram_chunks(position), invoked: invoked, raw_question: "Corrijo solo el estado del LED: el LED está encendido, no apagado.")
        assert result[:companion_turn], "position #{position} #{result[:companion_reason].inspect} #{result[:route_outcome]}"
        assert_equal 1, @plans.size
        assert_empty invoked
      end
    end

    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "kb-local")
    applied = Struct.new(:status).new(:scoped)
    stored = episode
    before = stored.to_h
    chunks = diagram_chunks(7)
    with_flags do
      assert_equal :plan, service.send(:companion_turn_skip_reason, applied: applied, chunks: chunks, episode: stored, raw_question: "muéstrame el plano de la fotocélula")
      assert_nil service.send(:companion_turn_skip_reason, applied: applied, chunks: chunks, episode: stored, raw_question: "no necesito el plano")
      assert_nil service.send(:companion_turn_skip_reason, applied: applied, chunks: chunks, episode: stored, raw_question: "la etiqueta del equipo dice VF5+")
      assert_nil service.send(:companion_turn_skip_reason, applied: applied, chunks: chunks, episode: stored, raw_question: "¿qué sigue?")
    end
    assert_equal before, stored.to_h
    assert BedrockRagService.plan_context?("¿qué sigue?", nil, [ { content: "Diagrama de la página (etiquetas literales):\n20\n" } ])
    assert_not BedrockRagService.plan_request?("¿qué sigue?", nil)
    assert BedrockRagService.plan_request?("muéstrame el plano de la fotocélula", nil)
    assert_not BedrockRagService.plan_request?("no necesito el plano", nil)
    assert_not BedrockRagService.plan_request?("la etiqueta del equipo dice VF5+", nil)
  end

  test "the other companion gates stay closed for the same chunks" do
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "kb-local")
    applied = Struct.new(:status).new(:scoped)
    chunks = diagram_chunks(0)
    with_flags do
      ENV["RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"] = "1"
      assert_equal :system_role, service.send(:companion_turn_skip_reason, applied: applied, chunks: chunks, episode: episode, raw_question: "¿qué sigue?")
      ENV.delete("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE")
      assert_equal :identity, service.send(:companion_turn_skip_reason, applied: Struct.new(:status).new(:no_compatible), chunks: chunks, episode: episode, raw_question: "¿qué sigue?")
      assert_equal :episode, service.send(:companion_turn_skip_reason, applied: applied, chunks: chunks, episode: nil, raw_question: "¿qué sigue?")
      assert_equal :raw_question, service.send(:companion_turn_skip_reason, applied: applied, chunks: chunks, episode: episode, raw_question: "  ")
      marked = [ { content: "FIELD_RECORD todavía en el relato\nLa puerta se para.\n" } ]
      assert_equal :field_records, service.send(:companion_turn_skip_reason, applied: applied, chunks: marked, episode: episode, raw_question: "¿qué sigue?")
    end
  end

  private

  def write_chunk(document, filename, text, page:, account:, name:)
    key = "bulk_chunks/#{account}/#{document}/#{filename}"
    @store.upload_text(key, text)
    @store.upload_text("#{key}.metadata.json", JSON.generate("metadataAttributes" => {
      "account_id" => account.to_s,
      "document_id" => document,
      "original_source_uri" => "s3://#{BUCKET}/bulk_uploads/#{document}.pdf",
      "original_filename" => "#{document}.pdf",
      "canonical_name" => name,
      "aliases" => [ "Hidra P2", "Bomba Hidra" ],
      "ingestion_path" => "manual_batch_v1",
      "ingestion_contract_version" => BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      "manual_corpus" => "account",
      "page_number" => page
    }))
  end

  def episode
    value = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: 2.minutes.ago)
    value.assign_goal!("El motor se para solo", correlation_id: "query:t1")
    value.write_fact!("manufacturer", status: "known", value: "Hidra", source: "user", correlation_id: "query:t1", at: Time.current.iso8601)
    value.append_identifier!("Hidra P2", correlation_id: "query:t1", source: "user")
    value.upsert_check!({ "subject" => "#9", "status" => "not_done" }, correlation_id: "query:t1")
    value
  end

  def session_with_history
    ConversationSession.create!(
      identifier: "web:companion-route-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy),
      active_episode: episode.to_h,
      conversation_history: [
        { "role" => "user", "content" => "Bomba Hidra P2. El motor se para solo. No he comprobado el #9.", "correlation_id" => "query:t1", "ts" => 2.minutes.ago.iso8601 },
        { "role" => "user", "content" => "¿qué sigue?", "correlation_id" => "query:t2", "ts" => 1.minute.ago.iso8601 }
      ]
    )
  end

  def diagram_chunks(diagram_at)
    body = "[DOCUMENT: bomba.pdf]\n[PDF_PAGE: 3]\n6.1 Averías\n• El motor se para solo.\n– Comprobar el ajuste del regulador de caudal (#9).\n"
    chunks = Array.new(8) { chunk_hash(body) }
    chunks[diagram_at] = chunk_hash("Diagrama de la página (etiquetas literales):\n20 receptor\n")
    chunks
  end

  def chunk_hash(content)
    {
      content: content,
      metadata: {
        "account_id" => accounts(:legacy).id.to_s,
        "document_id" => "doc-bomba",
        "original_source_uri" => "s3://#{BUCKET}/bulk_uploads/doc-bomba.pdf",
        "original_filename" => "doc-bomba.pdf",
        "canonical_name" => "Bomba Hidra P2",
        "aliases" => [ "Hidra P2" ],
        "page_number" => 3
      }
    }
  end

  def ask(session, chunks: nil, invoked: nil, raw_question: "¿qué sigue?")
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "kb-local")
    service.instance_variable_set(:@client, @kb.client)
    plans = @plans
    runtime = Aws::BedrockRuntime::Client.new(stub_responses: true, region: "us-east-1")
    runtime.define_singleton_method(:converse) do |params = {}, **kwargs|
      params = params.merge(kwargs)
      plans << params
      text = params[:messages].first[:content].first[:text]
      step = text[/^(S\d+\.\d+) \(paso de [^)]*\): Comprobar el ajuste/, 1]
      stub_data(:converse, {
        output: { message: { role: "assistant", content: [ { tool_use: {
          tool_use_id: "tool-1", name: Rag::CompanionPlan::TOOL_NAME,
          input: { "links" => [], "steps" => [ step ], "question" => "" }
        } } ] } },
        stop_reason: "tool_use",
        usage: { input_tokens: 1500, output_tokens: 60, total_tokens: 1560 },
        metrics: { latency_ms: 5 }
      })
    end
    generator = AiProvider.new
    generator.instance_variable_get(:@client).instance_variable_set(:@client, runtime)
    service.instance_variable_set(:@document_identity_generator, generator)
    if chunks
      service.define_singleton_method(:retrieve_chunks) { |*_args, **_kwargs| { retrieval: "ok", chunks: chunks } }
    end
    runtime.define_singleton_method(:invoke_model) do |*_args, **_kwargs|
      invoked << :generate_text if invoked
      Struct.new(:body).new(StringIO.new({ content: [ { text: "desde generate_text" } ], stop_reason: "end_turn", usage: { input_tokens: 3, output_tokens: 2 } }.to_json))
    end
    service.send(
      :document_identity_scope_result,
      "motor para solo",
      episode: session.active_episode,
      response_locale: :es,
      entity_s3_uris: [],
      entity_sources: [],
      force_entity_filter: false,
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conversation_session_id: session.id,
      correlation_id: "query:t2",
      raw_question: raw_question,
      conv_session: session
    )
  end

  def with_flags
    keys = %w[DOCUMENT_IDENTITY_SCOPE_ENABLED RAG_COMPANION_TURN RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE KNOWLEDGE_BASE_S3_BUCKET]
    previous = keys.index_with { |key| ENV[key] }
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["RAG_COMPANION_TURN"] = "1"
    ENV.delete("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE")
    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = BUCKET
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

require_relative "../../support/companion_plan_response"
