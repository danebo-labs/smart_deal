# frozen_string_literal: true

# Routes a field photo to :sonnet (default) or :opus (dense/large scan).
# Heuristic: binaries >= LARGE_PHOTO_THRESHOLD bytes are likely scanned documents,
# not typical field photos — route to Opus for higher fidelity.
# Opt-in Haiku pre-gate: FIELD_PHOTO_HAIKU_GATE_ENABLED=true sends a tiny call to
# verify before committing to Sonnet on borderline inputs.
class FieldPhotoDensityGate
  # 1.5 MB — scanned TIFF/PNG exports of dense schematics commonly exceed this;
  # typical JPEG field photos (phone camera) are 0.3–1.2 MB.
  LARGE_PHOTO_THRESHOLD = 1_500_000

  def self.decide(binary:, content_type:, filename:)
    new(binary: binary, content_type: content_type, filename: filename).decide
  end

  def initialize(binary:, content_type:, filename:)
    @binary       = binary
    @content_type = content_type
    @filename     = filename
  end

  def decide
    route = heuristic_route
    route = haiku_gate(route) if haiku_gate_enabled? && route == :sonnet
    Rails.logger.info(
      "FieldPhotoDensityGate: #{@filename} → #{route} (size=#{@binary.bytesize})"
    )
    route
  end

  private

  def heuristic_route
    @binary.bytesize >= LARGE_PHOTO_THRESHOLD ? :opus : :sonnet
  end

  def haiku_gate_enabled?
    ENV["FIELD_PHOTO_HAIKU_GATE_ENABLED"].to_s == "true"
  end

  def haiku_gate(route)
    client   = Anthropic::Client.new(api_key: anthropic_api_key)
    response = client.messages.create(
      model:      "claude-haiku-4-5-20251001",
      max_tokens: 64,
      system:     [ { type: "text", text: 'Reply ONLY with valid JSON: {"force_opus": true} or {"force_opus": false}' } ],
      messages:   [ {
        role:    "user",
        content: [
          {
            type:   "image",
            source: { type: "base64", media_type: @content_type,
                      data: Base64.strict_encode64(@binary) }
          },
          { type: "text",
            text: "Is this a high-density scanned document rather than a regular field photo? JSON only." }
        ]
      } ]
    )
    text   = response.content.find { |b| b.type.to_s == "text" }&.text.to_s.strip
    parsed = JSON.parse(text)
    parsed["force_opus"] ? :opus : route
  rescue StandardError => e
    Rails.logger.warn(
      "FieldPhotoDensityGate: Haiku gate error for #{@filename} — #{e.message}; keeping #{route}"
    )
    route
  end

  def anthropic_api_key
    ENV.fetch("ANTHROPIC_API_KEY", nil).presence ||
      Rails.application.credentials.dig(:anthropic, :api_key)
  end
end
