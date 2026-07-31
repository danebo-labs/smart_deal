# frozen_string_literal: true

# Fase 2.1 (plan rag-seguridades-gate5-produccion-2026-07-31): mide el rank real
# de la pagina objetivo con top-k 20 para las preguntas que hoy caen en
# top-k 3/12 y fallan por recall. Script desechable, una sola llamada
# Retrieve por pregunta (turnos distintos, no viola la regla de 1
# Retrieve/turno de usuario). Salida: tmp/pilot_gate/recall_probe.json.

require "json"
require "fileutils"

class RagSeguridadesRecallProbe
  ExternalDocument = Data.define(:id, :account, :display_name, :s3_key, :source_uri)

  PROBES = [
    {
      id: "serie_f_cerrojos",
      question: "En una Thyssen Serie F monoplaca, ¿qué LED debo mirar para saber si los " \
                 "cerrojos exteriores y de cabina están bien?",
      target_page: 95,
      current_top_k: 3
    },
    {
      id: "twister_embarba_puertas",
      question: "Estoy con una Twister TW de Embarba eléctrica y sospecho de la serie de " \
                 "puertas. ¿Qué LED de la placa me lo confirma?",
      target_page: 89,
      current_top_k: 3
    },
    {
      id: "em1000_v1_tabla",
      question: "En la placa EM 1000 V1, lista los LEDs y la serie que indica cada uno.",
      target_page: 34,
      current_top_k: 12
    },
    {
      id: "cmc4_tabla",
      question: "En la placa CMC 4 de Thyssen, lista los LEDs y qué indica cada uno.",
      target_page: 97,
      current_top_k: 12
    },
    {
      id: "spm_sin_placa",
      question: "¿A qué serie corresponde el LED SPM?",
      target_page: 9,
      current_top_k: 12
    }
  ].freeze

  TOP_K = 20

  def initialize(env: ENV)
    @env = env
    @output_path = env.fetch("RAG_SEGURIDADES_RECALL_PROBE_OUTPUT", "tmp/pilot_gate/recall_probe.json")
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
      measured_at: Time.current.utc.iso8601(6),
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
      question: probe.fetch(:question),
      target_page: target_page,
      current_top_k: probe.fetch(:current_top_k),
      rank_at_top_20: rank,
      found_in_top_20: rank.present?,
      retrieved_pages: chunks.map { |chunk| page_number_of(chunk) }
    }
  end

  def page_number_of(chunk)
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

RagSeguridadesRecallProbe.new.run!
