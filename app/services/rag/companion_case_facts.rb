# frozen_string_literal: true

module Rag
  # The current case as numbered facts. Each fact keeps its kind, so an
  # observation is never a check and a reported "not done" is never a task.
  # text is the technician's own sentence when one is found, else the stored
  # value. The episode is read, not changed.
  class CompanionCaseFacts
    Fact = Data.define(:id, :kind, :text, :subject, :result, :correlation_id, :literal, :answers) do
      def done_check?
        kind == "done_check"
      end
    end

    KIND_LABEL = {
      "goal" => "objetivo del técnico",
      "identity" => "identidad del equipo",
      "observation" => "observación del técnico",
      "done_check" => "comprobación que el técnico dice haber hecho",
      "not_done_check" => "comprobación que el técnico dice no haber hecho"
    }.freeze

    attr_reader :facts, :open_question

    def self.build(episode, session: nil)
      new(episode, session)
    end

    def initialize(episode, session)
      @facts = []
      @session = session
      @episode_record = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      parsed = @episode_record
      return if parsed.nil? || parsed.blank?

      pending = parsed.pending_question
      if pending.is_a?(Hash) && pending["type"] == "documented_context" &&
          pending["aspect"] != "scope" && pending["question"].present? &&
          open_contract_question?(pending, parsed)
        @open_question = pending
      end

      goal = parsed.goal&.[]("text").to_s.squish
      add("G", "goal", goal, correlation_id: parsed.goal&.[]("correlation_id")) if goal.present?
      SessionContextBuilder.companion_identity(parsed).split(", ").each { |value| add("I", "identity", value) }
      SessionContextBuilder.companion_observations(parsed).each do |item|
        text = without_replaced_led(item["text"].to_s, parsed)
        add("O", "observation", text.squish, correlation_id: item["correlation_id"], literal: true, answers: item["answers"])
      end
      Array(parsed.checks).each do |item|
        next unless item.is_a?(Hash) && item["subject"].present?

        span = SessionContextBuilder.companion_report_span(session, item)
        literal = span[:kind] == :original
        done = item["status"].to_s == "done"
        source = literal ? span[:text] : [ item["subject"], item["result"] ].compact_blank.join(": ")
        text = without_replaced_led(source, parsed)
        add(done ? "C" : "N", done ? "done_check" : "not_done_check", text.to_s.squish,
            subject: item["subject"].to_s.squish, result: item["result"].to_s.squish.presence,
            correlation_id: item["correlation_id"], literal: literal)
      end
    end

    def find(id)
      @facts.find { |fact| fact.id == id.to_s }
    end

    def goal
      @facts.find { |fact| fact.kind == "goal" }
    end

    def prompt_block
      lines = @episode_record ? AnswerContract.context_lines(@episode_record, @session) : []
      return "" if @facts.empty? && lines.empty?

      body = []
      if @facts.any?
        body << "Caso (estado actual, dicho por el técnico; no es documentación):"
        @facts.each { |fact| body << prompt_line(fact) }
      end
      body.concat(lines)
      body.join("\n")
    end

    def settled_part?(part_id)
      return false if @episode_record.nil? || @episode_record.blank?

      AnswerContract::SETTLED.include?(AnswerContract.part_state(@episode_record, part_id))
    end

    def settled_question?(question_id)
      question = @episode_record&.pending_question
      return false unless question.is_a?(Hash) && question["id"].to_s == question_id.to_s

      parts = Array(question["parts"]).select { |part| part.is_a?(Hash) && part["id"].present? }
      return false if parts.empty?

      parts.all? { |part| settled_part?(part["id"]) }
    end

    # Published wording of parts closed as complete or unknown. Partial and
    # contradictory stay out. Legacy episodes are not this contract.
    def settled_part_texts
      episode = @episode_record
      return [] unless episode && AnswerContract.active?(episode)

      question = episode.pending_question
      return [] unless question.is_a?(Hash)

      Array(question["parts"]).filter_map { |part|
        next unless part.is_a?(Hash)

        text = part["text"].to_s
        next if text.blank?
        next unless AnswerContract.settled?(AnswerContract.part_state(episode, part["id"]))

        text
      }
    end

    private

    def prompt_line(fact)
      if fact.kind == "observation" && fact.answers.is_a?(Hash) && fact.answers["q"].present?
        if fact.answers["aspect"] == "scope" && fact.answers["about"].present?
          return "#{fact.id} [alcance de «#{fact.answers['about']}», no es una comprobación completa]: «#{fact.text.sub(/\.\z/, '')}»."
        end

        return "#{fact.id} [respuesta del técnico a «#{fact.answers['q']}»]: «#{answer_words(fact)}»."
      end

      detail = fact.kind == "done_check" && fact.result.present? ? " Resultado: «#{fact.result}»." : ""
      "#{fact.id} [#{KIND_LABEL.fetch(fact.kind)}]: «#{fact.text.sub(/\.\z/, '')}».#{detail}"
    end

    def answer_words(fact)
      return fact.text.sub(/\.\z/, "") if fact.answers["contract"] == "ref"

      case fact.answers["r"]
      when "yes" then "sí"
      when "no" then "no"
      when "unknown" then "no sé"
      else fact.text.sub(/\.\z/, "")
      end
    end

    def open_contract_question?(pending, episode)
      return true if pending["id"].blank? || !pending["parts"].is_a?(Array) || pending["parts"].empty?

      AnswerContract.open_parts(episode).any?
    end

    # A stored sentence can still name the LED state the technician replaced.
    # The history keeps that sentence. The current fact does not.
    def without_replaced_led(text, episode)
      clauses = text.to_s.split(/\s+y\s+/i).map(&:squish).reject { |clause|
        replaced_led_clause?(clause, episode)
      }
      clauses.join(" y ")
    end

    def replaced_led_clause?(clause, episode)
      return false if ObservationCorrection.led_contrast(clause)

      state = ObservationCorrection.led_state(clause)
      return false if state.blank?

      qualifier = clause.to_s.squish[ObservationCorrection::LED_QUALIFIED, 1]
      Array(episode.observations).any? { |item|
        text = item["text"].to_s
        next false if ObservationCorrection.led_contrast(text)

        found = ObservationCorrection.led_state(text)
        next false if found.blank? || found.casecmp?(state)

        item_qualifier = text.squish[ObservationCorrection::LED_QUALIFIED, 1]
        qualifier.blank? || item_qualifier.blank? || qualifier.casecmp?(item_qualifier)
      }
    end

    def add(prefix, kind, text, subject: nil, result: nil, correlation_id: nil, literal: false, answers: nil)
      return if text.blank?

      number = @facts.count { |fact| fact.id.start_with?(prefix) } + 1
      @facts << Fact.new(
        id: "#{prefix}#{number}", kind: kind, text: text, subject: subject, result: result,
        correlation_id: correlation_id.to_s.presence, literal: literal, answers: answers.is_a?(Hash) ? answers : nil
      )
    end
  end
end
