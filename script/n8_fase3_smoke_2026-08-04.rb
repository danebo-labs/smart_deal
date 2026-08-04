# frozen_string_literal: true

# Fase 3 (plan_ciclo5_resolucion_decision9_2026-08-04.md): humo post-resync,
# 2 preguntas NUEVAS (no reutilizadas de v1-v4), ≤4 llamadas Bedrock (1
# retrieve_and_generate por pregunta = 1 Retrieve interno + 1 generación,
# vía BedrockRagService#query — la ruta de producción real para preguntas
# generales, a diferencia de Rag::StructuredEvidenceRoute que sólo aplica a
# queries de mapeo estructurado). Objetivo: confirmar que las páginas NO-ALJO
# recién parcheadas (EXCELSIOR p.38, FAIN/EKM66 p.45) ya no citan la
# línea/bloque de identidad ALJO incrustada (N8) y que la respuesta sigue
# siendo sana. Script desechable.

require "json"
require "fileutils"

class N8Fase3Smoke
  ExternalDocument = Data.define(:id, :account, :display_name, :s3_key, :source_uri)

  PROBES = [
    {
      id: "smoke_fase3_excelsior_pagina_38",
      question: "¿Qué conectores principales muestra el diagrama de la placa de conexiones del sistema EXCELSIOR en la página 38?",
      target_page: 38,
      expect_alias: "EXCELSIOR"
    },
    {
      id: "smoke_fase3_fain_ekm66_pagina_45",
      question: "¿Qué bloques de bornes muestra el diagrama del sistema EKM66 hidráulico en la página 45?",
      target_page: 45,
      expect_alias: "FAIN"
    }
  ].freeze

  DOCUMENT_ID = "b61f5d54-ff42-414a-97b7-01682d16f4b5"
  ACCOUNT_ID = 1

  def initialize(env: ENV)
    @env = env
    @output_path = env.fetch("RAG_N8_SMOKE_OUTPUT", "tmp/ciclo5_fase3_2026-08-04/n8_fase3_smoke_2026-08-04.json")
  end

  def run!
    document = find_document!
    account = document.account
    source_uri = document.respond_to?(:source_uri) ? document.source_uri : document.display_s3_uri(KbDocument::KB_BUCKET)

    probes = PROBES.map { |probe| probe_case(account, source_uri, probe) }

    payload = {
      measured_at: Time.current.utc.iso8601(6),
      document: { s3_key: document.s3_key, source_uri: source_uri },
      probes: probes
    }

    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts JSON.pretty_generate(payload)
    payload
  end

  private

  def probe_case(account, source_uri, probe)
    question = probe.fetch(:question)
    rag_service = BedrockRagService.new(account: account)
    result = rag_service.query(
      question,
      entity_s3_uris: [ source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      output_channel: :web,
      account_id: account.id
    )
    citations = Array(result[:citations])
    cited_pages = citations.map { |c| c[:page] || c["page"] }.compact
    excerpts = citations.flat_map { |c| Array(c[:excerpt] || c["excerpt"] || c[:content] || c["content"]) }
    n8_in_excerpts = excerpts.any? { |e| e.to_s.include?("ALJO Control Level 1B Altius") || e.to_s.include?("PIPELINE_INJECTED") }
    n8_in_answer = result[:answer].to_s.include?("ALJO Control Level 1B Altius") || result[:answer].to_s.include?("PIPELINE_INJECTED")

    {
      id: probe.fetch(:id),
      question: question,
      target_page: probe.fetch(:target_page),
      cited_pages: cited_pages,
      n8_contamination_in_citation_excerpts: n8_in_excerpts,
      n8_contamination_in_answer: n8_in_answer,
      answer: result[:answer],
      citations: citations
    }
  end

  def find_document!
    scope = KbDocument.where(account_id: ACCOUNT_ID)
    scope.where("display_name ILIKE :term OR s3_key ILIKE :term", term: "%SEGURIDADES%").first ||
      external_document
  end

  def external_document
    bucket = @env["KNOWLEDGE_BASE_S3_BUCKET"].to_s.presence || "multimodal-source-destination"
    s3_key = "bulk_chunks/1/#{DOCUMENT_ID}/original.pdf"
    source_uri = "s3://#{bucket}/uploads/#{ACCOUNT_ID}/#{DOCUMENT_ID}/original.pdf"
    account = Account.find_by(id: ACCOUNT_ID) ||
      Account.new(id: ACCOUNT_ID, slug: "external-#{ACCOUNT_ID}", display_name: "External account #{ACCOUNT_ID}")

    ExternalDocument.new(id: nil, account: account, display_name: "SEGURIDADES 1.1-1.pdf", s3_key: s3_key, source_uri: source_uri)
  end
end

N8Fase3Smoke.new.run!
