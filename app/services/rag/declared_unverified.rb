# frozen_string_literal: true

module Rag
  # Stage 1, FIELD_CHECK_OUTCOME. The technician said a check was not done or
  # could not be verified. The generator is told not to ask it again, and a
  # model can still do it (live run 20261120T012019Z, T6 asked for DCL after
  # three declarations). This is the deterministic control on the two places
  # the question could survive: the published text and the stored pending.
  #
  # A question repeats a declared datum when every signal or label it names
  # (an upper-case code such as DCL) is one the technician declared unverified
  # and has not reported on since. A later report that names the code without
  # a negation is the new reason to ask again. A question that also names a
  # code nobody declared is left alone. A text that is only that question is
  # kept: the control never publishes nothing.
  #
  # It reads the episode only: the checks stored as not done, and the
  # observations, which keep the order of the turns.
  class DeclaredUnverified
    CODE = /(?<![[:alnum:]])[A-Z][A-Z0-9]{1,5}(?![[:alnum:]])/
    NEGATION = /(?<![[:alnum:]])(?:no|ni|sin|nunca|tampoco|todavia|aun|not|yet)(?![[:alnum:]])/
    LABEL_TAIL = /(?:\*\*)?(?:pregunta|comprobaci[oó]n)(?::\*\*|\*\*:|:)[ \t]*\z/i

    Result = Data.define(:text, :question, :dropped)

    class << self
      # The declared codes still unverified. Empty when nothing was declared.
      def open_codes(episode)
        parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
        return [] if parsed.nil? || parsed.blank?

        observations = Array(parsed.observations).select { |row| row.is_a?(Hash) }
        Array(parsed.checks).select { |row| row.is_a?(Hash) && row["status"].to_s == "not_done" }.flat_map { |check|
          # Codes as the technician typed them: a lower-case word is not one.
          declared = check["subject"].to_s.scan(CODE).map(&:downcase).uniq
          declared.reject { |word| reported_since?(word, check, observations) }
        }.uniq
      end

      def repeated_question?(question, episode)
        codes = question.to_s.scan(CODE).map(&:downcase).uniq
        return false if codes.empty?

        (codes - open_codes(episode)).empty?
      end

      def without_repeated_question(text, episode:, locale: I18n.locale)
        question = PendingQuestion.question_in(text, locale: locale)
        return Result.new(text: text, question: nil, dropped: false) if question.blank?
        return Result.new(text: text, question: question, dropped: false) unless repeated_question?(question, episode)

        trimmed = remove(text, question)
        return Result.new(text: text, question: question, dropped: false) if trimmed.blank?

        ValidationCapture.record("companion_declared_unverified", "question" => question, "codes" => open_codes(episode)) if ValidationCapture.active?
        Result.new(text: trimmed, question: question, dropped: true)
      end

      private

      def remove(text, question)
        at = text.rindex(question)
        return text if at.nil?

        before = text[...at].sub(LABEL_TAIL, "").rstrip
        after = text[(at + question.length)..].to_s
        joined = after.start_with?("\n") || after.empty? ? "#{before}#{after}" : "#{before} #{after.lstrip}"
        joined.gsub(/\n{3,}/, "\n\n").strip
      end

      def reported_since?(word, check, observations)
        declared_at = observations.rindex { |row| row["correlation_id"] == check["correlation_id"] } || -1
        observations.each_with_index.any? do |row, index|
          index > declared_at && row["correlation_id"] != check["correlation_id"] &&
            words_of(row["text"]).include?(word) && !negated?(row["text"])
        end
      end

      def negated?(text)
        fold(text).match?(NEGATION)
      end

      def words_of(text)
        fold(text).scan(/[a-z0-9]+/)
      end

      def fold(text)
        I18n.transliterate(text.to_s).downcase
      end
    end
  end
end
