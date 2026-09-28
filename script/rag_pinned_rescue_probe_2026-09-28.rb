# frozen_string_literal: true

# Phase 3 read-only probe. Uses Rag::StructuredEvidenceRoute#pinned_retrieval,
# the same pin and the same rescue decision as a web turn. No generation, no
# S3 writes, no ingest, no deploy.
#
# Exit 0 when every case either recovered the section-9 fact or is a Phase 5
# dependency (an explicit row already in the first window blocked the rescue).
# Exit 1 on any other miss.

require "json"
require "fileutils"

class RagPinnedRescueProbe
  PinnedDocument = Struct.new(:id, :display_name, :s3_key, :source_uri, keyword_init: true) do
    def display_s3_uri(_bucket)
      source_uri
    end
  end

  CASES = [
    {
      id: 1,
      corpus: :seguridades,
      question: "EM2000 hidráulico obstáculo",
      facts: [ /\bCN7\b/, /\bCN8\b/ ]
    },
    {
      id: 2,
      corpus: :seguridades,
      question: "EM4000 V1 obstáculo",
      facts: [ /\bXC4\b/, /\bXC7\b/ ]
    },
    {
      id: 3,
      corpus: :seguridades,
      question: "EDEL K2 cerrojos exteriores",
      facts: [ /\b40\b[^\n]{0,40}CERROJOS EXTERIORES/i ]
    },
    {
      id: 4,
      corpus: :seguridades,
      question: "EDEL K2 dos embarques",
      facts: [ /\bF1\b/, /\bF2\b/ ]
    },
    {
      id: 5,
      corpus: :seguridades,
      question: "Falla la serie SCI del MR08",
      facts: [ /\bSCI\b/, /CN[\s\-]*112/i, /CN[\s\-]*109/i ]
    },
    {
      id: 6,
      corpus: :elemont,
      question: "Tengo encendida la luz H4. ¿Qué me está indicando?",
      facts: [ /luz piloto/i, /falla/i ]
    },
    {
      id: 7,
      corpus: :elemont,
      question: "¿A qué borne corresponde Seguridad OUT?",
      facts: [ /\b23\b[^\n]{0,40}SEGURIDAD OUT|SEGURIDAD OUT[^\n]{0,40}\b23\b/i ]
    },
    {
      id: 8,
      corpus: :elemont,
      question: "¿A qué borne corresponde Seguridad IN?",
      facts: [ /\b24\b[^\n]{0,40}SEGURIDAD IN|SEGURIDAD IN[^\n]{0,40}\b24\b/i ]
    },
    {
      id: 9,
      corpus: :elemont,
      question: "¿A qué borne corresponde el micro de nivel inferior?",
      facts: [ /\b30\b[^\n]{0,40}(?:INFERIOR|MICRO)|(?:INFERIOR|MICRO)[^\n]{0,40}\b30\b/i ]
    },
    {
      id: 10,
      corpus: :elemont,
      question: "¿A qué borne corresponde el micro de nivel superior?",
      facts: [ /\b31\b[^\n]{0,40}SUPERIOR|SUPERIOR[^\n]{0,40}\b31\b/i ]
    },
    {
      id: 11,
      corpus: :elemont,
      question: "¿A qué borne corresponde la llamada de nivel 1?",
      facts: [ /\b33\b[^\n]{0,40}LLAMADA|LLAMADA[^\n]{0,40}\b33\b/i ]
    },
    {
      id: 12,
      corpus: :elemont,
      question: "¿A qué borne corresponde la llamada de nivel 2?",
      facts: [ /\b34\b[^\n]{0,40}LLAMADA|LLAMADA[^\n]{0,40}\b34\b/i ]
    },
    {
      id: 13,
      corpus: :elemont,
      question: "¿Qué temporizador es T1?",
      facts: [ /modo\s*E\b/i, /3\s*min/i ]
    },
    {
      id: 14,
      corpus: :elemont,
      question: "¿Qué temporizador es T2?",
      facts: [ /modo\s*Wu\b/i, /<\s*1\s*seg/i ]
    }
  ].freeze

  def initialize(env: ENV)
    @env = env
    @output_path = env.fetch(
      "RAG_PINNED_RESCUE_PROBE_OUTPUT",
      "tmp/pilot_gate/pinned_rescue_probe_2026-09-28.json"
    )
  end

  def run!
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    account = find_account!
    documents = {
      seguridades: find_document!(account, "%SEGURIDADES%"),
      elemont: find_document!(account, "%Montacargas%")
    }
    service = BedrockRagService.new(account: account)
    results = CASES.map { |probe| probe_case(service, account, documents, probe) }
    payload = {
      measured_at: Time.current.utc.iso8601(6),
      documents: documents.transform_values { |document| document_payload(document) },
      cases: results,
      phase_3_misses: results.count { |row| row[:classification] == "phase_3_miss" },
      phase_5_dependencies: results.count { |row| row[:classification] == "phase_5_dependency" },
      hits: results.count { |row| row[:classification] == "hit" }
    }

    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts JSON.pretty_generate(payload)
    payload
  end

  def exit_code(payload)
    payload[:phase_3_misses].zero? ? 0 : 1
  end

  private

  def probe_case(service, account, documents, probe)
    document = documents.fetch(probe[:corpus])
    uri = source_uri(document)
    generator = Object.new
    generator.define_singleton_method(:query) { |*| raise "probe must not generate" }
    route = Rag::StructuredEvidenceRoute.build(
      question: probe[:question],
      account: account,
      entity_s3_uris: [ uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      output_channel: :web,
      rag_service: service,
      generator: generator,
      expander: Rag::SectionNeighborExpander.new
    )
    return missed(probe, "route_ineligible") unless route

    retrieval = route.pinned_retrieval
    return missed(probe, "retrieve_failed") if retrieval.is_a?(Rag::StructuredEvidenceRoute::Outcome)

    chunks = Array(retrieval[:chunks])
    text = chunks.map { |chunk| chunk[:content].to_s }.join("\n")
    report = route.retrieval_report
    evidence = probe[:facts].all? { |pattern| text.match?(pattern) }
    classification = classify(evidence, report, text, probe[:question])

    {
      id: probe[:id],
      question: probe[:question],
      corpus: probe[:corpus].to_s,
      classification: classification,
      evidence_present: evidence,
      rescued: report[:rescued],
      retrieve_count: report[:retrieve_count],
      queries: report[:queries],
      chunks: chunks.map { |chunk| chunk_summary(chunk) }
    }
  end

  def classify(evidence, report, text, question)
    return "hit" if evidence
    return "phase_3_miss" if report[:rescued]
    return "phase_5_dependency" if explicit_row_blocks?(text, question)

    "phase_3_miss"
  end

  def explicit_row_blocks?(text, question)
    needles = overlap_tokens(question)
    text.lines.map(&:strip).any? do |line|
      next false unless explicit_line?(line)

      line_tokens = overlap_tokens(line)
      (line_tokens & needles).any? || designator_in_line?(line, question)
    end
  end

  def explicit_line?(line)
    return false if line.blank?
    return false if line.match?(/\A[\s|:\-]+\z/)
    return false if line.match?(/\A(ACTION|EVIDENCE|EXPECTED_RESULT|SOURCE_SECTION|RECORD_ID|RECORD_TYPE|FIELD_RECORD|END_FIELD_RECORD|UNCERTAINTY)\b/i)

    line.match?(/\A\s*\|(?:[^|\n]*\|){2,}/) ||
      line.match?(/\A\s*[-*]?\s*[A-Za-z0-9][A-Za-z0-9._-]{0,12}\s*[:|\-=\u2013\u2014(]/)
  end

  def designator_in_line?(line, question)
    Rag::QueryEntities.analyze(question).identifiers.any? do |identifier|
      identifier.shape != :numeric &&
        identifier.canonical.match?(/\d/) &&
        Rag::QueryEntities.identifier_present?(line, identifier.canonical)
    end
  end

  def overlap_tokens(text)
    I18n.transliterate(text.to_s).scan(/[[:alnum:]]+/).filter_map do |token|
      if token.length >= 4
        folded = token.downcase
        folded.length > 5 ? folded.sub(/[ao]\z/, "") : folded
      elsif token.length >= 2 && (token.match?(/\d/) || token.match?(/\A[A-Z0-9]+\z/))
        token.downcase
      end
    end.to_set
  end

  def chunk_summary(chunk)
    metadata = chunk[:metadata].to_h.stringify_keys
    {
      rank: chunk[:rank],
      page: metadata["page_number"],
      chunk_sha256: chunk[:chunk_sha256],
      excerpt: chunk[:content].to_s.gsub(/\s+/, " ").slice(0, 180)
    }
  end

  def missed(probe, reason)
    {
      id: probe[:id],
      question: probe[:question],
      corpus: probe[:corpus].to_s,
      classification: "phase_3_miss",
      evidence_present: false,
      rescued: false,
      retrieve_count: 0,
      reason: reason,
      queries: [],
      chunks: []
    }
  end

  def find_account!
    slug = @env["RAG_PROBE_ACCOUNT_SLUG"].presence || "danebo-legacy"
    account = Account.find_by(slug: slug)
    account ||= Account.find_by(id: Integer(@env["RAG_PROBE_ACCOUNT_ID"], exception: false)) if @env["RAG_PROBE_ACCOUNT_ID"]
    return account if account

    raise ArgumentError, "Account #{slug} was not found."
  end

  def find_document!(account, term)
    key = @env["RAG_PROBE_DOCUMENT_KEY_#{term.delete('%').upcase}"].presence
    scope = KbDocument.where(account_id: account.id)
    document = if key
      scope.find_by(s3_key: key)
    else
      scope.where("display_name ILIKE :term OR s3_key ILIKE :term", term: term).order(:id).first
    end
    return document if document

    identity = identity_for(term)
    return identity if identity

    raise ArgumentError, "No document matched #{term} for account #{account.id}."
  end

  def identity_for(term)
    needle = term.delete("%").downcase
    path = Rails.root.join("config/document_identities.yml")
    entries = YAML.safe_load_file(path).fetch("documents")
    entry = entries.find do |row|
      row["display_name"].to_s.downcase.include?(needle) || row["s3_key"].to_s.downcase.include?(needle)
    end
    return unless entry

    key = entry.fetch("s3_key")
    PinnedDocument.new(
      id: nil,
      display_name: entry["display_name"],
      s3_key: key,
      source_uri: "s3://#{KbDocument::KB_BUCKET}/#{key}"
    )
  end

  def source_uri(document)
    document.display_s3_uri(KbDocument::KB_BUCKET)
  end

  def document_payload(document)
    {
      id: document.id,
      display_name: document.display_name,
      s3_key: document.s3_key,
      source_uri: source_uri(document)
    }
  end
end

probe = RagPinnedRescueProbe.new
payload = probe.run!
exit probe.exit_code(payload)
