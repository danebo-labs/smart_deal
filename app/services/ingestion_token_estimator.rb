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
#   :embed — Titan text embedding model (KB indexes chunk .txt files).
#            One embed call per chunk; estimate from chunk text size (or file text proxy).
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

  # Minimum embed tokens when chunk bytes cannot be read (empty prefix / S3 miss).
  MIN_EMBED_TOKENS = 100

  # Legacy Nova multimodal image patch bounds — kept for backward-compatible tests only.
  NOVA_IMAGE_BASE_TOKENS = 258
  NOVA_IMAGE_MAX_TOKENS  = 1290

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
    # Custom chunking writes a text chunk (field photo summary); Titan embeds text, not pixels.
    caption_chars = (bytes.to_s.bytesize * 0.05).to_i.clamp(400, 4_000)
    estimate_from_text("x" * caption_chars)
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

  # Sum S3 object sizes for chunk_*.txt under a prefix (proxy for Titan input tokens).
  # Avoids N get_object calls; ±10% vs actual tokenizer is acceptable for UI cost.
  def self.estimate_embed_from_chunks(s3:, bucket:, prefix:)
    return nil if prefix.blank? || bucket.blank?

    total_bytes = 0
    resp = s3.list_objects_v2(bucket: bucket, prefix: "#{prefix}/")
    loop do
      (resp.contents || []).each do |obj|
        key = obj.key.to_s
        next unless key.end_with?(".txt")
        next if key.end_with?(".metadata.json")

        total_bytes += obj.size.to_i
      end
      break unless resp.is_truncated

      resp = s3.list_objects_v2(bucket: bucket, prefix: "#{prefix}/", continuation_token: resp.next_continuation_token)
    end

    return nil if total_bytes.zero?

    tokens_from_bytes(total_bytes)
  rescue StandardError => e
    Rails.logger.warn("[IngestionTokenEstimator] chunk prefix estimate failed for #{prefix}: #{e.message}")
    nil
  end

  def self.tokens_from_bytes(byte_count)
    chars  = byte_count.clamp(MIN_EMBED_TOKENS, 2_000_000)
    tokens = (chars / CHARS_PER_TOKEN).ceil
    tokens.clamp(MIN_EMBED_TOKENS, 500_000)
  end
  private_class_method :tokens_from_bytes

  def self.embed_only(input_tokens)
    { parse: { input_tokens: 0, output_tokens: 0 },
      embed: { input_tokens: input_tokens.clamp(MIN_EMBED_TOKENS, 500_000), output_tokens: 0 } }
  end
end
