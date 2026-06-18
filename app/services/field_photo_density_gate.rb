# frozen_string_literal: true

# Routes a field photo to :sonnet (default) or :opus (dense/large scan).
# Decision is purely size-based: binaries >= LARGE_PHOTO_THRESHOLD bytes are likely
# scanned documents/schematics, not typical field photos — route to Opus for fidelity.
# Zero LLM calls in this path: deterministic, low-latency, zero cost.
#
# Gate 9R O1′ prep: every decision emits a structured "field_photo_gate" event with
# bytes, dimensions and format read from the image header (no decode of pixel data,
# no LLM). The decision itself is unchanged — telemetry first, routing change later.
class FieldPhotoDensityGate
  # 1.5 MB — scanned TIFF/PNG exports of dense schematics commonly exceed this;
  # typical JPEG field photos (phone camera) are 0.3–1.2 MB.
  LARGE_PHOTO_THRESHOLD = 1_500_000

  # @param correlation_id [String, nil] join key threaded from the caller:
  #   web path → image_compression.output_correlation_id (from SingleFileChunkingService#correlation_id);
  #   bulk path → asset.sha256-based key (from BulkCostV2RequestBuilder).
  def self.decide(binary:, content_type:, filename:, correlation_id: nil)
    new(binary: binary, content_type: content_type, filename: filename, correlation_id: correlation_id).decide
  end

  def initialize(binary:, content_type:, filename:, correlation_id: nil)
    @binary         = binary
    @content_type   = content_type
    @filename       = filename
    @correlation_id = correlation_id
  end

  def decide
    route = heuristic_route
    log_gate_decision(route)
    route
  end

  private

  def heuristic_route
    @binary.bytesize >= LARGE_PHOTO_THRESHOLD ? :opus : :sonnet
  end

  def log_gate_decision(route)
    dims    = image_dimensions
    model   = route == :opus ? BatchChunkingPrompt::MODEL_MULTIMODAL : BatchChunkingPrompt::MODEL_TEXT
    payload = {
      event:        "field_photo_gate",
      filename:     @filename,
      route:        route,
      model:        model,
      bytes:        @binary.bytesize,
      threshold:    LARGE_PHOTO_THRESHOLD,
      width:        dims[:width],
      height:       dims[:height],
      format:       dims[:format] || @content_type,
      content_type: @content_type
    }
    payload.merge!(content_signal)
    payload[:correlation_id] = @correlation_id if @correlation_id

    Rails.logger.info(JSON.generate(payload))
  rescue StandardError => e
    Rails.logger.warn("FieldPhotoDensityGate: telemetry failed for #{@filename} — #{e.message}")
  end

  # Header-only Vips load — reads dimensions without decoding pixel data.
  # Never lets a telemetry failure affect routing.
  def image_dimensions
    return { width: nil, height: nil, format: nil } unless plausible_image_header?

    img = Vips::Image.new_from_buffer(@binary, "")
    { width: img.width, height: img.height, format: img.get("vips-loader") }
  rescue StandardError
    { width: nil, height: nil, format: nil }
  end

  # Gate 9R O5-A: cheap content signal to distinguish line-art schematics
  # (white background + lines → high white_ratio) from continuous-tone field
  # photos. Pixel read on a shrunk copy; never affects routing.
  def content_signal
    return {} unless plausible_image_header?

    img    = Vips::Image.new_from_buffer(@binary, "")
    factor = [ [ img.width, img.height ].max / 256.0, 1.0 ].max
    small  = factor > 1.0 ? img.shrink(factor, factor) : img
    bw     = small.colourspace("b-w")
    {
      white_ratio: ((bw > 240).avg / 255.0).round(3),
      luma_mean:   bw.avg.round(1)
    }
  rescue StandardError
    {}
  end

  def plausible_image_header?
    case @content_type
    when "image/jpeg"
      @binary.start_with?("\xFF\xD8".b) && @binary.end_with?("\xFF\xD9".b)
    when "image/png"
      @binary.start_with?("\x89PNG\r\n\x1A\n".b)
    when "image/webp"
      @binary.start_with?("RIFF".b) && @binary.byteslice(8, 4) == "WEBP".b
    when "image/gif"
      @binary.start_with?("GIF87a".b, "GIF89a".b)
    else
      false
    end
  end
end
