# frozen_string_literal: true

module Rag
  # Technician text for a local Journey A validation. RagController does not
  # call this. Each fixture turn keeps its own facts. An extra question is
  # answered only when this turn already states it, or with "No lo sé." when
  # the fixture has no answer. It does not pull a later turn's fact forward,
  # and it does not invent where a click comes from.
  class JourneyAMessages
    UNKNOWN = "No lo sé."

    def self.adapt(turn_number:, original:, previous_answer:)
      new(turn_number: turn_number, original: original, previous_answer: previous_answer).adapt
    end

    def initialize(turn_number:, original:, previous_answer:)
      @turn_number = turn_number.to_i
      @original = original.to_s
      @previous_answer = previous_answer.to_s
    end

    def adapt
      sent = @original.dup
      notes = []
      question = last_question
      if spontaneous_click?(sent)
        sent = "Sigue el clic y la puerta no termina de cerrar."
        notes << "spontaneous_click"
      end
      if unanswered_precision?(question) && !sent.match?(/\bno lo s[eé]\b/i)
        sent = "#{sent} #{UNKNOWN}"
        notes << "unknown"
      end
      [ sent.squish, notes, question ]
    end

    private

    def spontaneous_click?(sent)
      @turn_number == 11 && sent.include?("esa revisión") &&
        !@previous_answer.match?(/clic|gu[ií]a|LED\s*7|obstrucci[oó]n|revis/i)
    end

    def last_question
      @previous_answer.split(/(?<=[.!?])\s+/).reverse.find { |part| part.include?("?") }&.strip
    end

    def unanswered_precision?(question)
      text = I18n.transliterate(question.to_s).downcase
      return false if text.blank?
      return true if text.match?(/proviene|de donde|origen del|suena en|en relacion/)
      return true if text.match?(/significa|quiere decir/)
      return true if text.match?(/indica/) && text.match?(/led|codigo|placa|display/)
      return true if text.match?(/tension|voltaje|terminal|borne/)

      false
    end
  end
end
