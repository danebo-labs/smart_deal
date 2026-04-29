# frozen_string_literal: true

# app/services/ingestion_token_estimator.rb
#
# Estimates Bedrock token consumption for a document being ingested into the
# Knowledge Base. Returns separate budgets for:
#
#   :parse — Opus foundation model parsing (BEDROCK_FOUNDATION_MODEL strategy).
#             Opus reads the full document and emits structured chunks with
#             identity headers. Input ≈ full text × HIERARCHICAL_OVERLAP_FACTOR;
#             output ≈ input × OPUS_OUTPUT_EXPANSION.
#
#   :embed — Nova multimodal embedding model. Processes each chunk + any images.
#            Image tokens are calculated from pixel dimensions (Nova patch grid).
#            No output tokens for embedding.
#
# All multipliers are documented approximations — see constants below.
# Actual AWS costs may differ ±10%; shown in UI with a disclaimer.
class IngestionTokenEstimator
  # HIERARCHICAL chunking creates parent + child chunks with overlap.
  # Empirically each token in the source appears ~1.3× across all chunks.
  HIERARCHICAL_OVERLAP_FACTOR = 1.3

  # Opus reformats content and injects **Document:** / **DOCUMENT_ALIASES:**
  # headers per chunk. Output is typically 10–20% larger than input.
  OPUS_OUTPUT_EXPANSION = 1.15

  # Nova multimodal: minimum patch tokens per image (≤ 512px side).
  NOVA_IMAGE_BASE_TOKENS = 258

  # Nova multimodal: maximum patch tokens per image (capped at ~1024×1024).
  NOVA_IMAGE_MAX_TOKENS = 1290

  # LocalTokenizer chars/token ratio (calibrated for Spanish/English technical docs).
  CHARS_PER_TOKEN = 3.5

  IMAGE_EXTENSIONS  = %w[.png .jpg .jpeg .gif .webp].freeze
  TEXT_EXTENSIONS   = %w[.txt .md .html .htm .csv].freeze
  PDF_EXTENSION     = ".pdf"

  # @param filename [String]  original filename (used to detect type)
  # @param bytes    [String]  raw file bytes (IO read result)
  # @return [Hash] { parse: { input_tokens:, output_tokens: }, embed: { input_tokens:, output_tokens: } }
  def self.estimate(filename:, bytes:)
    ext = File.extname(filename.to_s).downcase

    if IMAGE_EXTENSIONS.include?(ext)
      estimate_image(bytes)
    elsif ext == PDF_EXTENSION
      estimate_pdf(bytes)
    elsif TEXT_EXTENSIONS.include?(ext)
      estimate_text(bytes.to_s.force_encoding("UTF-8").scrub)
    else
      # DOCX, XLSX, DOC — no gem available; estimate from raw bytes as proxy
      # (compressed formats: actual text is ~30% of file size)
      approx_text = (bytes.to_s.bytesize * 0.3).to_i.clamp(100, 500_000)
      estimate_from_char_count(approx_text)
    end
  rescue StandardError => e
    Rails.logger.warn("[IngestionTokenEstimator] estimate failed for #{filename}: #{e.message}")
    fallback_estimate(bytes)
  end

  # --- private ---

  def self.estimate_image(bytes)
    image_tokens = nova_image_tokens_from_bytes(bytes)
    # Images go directly to embedding; Opus parsing produces a minimal caption chunk
    parse_input  = image_tokens  # Opus sees the image as a patch grid
    parse_output = (parse_input * OPUS_OUTPUT_EXPANSION).ceil

    { parse: { input_tokens: parse_input,  output_tokens: parse_output },
      embed:  { input_tokens: image_tokens, output_tokens: 0 } }
  end
  private_class_method :estimate_image

  def self.estimate_pdf(bytes)
    text = extract_pdf_text(bytes)
    text.present? ? estimate_from_text(text) : fallback_estimate(bytes)
  end
  private_class_method :estimate_pdf

  def self.estimate_text(text)
    text.present? ? estimate_from_text(text) : fallback_estimate(text)
  end
  private_class_method :estimate_text

  # Core calculation given extracted text content.
  def self.estimate_from_text(text)
    base_tokens  = (text.to_s.length / CHARS_PER_TOKEN).ceil
    chunk_tokens = (base_tokens * HIERARCHICAL_OVERLAP_FACTOR).ceil

    parse_input  = chunk_tokens
    parse_output = (parse_input * OPUS_OUTPUT_EXPANSION).ceil
    embed_input  = chunk_tokens   # embeddings operate on the same chunked tokens

    { parse: { input_tokens: parse_input,  output_tokens: parse_output },
      embed:  { input_tokens: embed_input,  output_tokens: 0 } }
  end
  private_class_method :estimate_from_text

  # Used for char count when text is already extracted as a string of known length.
  def self.estimate_from_char_count(char_count)
    estimate_from_text("x" * char_count)
  end
  private_class_method :estimate_from_char_count

  # Zero-content fallback — returns a minimal non-zero estimate so the record
  # is created and the user sees *something* rather than 0 tokens.
  def self.fallback_estimate(bytes)
    size = bytes.to_s.bytesize.clamp(100, 1_000_000)
    estimate_from_char_count((size * 0.5).to_i)
  end
  private_class_method :fallback_estimate

  # Extract all text from a PDF using pdf-reader gem.
  # Returns empty string on any error (caller falls back gracefully).
  def self.extract_pdf_text(bytes)
    require "pdf-reader"
    io     = StringIO.new(bytes.to_s)
    reader = PDF::Reader.new(io)
    reader.pages.map(&:text).join("\n")
  rescue StandardError
    ""
  end
  private_class_method :extract_pdf_text

  # Calculate Nova multimodal image tokens from raw image bytes.
  # Formula: ceil(width * height / 1024), clamped to [BASE, MAX].
  # Falls back to BASE when dimensions cannot be read.
  def self.nova_image_tokens_from_bytes(bytes)
    require "vips"
    io    = Vips::Image.new_from_buffer(bytes.to_s, "")
    w, h  = io.width, io.height
    raw   = ((w * h) / 1024.0).ceil
    raw.clamp(NOVA_IMAGE_BASE_TOKENS, NOVA_IMAGE_MAX_TOKENS)
  rescue StandardError
    NOVA_IMAGE_BASE_TOKENS
  end
  private_class_method :nova_image_tokens_from_bytes
end
