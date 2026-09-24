# frozen_string_literal: true

module Rag
  # Copies one underspecified technical object from the current goal into the
  # current turn. Fail closed: any doubt returns nil and the caller keeps the
  # turn unchanged. No stored component, no synonym expansion, no whole-goal paste.
  class TechnicalReferentResolver
    OPERATION = /ajust/i
    ARTICLE = /(?:el|la|los|las|este|esta|estos|estas|ese|esa|esos|esas|un|una|unos|unas)/i
    Result = Data.define(:status, :text) do
      def resolved? = status == :resolved
      def rejected? = status == :rejected
      def context_break? = status == :context_break

      def self.not_applicable
        new(status: :not_applicable, text: nil)
      end

      def self.resolved(text)
        new(status: :resolved, text: text)
      end

      def self.rejected
        new(status: :rejected, text: nil)
      end

      def self.context_break
        new(status: :context_break, text: nil)
      end
    end
    IDENTITY_HEADS = %w[modelo model marca fabricante].freeze
    CODE_ONLY = /\A(?:no\s+)?(?:(?:muestra|tiene|hay|da|es)\s+)?(?:(?:ningun|ninguna)\s+)?(?:codigo|code|error)(?:\s+\S+)?\z|\Asin codigo\z|\Ano code\z/
    COPULA = %w[es son un una el la los las modelo model marca fabricante no lo se].freeze
    UNKNOWN_ONLY = /\A(?:(?:el|la)\s+(?:modelo|model|marca|fabricante)\s+)?no (?:lo )?(?:se|sabemos|tengo)\z/
    MEASUREMENT_ONLY = /\A(?:lo medi|yo medi|medimos)(?: y da \d+(?:[.,]\d+)?)?\z/
    LINK = %w[de del].freeze
    PREPOSITION = %w[de del en con para sobre bajo].freeze
    ARTICLE_WORD = %w[el la los las].freeze

    def self.call(text:, goal_text:, goal_correlation_id:, goal_truncated:, prior_turns:, now:)
      new(
        text: text,
        goal_text: goal_text,
        goal_correlation_id: goal_correlation_id,
        goal_truncated: goal_truncated,
        prior_turns: Array(prior_turns),
        now: now
      ).call
    end

    # A bridge is the whole turn, not a brand or a code mentioned inside a fault.
    def self.identity_bridge?(text)
      normalized = FollowupQueryRewriter.normalize_label(text)
      return false if normalized.blank?
      return false if normalized.match?(RagRetrievalProfile::EXACT_PROCEDURE_PATTERN)

      brand_fact?(normalized) || normalized.match?(CODE_ONLY) || normalized.match?(UNKNOWN_ONLY) ||
        normalized.match?(MEASUREMENT_ONLY) || designator_only?(text) || model_fact?(normalized)
    end

    def self.brand_fact?(normalized)
      return false unless ActiveEpisodeTurn::MANUFACTURERS.any? { |brand| normalized.match?(/\b#{Regexp.escape(brand)}\b/) }

      leftover(normalized).empty?
    end

    def self.model_fact?(normalized)
      return false unless normalized.match?(/\b(?:modelo|model)\b/)

      leftover(normalized).length == 1
    end

    def self.leftover(normalized)
      stripped = normalized.dup
      ActiveEpisodeTurn::MANUFACTURERS.each { |brand| stripped = stripped.gsub(/\b#{Regexp.escape(brand)}\b/, " ") }
      stripped.split.reject { |word| COPULA.include?(word) }
    end

    # A label may precede the designator. A word after it is another claim.
    def self.designator_only?(text)
      tokens = text.to_s.scan(/[\p{L}\d][\p{L}\d\-]*/)
      return false if tokens.empty?

      labeled = tokens.drop(1)
      core = tokens.first && !KbDocumentResolver.specific_token?(tokens.first) ? labeled : tokens
      core.any? && core.all? { |token| KbDocumentResolver.specific_token?(token) }
    end

    # Declarative short turn that is not an identity fact. Questions stay on
    # the existing follow-up path. No component catalog.
    def self.specified_component?(text)
      new(
        text: text, goal_text: "", goal_correlation_id: "", goal_truncated: false,
        prior_turns: [], now: Time.current
      ).send(:specified_component?)
    end

    def self.independent_proposition?(text)
      return false if text.to_s.match?(/[?¿]/)

      !identity_bridge?(text)
    end

    def initialize(text:, goal_text:, goal_correlation_id:, goal_truncated:, prior_turns:, now:)
      @text = text.to_s
      @goal_text = goal_text.to_s
      @goal_correlation_id = goal_correlation_id.to_s
      @goal_truncated = goal_truncated
      @prior_turns = prior_turns
      @now = now
    end

    def call
      return Result.not_applicable unless @text.match?(OPERATION)
      return Result.rejected if @goal_truncated || @goal_text.blank? || @goal_correlation_id.blank?
      return Result.rejected unless @goal_text.match?(OPERATION)

      return Result.context_break if current_breaks_continuity?

      window = fresh_turns.last(ConversationSession::EPISODE_MAX_USER_MESSAGES)
      antecedent = antecedent_turn(window)
      return Result.rejected if antecedent.nil?
      return Result.context_break unless intermediates_are_bridges?(window, antecedent)

      source = object_phrase(@goal_text)
      return Result.rejected if source.blank?
      return Result.context_break if contaminated?(source) || coordinated?(source)

      expanded = expand(source)
      return expanded if expanded.is_a?(Result)
      return Result.rejected if expanded.blank? || expanded == @text.strip
      return Result.rejected if expanded.length > FollowupQueryRewriter::MAX_COMPOSED_CHARS

      Result.resolved(expanded)
    end

    private

    def fresh_turns
      cutoff = @now - ConversationSession::EPISODE_WINDOW
      @prior_turns.filter_map { |turn|
        ts = parse_time(turn["ts"] || turn[:ts])
        next if ts.nil? || ts < cutoff || ts > @now

        {
          "content" => (turn["content"] || turn[:content]).to_s,
          "correlation_id" => (turn["correlation_id"] || turn[:correlation_id]).to_s,
          "ts" => ts
        }
      }
    end

    def antecedent_turn(window)
      matches = window.select { |turn| turn["correlation_id"] == @goal_correlation_id }
      return nil unless matches.one?
      return nil unless same_provenance?(matches.first["content"])

      matches.first
    end

    def same_provenance?(content)
      goal = FollowupQueryRewriter.normalize_label(@goal_text)
      turn = FollowupQueryRewriter.normalize_label(content)
      return false if goal.blank? || turn.blank?

      goal == turn
    end

    def intermediates_are_bridges?(window, antecedent)
      after = false
      window.each do |turn|
        if turn.equal?(antecedent)
          after = true
          next
        end
        next unless after
        return false unless self.class.identity_bridge?(turn["content"])
      end
      true
    end

    def object_phrase(text)
      phrase = text.match(/\bse\s+ajust\w*\s+(.+?)\s*\??\s*\z/i)&.[](1).to_s.strip
      phrase.presence
    end

    def contaminated?(phrase)
      normalized = FollowupQueryRewriter.normalize_label(phrase)
      current = FollowupQueryRewriter.normalize_label(@text)
      return true if normalized.match?(/\bno es\b|\bno era\b/)

      ActiveEpisodeTurn::MANUFACTURERS.each do |brand|
        return true if normalized.match?(/\b#{Regexp.escape(brand)}\b/) && !current.match?(/\b#{Regexp.escape(brand)}\b/)
      end
      phrase.scan(ActiveEpisodeTurn::DESIGNATOR_RE).uniq.each do |token|
        next unless KbDocumentResolver.specific_token?(token)
        return true unless @text.match?(/\b#{Regexp.escape(token)}\b/)
      end
      unreaffirmed_name?(phrase) || identity_complement?(phrase)
    end

    # Evidence that this turn breaks continuity lives in the turn itself.
    # A missing antecedent, a stale timestamp, or a truncated goal does not.
    def current_breaks_continuity?
      return true if specified_component?

      source = object_phrase(@goal_text)
      source.present? && contaminated?(source)
    end

    # With a new explicit model, a single complement token is identity unless
    # it is a simple Spanish common noun. A function phrase has two content
    # words and stays copyable. No character-length cutoff and no model list.
    def identity_complement?(phrase)
      return false unless @text.match?(ActiveEpisodeTurn::MODEL_VALUE_RE)

      _head, modifier = split_np(phrase)
      words = content_words(modifier.presence || phrase)
      words.one? && !common_noun?(words.first)
    end

    def content_words(text)
      FollowupQueryRewriter.normalize_label(text).split.reject { |word|
        LINK.include?(word) || ARTICLE_WORD.include?(word) || PREPOSITION.include?(word)
      }
    end

    def common_noun?(word)
      return false unless word.match?(/\A[a-z]+\z/)
      return false unless word.match?(/[aeiou]/)
      return false if word.match?(/[kwxy]/)
      return false unless word.match?(/[rlmn]/)

      word.scan(/[aeiou]+/).size <= 2
    end

    # Mixed-case and all-caps tokens are product identity. specific_token?
    # misses names with no digit. An unreaffirmed one blocks the copy.
    def unreaffirmed_name?(phrase)
      current = FollowupQueryRewriter.normalize_label(@text)
      phrase.scan(/[\p{L}\d][\p{L}\d\-]*/).any? do |token|
        next false unless token.match?(/\p{Lu}/) && (token.match?(/\p{Ll}/) || token.match?(/\A[\p{Lu}\d]{2,}\z/))

        !current.match?(/\b#{Regexp.escape(FollowupQueryRewriter.normalize_label(token))}\b/)
      end
    end

    def expand(source)
      source_head, source_modifier = split_np(source)
      return Result.rejected if source_head.blank? || source_modifier.blank? || !pure_complement?(source_modifier)
      return Result.context_break if identity_complement?(source_modifier)

      current_object = object_phrase(@text).presence || matching_leading_np(source_head)
      if current_object.present?
        head, modifier = split_np(current_object)
        return Result.context_break unless head_compatible?(head, source_head)
        return Result.context_break if modifier.present?
        return Result.rejected unless current_object.match?(/\b(?:#{ARTICLE})\s+/i)

        insert_modifier(head, source_modifier)
      else
        return Result.context_break if technical_nps.any?

        insert_omitted(source)
      end
    end

    def matching_leading_np(source_head)
      nps = technical_nps.select { |np| head_compatible?(split_np(np).first, source_head) && split_np(np).last.blank? }
      return nil unless nps.one?

      nps.first
    end

    def coordinated?(phrase)
      phrase.to_enum(:scan, /\b(\p{L}+)\s+(?:y|e|o)\s+(\p{L}+)\b/i).any? {
        left = FollowupQueryRewriter.normalize_label(Regexp.last_match(1))
        right = FollowupQueryRewriter.normalize_label(Regexp.last_match(2))
        content_word?(left) && content_word?(right)
      }
    end

    def content_word?(word)
      word.present? && PREPOSITION.exclude?(word) && ARTICLE_WORD.exclude?(word) && LINK.exclude?(word)
    end

    # Only a chain of de/del complements. "en minispace" is an equipment
    # qualifier even when the model is written in lowercase.
    def pure_complement?(modifier)
      tokens = FollowupQueryRewriter.normalize_label(modifier).split
      return false if tokens.empty?

      first_phrase = true
      until tokens.empty?
        return false unless LINK.include?(tokens.first)

        link = tokens.shift
        article = ARTICLE_WORD.include?(tokens.first)
        tokens.shift if article
        return false if first_phrase && !(article || link == "del")

        first_phrase = false
        noun = false
        while tokens.first && PREPOSITION.exclude?(tokens.first)
          tokens.shift
          noun = true
        end
        return false unless noun
      end
      true
    end

    def specified_component?
      technical_nps.any? { |np| split_np(np).last.present? }
    end

    def technical_nps
      @text.to_enum(:scan, /\b((?:#{ARTICLE})\s+\p{L}+)/i).filter_map {
        match = Regexp.last_match
        next if IDENTITY_HEADS.include?(FollowupQueryRewriter.normalize_label(split_np(match[1]).first))

        extra = @text[match.end(0)..][/\A(?:\s+(?!se\b|como\b|c[oó]mo\b|y\b|e\b|o\b)(?:del?\s+(?:la\s+|los\s+|las\s+|el\s+)?\p{L}+|\p{L}+))+/i]
        "#{match[1]}#{extra}"
      }
    end

    def split_np(phrase)
      rest = phrase.to_s.sub(/\A(?:#{ARTICLE})\s+/i, "")
      head, modifier = rest.split(/\s+/, 2)
      [ head.to_s, modifier.to_s.strip ]
    end

    def head_compatible?(left, right)
      stem(left) == stem(right) && stem(left).present?
    end

    def stem(word)
      FollowupQueryRewriter.normalize_label(word).sub(/s\z/, "")
    end

    def insert_modifier(head, modifier)
      pattern = /\b((?:#{ARTICLE})\s+#{Regexp.escape(head)})\b/i
      return nil unless @text.scan(pattern).one?

      @text.sub(pattern) { "#{Regexp.last_match(1)} #{modifier}" }
    end

    def insert_omitted(source)
      return nil unless @text.scan(/\bajust\w*/i).one?

      verb = @text.match(/\b(ajust\w*)\b/i)[1]
      return nil unless plural_verb?(verb) == plural_object?(source)

      @text.sub(/\b(ajust\w*)\b/i) { "#{Regexp.last_match(1)} #{source}" }
    end

    def plural_verb?(verb)
      verb.match?(/n\z/i)
    end

    def plural_object?(phrase)
      phrase.match?(/\A(?:los|las|estos|estas|esos|esas|unos|unas)\b/i)
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
