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
    MANEUVER_CONFIRMED = /\b(?:la maniobra se completa|la puerta complet[oó] el cierre)\b/i
    CURRENT_TEST_CLEAR = /\b(?:sigue sin mostrar|no volvi[oó] a aparecer durante la prueba)\b/i
    FAULT_RECHECK = /\b(?:no vuelve a aparecer|sigue sin aparecer|vuelve a aparecer|persiste)\z/
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

      def without_redundant_followup(text, episode:, turn:, correlation_id:, locale:)
        question = PendingQuestion.followup_line(text, locale: locale)
        return text unless question

        parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
        part = completed_main_part(parsed, correlation_id)
        return text unless part

        normalized_question = FollowupQueryRewriter.normalize_label(question)
        redundant = if normalized_question.match?(INTERVENTION_DETAIL)
          report_clauses(part["text"], turn).present?
        elsif turn.match?(MANEUVER_CONFIRMED) && turn.match?(CURRENT_TEST_CLEAR)
          repeat_fault_check?(parsed, normalized_question, turn) || unavailable_check_repeated?(parsed, normalized_question, correlation_id)
        end
        return text unless redundant

        position = text.rindex(question)
        before = text[...position].sub(
          /(?:\A|(?<=[.!?])\s+|\n)[ \t]*(?:\*\*)?(?:pregunta|comprobaci[oó]n)(?::\*\*|\*\*:|:)[^.!?¿\n]*\z/i, ""
        )
        trimmed = "#{before.rstrip}#{text[(position + question.length)..]}".strip
        return text if trimmed.blank?

        ValidationCapture.record("companion_closure_followup_removed", "question" => question)
        trimmed
      end

      private

      def completed_main_part(episode, correlation_id)
        return unless AnswerContract.active?(episode) && correlation_id.present?

        parts = Array(episode.pending_question&.dig("parts"))
        part = parts.first if parts.one?
        return unless part && part["role"] == "main"

        id = part.fetch("id")
        return unless AnswerContract.part_state(episode, id) == "complete"
        return unless AnswerContract.current_replies(episode, id).any? { |reply| reply["cid"] == correlation_id }

        part
      end

      def repeat_fault_check?(episode, question, turn)
        fact = episode.fact("fault_code")
        fault = fact&.dig("value")
        if fact&.dig("status") == "absent_confirmed"
          fault = turn[/\bsigue sin mostrar\s+([A-Z][A-Z\d-]{1,9})\b/, 1]
        end
        return false if fault.blank? || !question.match?(FAULT_RECHECK)

        question.match?(/\A(?:el )?#{Regexp.escape(normalized(fault))}\b/)
      end

      def unavailable_check_repeated?(episode, question, correlation_id)
        return false unless question.start_with?("puedes ver el estado de ", "puede ver el estado de ")

        episode.checks.any? do |check|
          next false unless check["status"] == "not_done" && check["correlation_id"] == correlation_id

          subject = FollowupQueryRewriter.normalize_label(check["subject"])
          subject.present? && question.match?(/\bestado de #{Regexp.escape(subject)}\b/)
        end
      end

      def report_clauses(question, turn)
        asked = question.to_s.strip
        return unless asked.start_with?("¿") && asked.end_with?("?")

        asked = asked.delete_prefix("¿").delete_suffix("?")
        reported = turn.to_s.strip.sub(AFFIRMATION, "").sub(ATTRIBUTION, "").delete_suffix(".")
        return if [ asked, reported ].any? { |text| text.match?(/[¿?!«»“”"]/) }

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
