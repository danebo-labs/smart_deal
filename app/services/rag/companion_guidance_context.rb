# frozen_string_literal: true

module Rag
  # User context for one generation when equipment is known and no compatible
  # manufacturer body was retrieved. The model writes the next diagnostic
  # step. This object only bounds the facts that generation and answer
  # safety are allowed to see.
  class CompanionGuidanceContext
    MAX_CHARS = 2400
    QUESTION_CHARS = 400
    TURN_CHARS = 160
    MAX_TURNS = 2
    MAX_MANUALS = 3
    PHOTO_HEADING = "## Photo Evidence (this turn)"
    PROBLEM_HEADING = "## Active Field Problem"
    FIELD_LABELS = {
      "Component" => "component",
      "Manufacturer" => "manufacturer",
      "Model" => "model",
      "Subsystem" => "subsystem",
      "Visible text/codes" => "visible_text",
      "Condition" => "condition"
    }.freeze

    def self.build(question:, identity:, session_context:, labels:, locale:, mode: :known, manuals: nil)
      new(
        question: question,
        identity: identity,
        session_context: session_context,
        labels: labels,
        locale: locale,
        mode: mode,
        manuals: manuals
      )
    end

    # Name and page only. Chunk bodies stay out of the unknown-identity prompt.
    def self.withheld_manuals(chunks)
      Array(chunks).filter_map { |chunk|
        metadata = chunk[:metadata].to_h.stringify_keys
        name = metadata["canonical_name"].presence || metadata["original_filename"].presence
        next if name.blank? || name == "DATA_NOT_AVAILABLE"

        page = metadata["page_number"].presence
        page.present? ? "#{name}, p. #{page}" : name
      }.uniq.first(MAX_MANUALS)
    end

    def initialize(question:, identity:, session_context:, labels:, locale:, mode: :known, manuals: nil)
      @question = question.to_s.squish.truncate(QUESTION_CHARS, omission: "")
      @identity = identity
      @session_context = session_context.to_s
      @labels = Array(labels)
      @locale = locale
      @mode = mode.to_sym
      @manuals = Array(manuals).compact_blank.first(MAX_MANUALS)
    end

    def to_s
      text = [ instruction, turn_block ].compact_blank.join("\n\n")
      @context_truncated = text.length > MAX_CHARS
      @context_truncated ? text[0, MAX_CHARS] : text
    end

    def context_truncated?
      @context_truncated == true
    end

    # Accepted visual fields only. Identity text and reference-only manual
    # names are not evidence for a terminal, value, or code.
    def safety_evidence
      visual_fields.values.compact.join("\n")
    end

    private

    def instruction
      return unknown_instruction if unknown?

      <<~TEXT.strip
        # FIELD COMPANION
        You are assisting the technician in the field.
        There is no compatible manufacturer procedure available.
        Do not borrow procedures from reference-only manuals.
        Continue helping using the accepted visual observation, the active problem, and generic diagnostic reasoning.
        Ask for one high-value next observation when needed. One main question. A short alternative is allowed. Do not turn the answer into a questionnaire, and do not ask for manufacturer, model, controller, fault code, and a photo together.
        Clearly distinguish observation from guidance. Put what the photo shows in its own short sentence, then Danebo guidance. Guidance is a hypothesis or a field check, not a manufacturer instruction.
        Do not invent electrical values, distances, tolerances, torque, parameters, terminal numbers, terminal functions, fault-code meanings, manufacturer-specific sequences, menu names, or DIP positions.
        If the equipment identity conflicts, do not choose a manufacturer. Ask for the evidence that resolves the conflict before any manufacturer-specific step.
        On a follow-up, do not greet again. A short greeting is allowed only when this opens the case.
        Do not stop after saying there is no manual. Do not print DATA_NOT_AVAILABLE.
        Write the entire answer in #{language_name}.
      TEXT
    end

    def unknown?
      @mode == :unknown
    end

    def unknown_instruction
      <<~TEXT.strip
        # FIELD COMPANION
        You are assisting an elevator technician in the field.
        The equipment identity is not confirmed.
        Do not teach the contents of any retrieved manual. Those contents are not in this prompt.
        Keep this job in elevator field service. Do not reinterpret it as another kind of machine.
        Ask for one safe look, read, or listen check tied to the reported symptom. Put the observational verb and the thing observed in the same sentence. One main question. Do not make a questionnaire.
        If they ask for a procedure, reset, adjustment, value, or manufacturer operation, do not give those steps, do not invent the value, and do not reply by only asking which equipment this is. Say it is not confirmed, then ask that one check. Do not stop at the refusal, and do not send them to an unknown terminal.
        If they already report an action as done, use it as context and do not instruct it again.
        If the missing fact is which equipment this is, ask them to read the nameplate and report the manufacturer and model in that same sentence. Do not suggest either.
        Do not invent electrical values, distances, tolerances, torque, parameters, terminal numbers, terminal functions, fault-code meanings, manufacturer-specific sequences, menu names, DIP positions, selectors, waits, inspection mode, power cuts, or resets.
        If the equipment identity conflicts, do not choose a manufacturer. Ask for the evidence that resolves the conflict before any manufacturer-specific step.
        On a follow-up, do not greet again. A short greeting is allowed only when this opens the case.
        Do not stop after saying there is no manual. Do not print DATA_NOT_AVAILABLE.
        Do not cite manuals with [n].
        Write the entire answer in #{language_name}.
      TEXT
    end

    def turn_block
      return unknown_turn_block if unknown?

      lines = []
      lines << "Question: #{@question}" if @question.present?
      lines << "Active problem: #{goal}" if goal.present?
      identity_lines.each { |line| lines << line }
      if conflict.present?
        lines << "Identity conflict: #{conflict}. Do not choose either manufacturer."
      end
      if visual_fields.any?
        lines << "Accepted visual observation:"
        visual_fields.each { |label, value| lines << "- #{label}: #{value}" }
      end
      turns = technician_turns
      if turns.any?
        lines << "Technician observations:"
        turns.each { |turn| lines << "- #{turn}" }
      end
      lines << "No compatible manufacturer manual was found."
      if manual_names.any?
        lines << "Reference-only manuals, names only: #{manual_names.join('; ')}. Do not teach their contents."
      end
      lines << (follow_up? ? "Follow-up: yes." : "Follow-up: no.")
      lines.join("\n")
    end

    def unknown_turn_block
      lines = []
      lines << "Question: #{@question}" if @question.present?
      problem_projection_lines.each { |line| lines << line }
      if visual_fields.any?
        lines << "Accepted visual observation:"
        visual_fields.each { |label, value| lines << "- #{label}: #{value}" }
      end
      turns = technician_turns
      if turns.any?
        lines << "Technician observations:"
        turns.each { |turn| lines << "- #{turn}" }
      end
      if @manuals.any?
        lines << "Retrieved manuals, not confirmed for this equipment. Contents withheld. Available on explicit request:"
        @manuals.each { |name| lines << "- #{name}" }
      end
      lines << (follow_up? ? "Follow-up: yes." : "Follow-up: no.")
      lines.join("\n")
    end

    def problem_projection_lines
      section(PROBLEM_HEADING).lines.filter_map { |line|
        text = line.strip
        next if text.blank? || text.start_with?("(") || text.start_with?("These facts identify")

        text
      }
    end

    def language_name
      @locale.to_s == "en" ? "English" : "Spanish"
    end

    def goal
      @goal ||= section(PROBLEM_HEADING)[/^Goal:\s*(.+)$/, 1].to_s.squish.presence
    end

    def identity_lines
      return [] unless @identity.is_a?(EquipmentIdentity)

      @identity.facts.filter_map { |fact|
        value = fact["value"].to_s.squish
        next if value.blank?

        "Known equipment identity: #{fact['slot']} #{value} (#{fact['source']})"
      }
    end

    def conflict
      return nil unless @identity.is_a?(EquipmentIdentity)

      row = @identity.conflicts.find { |item| item["user"].present? && item["photo"].present? }
      return nil unless row

      "technician said #{row['user']}; the photo shows #{row['photo']}"
    end

    def visual_fields
      @visual_fields ||= begin
        found = {}
        section(PHOTO_HEADING).each_line do |line|
          match = line.strip.match(/\A- ([^:]+):\s*(.+)\z/)
          next unless match

          key = FIELD_LABELS[match[1]]
          value = present_value(match[2])
          found[match[1]] = value if key && value
        end
        found
      end
    end

    def technician_turns
      current = @question.squish
      section("## Recent Conversation").lines.filter_map { |line|
        stripped = line.strip
        next unless stripped.start_with?("User:")

        text = stripped.sub(/\AUser:\s*/, "").squish
        next if text.blank? || text == current

        text.truncate(TURN_CHARS, omission: "")
      }.last(MAX_TURNS)
    end

    def manual_names
      prefix = DocumentIdentityScope::OTHER_EQUIPMENT_PREFIX
      @labels.filter_map { |label|
        text = label.to_s.strip
        next unless text.start_with?(prefix)

        name = text.delete_prefix(prefix).squish
        next if name.blank? || name.casecmp("DATA_NOT_AVAILABLE").zero?

        name
      }.uniq.first(MAX_MANUALS)
    end

    def follow_up?
      @session_context.match?(/(?:^|\n)Assistant:/)
    end

    def section(heading)
      start = @session_context.index(heading)
      return "" unless start

      rest = @session_context[(start + heading.length)..]
      finish = rest.index(/\n## /)
      (finish ? rest[0...finish] : rest).to_s
    end

    def present_value(value)
      text = value.to_s.squish
      return nil if text.blank? || text.casecmp("unknown").zero?

      text
    end
  end
end
