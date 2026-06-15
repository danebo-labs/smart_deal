# frozen_string_literal: true

# Transforms FieldPhotoPrompt JSON into the standard envelope expected by
# BatchResultsParserService#validate! (document_name, aliases, summary, chunks).
# Produces a single compact chunk — no S0-S18 sections. Explicit technical
# evidence is preserved when the photo contains a legible circuit, diagram, label,
# value, connection, or warning; empty evidence arrays remain lightweight.
class FieldPhotoResultsParser
  EVIDENCE_ITEM_LIMIT = 30

  def self.to_envelope(raw_json)
    new(raw_json).to_envelope
  end

  def initialize(raw_json)
    @raw = raw_json
  end

  def to_envelope
    parsed = parse_json(@raw)
    aliases = Array(parsed["aliases"])

    {
      "document_name" => parsed["canonical_component"].to_s.presence || I18n.t("rag.unknown_component"),
      "aliases"       => aliases,
      "summary"       => parsed["summary"].to_s.presence,
      "chunks"        => [ { "text" => build_body(parsed), "page" => 1, "aliases" => aliases } ]
    }
  end

  private

  def parse_json(text)
    LlmJsonParser.parse(text)
  rescue JSON::ParserError => e
    raise BatchResultsParserService::ParseError,
          "FieldPhotoResultsParser: invalid JSON — #{e.message}"
  end

  def build_body(parsed)
    lines = [
      ("Component: #{parsed['canonical_component']}" if parsed["canonical_component"].present?),
      ("Manufacturer: #{parsed['manufacturer']}"     if parsed["manufacturer"].present?),
      ("Model: #{parsed['model']}"                   if parsed["model"].present?),
      ("Condition: #{parsed['condition']}"           if parsed["condition"].present?),
      ("Visible labels: #{Array(parsed['aliases']).compact_blank.join(', ')}" if Array(parsed["aliases"]).compact_blank.any?),
      evidence_lines("Visible text", parsed["visible_text"]),
      structured_evidence_lines(
        "Documented functions",
        parsed["documented_functions"],
        required_keys: %w[label function]
      ) do |item|
        evidence = item["evidence"].to_s.presence
        "#{item['label']}: #{item['function']}#{evidence ? " | Evidence: #{evidence}" : ""}"
      end,
      structured_evidence_lines(
        "Documented connections",
        parsed["documented_connections"],
        required_keys: %w[from to]
      ) do |item|
        evidence = item["evidence"].to_s.presence
        "#{item['from']} -> #{item['to']}#{evidence ? " | Evidence: #{evidence}" : ""}"
      end,
      structured_evidence_lines(
        "Documented values",
        parsed["documented_values"],
        required_keys: %w[label value]
      ) do |item|
        value = [ item["value"], item["unit"] ].compact_blank.join(" ")
        evidence = item["evidence"].to_s.presence
        "#{item['label']}: #{value}#{evidence ? " | Evidence: #{evidence}" : ""}"
      end,
      evidence_lines("Documented warnings", parsed["documented_warnings"]),
      ("Technical evidence: DATA_NOT_AVAILABLE beyond visible identification." unless technical_evidence?(parsed)),
      ("Notes: #{parsed['anti_hallucination_notes']}" if parsed["anti_hallucination_notes"].present?)
    ].compact

    lines.join("\n")
  end

  def evidence_lines(title, values)
    items = Array(values).map { |value| value.to_s.strip }.compact_blank.first(EVIDENCE_ITEM_LIMIT)
    return if items.empty?

    "#{title}:\n#{items.map { |item| "- #{item}" }.join("\n")}"
  end

  def structured_evidence_lines(title, values, required_keys:)
    items = Array(values).filter_map do |value|
      next unless value.is_a?(Hash)
      next unless required_keys.all? { |key| value[key].to_s.present? }

      rendered = yield(value).to_s.strip
      (rendered.presence)
    end.first(EVIDENCE_ITEM_LIMIT)
    return if items.empty?

    "#{title}:\n#{items.map { |item| "- #{item}" }.join("\n")}"
  end

  def technical_evidence?(parsed)
    return true if Array(parsed["visible_text"]).compact_blank.any?
    return true if Array(parsed["documented_warnings"]).compact_blank.any?

    {
      "documented_functions" => %w[label function],
      "documented_connections" => %w[from to],
      "documented_values" => %w[label value]
    }.any? do |key, required_keys|
      Array(parsed[key]).any? do |item|
        item.is_a?(Hash) && required_keys.all? { |required_key| item[required_key].to_s.present? }
      end
    end
  end
end
