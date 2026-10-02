# frozen_string_literal: true

module Rag
  # Post-photo retrieval fields. Reads the episode and the accepted
  # observation already in hand. Does not write the episode, does not
  # call a model, and does not retrieve.
  class PhotoRetrievalSnapshot
    Result = Data.define(:equipment_identity, :retrieval_question)
    IDENTITY_SLOTS = %w[manufacturer model].freeze
    WORK_SLOTS = %w[fault_code controller].freeze
    RELIABLE_SOURCES = %w[user photo].freeze
    EPHEMERAL_RELEVANCE = [ nil, "relevant", "uncertain" ].freeze
    Part = Struct.new(:text, :kind)

    def self.capture(episode:, question:, observation:, correlation_id:)
      observation = observation.to_h.stringify_keys
      tied = question.to_s.squish.present?
      identity = build_identity(
        episode: episode, observation: observation, question_tied: tied, correlation_id: correlation_id
      )
      Result.new(
        equipment_identity: identity,
        retrieval_question: compose_question(
          episode: episode, question: question, identity: identity
        )
      )
    end

    def self.build_identity(episode:, observation:, question_tied:, correlation_id:)
      rows = []
      IDENTITY_SLOTS.each do |slot|
        fact = known_fact(episode, slot)
        push_fact(rows, slot: slot, value: fact&.dig("value"), source: fact&.dig("source"), correlation_id: fact&.dig("correlation_id"))
      end
      if ephemeral_photo?(observation, question_tied)
        IDENTITY_SLOTS.each do |slot|
          next if rejected?(episode, slot, observation[slot])

          push_fact(rows, slot: slot, value: observation[slot], source: "photo", correlation_id: correlation_id)
        end
      end
      return nil if rows.empty?

      EquipmentIdentity.new(
        manufacturer: rows.find { |row| row["slot"] == "manufacturer" }&.dig("value"),
        needles: rows.pluck("value").uniq,
        facts: rows
      )
    end
    private_class_method :build_identity

    def self.ephemeral_photo?(observation, question_tied)
      return false unless question_tied
      return false if observation.blank?

      EPHEMERAL_RELEVANCE.include?(observation["relevance_to_goal"])
    end
    private_class_method :ephemeral_photo?

    def self.known_fact(episode, slot)
      return nil if episode.nil?

      fact = episode.fact(slot)
      return nil unless fact.is_a?(Hash) && fact["status"] == "known"
      return nil unless RELIABLE_SOURCES.include?(fact["source"].to_s)
      return nil if rejected?(episode, slot, fact["value"])

      fact
    end
    private_class_method :known_fact

    def self.push_fact(rows, slot:, value:, source:, correlation_id:)
      text = usable(value)
      return if text.nil? || source.blank?
      return if rows.any? { |row| row["slot"] == slot && same_label?(row["value"], text) }

      rows << {
        "slot" => slot,
        "value" => text,
        "source" => source.to_s,
        "correlation_id" => correlation_id.to_s
      }
    end
    private_class_method :push_fact

    def self.compose_question(episode:, question:, identity:)
      literal = TurnText.truncate(question.to_s.squish)
      return nil if literal.blank?

      parts = [ Part.new(literal, :literal) ]
      push_part(parts, goal_text(episode), :goal)
      WORK_SLOTS.each do |slot|
        fact = known_fact(episode, slot)
        push_part(parts, fact&.dig("value"), slot.to_sym)
      end
      observation_texts(episode).each { |text| push_part(parts, text, :observation) }
      Array(identity&.facts).each { |fact| push_part(parts, fact["value"], :identity) }
      fit(parts)
    end
    private_class_method :compose_question

    def self.goal_text(episode)
      return nil if episode.nil?

      text = episode.goal.is_a?(Hash) ? episode.goal["text"] : nil
      return nil if rejected_values(episode).any? { |value| text.to_s.downcase.include?(value.downcase) }

      usable(text)
    end
    private_class_method :goal_text

    def self.observation_texts(episode)
      return [] if episode.nil?

      rejected = rejected_values(episode)
      Array(episode.observations).filter_map { |item|
        text = item.is_a?(Hash) ? item["text"] : nil
        next if text.blank? || rejected.any? { |value| text.downcase.include?(value.downcase) }

        text
      }.last(ActiveEpisode::MAX_OBSERVATIONS)
    end
    private_class_method :observation_texts

    def self.push_part(parts, text, kind)
      clause = usable(text)
      return if clause.nil?
      return if parts.any? { |part| same_label?(part.text, clause) }

      parts << Part.new(clause, kind)
    end
    private_class_method :push_part

    # Observations, then fault_code and controller, then the literal turn.
    # Goal and accepted identity stay until the string is still over the
    # composer cap, and then the tail is cut.
    def self.fit(parts)
      limit = FollowupQueryRewriter::MAX_COMPOSED_CHARS
      while joined(parts).length > limit
        index = drop_index(parts)
        if index
          parts.delete_at(index)
          next
        end

        literal = parts.index { |part| part.kind == :literal }
        if literal && parts[literal].text.length > 1
          overflow = joined(parts).length - limit
          parts[literal].text = parts[literal].text[0, parts[literal].text.length - [ overflow, 1 ].max].to_s.rstrip
          parts.delete_at(literal) if parts[literal].text.blank?
          next
        end

        break
      end

      text = joined(parts)
      text = text.truncate(limit, omission: "") if text.length > limit
      text.presence
    end
    private_class_method :fit

    def self.drop_index(parts)
      %i[observation controller fault_code].each do |kind|
        index = parts.index { |part| part.kind == kind }
        return index if index
      end
      nil
    end
    private_class_method :drop_index

    def self.joined(parts)
      parts.map(&:text).compact_blank.join(" ")
    end
    private_class_method :joined

    def self.rejected?(episode, slot, value)
      label = FollowupQueryRewriter.normalize_label(value)
      Array(episode&.rejected).any? { |item|
        item["slot"] == slot && FollowupQueryRewriter.normalize_label(item["value"]) == label
      }
    end
    private_class_method :rejected?

    def self.rejected_values(episode)
      Array(episode&.rejected).filter_map { |item| item["value"].presence }
    end
    private_class_method :rejected_values

    def self.usable(value)
      text = value.to_s.squish
      return nil if text.blank? || text.casecmp("unknown").zero?

      text
    end
    private_class_method :usable

    def self.same_label?(left, right)
      FollowupQueryRewriter.normalize_label(left) == FollowupQueryRewriter.normalize_label(right)
    end
    private_class_method :same_label?
  end
end
