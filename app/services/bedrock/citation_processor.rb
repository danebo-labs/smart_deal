# frozen_string_literal: true

# app/services/bedrock/citation_processor.rb

class Bedrock::CitationProcessor
  # Extract citations from Bedrock response
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

  # Extract location information from citation
  def extract_location_info(location)
    return nil unless location&.s3_location&.uri

    uri = location.s3_location.uri
    uri_parts = uri.split('/')
    {
      bucket: uri_parts[2],
      key: uri_parts[3..-1].join('/'),
      uri: uri,
      type: 's3'
    }
  end

  # Build mapping from Bedrock citation numbers to Data Source numbers
  def build_citation_mapping(citations, s3_documents)
    return {} if citations.empty? || s3_documents.empty?

    # Build a map of S3 documents by filename for quick lookup
    s3_doc_map = {}
    s3_documents.each_with_index do |doc, index|
      doc_name = doc[:name] || doc['name']
      s3_doc_map[doc_name] = index + 1 if doc_name
    end

    # Map Bedrock citation index to Data Source number
    mapping = {}
    citations.each_with_index do |citation, index|
      bedrock_num = index + 1
      location = citation[:location]
      metadata = citation[:metadata] || {}

      # Extract filename from S3 URI
      filename = if location && location[:key]
                   File.basename(location[:key])
                 elsif location && location[:uri]
                   File.basename(location[:uri])
                 else
                   nil
                 end

      # Use title from metadata if available, otherwise use filename
      title = metadata['title'] || metadata[:title] || filename

      # Find matching document in Data Source by filename or title
      data_source_num = s3_doc_map[filename] || s3_doc_map[title] || bedrock_num
      mapping[bedrock_num] = data_source_num
    end

    mapping
  end

  # Replace Bedrock citation numbers with Data Source numbers in answer text
  def replace_citation_numbers(answer_text, citation_map)
    return answer_text if citation_map.empty?

    # Replace all citation numbers [1], [2], [1][3] with Data Source numbers
    answer_text.gsub(/\[(\d+)\]/) do |match|
      bedrock_num = $1.to_i
      data_source_num = citation_map[bedrock_num] || bedrock_num
      "[#{data_source_num}]"
    end
  end

  # Add citations to answer text if they're missing
  # This adds [1], [2], etc. at the end of sentences when citations are available
  def add_citations_to_answer(answer_text, citations, citation_map = {})
    return answer_text if citations.empty?

    # Split answer into sentences
    sentences = answer_text.split(/([.!?]\s+)/)
    result = []
    citation_index = 0

    sentences.each_with_index do |sentence, index|
      result << sentence
      
      # Add citation after every 2-3 sentences, or at the end
      if citation_index < citations.length && (index % 3 == 2 || index == sentences.length - 1)
        bedrock_num = citation_index + 1
        # Use Data Source number if mapping exists, otherwise use Bedrock number
        citation_num = citation_map[bedrock_num] || bedrock_num
        result << "[#{citation_num}]"
        citation_index += 1
      end
    end

    result.join
  end

  # Build numbered references by extracting citation numbers from answer text
  # and mapping them to documents from Data Source
  # Note: citation numbers in answer_text are now Data Source numbers (already replaced)
  def build_numbered_references(citations, answer_text, s3_documents = [])
    # Extract all citation numbers from answer text (e.g., [1], [2], [1][3])
    # These are now Data Source numbers, not Bedrock numbers
    citation_numbers = answer_text.scan(/\[(\d+)\]/).flatten.map(&:to_i).uniq.sort

    # Build a map of S3 documents by filename for quick lookup
    s3_doc_map = {}
    s3_documents.each_with_index do |doc, index|
      doc_name = doc[:name] || doc['name']
      s3_doc_map[doc_name] = index + 1 if doc_name
    end

    # Build reverse map: Data Source number -> citation data
    # We need to find which Bedrock citation corresponds to each Data Source number
    references = {}
    
    citations.each_with_index do |citation, index|
      location = citation[:location]
      metadata = citation[:metadata] || {}

      # Extract filename from S3 URI
      filename = if location && location[:key]
                   File.basename(location[:key])
                 elsif location && location[:uri]
                   File.basename(location[:uri])
                 else
                   'Document'
                 end

      # Use title from metadata if available, otherwise use filename
      title = metadata['title'] || metadata[:title] || filename

      # Find matching document in Data Source by filename
      data_source_number = s3_doc_map[filename] || s3_doc_map[title]
      
      if data_source_number
        references[data_source_number] = {
          number: data_source_number, # Data Source number (used in answer text)
          title: title,
          filename: filename,
          content: citation[:content],
          location: location,
          metadata: metadata
        }
      end
    end

    # Return references in order of appearance in answer text (by Data Source number)
    citation_numbers.filter_map { |num| references[num] }.uniq
  end
end
