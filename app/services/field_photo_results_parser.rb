# frozen_string_literal: true

# Transforms FieldPhotoPrompt JSON into the standard envelope expected by
# BatchResultsParserService#validate! (document_name, aliases, summary, chunks).
# Produces a single lightweight chunk — no S0-S18 sections.
class FieldPhotoResultsParser
  def self.to_envelope(raw_json)
    new(raw_json).to_envelope
  end

  def initialize(raw_json)
    @raw = raw_json
  end

  def to_envelope
    parsed = parse_json(@raw)
    {
      "document_name" => parsed["canonical_component"].to_s.presence || "Unknown Component",
      "aliases"       => Array(parsed["aliases"]),
      "summary"       => parsed["summary"].to_s.presence,
      "chunks"        => [ { "text" => build_body(parsed), "page" => 1 } ]
    }
  end

  private

  def parse_json(text)
    s = text.to_s.strip.sub(/\A```(?:json)?\s*\n?/i, "").sub(/\n?```\s*\z/, "").strip
    JSON.parse(s)
  rescue JSON::ParserError => e
    raise BatchResultsParserService::ParseError,
          "FieldPhotoResultsParser: invalid JSON — #{e.message}"
  end

  def build_body(parsed)
    [
      ("Component: #{parsed['canonical_component']}" if parsed["canonical_component"].present?),
      ("Manufacturer: #{parsed['manufacturer']}"     if parsed["manufacturer"].present?),
      ("Model: #{parsed['model']}"                   if parsed["model"].present?),
      ("Subsystem: #{parsed['subsystem']}"           if parsed["subsystem"].present?),
      ("Condition: #{parsed['condition']}"           if parsed["condition"].present?),
      ("Notes: #{parsed['anti_hallucination_notes']}" if parsed["anti_hallucination_notes"].present?)
    ].compact.join("\n")
  end
end
