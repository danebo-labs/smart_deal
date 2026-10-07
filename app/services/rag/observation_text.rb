# frozen_string_literal: true

module Rag
  # Exact copies and continuity echoes ("Sigue igual") add no new check.
  # Sharing a token does not make two observations the same: a changed
  # negation, place, condition, or result stays.
  module ObservationText
    STATUS_WORDS = %w[igual same unchanged cambio cambios].freeze
    FILLER_WORDS = %w[sigue aun continua todavia sin].freeze

    module_function

    def normalize(text)
      FollowupQueryRewriter.normalize_label(text)
    end

    def continuity_echo?(text)
      words = normalize(text).split
      return false if words.empty?
      return false unless words.all? { |word| STATUS_WORDS.include?(word) || FILLER_WORDS.include?(word) }

      words.any? { |word| STATUS_WORDS.include?(word) }
    end

    def redundant?(text, existing_labels)
      label = normalize(text)
      return true if label.blank? || continuity_echo?(text)
      return true if Array(existing_labels).include?(label)

      trailing_echo?(text, existing_labels)
    end

    def trailing_echo?(text, labels)
      label = normalize(text)
      stripped = label.sub(/\s+(?:sigue igual|sin cambios|sin cambio)\z/, "")
      return false if stripped == label || stripped.blank?

      Array(labels).include?(stripped)
    end

    def covered_by?(container, text)
      phrase = normalize(text)
      holder = normalize(container)
      return false if phrase.blank? || holder.blank?

      holder.match?(/(?<![[:alnum:]])#{Regexp.escape(phrase)}(?![[:alnum:]])/)
    end
  end
end
