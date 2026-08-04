# frozen_string_literal: true

# Fase 2 (plan_ciclo4_ajuste_final_2026-08-03.md): verificacion ad-hoc de la
# cobertura multi-placa (N11) tras encender RAG_FAMILY_AMBIGUITY_GUARD_ENABLED.
# 1 pregunta NUEVA (no reutilizada de v1/v2/v3 ni del v3 SPM/TW1-DELTA+):
# "LED DL2" es ambiguo entre ALJO (p.3) y KDT 11 dentro de la seccion CARLOS
# SILVA (p.13) -- caso real distinto, ya verificado en
# test/services/rag/family_ambiguity_detector_test.rb (dl2_chunks). Corre la
# ruta estructurada completa (1 Retrieve + 1 generacion) contra produccion,
# desplegada con el flag encendido. Script desechable, calcado de
# script/rag_page_pin_probe.rb.

require "json"
require "fileutils"

class RagFamilyAmbiguityProbe
  ExternalDocument = Data.define(:id, :account, :display_name, :s3_key, :source_uri)

  PROBES = [
    {
      id: "dl2_ambiguo_aljo_kdt11",
      question: "¿Qué serie indica el LED DL2 en el manual de seguridades?",
      expected_boards: [ "ALJO", "CARLOS SILVA" ]
    }
  ].freeze

  def initialize(env: ENV)
    @env = env
    @label = env.fetch("RAG_FAMILY_AMBIGUITY_PROBE_LABEL", "unlabeled")
    @output_path = env.fetch(
      "RAG_FAMILY_AMBIGUITY_PROBE_OUTPUT",
      "tmp/rag_family_ambiguity_probe_#{@label}_2026-08-03.json"
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

    results = PROBES.map { |probe| probe_case(account, source_uri, probe) }

    payload = {
      label: @label,
      measured_at: Time.current.utc.iso8601(6),
      family_ambiguity_guard_flag_enabled: flag_enabled?,
      document: {
        id: document.id,
        account_id: account.id,
        display_name: document.display_name,
        s3_key: document.s3_key,
        source_uri: source_uri
      },
      probes: results
    }

    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts JSON.pretty_generate(payload)
    payload
  end

  private

  def flag_enabled?
    Rag::FamilyAmbiguityGuardFlag.enabled?
  rescue NameError
    false
  end

  def probe_case(account, source_uri, probe)
    question = probe.fetch(:question)
    structured = Rag::StructuredEvidenceRoute.build(
      question: question,
      account: account,
      entity_s3_uris: [ source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      output_channel: :web,
      account_id: account.id
    )
    outcome = structured&.execute
    result = outcome&.result.to_h
    diagnostics = result[:diagnostics].to_h
    generation_chunks = Array(diagnostics[:generation_chunks])
    boards = generation_chunks.map { |chunk| board_label(chunk) }.compact.uniq

    {
      id: probe.fetch(:id),
      question: question,
      expected_boards: probe.fetch(:expected_boards),
      route_eligible: !structured.nil?,
      outcome_status: outcome&.status,
      generation_chunks: generation_chunks.size,
      generation_boards: boards,
      answer: result[:answer],
      citations: result[:citations],
      retrieval_trace: result[:retrieval_trace]
    }
  end

  def board_label(chunk)
    heading = Rag::BoardHeading.label(chunk[:content]).presence
    heading || chunk[:metadata].to_h.stringify_keys["section_identity"].presence
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
end

RagFamilyAmbiguityProbe.new.run!
