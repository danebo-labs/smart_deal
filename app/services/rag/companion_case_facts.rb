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

    attr_reader :facts

    def self.build(episode, session: nil)
      new(episode, session)
    end

    def initialize(episode, session)
      @facts = []
      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      return if parsed.nil? || parsed.blank?

      goal = parsed.goal&.[]("text").to_s.squish
      add("G", "goal", goal, correlation_id: parsed.goal&.[]("correlation_id")) if goal.present?
      SessionContextBuilder.companion_identity(parsed).split(", ").each { |value| add("I", "identity", value) }
      SessionContextBuilder.companion_observations(parsed).each do |item|
        add("O", "observation", item["text"].to_s.squish, correlation_id: item["correlation_id"], literal: true, answers: item["answers"])
      end
      Array(parsed.checks).each do |item|
        next unless item.is_a?(Hash) && item["subject"].present?

        span = SessionContextBuilder.companion_report_span(session, item)
        literal = span[:kind] == :original
        done = item["status"].to_s == "done"
        text = literal ? span[:text] : [ item["subject"], item["result"] ].compact_blank.join(": ")
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
      return "" if @facts.empty?

      lines = [ "Caso (estado actual, dicho por el técnico; no es documentación):" ]
      @facts.each do |fact|
        lines << prompt_line(fact)
      end
      lines.join("\n")
    end

    private

    def prompt_line(fact)
      if fact.kind == "observation" && fact.answers.is_a?(Hash) && fact.answers["q"].present?
        return "#{fact.id} [respuesta del técnico a «#{fact.answers['q']}»]: «#{answer_words(fact)}»."
      end

      detail = fact.kind == "done_check" && fact.result.present? ? " Resultado: «#{fact.result}»." : ""
      "#{fact.id} [#{KIND_LABEL.fetch(fact.kind)}]: «#{fact.text.sub(/\.\z/, '')}».#{detail}"
    end

    def answer_words(fact)
      case fact.answers["r"]
      when "yes" then "sí"
      when "no" then "no"
      when "unknown" then "no sé"
      else fact.text.sub(/\.\z/, "")
      end
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
