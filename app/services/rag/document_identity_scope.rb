# frozen_string_literal: true

module Rag
  # One compatibility policy for typed turns and photo turns.
  # Callers pass a Rag::EquipmentIdentity. An episode is accepted only so
  # the text path can be derived through EquipmentIdentity.from_episode.
  #
  # Outcomes when the policy is required (identity known):
  #   :scoped         — at least one chunk body applies to this equipment
  #   :no_compatible  — the policy ran and no body applies
  #   :unavailable    — the policy could not run reliably
  #
  # Required mode (identity known) is fail-closed. :scoped may generate from
  # applicable bodies. :no_compatible and :unavailable do not fall through to
  # an open retrieve_and_generate. A reference-only chunk may stay in the
  # generation context as source identity. It is not citable evidence.
  class DocumentIdentityScope
    Result = Data.define(
      :chunks, :labels, :blocked, :undeclared_private, :unconfirmed_general,
      :status, :reason, :applicability, :excluded_labels
    ) do
      def reference_only?
        Array(applicability).any? { |item| item == "reference_only" }
      end
    end
    PREAMBLE = "Only evidence marked THIS JOB'S EQUIPMENT can support a step, terminal, code, or value for this job. " \
               "Evidence marked REFERENCE ONLY — OTHER EQUIPMENT contains source identity only; its procedural body " \
               "was removed and cannot support an instruction for this job."
    OTHER_EQUIPMENT_PREFIX = "REFERENCE ONLY — OTHER EQUIPMENT:"
    # Generation constraint for a turn whose equipment is not confirmed.
    # It does not enter .apply. A pin is retrieval focus, not identity.
    IDENTITY_UNKNOWN_REFERENCE = "identity_unknown_reference"
    APPLICABILITY_BLOCK = <<~TEXT.strip.freeze
      # UNKNOWN EQUIPMENT IDENTITY / APPLICABILITY
      identity_unknown_reference

      The current equipment identity is not confirmed. Retrieved material may belong to equipment other than the unit being serviced.

      Treat it as indicative reference evidence only. It does not prove that a procedure applies to the current equipment.

      Do not present a procedure, terminal assignment, adjustment, wiring instruction, parameter or menu value, component mapping, part name, code, setting, reset sequence, learning sequence, or manufacturer-specific safety requirement from another manual as confirmed for the current equipment.

      When using such evidence, name the referenced manual and equipment, keep the citation and page, and state that applicability to the current job is not confirmed. Keep that reference separate from generic observational checks.

      Offer at least one observational check that only looks, reads, or listens. Do not bridge, short, disconnect, adjust, or invent a value.

      A pinned document is retrieval focus. It does not confirm equipment identity.
    TEXT
    IDENTITY_FIELDS = %w[canonical_name original_filename section_identity].freeze
    # A catalog fact is a query signal. It is not a needle. Controller is the
    # same: F8 may store it, and this list stays user and photo.
    NEEDLE_SOURCES = %w[user photo].freeze
    Resolution = Data.define(:values, :conflict, :manufacturer_labels, :excluded_labels)

    def self.applicable?(identity_or_episode)
      return false unless DocumentIdentityScopeFlag.enabled?

      identity = coerce_identity(identity_or_episode)
      identity.is_a?(EquipmentIdentity) && identity.known?
    end

    # Nil when identity is confirmed, malformed, or not an equipment identity.
    # Unknown and absent identity select the reference mode. A pin is not an input.
    def self.applicability_mode(identity)
      identity_unknown_reference?(identity) ? IDENTITY_UNKNOWN_REFERENCE : nil
    end

    def self.applicability_block_for(mode)
      return APPLICABILITY_BLOCK if mode.to_s == IDENTITY_UNKNOWN_REFERENCE

      nil
    end

    def self.identity_unknown_reference?(identity)
      return false if identity == :malformed
      return true if identity.nil?
      return !identity.known? if identity.is_a?(EquipmentIdentity)

      false
    end

    # Structural fence for a chunk that reached generation while equipment
    # identity is unconfirmed. The body stays so it can be named as another
    # manual. It is not .apply and it does not rank.
    UNCONFIRMED_REFERENCE_MARK = "UNCONFIRMED REFERENCE"

    def self.mark_unconfirmed_reference(chunks)
      Array(chunks).map do |chunk|
        chunk.merge(
          content: unconfirmed_reference_content(chunk),
          identity_applicability: "unconfirmed_reference"
        )
      end
    end

    def self.unconfirmed_reference_content(chunk)
      metadata = metadata_of(chunk)
      page = metadata["page_number"].presence || "DATA_NOT_AVAILABLE"
      [
        UNCONFIRMED_REFERENCE_MARK,
        "Manual: #{document_name(chunk)}",
        "Page: #{page}",
        "Not confirmed for the current equipment. Not this job's identity, procedure, code, terminal, value, or recovery.",
        chunk[:content].to_s
      ].join("\n")
    end

    # Post-generation applicability for identity_unknown_reference.
    # Identity tokens come from the retrieved chunks. A technical operation
    # comes from the closed lexicon below, not from imperative mood.
    IDENTITY_STOPWORDS = %w[
      de la el los las un una y o en del al para por con sin sobre
      the and of for a an to from
      manual documento listado averias averia norma montaje pagina page
      codigo codigos pdf png jpg jpeg
    ].freeze
    ES_IDENTITY_SUBJECT = /(?:este|esta|estos|estas|el|la|tu|tus|su|mi|nuestro|nuestra|nuestros|nuestras)/
    ES_IDENTITY_EQUIPMENT = /(?:equipo|ascensor|elevador|controlador|maniobra|unidad|placa|cuadro|instalacion)/
    ES_IDENTITY_GAP = /(?:\s+(?:de|del|este|esta|el|la|ascensor|equipo|elevador|un|una)){0,5}/
    ES_IDENTITY_COPULA = /(?:es|sea|son|tiene|dispone|usa|utiliza|cuenta|lleva|monta|corresponde\s+a)/
    EN_IDENTITY_SUBJECT = /(?:this|the|your|my|our)/
    EN_IDENTITY_EQUIPMENT = /(?:equipment|elevator|lift|controller|unit|board|drive)/
    EN_IDENTITY_COPULA = /(?:is|has|uses|utilizes|runs|matches|corresponds\s+to)/
    IDENTITY_ASSERTION_PATTERN = /
      \b#{ES_IDENTITY_SUBJECT}\s+#{ES_IDENTITY_EQUIPMENT}#{ES_IDENTITY_GAP}\s+#{ES_IDENTITY_COPULA}\b |
      \b#{EN_IDENTITY_SUBJECT}\s+#{EN_IDENTITY_EQUIPMENT}\s+#{EN_IDENTITY_COPULA}\b |
      \b(?:he|hemos|i\s+have|i)\s+identific(?:ado|ada|o|ed)\b |
      \bse\s+ha\s+identific(?:ado|ada)\b |
      \bse\s+trata\s+de\b |
      \bparece\s+ser\b |
      \blooks\s+like(?:\s+a)?\b |
      (?<!no[[:space:]])(?:\bes\s+un\b|\bit\s+s\s+a\b|\bit\s+is\s+a\b)
    /ix
    DEICTIC_EQUIPMENT_PATTERN = /
      \b(?:este|esta|estos|estas|tu|tus|su|mi|nuestro|nuestra|nuestros|nuestras|this|your|my|our)
      \s+(?:equipo|ascensor|elevador|controlador|maniobra|unidad|placa|cuadro|instalacion|
           equipment|elevator|lift|controller|unit|board|drive)\b
    /ix
    IDENTITY_NON_CONFIRMATION_PATTERN = /
      \bno\s+esta\s+confirmad |
      \bno\s+se\s+ha\s+confirmad |
      \bno\s+confirmad |
      \bsin\s+confirmar |
      \bnot\s+confirmed |
      \bunconfirmed\b
    /ix
    IDENTITY_CONFIRMATION_REQUEST_PATTERN = /
      \bconfirm(?:a|e|ar|en|ais|ed)?\s+(?:si|que|whether|if)\b
    /ix
    IDENTITY_DOCUMENTARY_PATTERN = /
      \ben\s+el\s+manual\b |
      \bin\s+the\s+(?:manual|document)\b |
      \bse\s+documenta\b |
      \b(?:the\s+manual\s+documents|is\s+documented\s+in)\b
    /ix
    # Closed operation families. Forms cover verb, infinitive, gerund, and nominal.
    # Visual "inspeccione" is not inspection mode. "cambiar" is not an operation.
    OPERATION_PATTERN = /
      \benvi(?:ar|a|e|o|alo|ala|ad|ando|ado)\b |
      \bmov(?:er|iendo|ido|imiento)(?:lo|la)?\b |
      \bmuev(?:e|a|an|as|elo|ela)\b |
      \bllev(?:ar|a|e|ando|arlo|arla)\s+(?:la\s+|el\s+)?cabina\b |
      \b(?:send|move|bring)(?:s|ing)?\b(?:\s+\w+){0,3}\s+(?:car|cab|it)\b |
      \b(?:entrar|entra|entre|pasar|pasa|pase|paso)\s+(?:a|en|al)\s+inspeccion\b |
      \bmodo\s+inspeccion\b |
      \binspection\s+mode\b |
      \benter(?:ing)?\s+inspection\b |
      \b(?:cort(?:ar|e|en|a|ando)|corte|quit(?:ar|e|a|ando)|cut(?:ting)?)\s+
        (?:la\s+|el\s+|de\s+la\s+|de\s+)?(?:tension|alimentacion|power|voltage)\b |
      \bcorte\s+de\s+(?:tension|alimentacion|luz|power)\b |
      \bconectar\b | \bconecte\b | \bconecta(?:r|ndo|do)?\b |
      \bdesconect\w* | \bdesconexion(?:es)?\b | \bdisconnect(?:s|ing|ed)?\b |
      \bpuente(?:ar|a|e|o|ando)?\b | \bbridge(?:s|d|ing)?\b | \bcortocircuit\w* |
      \bajust(?:ar|e|a|en|ando)\b | \bajuste\b | \badjust(?:s|ing|ed|ment|ments)?\b |
      \bcalibr(?:ar|a|e|acion|ando|aciones)\b | \bcalibrat(?:e|es|ed|ing|ion)\b |
      \breset(?:ear|ea|ee|eando)?\b | \breset\b |
      \brearm(?:ar|a|e|ando)?\b | \brearme\b |
      \bprogramar\b | \bprograme\b | \bprogramacion\b | \bprogramming\b | \bprogram\s+the\b |
      \bparametriz\w* | \bparameteriz\w* |
      \bconfigurar\b | \bconfigure\b | \bconfiguracion\b | \bconfiguration\b |
      \baprendizaje\b | \baprender\b | \blearning\b |
      \bpuls(?:ar|a|e|ad|ando|acion|aciones)\b | \bpress(?:es|ed|ing)?\b |
      \bgir(?:ar|a|e|en|ando|ado)\b | \brotat(?:e|es|ed|ing)\b |
      \babr(?:ir|a|an|id)\s+(?:la\s+|el\s+|las\s+|los\s+)?(?:puerta|cuadro|panel|tablero)\b |
      \bopen(?:s|ed|ing)?\s+(?:the\s+)?(?:door|panel|cabinet)\b |
      \bretir(?:ar|a|e|ando|elo|ela)\b | \bsustitu\w* | \breemplaz\w* |
      \breplac(?:e|es|ed|ing)\b | \bremov(?:e|es|ed|ing)\b |
      \bmedir\b | \bmide\b | \bmida\b | \bmedicion(?:es)?\b |
      \bmeasur(?:e|es|ed|ing|ement|ements)\b
    /ix
    OPERATION_NEGATOR_PATTERN = /
      \b(?:no|nunca|ni|evita|evite|evitar|eviten|do\s+not|never|avoid)\b
    /ix
    ACTION_REQUEST_PATTERN = /
      \b(?:puedes|podrias|podes|deberias|quieres|has\s+probado|probaste|
          could\s+you|can\s+you|should\s+you|have\s+you\s+tried|would\s+you)\b
    /ix
    NON_APPLICABILITY_PATTERN = /
      \bno\s+esta\s+confirmad |
      \bno\s+se\s+ha\s+confirmad |
      \bsin\s+confirmar |
      \bno\s+se\s+aplica |
      \bno\s+aplica\s+a\s+(?:este|tu|el|su)\s+equipo |
      \bpuede\s+no\s+aplicar |
      \bpuede\s+no\s+ser\s+(?:este|tu|mi|el|su|your)\s+(?:equipo|ascensor) |
      \bno\s+es\s+el\s+procedimiento\s+de\s+(?:este|tu|el|su)\s+equipo |
      \bno\s+corresponde\s+a\s+(?:este|tu|el|su)\s+equipo |
      \bnot\s+confirmed |
      \bunconfirmed\b |
      \bdoes\s+not\s+apply |
      \bmay\s+not\s+apply |
      \bnot\s+this\s+(?:job|equipment)\b
    /ix
    ATTRIBUTION_PATTERN = /
      \b(?:manual|documento|documentacion|segun|de\s+acuerdo\s+con|describe|documenta|
          according\s+to|the\s+manual)\b
    /ix
    CHUNK_DESIGNATOR_PATTERN = /\b[A-Z]{1,4}-?\d{1,4}\b/
    CHUNK_TIME_PATTERN = /\b\d+(?:[.,]\d+)?\s*(?:s|seg|segs|segundos?|seconds?)\b/i
    ApplicabilityUnit = Struct.new(:text, :paragraph_id, :index, :intro, :heading, :question, keyword_init: true)

    def self.unconfirmed_applicability_violation(answer, raw, chunks, question)
      applicability_hit(answer, raw, chunks, question)&.fetch(:kind)
    end

    def self.unconfirmed_applicability_basis(answer, raw, chunks, question)
      applicability_hit(answer, raw, chunks, question)&.fetch(:basis)
    end

    def self.unconfirmed_identity_assertion?(answer, chunks)
      return false if answer.blank?

      patterns = identity_phrase_patterns(chunks)
      return false if patterns.empty?

      applicability_units(answer).any? do |unit|
        identity_unit?(applicability_normalize(unit.text), patterns)
      end
    end

    def self.unconfirmed_reference_withheld(chunks, locale:)
      I18n.t(
        "rag.unconfirmed_reference_withheld",
        locale: locale,
        references: unconfirmed_reference_clause(chunks, locale)
      )
    end

    def self.log_applicability_violation(kind = :identity_assertion, basis: nil)
      detail = [ kind, basis ].compact.join(" ")
      Rails.logger.info("[APPLICABILITY_VIOLATION] #{detail}")
    end

    def self.needles(identity_or_episode)
      identity = coerce_identity(identity_or_episode)
      return [] unless identity.is_a?(EquipmentIdentity)

      resolve_needles(identity).values
    end

    def self.apply(chunks, identity_or_episode, focus_uris: [])
      identity = coerce_identity(identity_or_episode)
      if identity == :malformed
        return build_result(
          chunks: Array(chunks),
          labels: blank_labels(chunks),
          status: :unavailable,
          reason: :malformed_identity
        )
      end

      uris = Array(focus_uris).map { |uri| uri.to_s.strip }.compact_blank.to_set
      resolution = identity.is_a?(EquipmentIdentity) ? resolve_needles(identity) : empty_resolution
      needles = resolution.values
      return not_required(chunks) if !identity&.known? && needles.empty? && uris.empty?

      labels = []
      applicability = []
      scoped_chunks = Array(chunks).map do |chunk|
        kind = chunk_applicability(chunk, needles, focus_membership(chunk, uris), identity, resolution)
        case kind
        when :compatible, :neutral
          labels << this_job_line(document_name(chunk))
          applicability << kind.to_s
          chunk.merge(identity_applicability: kind.to_s)
        when :reference_only
          labels << other_equipment_line(document_name(chunk))
          applicability << "reference_only"
          chunk.merge(content: reference_identity(chunk), identity_applicability: "reference_only")
        else
          labels << nil
          applicability << nil
          chunk
        end
      end
      return not_required(chunks) if labels.all?(&:blank?) && !identity&.known?

      status = if applicability.any? { |item| item == "compatible" || item == "neutral" }
        :scoped
      elsif identity&.known?
        :no_compatible
      else
        :scoped
      end
      build_result(
        chunks: scoped_chunks,
        labels: labels,
        status: status,
        reason: resolution.conflict ? :conflicting_current_identity : nil,
        applicability: applicability,
        excluded_labels: resolution.excluded_labels
      )
    end

    # Same chunks, same order. The preamble is one line before the results.
    # A label is one line before that chunk's body.
    def self.generation_context(chunks, labels = [])
      body = Array(chunks).each_with_index.map { |chunk, index|
        content = chunk[:content].to_s
        label = labels[index]
        content = "#{label}\n#{content}" if label.present?
        [
          "<search_result>",
          "<content>",
          content,
          "</content>",
          "<source>",
          (index + 1).to_s,
          "</source>",
          "</search_result>"
        ].join("\n")
      }.join("\n")
      return body unless Array(labels).any?(&:present?)

      "#{PREAMBLE}\n#{body}"
    end

    def self.this_job_line(canonical_name)
      "THIS JOB'S EQUIPMENT: #{canonical_name}"
    end

    def self.other_equipment_line(name)
      "#{OTHER_EQUIPMENT_PREFIX} #{name}"
    end

    def self.reference_only_chunk?(chunk)
      return false unless chunk.respond_to?(:[])

      value = chunk[:identity_applicability] || chunk["identity_applicability"]
      value.to_s == "reference_only"
    end

    # Same order as the generation context. A reference-only slot is nil so a
    # later [n] cannot bind to a different chunk and cannot support a fact.
    def self.citable_evidence(records)
      Array(records).map { |record| reference_only_chunk?(record) ? nil : record }
    end

    def self.reference_identity(chunk)
      metadata = metadata_of(chunk)
      [
        "Manual: #{document_name(chunk)}",
        "Page: #{metadata["page_number"].presence || "DATA_NOT_AVAILABLE"}",
        "Section: #{metadata["section_identity"].presence || "DATA_NOT_AVAILABLE"}"
      ].join("\n")
    end
    private_class_method :reference_identity

    def self.applicability_hit(answer, raw, chunks, question)
      return nil if Array(chunks).empty?

      hits = [ answer, raw ].compact.uniq.filter_map { |text| applicability_hit_for(text, chunks, question) }
      return nil if hits.empty?

      identity = hits.find { |hit| hit[:kind] == :identity_assertion }
      return identity if identity

      procedures = hits.select { |hit| hit[:kind] == :procedure_application }
      return nil if procedures.empty?

      bases = procedures.filter_map { |hit| hit[:basis] }
      basis = if bases.include?(:operation) && bases.include?(:value_code) || bases.include?(:operation_and_value_code)
        :operation_and_value_code
      else
        bases.first
      end
      { kind: :procedure_application, basis: basis }
    end
    private_class_method :applicability_hit

    def self.applicability_hit_for(text, chunks, question)
      return nil if text.blank?

      patterns = identity_phrase_patterns(chunks)
      units = applicability_units(text)
      identity = false
      operation = false
      value = false
      units.each do |unit|
        normalized = applicability_normalize(unit.text)
        if identity_unit?(normalized, patterns)
          identity = true
          next
        end
        next if qualified_reference?(unit, units, patterns, chunks.size)
        next if observational_question?(unit)

        operation = true if operation_unit?(normalized)
        value = true if foreign_value_unit?(unit.text, chunks, question)
      end
      return { kind: :identity_assertion, basis: nil } if identity
      return nil unless operation || value

      basis = if operation && value
        :operation_and_value_code
      elsif operation
        :operation
      else
        :value_code
      end
      { kind: :procedure_application, basis: basis }
    end
    private_class_method :applicability_hit_for

    def self.identity_unit?(normalized, patterns)
      return false if normalized.blank? || patterns.empty?
      return false unless patterns.any? { |pattern| normalized.match?(pattern) }
      return false unless normalized.match?(IDENTITY_ASSERTION_PATTERN)
      return false if normalized.match?(IDENTITY_NON_CONFIRMATION_PATTERN)
      return false if normalized.match?(IDENTITY_CONFIRMATION_REQUEST_PATTERN)
      return false if normalized.match?(IDENTITY_DOCUMENTARY_PATTERN) && !normalized.match?(DEICTIC_EQUIPMENT_PATTERN)

      true
    end
    private_class_method :identity_unit?

    def self.operation_unit?(normalized)
      return false if normalized.blank?

      normalized.to_enum(:scan, OPERATION_PATTERN).any? do
        !negated_before?(normalized, Regexp.last_match.begin(0))
      end
    end
    private_class_method :operation_unit?

    def self.negated_before?(normalized, index)
      prefix = normalized[0...index]
      last = nil
      prefix.to_enum(:scan, OPERATION_NEGATOR_PATTERN).each { last = Regexp.last_match }
      return false unless last

      !prefix[last.end(0)..].match?(/[,:;]/)
    end
    private_class_method :negated_before?

    def self.observational_question?(unit)
      unit.question && !applicability_normalize(unit.text).match?(ACTION_REQUEST_PATTERN)
    end
    private_class_method :observational_question?

    def self.qualified_reference?(unit, units, patterns, chunk_count)
      attribution_window = [ unit.text, unit.intro, unit.heading ]
      neighbors = units.select { |other|
        other.paragraph_id == unit.paragraph_id && (other.index - unit.index).abs == 1
      }
      disclaimer_window = attribution_window + neighbors.map(&:text)
      attribution_window.compact.any? { |text| attribution_text?(text, patterns, chunk_count) } &&
        disclaimer_window.compact.any? { |text| applicability_normalize(text).match?(NON_APPLICABILITY_PATTERN) }
    end
    private_class_method :qualified_reference?

    def self.attribution_text?(text, patterns, chunk_count)
      normalized = applicability_normalize(text)
      return false unless normalized.match?(ATTRIBUTION_PATTERN)
      return true if patterns.any? { |pattern| normalized.match?(pattern) }

      text.to_s.scan(/\[(\d+)\]/).any? { |number,| number.to_i.between?(1, chunk_count) }
    end
    private_class_method :attribution_text?

    def self.foreign_value_unit?(original, chunks, question)
      return false if echo_of_question?(original, question)

      body = Array(chunks).map { |chunk| chunk[:content].to_s }.join("\n")
      return false if body.blank?
      return true if foreign_tokens(original, body, question, chunks).any?
      return true if promoted_code_meaning?(original, body, question)
      return true if promoted_connection?(original, body, question, chunks)
      return true if promoted_function?(original, body, question, chunks)

      false
    end
    private_class_method :foreign_value_unit?

    def self.foreign_tokens(original, body, question, chunks)
      phrases = identity_phrases(chunks).to_set
      tokens = []
      tokens.concat(original.to_s.scan(AnswerSafetyProcessor::IDENTIFIER_PATTERN))
      tokens.concat(fault_tokens(original))
      tokens.concat(number_unit_spans(original))
      tokens.concat(body.scan(CHUNK_DESIGNATOR_PATTERN).select { |token| original.include?(token) })
      tokens.uniq.select { |token|
        next false if identity_phrase_token?(token, phrases)
        next false unless body.match?(/#{Regexp.escape(token)}/i)
        next false if question.to_s.match?(/#{Regexp.escape(token)}/i)

        true
      }
    end
    private_class_method :foreign_tokens

    def self.identity_phrase_token?(token, phrases)
      label = normalize_label(token)
      phrases.any? { |phrase| phrase == label || phrase.include?(label) && label.length >= 3 }
    end
    private_class_method :identity_phrase_token?

    def self.fault_tokens(text)
      tokens = text.to_s.scan(AnswerSafetyProcessor::FAULT_CODE_PATTERN)
      tokens.concat(text.to_s.scan(CHUNK_DESIGNATOR_PATTERN))
      tokens.uniq
    end
    private_class_method :fault_tokens

    def self.number_unit_spans(text)
      spans = []
      text.to_s.scan(SourceFidelityGuard::PAIR_PATTERN) { spans << Regexp.last_match(0) }
      text.to_s.scan(SourceFidelityGuard::RANGE_PATTERN) { spans << Regexp.last_match(0) }
      text.to_s.scan(CHUNK_TIME_PATTERN) { spans << Regexp.last_match(0) }
      spans.uniq
    end
    private_class_method :number_unit_spans

    def self.promoted_code_meaning?(original, body, _question)
      return false unless original.match?(AnswerSafetyProcessor::CODE_MEANING_PATTERN)

      fault_tokens(original).any? { |token| body.include?(token) }
    end
    private_class_method :promoted_code_meaning?

    def self.promoted_connection?(original, body, _question, _chunks)
      return false unless original.match?(AnswerSafetyProcessor::CONNECTION_CLAIM_PATTERN)

      body_tokens(original).any? { |token| body.match?(/#{Regexp.escape(token)}/i) }
    end
    private_class_method :promoted_connection?

    def self.promoted_function?(original, body, _question, _chunks)
      return false unless original.match?(AnswerSafetyProcessor::COMPANION_FUNCTION_ATTRIBUTION_PATTERN)

      body_tokens(original).any? { |token| body.match?(/#{Regexp.escape(token)}/i) }
    end
    private_class_method :promoted_function?

    def self.body_tokens(original)
      tokens = original.to_s.scan(AnswerSafetyProcessor::IDENTIFIER_PATTERN)
      tokens.concat(fault_tokens(original))
      tokens.uniq
    end
    private_class_method :body_tokens

    def self.echo_of_question?(original, question)
      unit = applicability_normalize(original)
      asked = applicability_normalize(question)
      unit.length >= 12 && asked.present? && asked.include?(unit)
    end
    private_class_method :echo_of_question?

    def self.applicability_units(text)
      units = []
      heading = nil
      paragraph_id = 0
      text.to_s.split(/\n[ \t]*\n/).each do |block|
        lines = block.split("\n")
        next if lines.all? { |line| line.strip.empty? }
        if lines.one? && heading_line?(lines.first)
          heading = lines.first.strip
          next
        end

        intro = nil
        paragraph_units = []
        lines.each do |line|
          stripped = line.strip
          next if stripped.empty?
          if heading_line?(stripped)
            heading = stripped
            next
          end
          if intro_line?(stripped)
            intro = stripped
            paragraph_units << unit_for(stripped, paragraph_id, intro: nil, heading: heading)
            next
          end

          list = stripped.match?(SourceFidelityGuard::LIST_ITEM)
          body = list ? strip_list_marker(stripped) : stripped
          split_applicability_sentences(body).each do |sentence|
            paragraph_units << unit_for(
              sentence, paragraph_id, intro: (list ? intro : nil), heading: heading
            )
          end
          intro = nil unless list
        end
        paragraph_units.each_with_index { |unit, index| unit.index = index }
        units.concat(paragraph_units)
        paragraph_id += 1
      end
      units
    end
    private_class_method :applicability_units

    def self.unit_for(text, paragraph_id, intro:, heading:)
      ApplicabilityUnit.new(
        text: text, paragraph_id: paragraph_id, index: 0,
        intro: intro, heading: heading, question: text.strip.end_with?("?")
      )
    end
    private_class_method :unit_for

    def self.heading_line?(line)
      stripped = line.to_s.strip
      stripped.match?(/\A\#{1,6}\s+\S/) || stripped.match?(/\A\*\*[^*]+\*\*\z/)
    end
    private_class_method :heading_line?

    def self.intro_line?(line)
      line.to_s.strip.match?(/:\s*\z/) && !line.match?(SourceFidelityGuard::LIST_ITEM)
    end
    private_class_method :intro_line?

    def self.strip_list_marker(line)
      line.sub(/\A\s*(?:[-*•]|\d{1,2}[.)])\s+/, "")
    end
    private_class_method :strip_list_marker

    def self.split_applicability_sentences(text)
      pieces = []
      start_at = 0
      index = 0
      while index < text.length
        unless sentence_boundary_at?(text, index)
          index += 1
          next
        end
        chunk = text[start_at..index].strip
        pieces << chunk if chunk.present?
        index += 1
        index += 1 while index < text.length && text[index] == " "
        start_at = index
      end
      tail = text[start_at..].to_s.strip
      pieces << tail if tail.present?
      pieces
    end
    private_class_method :split_applicability_sentences

    def self.sentence_boundary_at?(text, index)
      char = text[index]
      return true if char == "\n" || char == "!" || char == "?"
      return false unless char == "."

      rest = text[(index + 1)..].to_s
      rest.match?(/\A\s*\z/) || rest.match?(/\A\s+[[:upper:]¿¡]/)
    end
    private_class_method :sentence_boundary_at?

    def self.applicability_normalize(text)
      normalize_label(text.to_s.gsub(/n't\b/i, " not "))
    end
    private_class_method :applicability_normalize

    def self.identity_phrase_patterns(chunks)
      identity_phrases(chunks).map { |phrase| /\b#{Regexp.escape(phrase)}\b/ }
    end
    private_class_method :identity_phrase_patterns

    def self.identity_phrases(chunks)
      phrases = []
      Array(chunks).each do |chunk|
        metadata = metadata_of(chunk)
        phrases.concat(brands_in_identity(chunk))
        IDENTITY_FIELDS.each do |field|
          phrases.concat(phrases_from_identity_text(normalize_label(metadata[field])))
        end
        Array(metadata["aliases"]).each do |label|
          phrases.concat(phrases_from_identity_text(normalize_label(label)))
          phrases.concat(brands_in_label(label))
        end
      end
      phrases.map { |phrase| phrase.to_s.squish }.uniq.select { |phrase| phrase.length >= 3 }
    end
    private_class_method :identity_phrases

    def self.phrases_from_identity_text(normalized)
      return [] if normalized.blank?

      content = normalized.split.reject { |token| IDENTITY_STOPWORDS.include?(token) || token.length < 2 }
      phrases = []
      content.each_cons(2) { |left, right| phrases << "#{left} #{right}" }
      content.each_with_index do |token, index|
        phrases << "#{content[index - 1]} #{token}" if index.positive? && token.match?(/\d/)
        phrases << token if token.match?(/\d/) && token.match?(/\p{L}/)
      end
      phrases.concat(content.select { |token| specific_identity_token?(token) }) if content.size <= 2
      phrases
    end
    private_class_method :phrases_from_identity_text

    def self.specific_identity_token?(token)
      token.length >= 3 && !token.match?(/\A\d+\z/)
    end
    private_class_method :specific_identity_token?

    def self.brands_in_label(label)
      normalized = normalize_label(label)
      return [] if normalized.blank?

      KbDocumentResolver::BRANDS.select { |brand| normalized.match?(/\b#{Regexp.escape(brand)}\b/) }
    end
    private_class_method :brands_in_label

    def self.unconfirmed_reference_clause(chunks, locale)
      names = unconfirmed_reference_labels(chunks)
      return I18n.t("rag.unconfirmed_reference_unnamed", locale: locale) if names.empty?

      I18n.t("rag.unconfirmed_reference_clause", locale: locale, names: names.join("; "))
    end
    private_class_method :unconfirmed_reference_clause

    def self.unconfirmed_reference_labels(chunks)
      Array(chunks).filter_map { |chunk|
        name = document_name(chunk)
        next if name.blank? || name == "DATA_NOT_AVAILABLE"

        page = metadata_of(chunk)["page_number"].presence
        page.present? ? "#{name}, p. #{page}" : name
      }.uniq.first(3)
    end
    private_class_method :unconfirmed_reference_labels

    def self.document_name(chunk)
      metadata = metadata_of(chunk)
      metadata["canonical_name"].presence ||
        metadata["original_filename"].presence ||
        "DATA_NOT_AVAILABLE"
    end
    private_class_method :document_name

    def self.not_required(chunks)
      build_result(chunks: Array(chunks), labels: blank_labels(chunks), status: nil, reason: :not_required)
    end
    private_class_method :not_required

    def self.build_result(chunks:, labels:, status:, reason: nil, applicability: nil, excluded_labels: [])
      Result.new(
        chunks: chunks,
        labels: labels,
        blocked: false,
        undeclared_private: 0,
        unconfirmed_general: 0,
        status: status,
        reason: reason,
        applicability: applicability || Array.new(Array(chunks).size),
        excluded_labels: Array(excluded_labels)
      )
    end
    private_class_method :build_result

    def self.blank_labels(chunks)
      Array.new(Array(chunks).size)
    end
    private_class_method :blank_labels

    # :out stays reference-only so a pin is not widened.
    # An explicit manufacturer conflict is reference-only before a selected
    # document can be accepted as neutral. A needle match is this job only
    # when that conflict is absent.
    # A selected document that names a different KbDocumentResolver brand is
    # reference-only. A selected document that does not name one stays
    # THIS JOB: the pin compensates for incomplete metadata.
    def self.chunk_applicability(chunk, needles, membership, identity, resolution)
      return :reference_only if membership == :out
      return :reference_only if resolution.conflict
      return :compatible if needles.any? && identity_matches?(chunk, needles)
      return conflicting_or_neutral(chunk, identity, resolution) if membership == :in
      return nil if needles.empty?

      :reference_only
    end
    private_class_method :chunk_applicability

    def self.conflicting_or_neutral(chunk, identity, resolution)
      return :neutral unless identity&.known?
      return :reference_only if conflicting_brand?(chunk, resolution)

      :neutral
    end
    private_class_method :conflicting_or_neutral

    def self.conflicting_brand?(chunk, resolution)
      brands = brands_in_identity(chunk)
      return false if brands.empty?

      known = resolution.manufacturer_labels
      brands.any? { |brand| known.none? { |label| label == brand || contains_word?(label, brand) } }
    end
    private_class_method :conflicting_brand?

    def self.brands_in_identity(chunk)
      metadata = metadata_of(chunk)
      text = IDENTITY_FIELDS.filter_map { |field| metadata[field].presence }.join(" ")
      normalized = FollowupQueryRewriter.normalize_label(text)
      return [] if normalized.blank?

      KbDocumentResolver::BRANDS.select { |brand| normalized.match?(/\b#{Regexp.escape(brand)}\b/) }
    end
    private_class_method :brands_in_identity

    def self.identity_matches?(chunk, needles)
      metadata = metadata_of(chunk)
      IDENTITY_FIELDS.any? do |field|
        needles.any? { |needle| contains_word?(metadata[field], needle) }
      end
    end
    private_class_method :identity_matches?

    def self.contains_word?(haystack, needle)
      normalized = FollowupQueryRewriter.normalize_label(haystack)
      label = FollowupQueryRewriter.normalize_label(needle)
      return false if normalized.blank? || label.blank?

      normalized.match?(/\b#{Regexp.escape(label)}\b/)
    end
    private_class_method :contains_word?

    # A current model is more specific than an inherited manufacturer.
    # Same-correlation facts travel together. Two current trusted
    # manufacturers are not a compatibility union: neither label makes a
    # body applicable. The current model, when there is one, stays a needle.
    #
    # An explicit manufacturer conflict recorded by F3 is different from a
    # stale inherited manufacturer. Neither side is applicable, and a model
    # from that photo does not make either manual a procedure for this job.
    def self.resolve_needles(identity)
      explicit = explicit_manufacturer_conflict(identity)
      return unresolved_manufacturer_conflict(identity, explicit) if explicit

      facts = identity.facts
      models = slot_facts(facts, "model")
      manufacturers = slot_facts(facts, "manufacturer")
      identifiers = slot_facts(facts, "identifier")
      current_model = models.last
      if current_model
        current_manufacturers = manufacturers.select { |fact| same_correlation?(fact, current_model) }
        current_identifiers = identifiers.select { |fact| same_correlation?(fact, current_model) }
        current_models = models.select { |fact| fact.equal?(current_model) || same_correlation?(fact, current_model) }
      else
        current_manufacturers = manufacturers
        current_identifiers = identifiers
        current_models = []
      end

      distinct = current_manufacturers.map { |fact| normalize_label(fact["value"]) }.uniq
      conflict = distinct.size > 1
      values = current_models.pluck("value")
      excluded = conflict ? current_manufacturers.pluck("value") : []
      current_manufacturers.each { |fact| values << fact["value"] } unless conflict
      current_identifiers.each do |fact|
        next if conflict && excluded.any? { |label| normalize_label(label) == normalize_label(fact["value"]) }

        values << fact["value"]
      end
      Resolution.new(
        values: values.map { |value| value.to_s.strip }.compact_blank.uniq,
        conflict: conflict,
        manufacturer_labels: conflict ? [] : current_manufacturers.map { |fact| normalize_label(fact["value"]) }.uniq,
        excluded_labels: excluded.map { |value| value.to_s.strip }.uniq
      )
    end
    private_class_method :resolve_needles

    def self.empty_resolution
      Resolution.new(values: [], conflict: false, manufacturer_labels: [], excluded_labels: [])
    end
    private_class_method :empty_resolution

    def self.explicit_manufacturer_conflict(identity)
      Array(identity.conflicts).find { |row|
        row["fact"] == "manufacturer" && row["user"].present? && row["photo"].present? &&
          normalize_label(row["user"]) != normalize_label(row["photo"])
      }
    end
    private_class_method :explicit_manufacturer_conflict

    def self.unresolved_manufacturer_conflict(identity, conflict)
      turn = conflict["correlation_id"].to_s
      excluded = [ conflict["user"], conflict["photo"] ]
      values = []
      slot_facts(identity.facts, "model").each do |fact|
        next if conflicting_observation?(fact, turn)

        values << fact["value"]
      end
      slot_facts(identity.facts, "identifier").each do |fact|
        next if conflicting_observation?(fact, turn)
        next if excluded.any? { |label| normalize_label(label) == normalize_label(fact["value"]) }

        values << fact["value"]
      end
      Resolution.new(
        values: values.map { |value| value.to_s.strip }.compact_blank.uniq,
        conflict: true,
        manufacturer_labels: [],
        excluded_labels: excluded.map { |value| value.to_s.strip }.uniq
      )
    end
    private_class_method :unresolved_manufacturer_conflict

    def self.conflicting_observation?(fact, turn)
      turn.present? && fact["correlation_id"].to_s == turn
    end
    private_class_method :conflicting_observation?

    def self.slot_facts(facts, slot)
      Array(facts).select do |fact|
        fact["slot"] == slot && needle_source?(fact) && fact["value"].present?
      end
    end
    private_class_method :slot_facts

    def self.needle_source?(fact)
      NEEDLE_SOURCES.include?(fact.to_h["source"].to_s)
    end
    private_class_method :needle_source?

    def self.focus_membership(chunk, uris)
      return nil if uris.empty?

      found = chunk_uris(chunk)
      return nil if found.empty?

      found.any? { |uri| uris.include?(uri) } ? :in : :out
    end
    private_class_method :focus_membership

    def self.chunk_uris(chunk)
      metadata = metadata_of(chunk)
      location = (chunk[:location] || chunk["location"] || {}).to_h
      [
        chunk[:location_uri], chunk["location_uri"],
        chunk[:original_source_uri], chunk["original_source_uri"],
        chunk[:bedrock_source_uri], chunk["bedrock_source_uri"],
        metadata["original_source_uri"],
        metadata["x-amz-bedrock-kb-source-uri"],
        location[:uri] || location["uri"]
      ].map { |value| value.to_s.strip }.compact_blank.uniq
    end
    private_class_method :chunk_uris

    def self.same_correlation?(earlier, current)
      turn = current["correlation_id"].to_s
      turn.present? && turn == earlier["correlation_id"].to_s
    end
    private_class_method :same_correlation?

    def self.normalize_label(value)
      FollowupQueryRewriter.normalize_label(value)
    end
    private_class_method :normalize_label

    def self.coerce_identity(input)
      return nil if input.nil?
      return input if input.is_a?(EquipmentIdentity)
      return EquipmentIdentity.from_episode(input) if input.is_a?(ActiveEpisode) || input.is_a?(Hash)

      :malformed
    end
    private_class_method :coerce_identity

    def self.metadata_of(chunk)
      chunk[:metadata].to_h.stringify_keys
    end
    private_class_method :metadata_of
  end
end
