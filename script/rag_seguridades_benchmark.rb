# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"

class RagSeguridadesBenchmark
  RUBRIC_PATH = Rails.root.join("script/fixtures/rag_seguridades_rubric.json")
  ExternalDocument = Data.define(:id, :account, :display_name, :s3_key, :source_uri)

  def initialize(env: ENV)
    @env = env
    rubric_path = env.fetch("RAG_SEGURIDADES_RUBRIC", RUBRIC_PATH)
    @rubric = JSON.parse(File.read(rubric_path))
    @output_path = env.fetch(
      "RAG_SEGURIDADES_OUTPUT",
      Rails.root.join("tmp/rag_seguridades_benchmark.json").to_s
    )
  end

  def run!
    rubric = filtered_rubric
    document = find_document!
    account = document.account
    source_uri =
      if document.respond_to?(:source_uri)
        document.source_uri
      else
        document.display_s3_uri(KbDocument::KB_BUCKET)
      end
    service = BedrockRagService.new(account: account)
    started_at = Time.current

    results = rubric.fetch("cases").map do |definition|
      run_case(service, account, definition, source_uri)
    end
    payload = {
      run_id: "seguridades:#{SecureRandom.uuid}",
      rubric_version: rubric.fetch("version"),
      started_at: started_at.utc.iso8601(6),
      finished_at: Time.current.utc.iso8601(6),
      document: {
        id: document.id,
        account_id: account.id,
        display_name: document.display_name,
        s3_key: document.s3_key,
        source_uri: source_uri
      },
      visual_text_audit: rubric.fetch("visual_text_audit", []),
      results: results
    }
    payload[:evaluation] = Rag::BenchmarkRubricEvaluator.new(
      rubric: rubric,
      payload: payload
    ).evaluate

    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts JSON.pretty_generate(payload.slice(:run_id, :rubric_version, :document, :evaluation))
    payload
  end

  private

  # Optional cheap re-verification of a subset of cases. The filter must also
  # apply to the rubric handed to the evaluator, otherwise the cases that were
  # never run are reported as missing_result failures.
  def filtered_rubric
    ids = @env["RAG_SEGURIDADES_CASE_IDS"].to_s.split(",").map(&:strip).reject(&:empty?)
    return @rubric if ids.empty?

    cases = @rubric.fetch("cases").select { |definition| ids.include?(definition["id"]) }
    raise ArgumentError, "No rubric cases match RAG_SEGURIDADES_CASE_IDS=#{ids.join(",")}" if cases.empty?

    @rubric.merge("cases" => cases)
  end

  def find_document!
    key = @env["RAG_SEGURIDADES_DOCUMENT_KEY"].to_s.presence
    account_id = Integer(@env["RAG_SEGURIDADES_ACCOUNT_ID"], exception: false)
    scope = account_id ? KbDocument.where(account_id: account_id) : KbDocument.all
    document =
      if key
        scope.find_by(s3_key: key)
      else
        scope.where("display_name ILIKE :term OR s3_key ILIKE :term", term: "%SEGURIDADES%").first
      end
    return document if document

    return external_document(key, account_id) if key && account_id

    raise ArgumentError,
      "SEGURIDADES document not found. Set RAG_SEGURIDADES_DOCUMENT_KEY and, if needed, RAG_SEGURIDADES_ACCOUNT_ID."
  end

  def external_document(key, account_id)
    bucket = @env["KNOWLEDGE_BASE_S3_BUCKET"].to_s.presence
    source_uri =
      if key.start_with?("s3://")
        key
      elsif bucket
        "s3://#{bucket}/#{key.delete_prefix("/")}"
      end
    raise ArgumentError, "KNOWLEDGE_BASE_S3_BUCKET is required for an external document key." unless source_uri

    account = Account.find_by(id: account_id) ||
      Account.new(id: account_id, slug: "external-#{account_id}", display_name: "External account #{account_id}")
    s3_key = source_uri.delete_prefix("s3://").split("/", 2).last

    ExternalDocument.new(
      id: nil,
      account: account,
      display_name: File.basename(s3_key),
      s3_key: s3_key,
      source_uri: source_uri
    )
  end

  def run_case(service, account, definition, source_uri)
    question = definition.fetch("question")
    retrieval = service.retrieve_chunks(
      question,
      entity_s3_uris: [ source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      number_of_results: RagRetrievalProfile.new(
        entity_sources: [ "document" ],
        question: question
      ).number_of_results
    )

    result =
      if Rag::DeterministicIntent.ambiguous_hardware_query?(question)
        Rag::AmbiguousModelResponder.new(
          question: question,
          account: account,
          entity_s3_uris: [ source_uri ],
          entity_sources: [ "document" ],
          force_entity_filter: true,
          response_locale: :es,
          rag_service: service
        ).execute
      end
    result ||= service.query(
      question,
      response_locale: :es,
      entity_s3_uris: [ source_uri ],
      entity_sources: [ "document" ],
      output_channel: :web,
      force_entity_filter: true,
      include_diagnostics: true
    )

    diagnostics = result[:diagnostics].to_h
    {
      id: definition.fetch("id"),
      category: definition.fetch("category"),
      severity: definition.fetch("severity"),
      source_pages: definition.fetch("source_pages"),
      question: question,
      answer: result[:answer].to_s,
      raw_answer: diagnostics[:raw_answer],
      internal_answer: diagnostics[:internal_answer],
      empty_stage: empty_stage(retrieval[:chunks], diagnostics[:raw_answer], result[:answer]),
      context_included_page_image: false,
      visual_description_present: retrieval[:chunks].any? { |chunk| visual_description?(chunk) },
      retrieval_trace: retrieval[:retrieval_trace],
      chunks: retrieval[:chunks],
      citations: result[:citations],
      generation_mode: result[:generation_mode] || "bedrock_retrieve_and_generate",
      model_invoked: result.key?(:model_invoked) ? result[:model_invoked] : true
    }
  rescue StandardError => e
    {
      id: definition.fetch("id"),
      category: definition.fetch("category"),
      severity: definition.fetch("severity"),
      source_pages: definition.fetch("source_pages"),
      question: question,
      answer: "",
      error_type: e.class.name,
      error_message: e.message
    }
  end

  def empty_stage(chunks, raw_answer, answer)
    return "retrieval" if Array(chunks).empty?
    return "generation" if raw_answer != nil && raw_answer.to_s.strip.empty?
    return "render" if answer.to_s.strip.empty?

    nil
  end

  def visual_description?(chunk)
    metadata = chunk[:metadata].to_h.stringify_keys
    return true if metadata["ingestion_path"] == "field_photo_v1"

    chunk[:content].to_s.match?(/visible labels|documented connections|diagrama|esquema visual/i)
  end
end

RagSeguridadesBenchmark.new.run! unless ENV["RAG_SEGURIDADES_LIBRARY_ONLY"] == "1"
