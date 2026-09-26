# frozen_string_literal: true

module Rag
  # One reconstruction record per technician turn. Cost stays on BedrockQuery.
  class TurnEvidence
    CAPTURE_ENV = "PILOT_AUDIT_CAPTURE"

    def self.build(correlation_id:, route:, outcome:, original_query: nil, effective_query: nil,
                   answer: nil, semantic: nil, photo: nil, chunk_ids: [], sources: [])
      new(
        correlation_id: correlation_id,
        route: route,
        outcome: outcome,
        original_query: original_query,
        effective_query: effective_query,
        answer: answer,
        semantic: semantic,
        photo: photo,
        chunk_ids: chunk_ids,
        sources: sources
      ).to_h
    end

    def self.log(...)
      payload = build(...)
      Rails.logger.info("[TURN_EVIDENCE] #{JSON.generate(payload)}")
      payload
    rescue StandardError => error
      Rails.logger.warn("TurnEvidence failed: #{error.class}: #{error.message}")
      nil
    end

    def self.evidence_from(citations)
      ids = []
      sources = []
      Array(citations).each do |citation|
        next unless citation.respond_to?(:[])

        meta = (citation[:metadata] || citation["metadata"] || {}).to_h.stringify_keys
        id = citation[:chunk_sha256] || citation["chunk_sha256"] ||
          citation[:chunk_id] || citation["chunk_id"] || meta["chunk_sha256"]
        ids << id.to_s if id.present?
        raw_title = meta["canonical_name"].presence || meta["title"].presence ||
          citation[:title] || citation["title"]
        title = raw_title.to_s.presence
        page = meta["page_number"] || meta["page"] || citation[:page] || citation["page"]
        next if title.blank? && page.blank?

        sources << { "title" => title, "page" => page }
      end
      [ ids, sources ]
    end

    def initialize(correlation_id:, route:, outcome:, original_query:, effective_query:, answer:,
                   semantic:, photo:, chunk_ids:, sources:)
      @correlation_id = correlation_id
      @route = route
      @outcome = outcome
      @original_query = original_query.to_s
      @effective_query = effective_query.to_s
      @answer = answer.to_s
      @semantic = semantic
      @photo = photo
      @chunk_ids = Array(chunk_ids)
      @sources = Array(sources)
    end

    def to_h
      payload = {
        "correlation_id" => @correlation_id,
        "route" => @route,
        "outcome" => @outcome.to_s,
        "original_query_sha256" => Digest::SHA256.hexdigest(@original_query),
        "effective_query_sha256" => Digest::SHA256.hexdigest(@effective_query),
        "semantic" => semantic_payload,
        "photo" => photo_payload,
        "chunk_ids" => @chunk_ids.map(&:to_s),
        "sources" => @sources.map { |source| source.to_h.stringify_keys.slice("title", "page") },
        "answer_sha256" => Digest::SHA256.hexdigest(@answer)
      }
      if ENV[CAPTURE_ENV] == "true"
        payload["original_query"] = @original_query
        payload["effective_query"] = @effective_query
        payload["answer"] = @answer
      end
      payload
    end

    private

    def semantic_payload
      return nil if @semantic.nil?

      row = @semantic.to_h.stringify_keys
      {
        "status" => row["status"],
        "relation" => row["relation"],
        "ambiguous" => row["ambiguous"]
      }
    end

    def photo_payload
      return nil if @photo.nil?

      row = @photo.to_h.stringify_keys
      {
        "intent_source" => row["intent_source"],
        "target_visible" => row.key?("target_visible") ? row["target_visible"] : nil
      }
    end
  end
end
