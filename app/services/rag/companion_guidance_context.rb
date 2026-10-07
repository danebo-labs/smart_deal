# frozen_string_literal: true

module Rag
  # User context for one generation when equipment is known and no compatible
  # manufacturer body was retrieved. The model writes the next diagnostic
  # step. This object only bounds the facts that generation and answer
  # safety are allowed to see.
  class CompanionGuidanceContext
    MAX_CHARS = 2400
    # Diagnostic only. Not rendered, not routed, and not TurnPerception::PROMPT_VERSION.
    COMPANION_POLICY_VERSION = "2026-10-06.2"
    ADVANCE_FAULT = "advance_fault"
    RESOLVE_IDENTITY = "resolve_identity"
    BASIS_IDENTIFICATION = "explicit_identification_request"
    BASIS_CONFIRMATION = "explicit_identity_confirmation_request"
    BASIS_DOCUMENTATION = "documentation_applicability"
    BASIS_DEFAULT = "default_fault_progress"
    OBJECTIVE_LINES = {
      ADVANCE_FAULT => "Current objective: advance the reported fault. Do not ask equipment identity by routine.",
      RESOLVE_IDENTITY => "Current objective: resolve equipment identity."
    }.freeze
    # Used only when the turn is advance_fault and no concrete state was reported.
    NO_STATE_OBJECTIVE = "Current objective: advance the current request. No fault or symptom was reported. Do not ask equipment identity by routine."
    SYMPTOM_LEAD = "Ask for one safe look, read, or listen check tied to the reported symptom. Put the observational verb and the thing observed in the same sentence. One main question. Do not make a questionnaire."
    TASK_LEAD = "This request is the anchor. Do not ask them to describe the fault, restate the symptom, or explain the abnormal behavior. If a check is needed, ask one that distinguishes causes, interprets a result already reported, or decides the next step of this request. One sentence. Not a checklist. Do not ask equipment identity by routine."
    PASSIVE_RULE = "Passive means a state that already exists. Do not have them press, activate, call, send, move, power, reset, or measure to create it."
    # Concrete equipment state already reported. Not a request, a manual, or an identity.
    STATE_CUE = /
      \bquedo\b | \batascad\w* | \bstuck\b | \btrapped\b | \bentre\s+pisos\b | \ba\s+nivel\b |
      \bno\s+(?:termina\s+de\s+)?(?:cierr\w*|cerr\w*|abr\w*|abiert\w*|nivel\w*|arranc\w*|mov\w*|funcion\w*|respond\w*)\b |
      \b(?:wont|will\s+not|does\s+not|doesnt|cannot|cant)\s+(?:close|open|level|start|move|run)\b |
      \b(?:ruido|sonido|zumbido|chasquido|vibracion|noise|sound|vibration|parpade\w*|intermit\w*|blink\w*)\b |
      \b(?:display|pantalla|indicador)\s+(?:\w+\s+){0,4}(?:muestra|indica|dice|ensen|shows|reads|displays|encendid\w*|lit)\b |
      \b(?:personas|gente|ocupantes|alguien)\s+(?:\w+\s+){0,4}(?:dentro|adentro|inside)\b |
      \b(?:puerta|door)\s+(?:\w+\s+){0,6}(?:abiert\w*|cerrad\w*|atascad\w*|open|closed|stuck)\b |
      \b(?:se\s+paro|parado|detenid\w*|stopped|not\s+moving)\b
    /ix
    IDENTITY_PROJECTION = /\A(?:manufacturer|model|marca|modelo|fabricante|controller|controlador)\b/i
    EQUIPMENT_WORD = /equipo|ascensor|elevador|montacargas|controlador|controller|elevator|equipment|lift|nameplate/i
    EQUIPMENT_TARGET = /\b(?:#{EQUIPMENT_WORD.source}|placa\s+de\s+caracteristicas|chapa\s+de\s+caracteristicas)\b/i
    NAMEPLATE_TARGET = /\b(?:nameplate|placa\s+de\s+caracteristicas|chapa\s+de\s+caracteristicas|placa\s+identificativa)\b/i
    IDENTIFY_VERB = /\b(?:identific\p{L}*|identify(?:ing)?|identification)\b/i
    IDENTITY_ATTRIBUTE = /\b(?:marca|modelo|fabricante|manufacturer|model|brand|make)\b/i
    IDENTITY_ASK = /\b(?:que|cual|cuales|what|which|identific\p{L}*|identify(?:ing)?|leer|lee|read)\b/i
    EQUIPMENT_COPULA = /\b(?:mi|este|esta|el|la|tu|nuestro|nuestra|our|my|this|the)\s+(?:equipo|ascensor|elevador|controlador|elevator|equipment|controller|lift)\s+(?:es|sea|seria|sera|is|was)\s+(?:un|una|a|an)\b/i
    CONFIRM_WHETHER = /\bconfirm\p{L}*\s+(?:si|que|whether|if)\b.{0,80}\b(?:equipo|ascensor|controlador|elevator|equipment|controller|marca|modelo|fabricante)\b/i
    PROPOSED_IDENTITY_COPULA = /(?:\A|[[:space:]¿])(?:[Ee]s|[Ss]era|[Ss]eria|[Ii]s)\s+(?:este[[:space:]]+|esta[[:space:]]+|this[[:space:]]+)?(?:un|una|el|la|a|an)\s+\p{Lu}[\p{L}\d-]{1,}/
    PART_ATTRIBUTE = /\b(?:marca|modelo|fabricante|model|brand|make|manufacturer)\s+(?:de|del|of)\s+(?:este|esta|el|la|un|una|mi|tu|this|my|our|the|a|an)?\s*(\p{L}+)/i
    CODE_MEANING = /\b(?:que significa|que indica|what does|what do|means)\b/
    CODE_TOKEN = /\b(?:codigo|code|fault|error|led)\s+\d{1,4}\b|\b[a-z]\d{2,4}\b|\b[a-z]\s+\d{2,4}\b/
    MANUAL_WORD = /\bmanual\b/
    APPLICABILITY_DOUBT = /\b(?:puede no|no se si|may not|not apply|no es mi|not this equipment|not be my)\b/
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

    def self.build(question:, identity:, session_context:, labels:, locale:, mode: :known, manuals: nil,
                   empty_retrieval: false, pinned_focus_empty: false)
      new(
        question: question,
        identity: identity,
        session_context: session_context,
        labels: labels,
        locale: locale,
        mode: mode,
        manuals: manuals,
        empty_retrieval: empty_retrieval,
        pinned_focus_empty: pinned_focus_empty
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

    def initialize(question:, identity:, session_context:, labels:, locale:, mode: :known, manuals: nil,
                   empty_retrieval: false, pinned_focus_empty: false)
      @question = question.to_s.squish.truncate(QUESTION_CHARS, omission: "")
      @identity = identity
      @session_context = session_context.to_s
      @labels = Array(labels)
      @locale = locale
      @mode = mode.to_sym
      @manuals = Array(manuals).compact_blank.first(MAX_MANUALS)
      @empty_retrieval = empty_retrieval == true
      @pinned_focus_empty = pinned_focus_empty == true
    end

    def to_s
      text = [ instruction, turn_block ].compact_blank.join("\n\n")
      @context_truncated = text.length > MAX_CHARS
      @context_truncated ? text[0, MAX_CHARS] : text
    end

    def context_truncated?
      @context_truncated == true
    end

    # The line in to_s is the generator-visible objective. These readers are
    # the same derivation, for diagnostics only.
    def turn_objective
      return nil unless unknown?

      identity_resolution_request? || identity_decides_documentation? ? RESOLVE_IDENTITY : ADVANCE_FAULT
    end

    def turn_objective_basis
      return nil unless unknown?
      return BASIS_CONFIRMATION if identity_confirmation_request?
      return BASIS_IDENTIFICATION if identification_request?
      return BASIS_DOCUMENTATION if identity_decides_documentation?

      BASIS_DEFAULT
    end

    # True only when a concrete equipment state, symptom, or observation is
    # already in this context. A prior request is not a state. Nil outside
    # unknown guidance. Diagnostic readers do not change the rendered text.
    def reported_state_present
      return nil unless unknown?

      state_reported?
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
        #{objective_line}
        Follow that objective.
        You are assisting an elevator technician in the field.
        The equipment identity is not confirmed.
        Do not teach the contents of any retrieved manual. Those contents are not in this prompt.
        Keep this job in elevator field service.
        #{observation_lead}
        If they ask for a procedure, reset, or value, do not give those steps, and do not reply by only asking which equipment this is. Say it is not confirmed, then ask that one check. Do not stop at the refusal, and do not send them to an unknown terminal.
        If they already report an action as done, use it as context and do not instruct it again.
        #{nameplate_rule}
        #{PASSIVE_RULE}
        You may observe, interpret, and hypothesize. Do not instruct a physical intervention, an operational intervention, or a tool or instrument measurement without applicable evidence.
        Do not invent electrical values, distances, tolerances, torque, parameters, terminal numbers, terminal functions, fault-code meanings, manufacturer-specific sequences, menu names, DIP positions, selectors, waits, inspection mode, power cuts, or resets.
        If the equipment identity conflicts, do not choose a manufacturer.
        On a follow-up, do not greet again.
        #{empty_retrieval_rule}
        Do not stop after saying there is no manual. Do not print DATA_NOT_AVAILABLE.
        Do not cite manuals with [n].
        Write the entire answer in #{language_name}.
      TEXT
    end

    def empty_retrieval_rule
      return "" unless @empty_retrieval

      rule = "The search returned no documentation. Do not say the manual does not exist. Offer one clarification that would narrow the next search, or Danebo field guidance labeled as Danebo guidance. No manufacturer procedure, value, or terminal."
      rule += " The pinned focus returned no evidence. Do not release the pin." if @pinned_focus_empty
      rule
    end

    def objective_line
      return OBJECTIVE_LINES.fetch(RESOLVE_IDENTITY) if turn_objective == RESOLVE_IDENTITY
      return NO_STATE_OBJECTIVE if task_anchored?

      OBJECTIVE_LINES.fetch(ADVANCE_FAULT)
    end

    # Identity resolution keeps the symptom lead so the nameplate rule stays
    # the main question. Only an advance_fault turn with no reported state
    # switches to the current request.
    def observation_lead
      task_anchored? ? TASK_LEAD : SYMPTOM_LEAD
    end

    def task_anchored?
      turn_objective == ADVANCE_FAULT && !reported_state_present
    end

    def state_reported?
      return true if state_text?(folded_question)
      return true if problem_projection_lines.any? { |line| state_projection?(line) }
      return true if visual_fields.any?
      return true if technician_turns.any? { |turn| state_text?(fold_text(turn)) }

      false
    end

    def state_projection?(line)
      label, body = line.split(":", 2)
      return false if label.to_s.match?(IDENTITY_PROJECTION)

      state_text?(fold_text(body || line))
    end

    def state_text?(folded)
      folded.present? && folded.match?(STATE_CUE)
    end

    def fold_text(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^\p{L}\d]+/, " ").squish
    end

    def nameplate_rule
      if turn_objective == RESOLVE_IDENTITY
        "Ask them to read the nameplate and report the manufacturer and model in one concise observational question. Do not suggest either. Do not confirm a proposed identity without evidence."
      else
        "Do not choose the nameplate or the equipment identity as the main question. Unknown identity only limits manufacturer-specific claims and unsupported procedures, values, or parameters."
      end
    end

    # Current equipment, its controller, or its nameplate. A part or product
    # question is not this request. Unknown identity is not this request.
    def identity_resolution_request?
      identity_confirmation_request? || identification_request?
    end

    # Signals already on the turn. Titles do not show that two manuals
    # belong to different equipment. No extra model call.
    def identity_decides_documentation?
      applicability_depends_on_model? || code_meaning_depends_on_equipment?
    end

    def applicability_depends_on_model?
      folded_question.match?(MANUAL_WORD) && folded_question.match?(APPLICABILITY_DOUBT)
    end

    def code_meaning_depends_on_equipment?
      folded_question.match?(CODE_MEANING) && folded_question.match?(CODE_TOKEN)
    end

    def identity_confirmation_request?
      folded = folded_question
      return true if folded.match?(EQUIPMENT_COPULA)
      return true if folded.match?(CONFIRM_WHETHER)

      proposed_identity_copula?
    end

    def identification_request?
      folded = folded_question
      return true if folded.match?(IDENTIFY_VERB) && folded.match?(EQUIPMENT_TARGET)
      return true if nameplate_question?(folded)

      equipment_attribute_question?(folded)
    end

    def equipment_attribute_question?(folded)
      return false unless folded.match?(IDENTITY_ATTRIBUTE)
      return false unless folded.match?(IDENTITY_ASK)
      return false unless folded.match?(EQUIPMENT_TARGET)
      return false if part_attribute?(folded)

      true
    end

    def nameplate_question?(folded)
      folded.match?(NAMEPLATE_TARGET) && folded.match?(IDENTITY_ASK)
    end

    def part_attribute?(folded)
      match = folded.match(PART_ATTRIBUTE)
      return false unless match

      !match[1].match?(EQUIPMENT_WORD)
    end

    def proposed_identity_copula?
      @question.match?(PROPOSED_IDENTITY_COPULA)
    end

    def folded_question
      @folded_question ||= fold_text(@question)
    end

    def turn_block
      return unknown_turn_block if unknown?

      lines = []
      lines << "Question: #{@question}" if @question.present?
      lines << "Active problem: #{goal}" if goal.present?
      episode_lines.each { |line| lines << line }
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

    def episode_lines
      problem_projection_lines.reject { |line| line.start_with?("Goal:") }
    end

    def problem_projection_lines
      section(PROBLEM_HEADING).lines.filter_map { |line|
        text = line.strip
        next if text.blank? || text.start_with?("(")
        next if text.start_with?("These facts identify", "Not a manual.", "Procedures, values, terminals")

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
