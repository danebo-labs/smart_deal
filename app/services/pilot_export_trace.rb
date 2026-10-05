# frozen_string_literal: true

# Fills a pilot report from the raw RAG trace that bin/pilot_metrics keeps in
# source_events.jsonl. The remote report only knows PILOT_USAGE, RAG_QUALITY
# and PILOT_AUDIT. Turns answered outside those lines still carry the question,
# the answer, the retrieval filter and the consulted chunks here.
class PilotExportTrace
  MARKERS = [
    [ "[PILOT_AUDIT]", "PILOT_AUDIT" ],
    [ "[RAG_QUALITY]", "RAG_QUALITY" ],
    [ "[TURN_EVIDENCE]", "TURN_EVIDENCE" ],
    [ "R1A_PROBE", "R1A_PROBE" ]
  ].freeze

  def self.apply!(report, source_path)
    new(report, source_path).apply!
  end

  def initialize(report, source_path)
    @report = report
    @source_path = source_path
  end

  def apply!
    return report unless source_path.present? && File.file?(source_path)

    grouped = events.group_by { |event| event[:payload]["correlation_id"].to_s }
    Array(report.dig("interactions", "by_correlation")).each do |interaction|
      rows = grouped[interaction["correlation_id"].to_s]
      next if rows.blank?

      merge_interaction(interaction, rows)
    end
    report
  end

  private

  attr_reader :report, :source_path

  def events
    rows = []
    File.foreach(source_path) do |line|
      marker, tag = MARKERS.find { |candidate, _tag| line.include?(candidate) }
      next unless marker

      payload = extract_json(line, marker)
      next unless payload.is_a?(Hash) && payload["correlation_id"].present?

      rows << { tag: tag, payload: payload }
    end
    rows
  end

  def extract_json(line, marker)
    JSON.parse(line[(line.index(marker) + marker.length)..].strip)
  rescue JSON::ParserError
    nil
  end

  def merge_interaction(interaction, rows)
    audit_rows = rows.select { |row| row[:tag] == "PILOT_AUDIT" }
    logged = audit_rows.find { |row| row[:payload]["type"] == "interaction" }&.fetch(:payload)
    quality = rows.find { |row| row[:tag] == "RAG_QUALITY" }&.fetch(:payload)
    turn = rows.reverse.find { |row| row[:tag] == "TURN_EVIDENCE" }&.fetch(:payload)
    probes = rows.select { |row| row[:tag] == "R1A_PROBE" }.pluck(:payload)

    audit = interaction["audit"].is_a?(Hash) ? interaction["audit"] : {}
    question = present_text(
      audit["question"], interaction["question"], logged&.[]("question"),
      turn&.[]("original_query"), quality&.[]("question")
    )
    answer = present_text(
      audit["answer"], interaction["answer_snippet"], logged&.[]("answer"),
      turn&.[]("answer"), quality&.[]("answer_snippet")
    )
    audit["question"] = question if question
    audit["answer"] = answer if answer
    if turn&.key?("original_query")
      raw = turn["original_query"].to_s.strip.presence
      interaction["question"] = raw if raw
    elsif turn
      interaction.delete("question")
    elsif question && interaction["question"].to_s.strip.empty?
      interaction["question"] = question
    end
    interaction["answer_snippet"] = answer if answer && interaction["answer_snippet"].to_s.strip.empty?

    if Array(audit["citations"]).empty?
      citations = Array(logged&.[]("citations")).presence || turn_citations(turn)
      audit["citations"] = citations if citations.any?
    end
    if Array(audit["chunks"]).empty?
      chunks = audit_rows.select { |row| row[:payload]["type"] == "chunk" }.map do |row|
        row[:payload].slice("document", "page", "section_identity", "chunk_sha256", "text", "truncated")
      end
      audit["chunks"] = chunks if chunks.any?
    end
    interaction["audit"] = audit if audit.any?

    citation_count = Array(audit["citations"]).size
    if interaction["citations_count"].to_i.zero? && citation_count.positive?
      interaction["citations_count"] = citation_count
    end
    chunk_count = Array(audit["chunks"]).size
    chunk_count = citation_count if chunk_count.zero?
    if interaction["retrieved_chunks"].to_i.zero? && chunk_count.positive?
      interaction["retrieved_chunks"] = chunk_count
    end

    scope = retrieval_scope(probes)
    interaction["retrieval_scope"] = scope if scope.any?
    consulted = consulted_sources(turn, probes)
    interaction["consulted_sources"] = consulted if consulted.any?
  end

  def turn_citations(turn)
    Array(turn&.[]("sources")).filter_map do |source|
      next unless source.is_a?(Hash)

      title = source["title"].to_s.presence
      page = source["page"]
      next if title.blank? && page.blank?

      { "title" => title, "page" => page }.compact
    end
  end

  def retrieval_scope(probes)
    probes.flat_map { |probe|
      probe["stage"] == "bedrock_request_filter" ? s3_uris(probe) : []
    }.uniq
  end

  def consulted_sources(turn, probes)
    labels = Array(turn&.[]("sources")).filter_map { |source|
      next unless source.is_a?(Hash)

      title = source["title"].to_s.presence
      page = source["page"]
      next if title.blank? && page.blank?

      [ title, (page.present? ? "p. #{page}" : nil) ].compact.join(" · ")
    }
    kept = probes.filter_map { |probe|
      probe["original_source_uri"].presence if probe["decision"] == "KEEP"
    }
    (labels + kept).uniq
  end

  def s3_uris(value, found = [])
    case value
    when Hash
      value.each_value { |child| s3_uris(child, found) }
    when Array
      value.each { |child| s3_uris(child, found) }
    when String
      found << value if value.start_with?("s3://")
    end
    found
  end

  def present_text(*values)
    values.each do |value|
      text = value.to_s
      return text unless text.strip.empty?
    end
    nil
  end
end
