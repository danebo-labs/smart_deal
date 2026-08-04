# frozen_string_literal: true

# Fase 6 (plan_ciclo5_resolucion_decision9_2026-08-04.md): UNICA corrida de
# script/fixtures/rag_seguridades_provenance_battery_v1.json (18 casos)
# contra el KB de produccion (job CCCDNEDFYL COMPLETE, SHA desplegado
# 0fad454). Reusa el mismo cascade de seleccion de ruta que
# script/rag_seguridades_benchmark.rb (StructuredEvidenceRoute ->
# AmbiguousModelResponder -> BedrockRagService#query) para tener paridad de
# produccion real -- ninguna de las 18 preguntas se fuerza a una ruta
# especifica que el usuario real no tomaria.
#
# Dos tipos de check, ambos deterministicos ($0 de juez, sin rubrica regex):
#   (a) citation_canonical_name_equals_section_identity: CERO citas cuyo
#       metadata crudo `canonical_name` (Bedrock::CitationProcessor#
#       extract_citations, no el `title` ya renderizado con el sufijo
#       " -- p. N") contradiga expected_section_identity.
#   (b) absence_of_forbidden_patterns_in_retrieved_content: CERO matches de
#       los forbidden_patterns del caso en el CUERPO COMPLETO de los chunks
#       recuperados (diagnostics[:retrieved_chunks], no el tooltip truncado
#       a 150 caracteres).
#
# Script desechable, calcado del patron de
# script/rag_fase5_checkpoint_smoke_2026-08-04.rb y
# script/rag_seguridades_benchmark.rb#run_case.

require "json"
require "fileutils"
require "digest"
require "securerandom"

class RagCiclo5Fase6ProvenanceBattery
  FIXTURE_PATH = Rails.root.join("script/fixtures/rag_seguridades_provenance_battery_v1.json")
  ExternalDocument = Data.define(:id, :account, :display_name, :s3_key, :source_uri)

  class CountingRagService
    attr_reader :retrieve_invocations

    def initialize(service)
      @service = service
      @retrieve_invocations = 0
    end

    def retrieve_chunks(...)
      @retrieve_invocations += 1
      @service.retrieve_chunks(...)
    end

    def query(...)
      @retrieve_invocations += 1
      @service.query(...)
    end

    def method_missing(name, ...)
      @service.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @service.respond_to?(name, include_private) || super
    end
  end

  def initialize(env: ENV)
    @env = env
    fixture_path = env.fetch("RAG_PROVENANCE_BATTERY_FIXTURE_PATH", FIXTURE_PATH)
    @battery = JSON.parse(File.read(fixture_path))
    @output_path = env.fetch(
      "RAG_PROVENANCE_BATTERY_OUTPUT",
      "tmp/rag_seguridades_provenance_battery_v1_run1_2026-08-04.json"
    )
  end

  def run!
    document = find_document!
    account = document.account
    source_uri =
      if document.respond_to?(:source_uri)
        document.source_uri
      else
        document.display_s3_uri(KbDocument::KB_BUCKET)
      end
    started_at = Time.current

    results = @battery.fetch("cases").map do |definition|
      run_case(account, definition, source_uri)
    end

    total_retrieve_invocations = results.sum { |r| r[:retrieve_invocations].to_i }
    canonical_name_mismatches = results.flat_map { |r| r[:canonical_name_mismatches] || [] }
    forbidden_pattern_matches = results.flat_map { |r| r[:forbidden_pattern_matches] || [] }
    empty_results = results.select { |r| r[:empty_result_warning] }

    payload = {
      run_id: "seguridades-provenance-battery:#{SecureRandom.uuid}",
      battery_version: @battery.fetch("version"),
      started_at: started_at.utc.iso8601(6),
      finished_at: Time.current.utc.iso8601(6),
      document: {
        id: document.id,
        account_id: account.id,
        display_name: document.display_name,
        s3_key: document.s3_key,
        source_uri: source_uri
      },
      summary: {
        cases: results.size,
        total_retrieve_invocations: total_retrieve_invocations,
        canonical_name_mismatches_count: canonical_name_mismatches.size,
        forbidden_pattern_matches_count: forbidden_pattern_matches.size,
        empty_results_count: empty_results.size,
        gate_check_4_passed: canonical_name_mismatches.empty? && forbidden_pattern_matches.empty?
      },
      canonical_name_mismatches: canonical_name_mismatches,
      forbidden_pattern_matches: forbidden_pattern_matches,
      empty_results: empty_results.pluck(:id),
      results: results
    }

    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts JSON.pretty_generate(payload.slice(:run_id, :battery_version, :document, :summary))
    payload
  end

  private

  def run_case(account, definition, source_uri)
    question = definition.fetch("question")
    counted_service = CountingRagService.new(BedrockRagService.new(account: account))

    structured = Rag::StructuredEvidenceRoute.build(
      question: question,
      account: account,
      entity_s3_uris: [ source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      output_channel: :web,
      account_id: account.id,
      rag_service: counted_service
    )
    outcome = structured&.execute

    result =
      if outcome&.status == :answered || outcome&.status == :abstained
        outcome.result
      elsif Rag::DeterministicIntent.ambiguous_hardware_query?(question)
        Rag::AmbiguousModelResponder.new(
          question: question,
          account: account,
          entity_s3_uris: [ source_uri ],
          entity_sources: [ "document" ],
          force_entity_filter: true,
          response_locale: :es,
          rag_service: counted_service
        ).execute
      end
    result ||= counted_service.query(
      question,
      response_locale: :es,
      entity_s3_uris: [ source_uri ],
      entity_sources: [ "document" ],
      output_channel: :web,
      force_entity_filter: true,
      include_diagnostics: true
    )

    build_case_payload(
      definition: definition,
      question: question,
      result: result,
      retrieve_invocations: counted_service.retrieve_invocations
    )
  rescue StandardError => e
    {
      id: definition.fetch("id"),
      check_category: definition.fetch("check_category"),
      severity: definition.fetch("severity"),
      question: question,
      answer: "",
      chunks: [],
      error_type: e.class.name,
      error_message: e.message,
      retrieve_invocations: counted_service&.retrieve_invocations.to_i,
      empty_result_warning: true
    }
  end

  def build_case_payload(definition:, question:, result:, retrieve_invocations:)
    citations = Array(result[:citations])
    chunks = Array(result.dig(:diagnostics, :retrieved_chunks))
    answer = result[:answer].to_s
    check = definition.fetch("check")

    case_payload = {
      id: definition.fetch("id"),
      check_category: definition.fetch("check_category"),
      severity: definition.fetch("severity"),
      question: question,
      answer: answer,
      citations: citations,
      chunks: chunks,
      retrieval_trace: result[:retrieval_trace],
      retrieve_invocations: retrieve_invocations,
      empty_result_warning: chunks.empty? || answer.strip.empty?
    }

    case check.fetch("type")
    when "citation_canonical_name_equals_section_identity"
      apply_canonical_name_check(case_payload, definition, citations)
    when "absence_of_forbidden_patterns_in_retrieved_content"
      apply_forbidden_pattern_check(case_payload, definition, chunks, answer)
    else
      raise ArgumentError, "Unknown provenance battery check type: #{check.fetch('type')}"
    end

    case_payload
  end

  def apply_canonical_name_check(case_payload, definition, citations)
    expected = definition.fetch("expected_section_identity")
    canonical_names = citations.map do |citation|
      metadata = citation[:metadata] || citation["metadata"] || {}
      metadata["canonical_name"] || metadata[:canonical_name]
    end
    mismatches = citations.each_with_index.filter_map do |citation, idx|
      canonical_name = canonical_names[idx]
      next if canonical_name.nil? || canonical_name == expected

      {
        case_id: definition.fetch("id"),
        citation_number: citation[:number] || citation["number"],
        citation_page: citation[:page] || citation["page"],
        expected_section_identity: expected,
        actual_canonical_name: canonical_name
      }
    end
    case_payload.merge!(
      expected_section_identity: expected,
      cited_pages: citations.map { |c| c[:page] || c["page"] }.compact,
      citation_canonical_names: canonical_names.compact,
      canonical_name_mismatches: mismatches,
      check_passed: mismatches.empty?
    )
  end

  def apply_forbidden_pattern_check(case_payload, definition, chunks, answer)
    forbidden_patterns = definition.dig("check", "forbidden_patterns")
    bodies = chunks.map { |c| (c[:content] || c["content"]).to_s }
    matches = []
    forbidden_patterns.each do |pattern|
      regex = Regexp.new(pattern)
      bodies.each_with_index do |body, idx|
        next unless body.match?(regex)

        matches << {
          case_id: definition.fetch("id"),
          pattern: pattern,
          chunk_index: idx,
          content_sha256: Digest::SHA256.hexdigest(body)
        }
      end
      next unless answer.match?(regex)

      matches << {
        case_id: definition.fetch("id"),
        pattern: pattern,
        chunk_index: nil,
        location: "answer"
      }
    end
    case_payload.merge!(
      expected_section_identity: definition["expected_section_identity"],
      target_page: definition["target_page"],
      forbidden_patterns: forbidden_patterns,
      retrieved_chunk_bodies_sha256: bodies.map { |b| Digest::SHA256.hexdigest(b) },
      forbidden_pattern_matches: matches,
      check_passed: matches.empty?
    )
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
        "s3://#{bucket}/#{key.delete_prefix('/')}"
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
end

RagCiclo5Fase6ProvenanceBattery.new.run!
