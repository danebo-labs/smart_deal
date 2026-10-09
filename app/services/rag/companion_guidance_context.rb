# frozen_string_literal: true

module Rag
  # User context for one generation when equipment is known and no compatible
  # manufacturer body was retrieved. The model writes the next diagnostic
  # step. This object only bounds the facts that generation and answer
  # safety are allowed to see.
  class CompanionGuidanceContext
    # Prompt budget. Episode facts outrank manuals, redundant history, and the
    # follow-up flag. Units that do not fit are omitted whole.
    MAX_CHARS = 2400
    # Diagnostic only. Not rendered, not routed, and not TurnPerception::PROMPT_VERSION.
    COMPANION_POLICY_VERSION = "2026-10-08.1"
    HYPOTHESIS_RULE = "Separate the report, the evidence, and a hypothesis. An unestablished part or place is conditional; do not treat it as present."
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
    SYMPTOM_LEAD = "You may ask one safe look, read, or listen check tied to the reported symptom. Put the observational verb and the thing observed in the same sentence. One main question. Do not make a questionnaire."
    DOC_GAP = "No applicable documentation for this job was retrieved this turn."
    EXIT_RULE = "#{DOC_GAP} Summarize what was verified, state what documentation is missing, then ask the one decisive datum or recommend escalation with that summary. Do not propose another check by routine."
    MANUAL_STOP = "Do not print DATA_NOT_AVAILABLE. A summary of what was verified and the missing documentation is a complete answer."
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
    PROCEDURE_LIMIT = "If they ask for a procedure, reset, or value, do not give those steps, and do not reply by only asking which equipment this is. Say it is not confirmed. Do not stop at the refusal. Do not send them to an unknown terminal."
    DONE_ACTION = "If they already report an action as done, use it as context and do not instruct it again."
    INTERVENTION_LIMIT = "Mark a hypothesis as a hypothesis. Do not instruct a physical or operational intervention, or a tool or instrument measurement without applicable evidence."
    QUESTION_RULE = "One useful question when needed. Not a questionnaire."
    UNKNOWN_INVENT = "Do not invent electrical values, terminals, fault-code meanings, sequences, menu names, DIP positions, selectors, waits, inspection mode, power cuts, or resets."
    KNOWN_INVENT = "Do not invent electrical values, distances, tolerances, torque, parameters, terminal numbers, terminal functions, fault-code meanings, manufacturer-specific sequences, menu names, or DIP positions."
    EMPTY_SEARCH = "The search returned no documentation. Do not say the manual does not exist."
    PIN_EMPTY = "The pinned focus returned no evidence. Do not release the pin."
    RANK_RULE = 2
    RANK_QUESTION = 3
    RANK_FACT = 4
    RANK_CHECK = 8
    RANK_FOLLOW_UP = 60
    RANK_OLD_TURN = 70
    RANK_REDUNDANT = 80
    RANK_MANUAL = 90
    CORRECTION_CUE = /
      \b(?:corrijo|correcci\p{L}*|me\s+equivoqu\p{L}*|en\s+realidad|lei\s+mal|instead|actually)\b |
      \bno\s+(?:es|era|de)\b
    /ix
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
    ORPHAN_HEADINGS = {
      "manuals_heading" => "manual",
      "turns_heading" => "turn",
      "visual_heading" => "visual"
    }.freeze
    GuidancePiece = Struct.new(:role, :text, :rank, :seq, keyword_init: true)

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
      raw_question = question.to_s.squish
      @question, question_rest = bound_words(raw_question, QUESTION_CHARS)
      @prior_cuts = []
      @prior_cuts << { "part" => "question", "text" => question_rest } if question_rest.present?
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
      kept, omitted = fit_guidance(guidance_pieces)
      rendered = render_guidance(kept)
      @context_truncated = omitted.any? || prior_cuts.any? || rendered.length > MAX_CHARS
      record_guidance_fit(rendered, omitted) if @context_truncated
      rendered
    end

    def context_truncated?
      @context_truncated == true
    end

    def record_guidance_fit(rendered, omitted)
      return unless ValidationCapture.active?

      ValidationCapture.record(
        "context_fit",
        "part" => "guidance",
        "chars" => rendered.length,
        "truncated" => true,
        "omitted" => omission_rows(omitted),
        "context_cap" => MAX_CHARS
      )
    end
    private :record_guidance_fit

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

    def unknown?
      @mode == :unknown
    end

    def instruction_pieces
      unknown? ? unknown_instruction_pieces : known_instruction_pieces
    end

    def unknown_instruction_pieces
      pieces = [
        rule_piece("# FIELD COMPANION"),
        rule_piece(objective_line),
        rule_piece("Follow that objective."),
        rule_piece(QUESTION_RULE),
        rule_piece("The equipment identity is not confirmed."),
        rule_piece(HYPOTHESIS_RULE),
        rule_piece(PROCEDURE_LIMIT),
        rule_piece(DONE_ACTION),
        rule_piece(PASSIVE_RULE),
        rule_piece(INTERVENTION_LIMIT),
        rule_piece(UNKNOWN_INVENT),
        rule_piece("If the equipment identity conflicts, do not choose a manufacturer."),
        rule_piece("On a follow-up, do not greet again.")
      ]
      pieces << rule_piece(EMPTY_SEARCH) if @empty_retrieval
      pieces << rule_piece(PIN_EMPTY) if @pinned_focus_empty
      pieces << rule_piece("Write the entire answer in #{language_name}.")
      pieces.concat(unknown_detail_pieces)
      pieces
    end

    def unknown_detail_pieces
      [
        detail_piece("You are assisting an elevator technician in the field.", 48),
        detail_piece("Do not teach retrieved manuals. Those contents are not in this prompt.", 42),
        detail_piece("Keep this job in elevator field service.", 49),
        detail_piece(observation_lead, 46),
        detail_piece(nameplate_rule, 44),
        detail_piece(manual_stop_line, 41),
        detail_piece("Do not cite manuals with [n].", 41)
      ]
    end

    def known_instruction_pieces
      pieces = [
        rule_piece("# FIELD COMPANION"),
        rule_piece("You are assisting the technician in the field."),
        rule_piece("There is no compatible manufacturer procedure available."),
        rule_piece("Do not borrow procedures from reference-only manuals."),
        rule_piece(HYPOTHESIS_RULE),
        rule_piece(KNOWN_INVENT),
        rule_piece("If the equipment identity conflicts, do not choose a manufacturer. Ask for the evidence that resolves the conflict before any manufacturer-specific step."),
        rule_piece("Write the entire answer in #{language_name}.")
      ]
      pieces.concat(known_detail_pieces)
      pieces
    end

    def known_detail_pieces
      [
        detail_piece("Continue helping using the accepted visual observation, the active problem, and generic diagnostic reasoning.", 44),
        detail_piece(known_next_step, 42),
        detail_piece("Clearly distinguish observation from guidance. Put what the photo shows in its own short sentence, then Danebo guidance. Guidance is a hypothesis or a field check, not a manufacturer instruction.", 45),
        detail_piece("On a follow-up, do not greet again. A short greeting is allowed only when this opens the case.", 48),
        detail_piece(manual_stop_line, 41)
      ]
    end

    def rule_piece(text)
      piece("instruction", text, RANK_RULE, text.length)
    end

    def detail_piece(text, rank)
      piece("instruction_detail", text, rank, text.length)
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
      return EXIT_RULE if documentation_exit?
      return TASK_LEAD if task_anchored?

      SYMPTOM_LEAD
    end

    def known_next_step
      return EXIT_RULE if documentation_exit?

      "One high-value next observation is optional. One main question. A short alternative is allowed. Do not turn the answer into a questionnaire, and do not ask for manufacturer, model, controller, fault code, and a photo together."
    end

    def manual_stop_line
      return "Do not print DATA_NOT_AVAILABLE." if documentation_exit?

      MANUAL_STOP
    end

    # The turn already says it does not know, or it only continues the same
    # check. A summary request is not this signal.
    def documentation_exit?
      folded = fold_text(@question)
      folded.match?(/\bno lo se\b/) || folded.match?(/\A(?:sigue igual|y ahora|no lo se)(?:\s+(?:sigue igual|y ahora|no lo se))*\z/)
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

    def guidance_pieces
      instruction_pieces + body_pieces
    end

    def body_pieces
      unknown? ? unknown_pieces : known_pieces
    end

    def unknown_pieces
      pieces = []
      pieces << piece("question", "Question: #{@question}", RANK_QUESTION, 0) if @question.present?
      problem_projection_lines.each { |line| append_problem_piece(pieces, line) }
      append_visual_pieces(pieces)
      append_turn_pieces(pieces)
      append_unknown_manual_pieces(pieces)
      pieces << follow_up_piece
      pieces
    end

    def known_pieces
      pieces = []
      pieces << piece("question", "Question: #{@question}", RANK_QUESTION, 0) if @question.present?
      pieces << piece("problem", "Active problem: #{goal}", RANK_FACT, 0) if goal.present?
      episode_lines.each { |line| append_problem_piece(pieces, line) }
      identity_lines.each { |line| pieces << piece("problem", line, RANK_FACT, 1) }
      if conflict.present?
        text = "Identity conflict: #{conflict}. Do not choose either manufacturer."
        pieces << piece("problem", text, RANK_FACT, 1)
      end
      append_visual_pieces(pieces)
      append_turn_pieces(pieces)
      pieces << piece("status", "No compatible manufacturer manual was found.", RANK_FACT, 0)
      if manual_names.any?
        text = "Reference-only manuals, names only: #{manual_names.join('; ')}. Do not teach their contents."
        pieces << piece("manual", text, RANK_MANUAL, manual_names.length)
      end
      pieces << follow_up_piece
      pieces
    end

    def append_problem_piece(pieces, line)
      unless line.start_with?("Obs:")
        pieces << piece("problem", line, RANK_FACT, line.start_with?("Goal:") ? 0 : 1)
        return
      end

      clauses = line.sub(/\AObs:\s*/, "").split("; ").filter_map { |clause| clause.squish.presence }
      clauses.each_with_index do |clause, index|
        rank = duplicate_observation?(clause, clauses[0...index]) ? RANK_REDUNDANT : RANK_FACT
        pieces << piece("observation", clause, rank, clauses.length - index)
      end
    end

    def append_visual_pieces(pieces)
      return if visual_fields.empty?

      pieces << piece("visual_heading", "Accepted visual observation:", 1, 0)
      visual_fields.each do |label, value|
        text = "- #{label}: #{value}"
        pieces << piece("visual", text, RANK_FACT, 1)
      end
    end

    def append_turn_pieces(pieces)
      turns = technician_turns
      return if turns.empty?

      pieces << piece("turns_heading", "Technician observations:", 1, 0)
      turns.each_with_index do |turn, index|
        pieces << piece("turn", "- #{turn}", turn_rank(turn, index, turns.length), turns.length - index)
      end
    end

    def append_unknown_manual_pieces(pieces)
      return if @manuals.empty?

      pieces << piece(
        "manuals_heading",
        "Retrieved manuals, not confirmed for this equipment. Contents withheld. Available on explicit request:",
        1,
        0
      )
      @manuals.each_with_index do |name, index|
        pieces << piece("manual", "- #{name}", RANK_MANUAL, @manuals.length - index)
      end
    end

    def follow_up_piece
      piece("follow_up", follow_up? ? "Follow-up: yes." : "Follow-up: no.", RANK_FOLLOW_UP, 0)
    end

    def piece(role, text, rank, seq)
      GuidancePiece.new(role: role, text: text, rank: rank, seq: seq)
    end

    def fit_guidance(pieces)
      chosen = pieces.dup
      omitted = []
      strip_orphan_headings(chosen, omitted)
      while render_guidance(chosen).length > MAX_CHARS
        victim = chosen.select { |item| item.rank > 1 }.max_by { |item| [ item.rank, item.seq ] }
        break unless victim

        chosen.delete(victim)
        omitted << victim
        strip_orphan_headings(chosen, omitted)
      end
      [ chosen, omitted ]
    end

    def strip_orphan_headings(chosen, omitted)
      ORPHAN_HEADINGS.each do |heading, child|
        next if chosen.any? { |item| item.role == child }

        chosen.select { |item| item.role == heading }.each do |item|
          chosen.delete(item)
          omitted << item
        end
      end
    end

    def render_guidance(pieces)
      head = pieces.select { |item| item.role.start_with?("instruction") }.map(&:text).join("\n")
      body = render_body(pieces.reject { |item| item.role.start_with?("instruction") })
      [ head.presence, body.presence ].compact.join("\n\n")
    end

    def render_body(pieces)
      lines = []
      observations = []
      pieces.each do |item|
        if item.role == "observation"
          observations << item.text
        else
          flush_observations(lines, observations)
          lines << item.text
        end
      end
      flush_observations(lines, observations)
      lines.join("\n")
    end

    def flush_observations(lines, observations)
      return if observations.empty?

      lines << "Obs: #{observations.join('; ')}"
      observations.clear
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
      @technician_turns ||= selected_history(raw_user_turns).filter_map { |text| present_turn(text) }
    end

    def raw_user_turns
      current = @question.squish
      section("## Recent Conversation").lines.filter_map { |line|
        stripped = line.strip
        next unless stripped.start_with?("User:")

        text = stripped.sub(/\AUser:\s*/, "").squish
        next if text.blank? || text == current

        text
      }
    end

    def selected_history(texts)
      window = texts.last(MAX_TURNS)
      correction = texts.reverse.find { |text| correction_text?(text) }
      return window if correction.nil? || window.include?(correction)

      ordered = texts.select { |text| text.equal?(correction) || window.include?(text) }
      while ordered.size > MAX_TURNS
        index = ordered.index { |text| !text.equal?(correction) && redundant_history?(text) }
        index ||= ordered.index { |text| !text.equal?(correction) }
        break unless index

        ordered.delete_at(index)
      end
      ordered
    end

    def present_turn(text)
      return text if text.length <= TURN_CHARS || correction_text?(text)

      kept, rest = bound_words(text, TURN_CHARS)
      prior_cuts << { "part" => "turn", "text" => rest } if rest.present?
      kept.presence
    end

    def correction_text?(text)
      fold_text(text).match?(CORRECTION_CUE)
    end

    def turn_rank(turn, index, count)
      return RANK_REDUNDANT if redundant_history?(turn)
      return RANK_FACT if correction_text?(turn)

      index == count - 1 ? RANK_CHECK : RANK_OLD_TURN
    end

    def redundant_history?(text)
      return true if ObservationText.continuity_echo?(text)

      holders = [ goal, *observation_clauses ].compact
      holders.any? { |holder| ObservationText.covered_by?(holder, text) }
    end

    def duplicate_observation?(clause, earlier)
      return true if ObservationText.continuity_echo?(clause)
      return true if goal.present? && ObservationText.covered_by?(goal, clause)

      earlier.any? { |other| ObservationText.covered_by?(other, clause) }
    end

    def observation_clauses
      problem_projection_lines.flat_map { |line|
        next [] unless line.start_with?("Obs:")

        line.sub(/\AObs:\s*/, "").split("; ").filter_map { |clause| clause.squish.presence }
      }
    end

    def bound_words(text, limit)
      return [ text, nil ] if text.length <= limit

      window = text[0, limit]
      space = window.rindex(" ")
      kept = space && space >= (limit / 2) ? window[0, space] : window
      rest = text[kept.length..].to_s.squish
      [ kept.squish, rest.presence ]
    end

    def prior_cuts
      @prior_cuts ||= []
    end

    def omission_rows(omitted)
      rows = omitted.map { |item| { "part" => item.role, "text" => item.text } }
      prior_cuts.each { |cut| rows << cut.merge("prior_cut" => true) }
      rows
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
