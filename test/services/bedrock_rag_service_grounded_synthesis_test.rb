# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"

class BedrockRagServiceGroundedSynthesisTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  STRICT_OFF_SHA256 = "9182ccf3ac853409bd66cbc58ba808d28d5ce192ce90a44593f6d51a33d74ff8"
  LEGACY_TAIL =
    "**DATA_NOT_AVAILABLE** — el dato solicitado no está documentado; requiere verificación en campo."

  SECTION7_FIXTURE = <<~TEXT.strip
    La documentación establece que la tensión de los cables de suspensión debe ser igual [1].

    Interpretación técnica: la longitud efectiva se regula por el ajuste fino o grueso de cada ramal; el elemento elástico no se regula como pieza suelta. No se prescribe una intervención.

    Falta el identificador del conjunto (DATA_NOT_AVAILABLE). ¿Cuántos cables llegan a ese amarre, y cada uno tiene su propio resorte con una tuerca encima de la varilla?
  TEXT

  setup do
    @account = accounts(:legacy)
    @original_gs = ENV.fetch("RAG_GROUNDED_SYNTHESIS_ENABLED", nil)
    @original_ids = ENV.fetch("RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS", nil)
    @original_partial = ENV.fetch("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil)
    @original_kb = ENV.fetch("BEDROCK_KNOWLEDGE_BASE_ID", nil)
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "test-kb"
    ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
    ENV.delete("RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS")
    ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
  end

  teardown do
    restore_env("RAG_GROUNDED_SYNTHESIS_ENABLED", @original_gs)
    restore_env("RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS", @original_ids)
    restore_env("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", @original_partial)
    restore_env("BEDROCK_KNOWLEDGE_BASE_ID", @original_kb)
    reset_prompt_memo
  end

  test "variant off is byte-identical to the current strict template" do
    prompt = BedrockRagService.load_generation_prompt_template(grounded_synthesis: false)

    assert_equal STRICT_OFF_SHA256, Digest::SHA256.hexdigest(prompt)
    assert_not_includes prompt, "GROUNDED_SYNTHESIS"
    assert_not_includes prompt, "STRICT_ONLY"
    assert_not_includes prompt, BedrockRagService::GROUNDED_SYNTHESIS_PROMPT_PREFIX
    assert_not_includes prompt, BedrockRagService::STRICT_ONLY_PROMPT_PREFIX
  end

  test "variant on keeps no STRICT_ONLY line and no literal variant prefix" do
    prompt = BedrockRagService.load_generation_prompt_template(grounded_synthesis: true)

    assert_not_includes prompt, "STRICT_ONLY"
    assert_not_includes prompt, "GROUNDED_SYNTHESIS"
    assert_not_includes prompt, BedrockRagService::GROUNDED_SYNTHESIS_PROMPT_PREFIX
    assert_not_includes prompt, BedrockRagService::STRICT_ONLY_PROMPT_PREFIX
    assert_includes prompt, "# DISCRIMINATING QUESTION"
    assert_includes prompt, "Interpretación técnica:"
    assert_includes prompt, "pertinent to the same component and function"
    assert_includes prompt, "compatible fragments of the same document"
  end

  test "NO MATCH bullets are unchanged between variants" do
    off = BedrockRagService.load_generation_prompt_template(grounded_synthesis: false)
    on = BedrockRagService.load_generation_prompt_template(grounded_synthesis: true)
    pattern = /# NO MATCH\n.*?(?=\n# FORMAT)/m

    assert_equal off[pattern], on[pattern]
    assert_not_includes on[pattern], "# DISCRIMINATING QUESTION"
  end

  test "production memoizes by partial_contract and grounded_synthesis" do
    reset_prompt_memo
    Rails.env.define_singleton_method(:production?) { true }

    off = BedrockRagService.load_generation_prompt_template(grounded_synthesis: false)
    off_again = BedrockRagService.load_generation_prompt_template(grounded_synthesis: false)
    on = BedrockRagService.load_generation_prompt_template(grounded_synthesis: true)

    assert_same off, off_again
    assert_not_same off, on
    cache = BedrockRagService.instance_variable_get(:@generation_prompt_templates)
    assert cache.key?([ false, false ])
    assert cache.key?([ false, true ])
  ensure
    if Rails.env.singleton_class.instance_methods(false).include?(:production?)
      Rails.env.singleton_class.remove_method(:production?)
    end
    reset_prompt_memo
  end

  test "track methods estimate tokens via load_generation_prompt_with_locale" do
    service = BedrockRagService.new(account: @account)
    calls = []
    service.define_singleton_method(:load_generation_prompt_with_locale) do |*args, **kwargs|
      calls << { args: args, kwargs: kwargs }
      "PROMPT"
    end

    original = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**_| }

    service.send(
      :track_rag_usage,
      question: "q",
      raw_answer: "a",
      visible_answer: "a",
      config: {},
      retrieved_chunks: [],
      observed_chunk_basis: "none",
      input_token_basis: "prompt_template_plus_observed_chunks",
      bedrock_cited_references_count: 0,
      doc_refs_present: false,
      doc_refs_valid: false,
      doc_refs_count: 0,
      entity_filter_applied: false,
      response_locale: :es,
      session_context: nil,
      output_channel: :web,
      correlation_id: "c",
      generation_attempt: 1,
      applied_filter_uris: [],
      latency_ms: 1,
      model_id: "m",
      attribution: { account_id: @account.id }
    )
    service.send(
      :track_filtered_no_results_attempt,
      question: "q",
      raw_answer: "a",
      config: {},
      correlation_id: "c",
      latency_ms: 1,
      response_locale: :es,
      session_context: nil,
      output_channel: :web,
      attribution: { account_id: @account.id }
    )

    assert_equal 2, calls.size
    assert(calls.all? { |call| call[:args].first == "q" })
  ensure
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**kwargs| original.call(**kwargs) } if original
  end

  test "load_generation_prompt_with_locale passes the instance grounded_synthesis value" do
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "true"
    service = BedrockRagService.new(account: @account)
    seen = nil
    original = BedrockRagService.method(:load_generation_prompt_template)
    BedrockRagService.define_singleton_method(:load_generation_prompt_template) do |**kwargs|
      seen = kwargs
      original.call(**kwargs)
    end

    service.send(:load_generation_prompt_with_locale, "pregunta", response_locale: :es)

    assert_equal({ grounded_synthesis: true }, seen)
  ensure
    BedrockRagService.define_singleton_method(:load_generation_prompt_template) do |**kwargs|
      original.call(**kwargs)
    end if original
  end

  test "D5 skips the absence footer when grounded synthesis and a citation marker are present" do
    answer = "La documentación no contiene el procedimiento solicitado. La tensión debe ser igual [1]."

    with_footer = normalize(answer, grounded_synthesis: false)
    without_footer = normalize(answer, grounded_synthesis: true)

    assert_equal "#{answer}\n\n#{LEGACY_TAIL}", with_footer
    assert_equal answer, without_footer
  end

  test "D5 still appends the footer when there is no citation marker" do
    answer = "La documentación no contiene el procedimiento solicitado."

    assert_equal "#{answer}\n\n#{LEGACY_TAIL}", normalize(answer, grounded_synthesis: false)
    assert_equal "#{answer}\n\n#{LEGACY_TAIL}", normalize(answer, grounded_synthesis: true)
  end

  test "variant prompt stays within 5 percent of the strict prompt" do
    strict = BedrockRagService.load_generation_prompt_template(grounded_synthesis: false)
    variant = BedrockRagService.load_generation_prompt_template(grounded_synthesis: true)
    strict_tokens = AnthropicTokenCounter::LocalTokenizer.estimate(strict)
    variant_tokens = AnthropicTokenCounter::LocalTokenizer.estimate(variant)

    assert_operator variant_tokens, :<=, (strict_tokens * 1.05)
  end

  test "initialize records enabled_for? on the instance" do
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "true"
    enabled = BedrockRagService.new(account: @account)
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "false"
    disabled = BedrockRagService.new(account: @account)

    assert_equal true, enabled.instance_variable_get(:@grounded_synthesis)
    assert_equal false, disabled.instance_variable_get(:@grounded_synthesis)
  end

  test "quality and regression telemetry carry contract_version and grounded_synthesis" do
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "true"
    service = BedrockRagService.new(account: @account)
    citation_attribution = Rag::CitationAttributionGuard::Result.new(
      answer: "ok", dropped_segments: [], anchors: [], identities: []
    )
    log_output = StringIO.new
    logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(logger)

    service.send(
      :log_quality_signal,
      question: "q",
      answer: "a",
      citations: [],
      doc_refs: nil,
      raw_citations: [],
      latency_ms: 1,
      entity_filter: [],
      evidence_mode: "none",
      retrieved_chunks: [],
      canned_no_results: false,
      canned_with_retrieval: false,
      correlation_id: "c",
      attribution: { account_id: @account.id },
      citation_attribution: citation_attribution
    )
    service.send(
      :log_rag_regression,
      config: {},
      retrieved_chunks: [],
      observed_chunk_basis: "none",
      input_token_basis: "prompt_template_plus_observed_chunks",
      bedrock_cited_references_count: 0,
      doc_refs_present: false,
      doc_refs_valid: false,
      doc_refs_count: 0,
      entity_filter_applied: false,
      raw_answer: "a",
      visible_answer: "a",
      input_tokens: 1,
      output_tokens: 1,
      model_id: "m",
      latency_ms: 1
    )

    quality = json_from(log_output.string, "[RAG_QUALITY]")
    regression = json_from(log_output.string, "[RAG_REGRESSION]")
    assert_equal "gs-v1", quality["contract_version"]
    assert_equal true, quality["grounded_synthesis"]
    assert_equal "gs-v1", regression["contract_version"]
    assert_equal true, regression["grounded_synthesis"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "section 7 fixture survives answer safety and attribution without I11" do
    processed = Rag::AnswerSafetyProcessor.new(locale: :es).call(
      SECTION7_FIXTURE,
      evidence: [ { content: "tensión igual en cables de suspensión" } ]
    )

    assert_includes processed, "Interpretación técnica:"
    assert_includes processed, "tensión de los cables"
    assert_includes processed, I18n.t("rag.data_not_available", locale: :es)
    assert_not Rag::AnswerSafetyProcessor.requires_evidence?(SECTION7_FIXTURE.sub("DATA_NOT_AVAILABLE", ""))

    guarded = Rag::CitationAttributionGuard.new(question: "Cómo se ajustan", citations: []).call(processed)
    assert_equal processed, guarded.answer
    assert_not guarded.dropped_any?
  end

  test "generation prompt names no manufacturer model or concrete recipe" do
    raw = Rails.root.join("app/prompts/bedrock/generation.txt").read
    on = BedrockRagService.load_generation_prompt_template(grounded_synthesis: true)

    %w[Yida MiniSpace enchufe BOLIVAR].each do |term|
      assert_not_includes raw, term
      assert_not_includes on, term
    end
    assert_not_includes on, "3 mm"
    assert_not_includes on, "5%"
  end

  private

  def normalize(answer, **kwargs)
    BedrockRagService.allocate.send(:normalize_absence_semantics, answer, **kwargs)
  end

  def json_from(log, marker)
    line = log.lines.find { |entry| entry.include?(marker) }
    assert line, "#{marker} must be logged"
    JSON.parse(line.split("#{marker} ", 2).last)
  end

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  def reset_prompt_memo
    if BedrockRagService.instance_variable_defined?(:@generation_prompt_templates)
      BedrockRagService.remove_instance_variable(:@generation_prompt_templates)
    end
    if BedrockRagService.instance_variable_defined?(:@generation_prompt_template)
      BedrockRagService.remove_instance_variable(:@generation_prompt_template)
    end
  end
end
