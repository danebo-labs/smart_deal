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

  # Adds [n] citation markers to answer text when Bedrock omits them.
  # Distributes markers every ~3 sentences across available citations.
  # @param answer_text [String]
  # @param citations [Array<Hash>]
  # @return [String]
  def add_citations_to_answer(answer_text, citations)
    return answer_text if citations.empty?

    sentences = answer_text.split(/([.!?]\s+)/)
    result = []
    citation_index = 0

    sentences.each_with_index do |sentence, index|
      result << sentence

      if citation_index < citations.length && (index % 3 == 2 || index == sentences.length - 1)
        result << "[#{citation_index + 1}]"
        citation_index += 1
      end
    end

    result.join
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
      title = metadata['title'] || metadata[:title] || filename

      {
        number: num,
        title: title,
        filename: filename,
        content: citation[:content],
        location: location,
        metadata: metadata
      }
    end
  end

  private

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
end
