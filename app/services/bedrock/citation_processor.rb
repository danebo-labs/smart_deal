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
  # @return [Array<Hash>]
  def build_numbered_references(citations, answer_text)
    citation_numbers = answer_text.scan(/\[(\d+)\]/).flatten.map(&:to_i).uniq.sort

    citation_numbers.filter_map do |num|
      citation = citations[num - 1]
      next unless citation

      location = citation[:location]
      metadata = citation[:metadata] || {}

      filename = extract_filename(location)
      base_title = metadata['title'] || metadata[:title] || filename
      page = extract_page_number(metadata, content: citation[:content], location: location)
      title = page ? "#{base_title} — p. #{page}" : base_title

      {
        number: num,
        title: title,
        filename: filename,
        page: page,
        content: citation[:content],
        location: location,
        metadata: metadata
      }
    end
  end

  private

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
