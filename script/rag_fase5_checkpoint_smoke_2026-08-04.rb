# frozen_string_literal: true

# Fase 5 (plan_ciclo5_resolucion_decision9_2026-08-04.md): humo de 1 llamada
# del checkpoint de despliegue post Fases 1-3. Pregunta NUEVA, fuera de todo
# holdout (v1-v4) y de los fixtures congelados de la Fase 4 (no leidos por
# esta fase), que nombra una pagina divisora casi vacia (51, portada KONE
# MONOSPACE) para forzar la expansion de vecindad (H1/H6/H8) hacia la pagina
# 52 (contenido real KONE MONOSPACE, conector XLH5 -- INTERRUPTOR REVISION
# 270). Ejercita los DOS fixes bloqueantes de este ciclo en una sola llamada:
# (a) la cita debe atribuir "KONE" (no "ALJO Control Level 1B Altius" --
# H1, bug de cache del expansor); (b) el cuerpo recuperado no debe contener
# la linea/bloque de identidad N8 (H4, parche de datos Fase 3). Via
# Rag::StructuredEvidenceRoute (la ruta real que invoca
# Rag::SectionNeighborExpander para preguntas de mapeo estructurado),
# replicando el patron de script/rag_page_pin_smoke.rb (ciclo 4, Fase 6).
# Script desechable.

require "json"
require "fileutils"

class RagFase5CheckpointSmoke
  ExternalDocument = Data.define(:id, :account, :display_name, :s3_key, :source_uri)

  PROBE = {
    id: "smoke_fase5_checkpoint_kone_monospace_pagina_51",
    question: "En la página 51 del manual de seguridades (portada de sección KONE MONOSPACE), ¿a qué conector está conectado el terminal 270 (INTERRUPTOR REVISION)?",
    target_divider_page: 51,
    expected_canonical_name: "KONE"
  }.freeze

  N8_MARKERS = [ "ALJO Control Level 1B Altius", "PIPELINE_INJECTED" ].freeze

  def initialize(env: ENV)
    @env = env
    @output_path = env.fetch(
      "RAG_FASE5_CHECKPOINT_SMOKE_OUTPUT",
      "tmp/ciclo5_fase5_2026-08-04/checkpoint_smoke_2026-08-04.json"
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

    result = probe_case(account, source_uri)

    payload = {
      measured_at: Time.current.utc.iso8601(6),
      flags: {
        structured_evidence_route_enabled: flag_enabled?(Rag::StructuredEvidenceRouteFlag),
        page_pin_enabled: flag_enabled?(Rag::PagePinFlag),
        family_ambiguity_guard_enabled: flag_enabled?(Rag::FamilyAmbiguityGuardFlag)
      },
      document: {
        id: document.id,
        account_id: account.id,
        display_name: document.display_name,
        s3_key: document.s3_key,
        source_uri: source_uri
      },
      probe: result
    }

    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts JSON.pretty_generate(payload)
    payload
  end

  private

  def flag_enabled?(klass)
    klass.enabled?
  rescue NameError, NoMethodError
    nil
  end

  def probe_case(account, source_uri)
    question = PROBE.fetch(:question)
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

    citations = Array(result[:citations])
    cited_pages = citations.map { |c| c[:page] || c["page"] }.compact
    citation_canonical_names = citations.map { |c| c.dig(:metadata, "canonical_name") || c.dig(:metadata, :canonical_name) }.compact

    retrieved_chunks = Array(result.dig(:diagnostics, :retrieved_chunks))
    full_bodies = retrieved_chunks.map { |c| c[:content].to_s }
    n8_in_full_bodies = full_bodies.any? { |body| N8_MARKERS.any? { |marker| body.include?(marker) } }
    n8_in_answer = N8_MARKERS.any? { |marker| result[:answer].to_s.include?(marker) }

    expansions = Array(result[:retrieval_trace]&.dig(:structured_route, :expansion_mechanisms) ||
                        result.dig(:diagnostics, :expansions)&.pluck(:mechanism))

    {
      id: PROBE.fetch(:id),
      question: question,
      target_divider_page: PROBE.fetch(:target_divider_page),
      expected_canonical_name: PROBE.fetch(:expected_canonical_name),
      route_eligible: !structured.nil?,
      outcome_status: outcome&.status,
      cited_pages: cited_pages,
      neighbor_expansion_occurred: expansions.include?("section_identity"),
      citation_canonical_names: citation_canonical_names,
      manufacturer_attribution_correct: citation_canonical_names.all? { |n| n == PROBE.fetch(:expected_canonical_name) } && citation_canonical_names.any?,
      n8_contamination_in_retrieved_bodies: n8_in_full_bodies,
      n8_contamination_in_answer: n8_in_answer,
      both_fixes_verified: expansions.include?("section_identity") &&
        citation_canonical_names.any? && citation_canonical_names.all? { |n| n == PROBE.fetch(:expected_canonical_name) } &&
        !n8_in_full_bodies && !n8_in_answer,
      answer: result[:answer],
      citations: citations,
      retrieved_chunk_bodies_sha256: full_bodies.map { |b| Digest::SHA256.hexdigest(b) },
      retrieval_trace: result[:retrieval_trace]
    }
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

RagFase5CheckpointSmoke.new.run!
