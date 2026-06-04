# frozen_string_literal: true

# Routes a field photo to :sonnet (default) or :opus (dense/large scan).
# Decision is purely size-based: binaries >= LARGE_PHOTO_THRESHOLD bytes are likely
# scanned documents/schematics, not typical field photos — route to Opus for fidelity.
# Zero LLM calls in this path: deterministic, low-latency, zero cost.
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
    Rails.logger.info("FieldPhotoDensityGate: #{@filename} → #{route} (size=#{@binary.bytesize})")
    route
  end

  private

  def heuristic_route
    @binary.bytesize >= LARGE_PHOTO_THRESHOLD ? :opus : :sonnet
  end
end
