# frozen_string_literal: true

module Rag
  # Binds an explicit report to one conjunctive check when every proposition
  # can be matched. Keep the wording within each clause, including polarity and values.
  class CompoundCheckReply
    AFFIRMATION = /\Así[.,:]\s*/i
    ATTRIBUTION = /\A(?:(?:el|la)\s+\p{L}+\s+(?:confirmó|comprobó|verificó|constató|informó|indicó)|confirmo|comprobé|verifiqué|constaté)\s+que\s+/i
    CLAUSE_BREAK = /[.,;]\s+|\s+[ye]\s+/i
    INVERTED = /\A((?:se )?\p{L}+) ((?:el|la|los|las) .+)\z/
    DETERMINER = /\b(?:el|la|los|las)\b/
    INTERVENTION_DETAIL = /
      \b(?:que|como)\s+(?:se\s+)?(?:repar|ajust|reemplaz|sustituy|corrig|intervin)(?:o|aron|aste|ieron|iste)\b |
      \A(?:que|cual)\s+(?:fue\s+)?(?:(?:el|la)\s+)?(?:intervencion|reparacion|ajuste)\b |
      \bdetalles?\s+d(?:e(?:\s+la)?|el)\s+(?:intervencion|reparacion|ajuste)\b
    /x.freeze

    class << self
      def recover(episode, turn, checks:, observations:)
        parts = AnswerContract.open_parts(episode)
        part = parts.first if parts.one?
        return unless part && part["role"] == "main" && AnswerContract.part_state(episode, part["id"]).nil?

        reported = report_clauses(part["text"], turn)
        return unless reported && checks.all? { |check| check_carries_result?(check) }

        checked = checks.map { |check| normalized(check["subject"]) }
        return unless (checked - reported).empty?
        return unless (reported - checked - observations.map { |text| normalized(text) }).empty?

        {
          "question_id" => episode.pending_question.fetch("id"), "part_id" => part.fetch("id"),
          "state" => "complete", "quote" => turn
        }
      end

      def without_intervention_followup(text, episode:, turn:, correlation_id:, locale:)
        question = PendingQuestion.followup_line(text, locale: locale)
        return text unless question && FollowupQueryRewriter.normalize_label(question).match?(INTERVENTION_DETAIL)
        return text unless confirmed_now?(episode, turn, correlation_id)

        position = text.rindex(question)
        before = text[...position].sub(/(?:\A|\n)[ \t]*(?:\*\*)?[^.!?:¿?\n]{1,45}(?::\*\*|\*\*:|:)[ \t]*\z/, "")
        trimmed = "#{before.rstrip}#{text[(position + question.length)..]}".strip
        return text if trimmed.blank?

        ValidationCapture.record("companion_closure_followup_removed", "question" => question)
        trimmed
      end

      private

      def confirmed_now?(episode, turn, correlation_id)
        parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
        return false unless AnswerContract.active?(parsed) && correlation_id.present?

        parts = Array(parsed.pending_question&.dig("parts"))
        return false unless parts.one? && parts.first["role"] == "main"

        id = parts.first.fetch("id")
        return false unless AnswerContract.part_state(parsed, id) == "complete"

        AnswerContract.current_replies(parsed, id).any? { |reply| reply["cid"] == correlation_id } &&
          report_clauses(parts.first["text"], turn).present?
      end

      def report_clauses(question, turn)
        asked = question.to_s.strip
        return unless asked.start_with?("¿") && asked.end_with?("?")

        asked = asked.delete_prefix("¿").delete_suffix("?")
        reported = turn.to_s.strip.sub(AFFIRMATION, "").sub(ATTRIBUTION, "").delete_suffix(".")
        return if [asked, reported].any? { |text| text.match?(/[¿?!«»“”"]/) }

        wanted = clauses(asked)
        supplied = clauses(reported)
        return unless wanted.size >= 2 && supplied.size == wanted.size && supplied.uniq == supplied
        matches = wanted.map { |expected| supplied.select { |actual| same_clause?(expected, actual) } }
        return unless matches.all?(&:one?) && matches.flatten.uniq.size == supplied.size

        supplied
      end

      def clauses(text)
        text.split(CLAUSE_BREAK).map { |clause| normalized(clause) }
      end

      def same_clause?(expected, actual)
        return true if expected == actual

        inverted = INVERTED.match(expected)
        return false unless inverted

        predicate, rest = inverted.captures
        match = /(?<!\S)#{Regexp.escape(predicate)}(?!\S)/.match(actual)
        return false unless match

        subject = match.pre_match.strip
        subject.match?(/\A(?:el|la|los|las) /) && subject.scan(DETERMINER).one? &&
          "#{match.pre_match}#{match.post_match}".squish == rest
      end

      def check_carries_result?(check)
        return false unless check["status"] == "done" && check["result"].present?

        normalized(check["subject"]).match?(/(?<!\S)#{Regexp.escape(normalized(check["result"]))}(?!\S)/)
      end

      def normalized(text)
        TurnPerception.normalize_span_text(text)
      end
    end
  end
end
