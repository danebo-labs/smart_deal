# frozen_string_literal: true

module Rag
  # Deterministic reading of this turn. It builds the retrieval string and
  # picks one of the four decisions. It does not call a model and it does
  # not write Document Focus.
  class TechnicalUnderstanding
    Decision = Data.define(
      :decision, :retrieval_query, :clarification, :pending_subject,
      :outside_discovery, :owns_query, :bare_identifier, :ask_when, :mutations,
      :dialogue_function, :context_carry
    ) do
      def clarify_first?
        decision == "clarify_first"
      end

      def search_and_clarify?
        decision == "search_and_clarify"
      end

      def best_effort?
        decision == "best_effort"
      end
    end

    IDENTITY_KEYS = %w[manufacturer model controller].freeze
    RELIABLE_SOURCES = %w[user photo catalog].freeze
    # A trailing "+" is part of the designator: CEA15+ is not CEA15.
    TOKEN_RE = /[A-Za-z0-9][A-Za-z0-9-]{1,29}\+?/
    NEGATED_RE = /\bno (?:es|era)\s+([a-z0-9][a-z0-9-]{1,30})/
    REPLACEMENT_RE = /\b(?:es|era)\s+([a-z0-9][a-z0-9-]{1,30})/
    SEARCH_RE = /\bbusca con eso\b|\bbusca igual\b/
    SHORT_UNKNOWN_RE = /\Ano (?:lo )?se\z/
    FILLERS = %w[que es significa quiere decir what is el la un una componente component de del].freeze
    GREETINGS = %w[hola hey bye chau].freeze
    MAX_PRIOR = 6
    MAX_OBSERVATIONS = 3

    FOLLOW_UP_RE = /\A(?:que reviso|y ahora|eso puede causar|como lo soluciono|que hago ahora)\b/
    META_RE = /\b(?:necesitas|necesita)\b.{0,40}\b(?:controlador|controller|modelo|marca|fabricante)\b|\Avolviendo a lo anterior\b/
    NEW_PROBLEM_RE = /\Anueva falla\b|\Aotra falla\b|\Aotro equipo\b/
    SIGNAL_RE = /\d|\b(?:pas[ae]|magnetiza\w*|cierr\w*|abr\w*|velocidad|fall\w*|puert\w*|iman\w*|codig\w*|error)\b/
    DIALOGUE_FUNCTIONS = %w[technical_report follow_up answer_pending correction meta_question new_problem].freeze

    def self.call(text:, episode:, focus_count: 0, prior_turns: [], locale: :es, analysis: nil)
      new(
        text: text, episode: episode, focus_count: focus_count,
        prior_turns: prior_turns, locale: locale, analysis: analysis
      ).call
    end

    def initialize(text:, episode:, focus_count:, prior_turns:, locale:, analysis: nil)
      @text = text.to_s.strip
      @normalized = FollowupQueryRewriter.normalize_label(@text)
      @words = @normalized.split
      @episode = episode
      @focus_count = focus_count.to_i
      @prior_turns = Array(prior_turns)
      @locale = locale.to_sym
      @analysis = analysis
    end

    def call
      resolutions = token_resolutions
      negated = negated_values
      replacement = replacement_value(negated)
      bare = bare_identifier
      identity = known_identity(negated)
      decision = choose(bare, resolutions, identity)
      carried = carry_context?(resolutions)
      owned = owns?(decision, resolutions, bare, negated, carried)
      query = retrieval_query(resolutions, negated, replacement)
      clarification, subject, ask_when = clarification_for(decision, bare, resolutions)
      Decision.new(
        decision: decision,
        retrieval_query: query,
        clarification: clarification,
        pending_subject: subject,
        outside_discovery: outside?(decision, bare, identity),
        owns_query: owned,
        bare_identifier: bare,
        ask_when: ask_when,
        mutations: mutations(resolutions, negated, replacement),
        dialogue_function: dialogue,
        context_carry: carried && !base_owns?(decision, resolutions, bare, negated)
      )
    end

    def self.apply!(episode, decision)
      return if episode.nil? || episode.blank? || decision.nil?

      new(text: "", episode: episode, focus_count: 0, prior_turns: [], locale: :es, analysis: nil)
        .apply_mutations!(episode, decision)
    end

    def apply_mutations!(episode, decision)
      return if episode.nil? || episode.blank?

      decision.mutations.each do |mutation|
        case mutation[:op]
        when :clear
          episode.clear_fact!(mutation[:key])
          strip_goal(episode, mutation[:value])
          strip_observations(episode, mutation[:value])
        when :write
          episode.write_fact!(
            mutation[:key],
            status: "known",
            value: mutation[:value],
            source: mutation[:source],
            correlation_id: mutation[:correlation_id].to_s,
            at: Time.current.iso8601
          )
        when :observe
          episode.append_observation!(mutation[:value], correlation_id: mutation[:correlation_id])
        when :clear_observations
          episode.clear_observations!
        end
      end
    end

    private

    def choose(bare, resolutions, identity)
      return "ready" if resolutions.any? { |item| item.type.present? && item.manufacturer.present? && item.status != :ambiguous }
      return "best_effort" if search_request?
      return "best_effort" if controller_unknown_answer?
      return "best_effort" if identity_unknown? && (bare || short_unknown?)
      return "search_and_clarify" if resolutions.any? { |item| item.status == :ambiguous }
      return "clarify_first" if bare && @focus_count.zero? && identity.empty? && resolutions.none? { |item| item.status == :exact }
      return "search_and_clarify" if bare && identity.empty?
      return "ready" if bare && identity.size >= 2
      return "search_and_clarify" if identity.any? && identity.exclude?("controller") && identity.exclude?("model") && symptom?
      "ready"
    end

    def outside?(decision, bare, identity)
      return false if decision == "clarify_first"
      return true if decision == "best_effort"
      return false if bare && identity.empty? && @focus_count.positive?

      true
    end

    def owns?(decision, resolutions, bare, negated, carried)
      base_owns?(decision, resolutions, bare, negated) || carried
    end

    def base_owns?(decision, resolutions, bare, negated)
      decision == "clarify_first" || (decision == "best_effort" && (bare.present? || search_request? || short_unknown? || controller_unknown_answer?)) || bare.present? ||
        resolutions.any? { |item| item.type.present? || item.status == :ambiguous } ||
        controller_negated?(negated)
    end

    def controller_negated?(negated)
      fact = @episode&.fact("controller")
      return false unless fact && fact["status"] == "known"

      negated.any? { |token| same?(fact["value"], token) }
    end

    def dropped_catalog_manufacturer?(negated)
      fact = @episode&.fact("manufacturer")
      fact && fact["source"] == "catalog" && controller_negated?(negated)
    end

    def clarification_for(decision, bare, resolutions)
      ambiguous = resolutions.find { |item| item.status == :ambiguous }
      if ambiguous
        text = I18n.t("rag.clarify_ambiguous_designator", token: ambiguous.candidates.join(" / "), locale: @locale)
        return [ text, "controller", :always ]
      end
      if decision == "best_effort" && (bare || search_request? || short_unknown? || controller_unknown_answer?)
        return [ I18n.t("rag.best_effort_candidate", locale: @locale), nil, :always ]
      end
      if decision == "search_and_clarify" && bare.nil? && known_identity([]).include?("manufacturer") &&
          known_identity([]).exclude?("controller") && known_identity([]).exclude?("model") && symptom?
        return [ I18n.t("rag.clarify_controller", locale: @locale), "controller", :always ]
      end
      return [ nil, nil, nil ] unless %w[clarify_first search_and_clarify].include?(decision) && bare

      key = decision == "clarify_first" ? "rag.clarify_identifier" : "rag.clarify_identifier_focus"
      when_to_ask = decision == "clarify_first" ? :instead : :absence
      [ I18n.t(key, token: bare.upcase, locale: @locale), "controller", when_to_ask ]
    end

    def retrieval_query(resolutions, negated, replacement)
      parts = []
      push_part(parts, current_turn(negated, replacement))
      push_part(parts, known_value("fault_code", negated))
      resolutions.each do |item|
        next unless item.status == :exact || item.status == :prefix
        next if negated.any? { |token| same?(item.value, token) }

        push_part(parts, item.value)
        push_part(parts, item.manufacturer)
      end
      push_part(parts, known_value("controller", negated))
      push_part(parts, known_value("model", negated))
      push_part(parts, known_value("manufacturer", negated)) unless dropped_catalog_manufacturer?(negated)
      observations.each { |line| push_part(parts, line) }
      push_part(parts, goal_text(negated))
      trim(parts)
    end

    def push_part(parts, text)
      value = text.to_s.squish
      return if value.blank?

      folded = FollowupQueryRewriter.normalize_label(value)
      return if parts.any? { |part| FollowupQueryRewriter.normalize_label(part).include?(folded) }

      parts.reject! { |part| redundant_fact?(part, folded) }
      parts << value
    end

    def redundant_fact?(part, haystack)
      folded = FollowupQueryRewriter.normalize_label(part)
      return false unless fact_value?(folded)

      covers?(haystack, folded)
    end

    def fact_value?(folded)
      return false if folded.blank?

      %w[manufacturer model controller fault_code].any? { |key|
        fact = @episode&.fact(key)
        fact && FollowupQueryRewriter.normalize_label(fact["value"]) == folded
      }
    end

    def covers?(haystack, needle)
      return false if needle.blank?

      /(?:\A| )#{Regexp.escape(needle)}(?: |\z)/.match?(haystack)
    end

    def trim(parts)
      while parts.join(" ").length > FollowupQueryRewriter::MAX_COMPOSED_CHARS && parts.size > 1
        parts.pop
      end
      text = parts.join(" ")
      text = text.first(FollowupQueryRewriter::MAX_COMPOSED_CHARS) if text.length > FollowupQueryRewriter::MAX_COMPOSED_CHARS
      return text if text.present?
      return nil if omit_current_turn?

      @text
    end

    def current_turn(negated, replacement)
      return "" if omit_current_turn?

      turn = @text.dup
      negated.each { |token| turn = turn.gsub(/\b#{Regexp.escape(token)}\b/i, " ") }
      turn = "#{turn} #{replacement}" if replacement.present? && turn.downcase.exclude?(replacement.downcase)
      turn.squish
    end

    def token_resolutions
      catalog = DocumentIdentityCatalog.current
      @text.scan(TOKEN_RE).filter_map { |token|
        resolution = catalog.resolve_designator(token)
        resolution if resolution.status != :none
      }.uniq { |item| [ item.status, item.value, item.candidates ] }
    end

    def bare_identifier
      words = @normalized.sub(/\?\z/, "").split
      words = words.drop(2) if words.first(2) == %w[que es] || words.first(2) == %w[what is]
      words = words.drop(1) while FILLERS.include?(words.first)
      return nil unless words.one?

      token = words.first
      return nil unless token.match?(/\A[a-z0-9]{2,4}\z/)
      return nil unless token.match?(/\d/) || token.match?(/\A[a-z]{3,4}\z/)
      return nil if known_brand?(token) || GREETINGS.include?(token)

      token
    end

    def known_identity(negated)
      IDENTITY_KEYS.select { |key|
        fact = @episode&.fact(key)
        fact && fact["status"] == "known" && RELIABLE_SOURCES.include?(fact["source"].to_s) &&
          negated.none? { |token| same?(fact["value"], token) }
      }
    end

    def known_value(key, negated)
      fact = @episode&.fact(key)
      return nil unless fact && fact["status"] == "known"
      return nil if negated.any? { |token| same?(fact["value"], token) }

      fact["value"]
    end

    def identity_unknown?
      IDENTITY_KEYS.any? { |key| @episode&.fact(key)&.dig("status") == "unknown_confirmed" }
    end

    def known_brand?(token)
      ActiveEpisodeTurn::MANUFACTURERS.any? { |brand|
        brand == token || brand.split.first == token
      }
    end

    def search_request?
      SEARCH_RE.match?(@normalized)
    end

    def short_unknown?
      SHORT_UNKNOWN_RE.match?(@normalized)
    end

    def symptom?
      @normalized.match?(/\b(puerta|cierra|abre|nivela|falla|error|ruido|codigo)\b/)
    end

    def negated_values
      values = @normalized.scan(NEGATED_RE).flatten
      replacements = @normalized.scan(REPLACEMENT_RE).flatten
      if values.empty? && @normalized.match?(/\bno\b/)
        fact = @episode&.fact("controller")
        if fact && fact["status"] == "known" && replacements.any? { |token| !same?(fact["value"], token) }
          values << fact["value"].to_s
        end
      end
      IDENTITY_KEYS.each do |key|
        fact = @episode&.fact(key)
        next unless fact && fact["status"] == "known"
        next unless values.any? { |token| same?(fact["value"], token) }

        values << FollowupQueryRewriter.normalize_label(fact["value"])
      end
      values.compact_blank.uniq
    end

    def replacement_value(negated)
      @text.to_s.scan(/\b(?:es|era)\s+([A-Za-z0-9][A-Za-z0-9-]{1,30})/i).flatten.find { |token|
        negated.none? { |old| same?(old, token) }
      }
    end

    def mutations(resolutions, negated, replacement)
      list = []
      IDENTITY_KEYS.each do |key|
        fact = @episode&.fact(key)
        next unless fact && fact["status"] == "known"
        next unless negated.any? { |token| same?(fact["value"], token) }

        list << { op: :clear, key: key, value: fact["value"] }
      end
      if list.any? { |item| item[:op] == :clear && item[:key] == "controller" }
        manufacturer = @episode&.fact("manufacturer")
        if manufacturer && manufacturer["source"] == "catalog"
          list << { op: :clear, key: "manufacturer", value: manufacturer["value"] }
        end
        if replacement.present?
          list << { op: :write, key: "controller", value: replacement, source: "user", correlation_id: nil }
        end
      end
      observation_spans.each do |span|
        list << { op: :observe, value: span, correlation_id: nil }
      end
      list << { op: :clear_observations } if dialogue == "new_problem"
      resolutions.each do |item|
        next unless item.type && item.manufacturer && item.status != :ambiguous
        next if negated.any? { |token| same?(item.value, token) }

        list << write_mutation("controller", item.value, "catalog") if item.type == "controller" && writable?("controller")
        list << write_mutation("model", item.value, "catalog") if item.type == "model" && writable?("model")
        list << write_mutation("manufacturer", item.manufacturer, "catalog") if writable?("manufacturer")
      end
      list.compact
    end

    def write_mutation(key, value, source)
      { op: :write, key: key, value: value, source: source, correlation_id: nil }
    end

    def writable?(key)
      fact = @episode&.fact(key)
      return true if fact.nil? || fact["status"] == "unknown_confirmed"
      return false if %w[user photo].include?(fact["source"].to_s) && fact["status"] == "known"

      true
    end

    def observations
      return [] if dialogue == "new_problem" || dialogue == "correction"

      stored = Array(@episode&.observations).filter_map { |row|
        without_replaced_brands(row["text"].to_s).squish.presence
      }
      return stored.last(MAX_OBSERVATIONS) if stored.any?
      return [] unless carry_context?(token_resolutions)

      filtered_prior_turns.last(MAX_PRIOR).last(MAX_OBSERVATIONS)
    end

    def filtered_prior_turns
      @prior_turns.filter_map { |turn|
        body = turn.is_a?(Hash) ? turn["content"] : turn
        line = body.to_s.squish.presence
        next if line.blank?
        next if FollowupQueryRewriter.normalize_label(line) == @normalized
        next unless technical_line?(line)

        line
      }
    end

    def goal_text(negated)
      text = @episode&.goal&.dig("text").to_s
      return nil if conversational_line?(text)

      text = without_replaced_brands(text)
      negated.each { |token| text = text.gsub(/\b#{Regexp.escape(token)}\b/i, " ") }
      text.squish.presence
    end

    def without_replaced_brands(text)
      current = FollowupQueryRewriter.normalize_label(known_value("manufacturer", []))
      return text if current.blank?

      ActiveEpisodeTurn::MANUFACTURERS.sort_by { |brand| -brand.length }.each do |brand|
        next if current == brand || current.start_with?("#{brand} ") || brand.start_with?("#{current} ")

        text = text.to_s.gsub(/\b#{Regexp.escape(brand)}\b/i, " ")
      end
      text.to_s.squish
    end

    def strip_observations(episode, value)
      token = value.to_s
      return if token.blank?

      episode.observations.map! do |row|
        text = row["text"].to_s.gsub(/\b#{Regexp.escape(token)}\b/i, " ").squish
        next if text.blank?

        row.merge("text" => text)
      end
      episode.observations.compact!
    end

    def strip_goal(episode, value)
      text = episode.goal&.dig("text").to_s
      return if text.blank?

      stripped = text.gsub(/\b#{Regexp.escape(value.to_s)}\b/i, " ").squish
      if stripped.blank?
        episode.clear_goal!
      else
        episode.assign_goal!(stripped, correlation_id: episode.goal["correlation_id"])
      end
    end

    def same?(left, right)
      FollowupQueryRewriter.normalize_label(left) == FollowupQueryRewriter.normalize_label(right)
    end

    def dialogue
      return @dialogue if defined?(@dialogue)

      function = if controller_unknown_answer? || model_unknown_answer? || (short_unknown? && !search_request?)
        "answer_pending"
      elsif meta?
        "meta_question"
      elsif follow_up?
        "follow_up"
      elsif correction?
        "correction"
      elsif new_problem?
        "new_problem"
      else
        "technical_report"
      end
      @dialogue = DIALOGUE_FUNCTIONS.include?(function) ? function : "technical_report"
    end

    def meta?
      META_RE.match?(@normalized)
    end

    def follow_up?
      FOLLOW_UP_RE.match?(@normalized)
    end

    def correction?
      NEGATED_RE.match?(@normalized) || @normalized.match?(/\bno (?:es|era)\b/)
    end

    def new_problem?
      NEW_PROBLEM_RE.match?(@normalized)
    end

    def controller_unknown_answer?
      return false unless @normalized.match?(/\bno (?:lo )?se\b/)
      return false if search_request?

      pending = @episode&.pending_fact&.dig("subject") || @episode&.pending_question&.dig("type")
      pending == "controller" || @normalized.match?(/\b(?:controlador|controller)\b/)
    end

    def model_unknown_answer?
      @normalized.match?(/\bno (?:lo )?se\b/) && @normalized.match?(/\bmodelo\b/) &&
        !@normalized.match?(/\b(?:controlador|controller)\b/)
    end

    def omit_current_turn?
      dialogue == "meta_question" || controller_unknown_answer? || (short_unknown? && !search_request?)
    end

    def carry_context?(resolutions)
      return false if dialogue == "correction" || dialogue == "new_problem"
      return false unless technical_substance? || filtered_prior_turns.any?
      return true if dialogue == "follow_up" || dialogue == "meta_question" || controller_unknown_answer?
      return true if search_request?
      return false if model_unknown_answer?
      return false if dialogue == "technical_report" && !technical_line?(@text)
      return false if @words.size >= 8
      return false if @words.size >= 6 && resolutions.any? { |item| item.status == :exact || item.status == :prefix }

      dialogue == "technical_report"
    end

    def technical_substance?
      return true if known_identity([]).any? || identity_unknown?
      return true if Array(@episode&.observations).any?

      goal = @episode&.goal&.dig("text").to_s
      normalized_goal = FollowupQueryRewriter.normalize_label(goal)
      return false if normalized_goal.blank? || normalized_goal == @normalized

      technical_line?(goal)
    end

    def technical_line?(text)
      normalized = FollowupQueryRewriter.normalize_label(text)
      return false if normalized.blank? || conversational_line?(normalized)

      SIGNAL_RE.match?(normalized)
    end

    def conversational_line?(text)
      normalized = FollowupQueryRewriter.normalize_label(text)
      normalized.match?(META_RE) || normalized.match?(FOLLOW_UP_RE) || normalized.match?(SHORT_UNKNOWN_RE) ||
        (normalized.match?(/\bno (?:lo )?se\b/) && normalized.match?(/\b(?:controlador|controller)\b/) && !normalized.match?(SIGNAL_RE))
    end

    def observation_spans
      return [] unless dialogue == "technical_report" && technical_line?(@text)

      spans = literal_analysis_observations
      spans = [ @text.squish ] if spans.empty?
      spans.map { |span| span.first(ActiveEpisode::MAX_OBSERVATION_CHARS) }.uniq
    end

    def literal_analysis_observations
      return [] unless @analysis.respond_to?(:technical_observations)

      Array(@analysis.technical_observations).filter_map { |span|
        text = span.to_s.squish
        next if text.blank?
        next unless @normalized.include?(FollowupQueryRewriter.normalize_label(text))

        text
      }
    end
  end
end
