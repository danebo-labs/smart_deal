# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../support/local_chunk_directory"
require_relative "../../support/local_knowledge_base"
require_relative "../../support/companion_direct_runtime"

# Product entry: execute_rag_query, one stubbed Converse, the existing gate.
class Rag::CompanionDirectRouteTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include CompanionDirectRuntime

  QUOTE = "Solo si el caudal baja, revisar el sensor."
  VALID = "Si el caudal baja, revisa el sensor: «#{QUOTE}» [1]"
  ALTERED = "El texto indica «si el caudal baja, revisar el sensor.» [1]"
  MISSING = "«#{QUOTE}» [9]"
  TECHNICAL = "El LED está encendido."
  NOTICE = "Esto no está en la documentación cargada en este turno"
  TOKEN = "TOKEN-REGISTRO-TERMINAL"
  POISON = "¿Cuál es el caudal exacto?"

  setup do
    @account = accounts(:legacy)
    @user = users(:one)
    @root = Pathname.new(Dir.mktmpdir("companion-direct"))
    @store = LocalChunkDirectory.new(@root)
    @document = KbDocument.create!(
      s3_key: "manuals/companion-direct-bomba.pdf",
      display_name: "Bomba Hidra P2",
      account: @account,
      aliases: []
    )
    @uri = @document.canonical_uri
    write_chunk
    @kb = LocalKnowledgeBase.new(@root, bucket: "local-kb")
    @requests = []
    @reply = ->(_params) { text_reply(VALID) }
    @runtime = Aws::BedrockRuntime::Client.new(stub_responses: true, region: "us-east-1")
    bind_recorded_converse(@runtime)
    test = self
    @runtime.stub_responses(:converse, ->(context) { test.converse_stub(context) })
    Thread.current[:companion_direct_runtime] = @runtime
    Thread.current[:companion_direct_kb] = @kb
    @saved_s3 = Aws.config.slice(:s3).compact
    store = @store
    Aws.config[:s3] = {
      stub_responses: {
        list_objects_v2: ->(context) { { contents: store.list_keys(prefix: context.params[:prefix]).map { |key| { key: key } }, is_truncated: false } },
        get_object: ->(context) { { body: store.download(context.params[:key]).to_s } },
        put_object: "AccessDenied",
        delete_objects: "AccessDenied"
      }
    }
    @host = CompanionDirectHost.new(@account, @user)
    install_companion_direct_runtime!
    install_direct_anthropic!(self)
  end

  teardown do
    Thread.current[:companion_direct_anthropic] = nil
    remove_companion_direct_runtime!
    Thread.current[:companion_direct_runtime] = nil
    Thread.current[:companion_direct_kb] = nil
    Thread.current[:companion_direct_service] = nil
    Aws.config.delete(:s3)
    Aws.config.merge!(@saved_s3.to_h)
    FileUtils.remove_entry(@root) if @root
  end

  test "a literal citation is the published answer and the request has no tool" do
    result = direct { ask("Si el caudal baja, ¿qué reviso?") }
    params = @requests.last
    text = request_text(params)

    assert result.success?, result.error_message
    assert result.companion_turn
    assert_equal :answered, result.route_outcome
    assert_includes result.answer, QUOTE
    assert_equal true, result.companion_publication["accepted"]
    assert_not_includes text, TOKEN
    assert_includes text, "[1] Bomba Hidra P2, página 3"
    assert_includes text, QUOTE
    sent = request_hash(params)
    assert_nil sent[:tools]
    assert_nil sent[:output_config]
    assert_nil sent[:temperature]
    assert_equal "claude-haiku-5-5", sent[:model]
    assert_equal Rag::CompanionDirectAnswer::GENERATION_MAX_TOKENS, sent[:max_tokens]
    assert_equal({ type: "adaptive", display: "summarized" }, sent[:thinking])
    assert_equal %w[user], request_roles(params).uniq
    job = enqueued_jobs.reverse.find { |item| item[:job] == TrackBedrockQueryJob || item["job_class"] == "TrackBedrockQueryJob" }
    assert job, enqueued_jobs.inspect
    args = job[:args] || job["arguments"]
    route = args.last
    route = route[:route] || route["route"] if route.is_a?(Hash)
    assert_equal "companion_direct", route
  end

  test "an altered citation, a missing marker, an uncited claim, and a cut answer abstain" do
    direct do
      @reply = ->(_params) { text_reply(ALTERED) }
      altered = ask("Si el caudal baja, ¿qué reviso?")
      # CompanionClaimBacking drops the unbacked sentence before the gate.
      assert_abstained altered, "R5"

      @requests.clear
      @reply = ->(_params) { text_reply(MISSING) }
      missing = ask("Si el caudal baja, ¿qué reviso?")
      assert_abstained missing, "R5"

      @requests.clear
      @reply = ->(_params) { text_reply(TECHNICAL) }
      technical = ask("Si el caudal baja, ¿qué reviso?")
      assert_abstained technical, "R5"

      @requests.clear
      @reply = ->(_params) { text_reply(VALID, stop: "max_tokens") }
      cut = ask("Si el caudal baja, ¿qué reviso?")
      assert_abstained cut, "R4"
      assert_equal abstain, cut.answer
    end
  end

  test "the exact missing-documentation sentence is published and a tool call is not" do
    notice = direct do
      @reply = ->(_params) { text_reply(NOTICE) }
      ask("Si el caudal baja, ¿qué reviso?")
    end
    assert notice.success?, notice.error_message
    assert_equal :answered, notice.route_outcome
    assert_includes notice.answer, NOTICE
    assert_not_includes notice.answer, "revisar el sensor"

    refused = direct do
      @requests.clear
      @reply = ->(_params) { tool_reply }
      ask("Si el caudal baja, ¿qué reviso?")
    end
    assert_equal abstain, refused.answer
    assert_nil request_hash(@requests.last)[:tool_config]
    assert_not_includes refused.answer, "no publicar"
  end

  test "without the flag the plan tool is still the request" do
    @reply = ->(params) { plan_reply(params) }
    result = with_flags(generation: "plan") { ask("Si el caudal baja, ¿qué reviso?") }
    params = request_hash(@requests.last)
    tool = params.dig(:tool_config, :tools, 0, :tool_spec, :name)
    tool = params.dig(:tool_config, "tools", 0, "tool_spec", "name") if tool.nil?

    assert result.companion_turn
    assert_equal "companion_plan", tool
    assert_equal Rag::CompanionPlan::MAX_TOKENS, config_value(@requests.last, :max_tokens)
    assert_not_equal Rag::CompanionDirectAnswer::MAX_TOKENS, config_value(@requests.last, :max_tokens)
  end

  test "a sleeping model is retried and a validation error is not" do
    calls = 0
    @reply = lambda do |_params|
      calls += 1
      calls == 1 ? "ServiceUnavailableException" : text_reply(VALID)
    end
    result = without_retry_pause do
      with_flags(limit: "2") { ask("Si el caudal baja, ¿qué reviso?") }
    end
    assert_equal 2, calls
    assert_equal 2, @requests.size
    assert_includes result.answer, QUOTE

    calls = 0
    @requests.clear
    @reply = lambda do |_params|
      calls += 1
      "ValidationException"
    end
    refused = with_flags(limit: "2") { ask("Si el caudal baja, ¿qué reviso?") }
    assert_equal 1, calls
    assert_not_includes refused.answer.to_s, QUOTE
    assert_nil refused.provider_rejection
    assert_includes refused.answer.to_s, I18n.t("rag.generation_failed", locale: :es)
    assert_not_includes refused.answer.to_s, I18n.t("rag.data_not_available", locale: :es)
  end

  test "a retrieved section stays in the trace when the provider rejects generation" do
    previous_require = ENV["GUION2_DIRECT_REQUIRE"]
    ENV["GUION2_DIRECT_REQUIRE"] = "1"
    unless defined?(Guion2Direct) && Guion2Direct.respond_to?(:turn_status)
      load Rails.root.join("script/field_companion/run_guion2.rb")
    end
    passage = captured_section_58
    message = captured_provider_rejection
    question = pasada1_root.join("pasada1/guion2/turn-1/question.txt").read.strip
    second = pasada1_root.join("pasada1/guion2/turn-2/question.txt").read.strip
    write_captured_passage(passage)
    @reply = lambda do |_params|
      raise Aws::BedrockRuntime::Errors::ValidationException.new(nil, message)
    end

    result = nil
    events = Rag::ValidationCapture.capture do
      result = with_flags(limit: "1") { ask(question) }
    end

    notice = I18n.t("rag.generation_failed", locale: :es)
    absence = I18n.t("rag.data_not_available", locale: :es)
    assert result.success?, result.error_message
    assert_includes result.answer, notice
    assert_not_includes result.answer, absence
    assert_not_includes result.answer, I18n.t("rag.companion_contract_invalid", locale: :es)
    assert_not_includes result.answer, "se abrirán lentamente"
    assert_includes citation_text(result), passage
    assert_equal "access_denied", result.provider_rejection
    assert_equal message, result.provider_error_message
    assert_equal :unavailable, result.route_outcome
    exit_event = events.reverse.find { |event| event["kind"] == "route_exit" && event["exit"] == "identity_closed" }
    assert exit_event, events.pluck("kind").inspect
    assert_equal "access_denied", exit_event["provider_rejection"]
    assert_equal message, exit_event["provider_error_message"]
    assert_equal true, exit_event["evidence_retained"]
    assert_includes Array(exit_event["evidence"]).pluck("content").join, passage
    published = events.reverse.find { |event| event["kind"] == "published_answer" && event["provider_error_message"].present? }
    assert_includes published["answer"], notice
    assert_not_includes published["answer"], absence
    assert_equal message, published["provider_error_message"]
    assert_equal 1, @requests.size

    ran = 1
    if Guion2Direct.turn_status(result, nil, nil) == "returned"
      ran += 1
      ask(second)
    end
    assert_equal "provider_rejected", Guion2Direct.turn_status(result, nil, nil)
    assert_equal 1, ran
    assert_equal 1, @requests.size
    runner = Rails.root.join("script/field_companion/run_guion2.rb").read
    live = Rails.root.join("script/field_companion/run_case_record_live.rb").read
    assert_includes runner, "turn_status(result, error, written)"
    assert_includes runner, 'break if row["status"] != "returned"'
    assert_includes live, "Guion2Direct.one_turn"
    assert_includes live, 'break if row["status"] != "returned"'
  ensure
    if previous_require.nil?
      ENV.delete("GUION2_DIRECT_REQUIRE")
    else
      ENV["GUION2_DIRECT_REQUIRE"] = previous_require
    end
  end

  test "a poisoned plan question is not published on the direct turn" do
    @reply = lambda do |_params|
      service = Thread.current[:companion_direct_service]
      service.instance_variable_set(:@companion_plan_pending, {
        "type" => "documented_context",
        "question" => POISON,
        "targets" => [ { "item" => "sensor de caudal", "document_key" => "doc-bomba", "filename" => "bomba.pdf", "page" => "3" } ]
      })
      service.instance_variable_set(:@companion_plan_stop_reason, "max_tokens")
      text_reply("#{VALID} #{POISON}")
    end
    result = direct { ask("Si el caudal baja, ¿qué reviso?") }

    assert_equal :answered, result.route_outcome
    assert_nil result.pending_question
    assert_includes result.answer, QUOTE
    assert_equal true, result.companion_publication["accepted"]
  end

  test "the prompt has no script-specific example and the low score chunk stays out" do
    text = Rails.root.join("app/prompts/bedrock/companion_direct.txt").read
    %w[VF5 Fermator fotocélula fotocelula autoajuste S1.9].each do |token|
      assert_not_includes text.downcase, token.downcase
    end
    assert_includes text, NOTICE
    assert_includes text, "No veo X"

    huge = chunk_hash("#{'a' * 20_000}\nUNICO-DESCARTADO\n", score: 0.1)
    kept = chunk_hash("Bomba Hidra P2.\n#{QUOTE}\n", score: 0.9)
    session = pinned_session
    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: "¿qué reviso?", chunks: [ huge, kept ], episode: session.active_episode,
      session: session, correlation_id: nil
    )
    assert_equal 1, prepared.chunks.size
    assert_includes prepared.user, QUOTE
    assert_not_includes prepared.user, "UNICO-DESCARTADO"
    assert_nil prepared.params[:tool_config]
  end

  def converse_stub(context)
    params = context.params
    @requests << params
    @reply.call(params)
  end

  private

  def ask(question)
    @host.ask(question, **ask_args(question))
  end

  def direct(&block)
    with_flags(&block)
  end

  def without_retry_pause
    original = Rag::TransientBackoff.method(:wait_seconds)
    Rag::TransientBackoff.define_singleton_method(:wait_seconds) { |*| 0 }
    yield
  ensure
    Rag::TransientBackoff.define_singleton_method(:wait_seconds) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def ask_args(question)
    session = pinned_session
    {
      conv_session: session,
      account: @account,
      user_id: @user.id,
      correlation_id: "query:direct",
      response_locale: :es,
      entity_s3_uris: [ @uri ],
      raw_question: question,
      episode_turn: continued_turn(question),
      output_channel: :web
    }
  end

  def pinned_session
    session = ConversationSession.create!(
      identifier: "web:companion-direct-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: @user,
      account: @account,
      active_episode: hidra_episode.to_h
    )
    assert session.pin_kb_document!(@document)
    session
  end

  def hidra_episode
    value = Rag::ActiveEpisode.open(correlation_id: "query:setup", now: 10.minutes.ago)
    value.write_fact!(
      "manufacturer", status: "known", value: "Hidra", source: "user",
      correlation_id: "query:setup", at: Time.current.iso8601
    )
    value
  end

  def continued_turn(question)
    understanding = Struct.new(:meta?, :clarify_first?, :owns_query, :retrieval_query, :clarification, :decision).new(
      false, false, false, nil, nil, "ready"
    )
    Struct.new(:understanding, :decision, :reason, :composed).new(understanding, :continued, "continued", question)
  end

  def write_chunk
    key = "bulk_chunks/#{@account.id}/doc-bomba/chunk_p3_1.txt"
    @store.upload_text(key, <<~TEXT)
      [DOCUMENT: bomba.pdf]
      [PDF_PAGE: 3]
      6.1 Caudal
      Bomba Hidra P2.
      Solo si el caudal baja, revisar el sensor.
      # FIELD-SAFETY EVIDENCE RECORDS
      FIELD_RECORD:
      RECORD_ID: rec-1
      SOURCE_SECTION_OR_PAGE: 6.1
      SOURCE_PDF_PAGE: 3
      RECORD_TYPE: NOTE
      ACTION: no usar
      EXPECTED_RESULT: ninguno
      DETAILS: #{TOKEN}
      DERIVATION: none
      DERIVATION_EVIDENCE: none
      STOP_WORK_TRIGGER: none
      STOP_WORK_REQUIRED_ACTION: none
      REPAIR_AUTHORITY: none
      UNCERTAINTY: none
      EVIDENCE: none
      END_FIELD_RECORD
    TEXT
    @store.upload_text("#{key}.metadata.json", JSON.generate("metadataAttributes" => {
      "account_id" => @account.id.to_s,
      "document_id" => "doc-bomba",
      "original_source_uri" => @uri,
      "original_filename" => "bomba.pdf",
      "canonical_name" => "Bomba Hidra P2",
      "aliases" => [ "Hidra P2", "Bomba Hidra" ],
      "ingestion_path" => "manual_batch_v1",
      "manual_corpus" => "account",
      "page_number" => 3
    }))
  end

  def chunk_hash(content, score:)
    {
      content: content,
      score: score,
      metadata: {
        "canonical_name" => "Bomba Hidra P2",
        "page_number" => 3,
        "account_id" => @account.id.to_s
      }
    }
  end

  def tool_reply
    {
      output: { message: { role: "assistant", content: [
        { text: "no publicar" },
        { tool_use: { tool_use_id: "tool-1", name: "companion_plan", input: {} } }
      ] } },
      stop_reason: "tool_use",
      usage: { input_tokens: 20, output_tokens: 8, total_tokens: 28 },
      metrics: { latency_ms: 5 }
    }
  end

  def plan_reply(params)
    text = request_text(params)
    step = text[/^(S\d+\.\d+) \(paso/m, 1]
    input = {
      "links" => [],
      "steps" => [ step ].compact,
      "question" => "",
      "question_about" => [],
      "applicability" => { "statement" => "", "conditions" => [] }
    }
    {
      output: { message: { role: "assistant", content: [ { tool_use: {
        tool_use_id: "tool-1", name: "companion_plan", input: input
      } } ] } },
      stop_reason: "tool_use",
      usage: { input_tokens: 80, output_tokens: 30, total_tokens: 110 },
      metrics: { latency_ms: 5 }
    }
  end

  def config_value(params, key)
    config = request_hash(params)[:inference_config]
    config = config.to_h if config.respond_to?(:to_h) && !config.is_a?(Hash)
    config[key] || config[key.to_s]
  end

  def rules(result)
    Array(result.companion_publication && result.companion_publication["reasons"]).pluck("rule")
  end

  def abstain
    I18n.t("rag.companion_contract_invalid", locale: :es)
  end

  def assert_abstained(result, rule)
    assert result.success?, result.error_message
    assert_equal :abstained, result.route_outcome, result.companion_publication.inspect
    assert_equal abstain, result.answer
    assert_includes rules(result), rule
  end

  def pasada1_root
    Rails.root.join("tmp/field_companion/case_record")
  end

  def captured_provider_rejection
    informe = pasada1_root.join("INFORME_PASADA1.md").read
    message = informe[/anthropic\.claude-haiku-5-5 is not available for this account\./]
    flunk "INFORME_PASADA1.md no conserva el rechazo del proveedor" if message.blank?

    message
  end

  def captured_section_58
    root = pasada1_root.join("pasada1/guion2/turn-1/bodies")
    line = Dir.glob(root.join("*.txt").to_s).lazy.filter_map { |path|
      File.read(path).lines.find { |row|
        row.include?("se abrirán lentamente en la primera operación después de un fallo de alimentación")
      }
    }.first
    flunk "la captura de G2 T1 no conserva el §5.8" if line.blank?

    line.strip
  end

  def write_captured_passage(passage)
    key = "bulk_chunks/#{@account.id}/doc-bomba/chunk_p3_1.txt"
    @store.upload_text(key, <<~TEXT)
      [DOCUMENT: bomba.pdf]
      [PDF_PAGE: 8]
      Bomba Hidra P2.
      #{passage}
    TEXT
    @store.upload_text("#{key}.metadata.json", JSON.generate("metadataAttributes" => {
      "account_id" => @account.id.to_s,
      "document_id" => "doc-bomba",
      "original_source_uri" => @uri,
      "original_filename" => "bomba.pdf",
      "canonical_name" => "Bomba Hidra P2",
      "aliases" => [ "Hidra P2", "Bomba Hidra" ],
      "ingestion_path" => "manual_batch_v1",
      "manual_corpus" => "account",
      "page_number" => 8
    }))
  end

  def citation_text(result)
    Array(result.retrieved_citations).map { |item|
      next item.to_s unless item.respond_to?(:[])

      item[:content] || item["content"]
    }.join("\n")
  end

  def with_flags(generation: "direct", limit: nil)
    keys = %w[
      DOCUMENT_IDENTITY_SCOPE_ENABLED RAG_COMPANION_TURN RAG_COMPANION_GENERATION
      RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE FIELD_COMPANION_TURN_ENABLED BEDROCK_KNOWLEDGE_BASE_ID
      RAG_TRANSIENT_ATTEMPT_LIMIT
    ]
    previous = keys.index_with { |key| ENV[key] }
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["RAG_COMPANION_TURN"] = "1"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "kb-local"
    ENV.delete("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE")
    generation.nil? ? ENV.delete("RAG_COMPANION_GENERATION") : ENV["RAG_COMPANION_GENERATION"] = generation
    limit.nil? ? ENV.delete("RAG_TRANSIENT_ATTEMPT_LIMIT") : ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = limit
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
