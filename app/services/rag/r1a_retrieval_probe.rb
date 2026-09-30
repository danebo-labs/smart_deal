# frozen_string_literal: true

module Rag
  # TEMPORARY R1A DIAGNOSTIC. Observational log only. Remove after the R1A
  # production smoke. This class does not filter, rank, authorize, mutate
  # session state, or change a response. It records metadata the request
  # already has.
  class R1aRetrievalProbe
    QUERY_LIMIT = 180
    URI_LIMIT = 300

    class << self
      def emit(correlation_id:, stage:, query: nil, **fields)
        line = {
          "correlation_id" => correlation_id.to_s,
          "stage" => stage.to_s,
          "query" => query.to_s.first(QUERY_LIMIT)
        }
        fields.each do |key, value|
          next if value.nil?

          line[key.to_s] = value
        end
        Rails.logger.info("R1A_PROBE #{JSON.generate(line)}")
        nil
      rescue StandardError
        nil
      end

      def observe_chunk(correlation_id:, stage:, chunk:, kept:, viewer_account_id:, query: nil, rank: nil, score: nil)
        metadata = metadata_of(chunk)
        emit(
          correlation_id: correlation_id,
          stage: stage,
          query: query,
          rank: rank,
          score: score,
          account_id: metadata&.[]("account_id"),
          document_id: metadata&.[]("document_id"),
          original_source_uri: metadata&.[]("original_source_uri").to_s.first(URI_LIMIT).presence,
          ingestion_path: metadata&.[]("ingestion_path").presence,
          manual_corpus: metadata&.[]("manual_corpus").presence,
          decision: kept ? "KEEP" : "DROP",
          reason: reason_for(metadata, viewer_account_id)
        )
      end

      def reason_for(metadata, viewer_account_id)
        return "metadata_unreadable" if metadata.nil?

        account_id = metadata["account_id"].to_s.presence
        return "account_id_blank" if account_id.blank?
        return "owner" if account_id == viewer_account_id.to_s
        return "foreign_photo" if metadata["ingestion_path"].to_s == Rag::SharedManualCorpus::PHOTO_INGESTION_PATH
        return "private_corpus" if metadata[Rag::SharedManualCorpus::ATTRIBUTE].to_s == Rag::SharedManualCorpus::ACCOUNT
        return "general" if metadata[Rag::SharedManualCorpus::ATTRIBUTE].to_s == Rag::SharedManualCorpus::GENERAL
        return "shared_member" if Rag::SharedManualCorpus.member_id?(account_id)

        "foreign_private"
      end

      def metadata_of(chunk)
        return nil unless chunk.is_a?(Hash)

        raw = chunk.key?(:metadata) ? chunk[:metadata] : chunk["metadata"]
        return nil if raw.nil?

        raw = raw.to_h if !raw.is_a?(Hash) && raw.respond_to?(:to_h)
        return nil unless raw.is_a?(Hash)

        raw.stringify_keys
      rescue StandardError
        nil
      end
    end
  end
end
