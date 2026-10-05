# frozen_string_literal: true

module Rag
  # Durable copy of a DocumentIdentityScope decision. Reads the identity and
  # the Result the caller already has. Does not retrieve, generate, or decide.
  class DocumentIdentityScopeEvent
    def self.record(identity:, correlation_id:, applied: nil, status: nil, reason: nil,
                    account_id: nil, user_id: nil, conversation_session_id: nil, episode: nil,
                    results_count: nil, contexts_delivered: nil, evidence_applicability: nil)
      status = applied.status if applied && status.nil?
      reason = applied.reason if applied && reason.nil?
      result = status&.to_s.presence || reason&.to_s.presence
      PilotUsageLog.log(
        "document_identity_scope",
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        episode_id: episode_identifier(episode),
        manufacturer: manufacturer_of(identity),
        model: model_of(identity),
        identity_after: compact_facts(identity),
        scope_needles: needles_of(identity),
        identity_conflict: conflict?(applied, reason),
        result: result,
        outcome_reason: reason&.to_s.presence,
        results_count: results_count,
        contexts_delivered: contexts_delivered,
        evidence_applicability: evidence_applicability
      )
    rescue StandardError => error
      Rails.logger.warn("document_identity_scope telemetry failed #{error.class}")
    end

    def self.episode_identifier(episode)
      return nil if episode.nil?
      return episode.episode_id if episode.respond_to?(:episode_id)
      return episode["episode_id"] || episode[:episode_id] if episode.respond_to?(:[])

      nil
    end
    private_class_method :episode_identifier

    def self.manufacturer_of(identity)
      return nil unless identity.is_a?(EquipmentIdentity)

      identity.manufacturer.presence
    end
    private_class_method :manufacturer_of

    def self.model_of(identity)
      return nil unless identity.is_a?(EquipmentIdentity)

      identity.facts.find { |fact| fact["slot"] == "model" }&.dig("value").presence
    end
    private_class_method :model_of

    def self.compact_facts(identity)
      return "none" unless identity.is_a?(EquipmentIdentity)

      parts = identity.facts.filter_map do |fact|
        next unless %w[manufacturer model].include?(fact["slot"])

        value = fact["value"].to_s
        next if value.blank?

        "#{fact['slot']}:#{value}:#{fact['source']}"
      end
      parts.presence&.join("|") || "none"
    end
    private_class_method :compact_facts

    def self.needles_of(identity)
      return [] unless identity.is_a?(EquipmentIdentity)

      DocumentIdentityScope.needles(identity)
    end
    private_class_method :needles_of

    def self.conflict?(applied, reason)
      reason.to_s == "conflicting_current_identity" || Array(applied&.excluded_labels).any?
    end
    private_class_method :conflict?
  end
end
