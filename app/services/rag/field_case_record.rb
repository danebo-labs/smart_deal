# frozen_string_literal: true

module Rag
  # Spanish case line shown with a document-identity answer.
  # Copies the episode. Does not fill a missing check result and does not
  # list the manual. The returned history text is the answer without this line.
  class FieldCaseRecord
    DOCUMENT_IDENTITY = "document_identity_scope"
    Attachment = Data.define(:presented, :history)

    class << self
      def attach(answer, episode:, generation_mode:)
        text = answer.to_s
        record = render(episode, generation_mode: generation_mode)
        return Attachment.new(presented: text, history: nil) if record.empty?

        presented = text.strip.empty? ? record : "#{record}\n\n#{text}"
        Attachment.new(presented: presented, history: text)
      end

      def render(episode, generation_mode:)
        return "" unless generation_mode.to_s == DOCUMENT_IDENTITY
        return "" if episode.nil? || episode.blank? || episode.status != "active"
        return "" if episode.observations.blank? && episode.checks.blank?

        clauses = [ "Registro del caso." ]
        equipment = equipment_clause(episode)
        clauses << "Equipo: #{equipment}." if equipment
        goal = episode.goal&.[]("text").to_s.squish
        clauses << "Síntoma: #{quote(goal)}." if goal.present?
        observations = SessionContextBuilder.case_observations(episode)
        if observations.any?
          clauses << "Observaciones: #{observations.map { |item| quote(item) }.join(', ')}."
        end
        checks = check_clause(episode)
        clauses << "Comprobaciones: #{checks}." if checks
        clauses.join(" ")
      end

      private

      def equipment_clause(episode)
        values = []
        %w[manufacturer model].each do |key|
          fact = episode.fact(key)
          next unless fact.is_a?(Hash) && fact["status"] == "known"
          next unless %w[user catalog].include?(fact["source"].to_s)

          value = fact["value"].to_s.squish
          values << value if value.present?
        end
        Array(episode.identifiers).each do |item|
          next unless item.is_a?(Hash)

          source = item["source"].to_s
          next unless source.empty? || source == "user"

          value = item["value"].to_s.squish
          values << value if value.present?
        end
        values.uniq.reject { |value| covered_by_longer?(value, values) }.join(", ").presence
      end

      def covered_by_longer?(value, values)
        values.any? { |other| other != value && ObservationText.covered_by?(other, value) }
      end

      def check_clause(episode)
        fragments = Array(episode.checks).filter_map { |item| check_fragment(item) }
        fragments.join("; ").presence
      end

      def check_fragment(item)
        return nil unless item.is_a?(Hash)

        subject = item["subject"].to_s.squish
        return nil if subject.empty?

        case item["status"].to_s
        when "not_done"
          "#{subject}, sin hacer"
        when "done"
          result = item["result"].to_s.squish
          result.empty? ? "#{subject}, hecha, sin resultado registrado" : "#{subject}, hecha, #{quote(result)}"
        end
      end

      def quote(text)
        "«#{text}»"
      end
    end
  end
end
