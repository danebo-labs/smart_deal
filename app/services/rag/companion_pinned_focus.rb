# frozen_string_literal: true

module Rag
  # A companion turn whose retrieval focus is a pinned document.
  # The exhaustive reranker flag is not this predicate.
  module CompanionPinnedFocus
    module_function

    def focus?(entity_sources:, entity_s3_uris:, raw_question:, episode:, plan_request:)
      return false unless plan_enabled?
      return false if ENV["RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"] == "1"
      return false unless Array(entity_sources).include?("document")
      return false if Array(entity_s3_uris).map(&:to_s).uniq.empty?
      return false if raw_question.blank?
      return false if plan_request

      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      parsed.present? && parsed.status == "active"
    end

    def plan_enabled?
      value = ENV["RAG_COMPANION_TURN"]
      return true if value.nil? || value.strip.empty?

      value == "1" || value == "true"
    end
  end
end
