# frozen_string_literal: true

module Rag
  # Bounded identity for one retrieval turn. Photo turns carry the N2
  # snapshot. Text turns derive one from the live episode. The object is
  # not a compatibility decision and it is not a catalog.
  class EquipmentIdentity
    attr_reader :manufacturer, :needles, :facts

    def self.from_episode(episode)
      return nil if episode.nil?

      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      facts = []
      %w[manufacturer model].each do |slot|
        fact = parsed.fact(slot)
        next unless known_needle_fact?(fact)

        facts << fact_row(slot, fact)
      end
      Array(parsed.identifiers).each do |item|
        next unless item.is_a?(Hash)
        next unless DocumentIdentityScope::NEEDLE_SOURCES.include?(item["source"].to_s)
        next if item["value"].blank?

        facts << {
          "slot" => "identifier",
          "value" => item["value"].to_s.strip,
          "source" => item["source"].to_s,
          "correlation_id" => item["correlation_id"].to_s
        }
      end
      return nil if facts.empty?

      new(
        manufacturer: facts.find { |fact| fact["slot"] == "manufacturer" }&.dig("value"),
        needles: facts.pluck("value").uniq,
        facts: facts
      )
    end

    def self.known_needle_fact?(fact)
      return false unless fact.is_a?(Hash)
      return false unless fact["status"] == "known" && fact["value"].present?
      return false unless DocumentIdentityScope::NEEDLE_SOURCES.include?(fact["source"].to_s)

      true
    end
    private_class_method :known_needle_fact?

    def self.fact_row(slot, fact)
      {
        "slot" => slot,
        "value" => fact["value"].to_s.strip,
        "source" => fact["source"].to_s,
        "correlation_id" => fact["correlation_id"].to_s
      }
    end
    private_class_method :fact_row

    def initialize(manufacturer:, needles:, facts:)
      @manufacturer = manufacturer
      @needles = Array(needles).map(&:to_s).freeze
      @facts = Array(facts).map { |fact| fact.to_h.stringify_keys.freeze }.freeze
      freeze
    end

    # Known for the required policy when a user or photo fact names a
    # manufacturer or a model. Controller, fault code, catalog, and a bare
    # identifier are not enough.
    def known?
      facts.any? do |fact|
        %w[manufacturer model].include?(fact["slot"]) &&
          DocumentIdentityScope::NEEDLE_SOURCES.include?(fact["source"]) &&
          fact["value"].present?
      end
    end
  end
end
