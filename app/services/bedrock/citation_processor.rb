# frozen_string_literal: true

# app/services/bedrock/citation_processor.rb
#
# Processes citations returned by Bedrock's retrieve_and_generate API.
# All information (filename, title, content) is extracted directly from the
# API response — no S3 listing is required.

class Bedrock::CitationProcessor
  # Extracts citations from the raw Bedrock response.
  # Each citation contains the source chunk content and its S3 location.
  # @return [Array<Hash>]
  def extract_citations(citations)
    return [] unless citations

    citations.flat_map do |citation|
      citation.retrieved_references.map do |ref|
        location = extract_location_info(ref.location)
        {
          content: ref.content&.text,
          location: location,
          metadata: ref.metadata || {}
        }
      end
    end
  end

  # Inserts [n] markers using the REAL attribution spans Bedrock returns in
  # `citation.generated_response_part.text_response_part.span`. Each marker number
  # is the 1-based index of its retrieved reference in the same flattened order as
  # #extract_citations, so #build_numbered_references resolves them correctly.
  #
  # This is the genuine attribution contract — markers land at the exact end of the
  # cited passage instead of being sprinkled every ~3 sentences.
  #
  # @param answer_text [String]
  # @param raw_citations [Array] the raw Bedrock response.citations objects
  # @return [String]
  def add_span_citations(answer_text, raw_citations)
    return answer_text if raw_citations.blank?

    insertions = []
    reference_number = 0

    raw_citations.each do |citation|
      references = Array(citation.retrieved_references)
      numbers = references.map { reference_number += 1 }
      next if numbers.empty?

      offset = span_end(citation) || answer_text.length
      insertions << [ offset.clamp(0, answer_text.length), numbers.map { |n| "[#{n}]" }.join ]
    end
    return answer_text if insertions.empty?

    # Insert from the tail so earlier offsets stay valid.
    insertions.sort_by { |offset, _marker| -offset }.each do |offset, marker|
      answer_text = "#{answer_text[0...offset]}#{marker}#{answer_text[offset..]}"
    end
    answer_text
  end

  # Builds the ordered list of references that appear in the answer text.
  # Citation numbers in answer_text (e.g. [1], [2]) map directly to the
  # citations array by 1-based index — no S3 lookup required.
  # @param citations [Array<Hash>]
  # @param answer_text [String]
  # @param question [String, nil] when present, used to derive matched_excerpt
  # @return [Array<Hash>]
  def build_numbered_references(citations, answer_text, question: nil)
    citation_numbers = answer_text.scan(/\[(\d+)\]/).flatten.map(&:to_i).uniq.sort

    citation_numbers.filter_map do |num|
      citation = citations[num - 1]
      next unless citation

      location = citation[:location]
      metadata = citation[:metadata] || {}

      filename = extract_filename(location)
      # .presence is required: the sidecar writes canonical_name.to_s, which can be
      # "" — and "" is truthy in Ruby, so a bare `||` would never fall through.
      base_title = metadata['canonical_name'].presence || metadata[:canonical_name].presence ||
                   metadata['title'].presence || metadata[:title].presence || filename
      page = extract_page_number(metadata, content: citation[:content], location: location)
      title = page ? "#{base_title} — p. #{page}" : base_title

      {
        number: num,
        title: title,
        filename: filename,
        page: page,
        content: citation[:content],
        location: location,
        metadata: metadata,
        matched_excerpt: matched_excerpt(citation[:content], question)
      }
    end
  end

  private

  # Chunks are written as `header + body` (BatchResultsParserService#identity_header):
  # three bracketed metadata lines followed by a blank line. Never surface that
  # block as a "matching excerpt" — the technician needs a sentence from the
  # manual, not internal ingestion metadata.
  HEADER_PATTERN = /\A\[DOCUMENT:.*?\]\n\[SOURCE_URI:.*?\]\n\[SEARCH_ALIASES:.*?\]\n\n/m.freeze

  # Legacy chunk bodies (OWRPGSX6XK Lambda path) and Opus-authored S0 identification
  # blocks prepend markdown metadata — bold headers, section headings, table rows,
  # and alias bullets — before any real content. None of that is a "matching
  # excerpt" a technician should see; filter it out line-by-line before splitting
  # into candidate sentences.
  METADATA_LINE_PATTERN = /\A\s*(?:\*\*[A-Z_]+:|\||#+\s|-\s+[a-z0-9 ]+\z|\[(?:DOCUMENT|SOURCE_URI|SEARCH_ALIASES):)/.freeze

  MIN_EXCERPT_TOKEN_LENGTH = 4
  EXCERPT_MAX_CHARS = 140
  EXCERPT_STOPWORDS = %w[
    para como cual cuales donde cuando desde hasta sobre entre este esta estos estas
    that this these those with from what which where when about
  ].to_set.freeze

  # Deterministic, dependency-free selection of the sentence in `content` that
  # best overlaps with the technician's question. Returns nil rather than ever
  # fabricating a fragment: the renderer falls back to the current behavior.
  def matched_excerpt(content, question)
    return nil if content.blank? || question.blank?

    tokens = excerpt_tokens(question)
    return nil if tokens.empty?

    threshold = tokens.size == 1 ? 1 : 2
    best = nil
    best_score = 0
    sentences(content).each do |sentence|
      score = (excerpt_tokens(sentence) & tokens).size
      next if score <= best_score

      best_score = score
      best = sentence
    end
    return nil if best.nil? || best_score < threshold

    best.squish.truncate(EXCERPT_MAX_CHARS)
  end

  def excerpt_tokens(text)
    I18n.transliterate(text.to_s).downcase.scan(/[[:alnum:]]+/)
      .select { |token| token.length >= MIN_EXCERPT_TOKEN_LENGTH }
      .reject { |token| EXCERPT_STOPWORDS.include?(token) }
      .to_set
  end

  def sentences(content)
    text = content.to_s.sub(HEADER_PATTERN, "")
    lines = text.split("\n").reject do |line|
      line.match?(METADATA_LINE_PATTERN) || line.include?("PIPELINE_INJECTED")
    end
    lines.join(" ").split(/(?<=[.!?])\s+/)
  end

  # Extracts the character end offset of a citation's generated span, tolerating
  # both AWS SDK struct accessors and plain hashes (recorded fixtures).
  def span_end(citation)
    part = dig_span(citation, :generated_response_part, :text_response_part, :span)
    return nil unless part

    value = dig_span(part, :end)
    return value if value.is_a?(Integer) && value >= 0

    nil
  end

  def dig_span(object, *keys)
    keys.reduce(object) do |node, key|
      break nil if node.nil?

      if node.respond_to?(key)
        node.public_send(key)
      elsif node.respond_to?(:[])
        node[key] || node[key.to_s]
      end
    end
  end

  def extract_location_info(location)
    return nil unless location&.s3_location&.uri

    uri = location.s3_location.uri
    uri_parts = uri.split('/')
    {
      bucket: uri_parts[2],
      key: uri_parts[3..].join('/'),
      uri: uri,
      type: 's3'
    }
  end

  def extract_filename(location)
    if location && location[:key]
      File.basename(location[:key])
    elsif location && location[:uri]
      File.basename(location[:uri])
    else
      'Document'
    end
  end

  def extract_page_number(metadata, content:, location:)
    value = [
      metadata["page_number"],
      metadata[:page_number],
      metadata["page"],
      metadata[:page],
      metadata["x-amz-bedrock-kb-document-page-number"],
      metadata[:"x-amz-bedrock-kb-document-page-number"]
    ].compact.first
    page = Integer(value, exception: false)
    return page if page&.positive?

    text_page = content.to_s.match(
      /(?:\*\*Page:\*\*|\bPage:|\bPage\b|\bP[aá]gina:|\bP[aá]gina\b)\s*(\d{1,4})/i
    )&.captures&.first
    page = Integer(text_page, exception: false)
    return page if page&.positive?

    key = if location
      location[:key] || location["key"] || location[:uri] || location["uri"]
    end.to_s
    key_page = key.match(/(?:\A|\/)chunk_p(\d{1,4})(?:_|\.)/i)&.captures&.first
    page = Integer(key_page, exception: false)
    page if page&.positive?
  end
end
