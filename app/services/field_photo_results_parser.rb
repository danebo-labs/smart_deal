# frozen_string_literal: true

# Transforms FieldPhotoPrompt JSON into the standard envelope expected by
# BatchResultsParserService#validate! (document_name, aliases, summary, chunks).
# Produces a single compact chunk — no S0-S18 sections. Explicit technical
# evidence is preserved when the photo contains a legible circuit, diagram, label,
# value, connection, or warning; empty evidence arrays remain lightweight.
class FieldPhotoResultsParser
  EVIDENCE_ITEM_LIMIT = 30

  # @param locale [String, Symbol, nil] Locale for the chunk body's field labels
  #   ("Component:"/"Componente:", etc). Defaults to :en — NOT the ambient
  #   I18n.locale — because the bulk/backoffice ingestion path
  #   (IngestBatchResultsJob) never threads a locale here and its already-indexed
  #   corpus/tests assume English labels. The live chat path
  #   (FieldPhotoAnalysisService) passes the resolved response locale explicitly.
  def self.to_envelope(raw_json, locale: nil)
    new(raw_json, locale: locale).to_envelope
  end

  def initialize(raw_json, locale: nil)
    @raw = raw_json
    @locale = locale
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

  def body_locale
    candidate = @locale.to_s.presence&.to_sym
    I18n.available_locales.include?(candidate) ? candidate : :en
  end

  def label(key)
    I18n.t("rag.field_photo_parser.#{key}", locale: body_locale)
  end

  def parse_json(text)
    LlmJsonParser.parse(text)
  rescue JSON::ParserError => e
    raise BatchResultsParserService::ParseError,
          "FieldPhotoResultsParser: invalid JSON — #{e.message}"
  end

  def build_body(parsed)
    lines = [
      ("#{label('component_label')}: #{parsed['canonical_component']}" if parsed["canonical_component"].present?),
      ("#{label('manufacturer_label')}: #{parsed['manufacturer']}"     if parsed["manufacturer"].present?),
      ("#{label('model_label')}: #{parsed['model']}"                   if parsed["model"].present?),
      ("#{label('condition_label')}: #{parsed['condition']}"           if parsed["condition"].present?),
      ("#{label('visible_labels_label')}: #{Array(parsed['aliases']).compact_blank.join(', ')}" if Array(parsed["aliases"]).compact_blank.any?),
      evidence_lines(label("visible_text_label"), parsed["visible_text"]),
      structured_evidence_lines(
        label("documented_functions_label"),
        parsed["documented_functions"],
        required_keys: %w[label function]
      ) do |item|
        evidence = item["evidence"].to_s.presence
        "#{item['label']}: #{item['function']}#{evidence ? " | Evidence: #{evidence}" : ""}"
      end,
      structured_evidence_lines(
        label("documented_connections_label"),
        parsed["documented_connections"],
        required_keys: %w[from to]
      ) do |item|
        evidence = item["evidence"].to_s.presence
        "#{item['from']} -> #{item['to']}#{evidence ? " | Evidence: #{evidence}" : ""}"
      end,
      structured_evidence_lines(
        label("documented_values_label"),
        parsed["documented_values"],
        required_keys: %w[label value]
      ) do |item|
        value = [ item["value"], item["unit"] ].compact_blank.join(" ")
        evidence = item["evidence"].to_s.presence
        "#{item['label']}: #{value}#{evidence ? " | Evidence: #{evidence}" : ""}"
      end,
      evidence_lines(label("documented_warnings_label"), parsed["documented_warnings"]),
      (label("no_technical_evidence") unless technical_evidence?(parsed)),
      ("#{label('notes_label')}: #{parsed['anti_hallucination_notes']}" if parsed["anti_hallucination_notes"].present?)
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
