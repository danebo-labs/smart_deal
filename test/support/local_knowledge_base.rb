# frozen_string_literal: true

require "json"
require "pathname"

# Lexical stand-in for Bedrock Retrieve over a local chunk directory written
# by BatchResultsParserService. It applies the request's metadata filter and
# its number_of_results, and ranks every filtered chunk by BM25 over the chunk
# text. It is not the Bedrock vector or hybrid ranking, so it proves the
# application path, not retrieval quality (F4).
class LocalKnowledgeBase
  K1 = 1.2
  B = 0.75
  DEFAULT_RESULTS = 5

  attr_reader :calls

  def initialize(root, bucket:)
    @root = Pathname(root)
    @bucket = bucket
    @calls = []
  end

  # Aws stub_responses handler for :retrieve.
  def handler
    ->(context) { retrieve(context.params) }
  end

  # SDK client whose retrieve answers from this directory. The response is
  # built by the SDK from the stub data, so callers read the same structs.
  # An instance method also passes LiveAwsBlock, which only blocks the class.
  def client
    kb = self
    sdk = Aws::BedrockAgentRuntime::Client.new(stub_responses: true, region: "us-east-1")
    sdk.define_singleton_method(:retrieve) { |params = {}, **kwargs| stub_data(:retrieve, kb.retrieve(params.merge(kwargs))) }
    sdk.define_singleton_method(:retrieve_and_generate) { |*| raise ArgumentError, "LocalKnowledgeBase does not generate" }
    sdk
  end

  def retrieve(params)
    config = params.dig(:retrieval_configuration, :vector_search_configuration) || {}
    query = params.dig(:retrieval_query, :text).to_s
    limit = (config[:number_of_results] || DEFAULT_RESULTS).to_i
    kept = documents.select { |doc| matches?(config[:filter], doc[:metadata]) }
    ranked = rank(query, kept).first(limit)
    @calls << { "query" => query, "number_of_results" => limit, "filtered" => kept.size, "keys" => ranked.map { |row| row[:doc][:key] } }
    {
      retrieval_results: ranked.map do |row|
        {
          content: { text: row[:doc][:text], type: "TEXT" },
          location: { type: "S3", s3_location: { uri: "s3://#{@bucket}/#{row[:doc][:key]}" } },
          metadata: row[:doc][:metadata],
          score: row[:score]
        }
      end
    }
  end

  def documents
    @documents ||= Dir.glob(@root.join("**/*.txt").to_s).sort.map do |path|
      key = Pathname(path).relative_path_from(@root).to_s
      sidecar = "#{path}.metadata.json"
      attributes = File.file?(sidecar) ? JSON.parse(File.read(sidecar)).fetch("metadataAttributes", {}) : {}
      text = File.read(path)
      {
        key: key,
        text: text,
        tokens: tokens(text),
        metadata: attributes.merge("x-amz-bedrock-kb-source-uri" => "s3://#{@bucket}/#{key}")
      }
    end
  end

  private

  def rank(query, docs)
    terms = tokens(query).uniq
    return [] if terms.empty? || docs.empty?

    average = docs.sum { |doc| doc[:tokens].size }.to_f / docs.size
    scored = docs.map do |doc|
      counts = doc[:tokens].tally
      score = terms.sum do |term|
        frequency = counts[term].to_i
        next 0.0 if frequency.zero?

        holders = docs.count { |other| other[:tokens].include?(term) }
        idf = Math.log(1 + ((docs.size - holders + 0.5) / (holders + 0.5)))
        idf * (frequency * (K1 + 1)) / (frequency + (K1 * (1 - B + (B * doc[:tokens].size / average))))
      end
      { doc: doc, score: score }
    end
    top = scored.pluck(:score).max.to_f
    scored.select { |row| row[:score].positive? }
          .sort_by { |row| [ -row[:score], row[:doc][:key] ] }
          .map { |row| row.merge(score: top.positive? ? (row[:score] / top).round(6) : 0.0) }
  end

  def tokens(text)
    I18n.transliterate(text.to_s).downcase.scan(/[a-z0-9]{2,}/)
  end

  def matches?(filter, metadata)
    return true if filter.nil?

    node = filter.to_h.transform_keys(&:to_sym)
    operator, clause = node.first
    case operator
    when :and_all then Array(clause).all? { |item| matches?(item, metadata) }
    when :or_all then Array(clause).any? { |item| matches?(item, metadata) }
    else leaf?(operator, clause.to_h.transform_keys(&:to_sym), metadata)
    end
  end

  def leaf?(operator, clause, metadata)
    actual = metadata[clause[:key].to_s]
    expected = clause[:value]
    case operator
    when :equals then actual.to_s == expected.to_s && !actual.nil?
    when :not_equals then actual.to_s != expected.to_s
    when :in then !actual.nil? && Array(expected).map(&:to_s).include?(actual.to_s)
    when :not_in then actual.nil? || Array(expected).map(&:to_s).exclude?(actual.to_s)
    when :list_contains then Array(actual).map(&:to_s).include?(expected.to_s)
    when :string_contains then actual.to_s.include?(expected.to_s)
    when :starts_with then actual.to_s.start_with?(expected.to_s)
    else raise ArgumentError, "LocalKnowledgeBase does not support filter operator #{operator}"
    end
  end
end
