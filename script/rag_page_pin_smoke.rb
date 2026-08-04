# frozen_string_literal: true

# Fase 6 (plan_ciclo4_ajuste_final_2026-08-03.md): humo de 1 llamada del
# checkpoint de despliegue. Pregunta NUEVA, fuera de todo holdout (v1/v2/v3/v4),
# que nombra la pagina 40 (TOKIBAT 2.007, LED DL27 SSH) para ejercitar el
# page-pin (N10) contra el codigo ya desplegado (SHA de esta sesion). Ruta
# estructurada completa (1 Retrieve + 1 generacion), igual que
# script/rag_family_ambiguity_probe.rb. Script desechable.

require "json"
require "fileutils"

class RagPagePinSmoke
  ExternalDocument = Data.define(:id, :account, :display_name, :s3_key, :source_uri)

  PROBE = {
    id: "smoke_fase6_tokibat_pagina_40",
    question: "¿Qué serie indica el LED DL27 SSH en la página 40 del manual de seguridades?",
    target_page: 40
  }.freeze

  def initialize(env: ENV)
    @env = env
    @label = env.fetch("RAG_PAGE_PIN_SMOKE_LABEL", "fase6_checkpoint")
    @output_path = env.fetch(
      "RAG_PAGE_PIN_SMOKE_OUTPUT",
      "tmp/rag_page_pin_smoke_#{@label}_2026-08-04.json"
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
      label: @label,
      measured_at: Time.current.utc.iso8601(6),
      page_pin_flag_enabled: page_pin_flag_enabled?,
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

  def page_pin_flag_enabled?
    Rag::PagePinFlag.enabled?
  rescue NameError
    false
  end

  def probe_case(account, source_uri)
    question = PROBE.fetch(:question)
    target_page = PROBE.fetch(:target_page)
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

    {
      id: PROBE.fetch(:id),
      question: question,
      target_page: target_page,
      route_eligible: !structured.nil?,
      outcome_status: outcome&.status,
      cited_pages: cited_pages,
      page_pin_exact_match: cited_pages.include?(target_page),
      answer: result[:answer],
      citations: citations,
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

RagPagePinSmoke.new.run!
