# frozen_string_literal: true

# Fase 1 (plan_ciclo4_ajuste_final_2026-08-03.md): verificacion ad-hoc del
# page-pin (N10). 4 preguntas NUEVAS (no reutilizadas de v1/v2/v3) sobre los
# clusters de paginas casi-duplicadas FAIN/RECOBA (46, 76) y THYSSEN (92, 97).
# Un solo Retrieve por pregunta (no retrieve_and_generate: mide ranking, no
# generacion). Corre una vez ANTES del deploy de la Fase 1 (baseline, codigo
# sin el filtro) y una vez DESPUES (codigo desplegado, flag
# RAG_PAGE_PIN_ENABLED=true) — before/after, misma corrida no se repite.
# Script desechable, calcado de script/rag_seguridades_recall_probe.rb.

require "json"
require "fileutils"

class RagPagePinProbe
  ExternalDocument = Data.define(:id, :account, :display_name, :s3_key, :source_uri)

  PROBES = [
    {
      id: "fain_pagina_76_terminal",
      question: "¿Qué terminal de conexión aparece descrito en la página 76 del manual de seguridades?",
      target_page: 76,
      cluster: "fain_recoba_46_76_79"
    },
    {
      id: "fain_pagina_46_procedimiento",
      question: "¿Qué procedimiento de verificación describe la página 46 del manual de seguridades?",
      target_page: 46,
      cluster: "fain_recoba_46_76_79"
    },
    {
      id: "thyssen_pagina_92_indicador",
      question: "¿Qué indicador luminoso se describe en la página 92 para la placa Thyssen?",
      target_page: 92,
      cluster: "thyssen_92_97"
    },
    {
      id: "thyssen_pagina_97_tabla",
      question: "¿Qué contenido tiene la página 97 relativo a la placa CMC4?",
      target_page: 97,
      cluster: "thyssen_92_97"
    }
  ].freeze

  TOP_K = RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS # 12, mismo top_k que la ruta estructurada del v3

  def initialize(env: ENV)
    @env = env
    @label = env.fetch("RAG_PAGE_PIN_PROBE_LABEL", "unlabeled")
    @output_path = env.fetch(
      "RAG_PAGE_PIN_PROBE_OUTPUT",
      "tmp/rag_page_pin_probe_#{@label}_2026-08-03.json"
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
    service = BedrockRagService.new(account: account)

    results = PROBES.map { |probe| probe_case(service, source_uri, probe) }

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
      top_k: TOP_K,
      probes: results
    }

    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts JSON.pretty_generate(payload)
    payload
  end

  private

  # Rag::PagePinFlag does not exist yet in the pre-Fase-1 deployed image — the
  # "before" run of this same script must not blow up on a missing constant.
  def page_pin_flag_enabled?
    Rag::PagePinFlag.enabled?
  rescue NameError
    false
  end

  def probe_case(service, source_uri, probe)
    retrieval = service.retrieve_chunks(
      probe.fetch(:question),
      entity_s3_uris: [ source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      number_of_results: TOP_K
    )
    chunks = retrieval[:chunks]
    target_page = probe.fetch(:target_page)
    matches = chunks.select { |chunk| page_number_of(chunk) == target_page.to_f }
    rank = matches.pluck(:rank).min

    {
      id: probe.fetch(:id),
      cluster: probe.fetch(:cluster),
      question: probe.fetch(:question),
      target_page: target_page,
      rank_at_top_k: rank,
      found_in_top_k: rank.present?,
      top1_page: page_number_of(chunks.find { |c| c[:rank] == 1 }),
      retrieved_pages: chunks.map { |chunk| page_number_of(chunk) },
      vector_search_configuration: retrieval.dig(:retrieval_trace, :vector_search_configuration)
    }
  end

  def page_number_of(chunk)
    return nil unless chunk

    Float(chunk.dig(:metadata, "page_number"), exception: false)
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

RagPagePinProbe.new.run!
