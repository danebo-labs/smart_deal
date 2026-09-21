# frozen_string_literal: true

module Rag
  # Deterministic continuation of one technical question when the next turn
  # is only a catalog identifier. No HTTP, no model, no persistence.
  class FollowupQueryRewriter
    Result = Data.define(
      :question, :applied, :reason, :previous_correlation_id, :catalog_matches
    )

    MAX_FOLLOWUP_CHARS = 120
    MAX_FOLLOWUP_TOKENS = 12
    MAX_COMPOSED_CHARS = 442

    LEADING_INTERROGATIVE = /\A(?:y\s+)?(?:que|como|cual|cuanto|por que|what|how|which|why|when|where)\b/
    IDENTIFIER_PREFIX = /
      \A(?:
        it(?:'|\u2019)s\s+a\s+ |
        it\s+is\s+a\s+ |
        it(?:'|\u2019)s\s+ |
        it\s+is\s+ |
        es\s+una\s+ |
        es\s+un\s+ |
        es\s+
      )
    /ix
    IDENTIFICATION_LEXEME = /\b(?:marca|modelo|fabricante|manufacturer|model|nameplate|placa|brand)\b/i
    TECHNICAL_LEXEME = /\b(?:que|como|cual|cuanto|por que|what|how|which|why|when|where)\b/

    def self.call(question:, conversation_session:, account:, correlation_id:, now: Time.current)
      new(
        question: question,
        conversation_session: conversation_session,
        account: account,
        correlation_id: correlation_id,
        now: now
      ).call
    end

    def self.new_question?(text)
      return false if text.blank?
      return true if text.include?("?") || text.include?("¿")

      normalize_label(text).match?(LEADING_INTERROGATIVE)
    end

    def self.closed_followup_shape?(text)
      return false if text.blank? || text.include?("\n")
      return false if text.length > MAX_FOLLOWUP_CHARS

      text.split(/\s+/).size <= MAX_FOLLOWUP_TOKENS
    end

    def self.explicit_question?(text)
      stripped = text.to_s.strip
      return false if stripped.blank? || stripped.start_with?("[FOTO]")
      return true if stripped.include?("?") || stripped.include?("¿")

      normalize_label(stripped).match?(TECHNICAL_LEXEME)
    end

    def self.stored_whole?(text)
      value = text.to_s
      return false if value.length > ConversationSession::MAX_MSG_LENGTH
      return false if value.length == ConversationSession::MAX_MSG_LENGTH && value.end_with?("...")

      true
    end

    def self.normalize_label(value)
      value.to_s
           .unicode_normalize(:nfkd)
           .gsub(/\p{Mn}/, "")
           .downcase
           .gsub(/[^\p{L}\d]+/, " ")
           .squish
    end

    def initialize(question:, conversation_session:, account:, correlation_id:, now:)
      @question = question
      @conversation_session = conversation_session
      @account = account
      @correlation_id = correlation_id
      @now = now
    end

    def call
      return result(reason: "no_session") if @conversation_session.nil?
      return result(reason: "non_web_channel") unless allowed_channel?
      return result(reason: "account_mismatch") unless account_matches?
      return result(reason: "new_question") if new_question?(stripped_question)
      return result(reason: "not_identifier") unless closed_followup_shape?(stripped_question)

      pair = discriminant_pair
      return pair if pair.is_a?(Result)

      previous, previous_correlation_id = pair
      composed = "#{previous}\n#{stripped_question}"
      if composed.length > MAX_COMPOSED_CHARS
        return result(reason: "budget_exceeded", previous_correlation_id: previous_correlation_id)
      end

      identifier = identifier_for_match(stripped_question)
      if identifier.blank?
        return result(reason: "not_identifier", previous_correlation_id: previous_correlation_id)
      end

      matches = KbDocumentResolver.resolve_scoped(identifier, account: @account)
      unless catalog_identifier?(identifier, matches)
        return result(
          reason: "not_identifier",
          previous_correlation_id: previous_correlation_id,
          catalog_matches: matches
        )
      end

      result(
        question: composed,
        applied: true,
        reason: "rewritten",
        previous_correlation_id: previous_correlation_id,
        catalog_matches: matches
      )
    end

    private

    def stripped_question
      @stripped_question ||= @question.to_s.strip
    end

    def result(question: nil, applied: false, reason:, previous_correlation_id: nil, catalog_matches: [])
      Result.new(
        question: question || stripped_question,
        applied: applied,
        reason: reason,
        previous_correlation_id: previous_correlation_id,
        catalog_matches: catalog_matches
      )
    end

    def allowed_channel?
      session = @conversation_session
      return false unless session.respond_to?(:channel)

      session.channel == "web" ||
        (SharedSession::ENABLED && session.channel == SharedSession::CHANNEL)
    end

    def account_matches?
      return false if @account.nil? || !@conversation_session.respond_to?(:account_id)

      @conversation_session.account_id.present? && @conversation_session.account_id == @account.id
    end

    def new_question?(text)
      self.class.new_question?(text)
    end

    def closed_followup_shape?(text)
      self.class.closed_followup_shape?(text)
    end

    def discriminant_pair
      rows = episode_rows
      status, current = find_current(rows)
      return result(reason: "ambiguous_history") if status == :ambiguous

      users = previous_users(rows, current)
      return result(reason: "no_episode") if users.empty?

      explicit = users.select { |row| explicit_question?(row["content"]) }
      return result(reason: "no_discriminant") if explicit.empty?
      return result(reason: "ambiguous_history") if explicit.size > 1

      candidate = explicit.last
      return result(reason: "no_discriminant") unless stored_whole?(candidate["content"])
      return result(reason: "ambiguous_history") if users.any? { |row| row["index"] > candidate["index"] }

      chosen = assistant_after(rows, candidate, current)
               .reject { |row| row["content"].strip.start_with?("[FOTO]") }
               .last
      return result(reason: "no_discriminant") if chosen.nil? || blocked_assistant?(chosen["content"])
      return result(reason: "ambiguous_history") if identification_questions(chosen["content"]).size >= 2

      [ candidate["content"].strip, candidate["correlation_id"] ]
    end

    def episode_rows
      return [] unless @conversation_session.respond_to?(:conversation_history)

      cutoff = @now - ConversationSession::EPISODE_WINDOW
      rows = []
      Array(@conversation_session.conversation_history).each_with_index do |message, index|
        row = stringify_message(message)
        ts = parse_ts(row["ts"])
        next if ts.nil? || ts < cutoff || ts > @now

        rows << row.merge("ts" => ts, "index" => index)
      end
      rows
    end

    def stringify_message(message)
      {
        "role" => (message["role"] || message[:role]).to_s,
        "content" => (message["content"] || message[:content]).to_s,
        "ts" => message["ts"] || message[:ts],
        "correlation_id" => (message["correlation_id"] || message[:correlation_id]).presence
      }
    end

    def find_current(rows)
      if @correlation_id.present?
        hits = rows.select { |row| row["role"] == "user" && row["correlation_id"] == @correlation_id }
        return [ :ambiguous, nil ] if hits.size > 1
        return [ :found, hits.first ] if hits.size == 1
      end

      hits = rows.select { |row| row["role"] == "user" && row["content"].strip == stripped_question }
      return [ :ambiguous, nil ] if hits.size > 1
      return [ :found, hits.first ] if hits.size == 1

      [ :absent, nil ]
    end

    def previous_users(rows, current)
      users = rows.select { |row| row["role"] == "user" }
      users = users.select { |row| row["index"] < current["index"] } if current
      users.last(ConversationSession::EPISODE_MAX_USER_MESSAGES)
    end

    def assistant_after(rows, candidate, current)
      rows.select do |row|
        row["role"] == "assistant" &&
          row["index"] > candidate["index"] &&
          (current.nil? || row["index"] < current["index"])
      end
    end

    def explicit_question?(text)
      self.class.explicit_question?(text)
    end

    def stored_whole?(text)
      self.class.stored_whole?(text)
    end

    def blocked_assistant?(text)
      stripped = text.to_s.strip
      return true if stripped.blank?

      blocked_assistant_copies.include?(stripped)
    end

    def blocked_assistant_copies
      @blocked_assistant_copies ||= [
        I18n.t("rag.generation_retry", locale: :es),
        I18n.t("rag.generation_retry", locale: :en),
        I18n.t("rag.selection_turn_prompt", locale: :es),
        I18n.t("rag.selection_turn_prompt", locale: :en)
      ]
    end

    def identification_questions(text)
      text.to_s.split(/(?<=\?)/).filter_map do |sentence|
        cleaned = sentence.strip
        next if cleaned.blank? || !cleaned.end_with?("?")
        next unless cleaned.match?(IDENTIFICATION_LEXEME)

        normalize_label(cleaned)
      end.uniq
    end

    def identifier_for_match(text)
      text.sub(IDENTIFIER_PREFIX, "")
          .sub(/\A[[:punct:]]+/, "")
          .sub(/[[:punct:]]+\z/, "")
          .squish
    end

    def catalog_identifier?(identifier, matches)
      exact_catalog_name?(identifier, matches) || specific_designator_covered?(identifier, matches)
    end

    def exact_catalog_name?(identifier, matches)
      target = normalize_label(identifier)
      return false if target.blank?

      matches.any? do |match|
        names = [ match.document.display_name, *Array(match.document.aliases) ]
        names.any? { |name| normalize_label(name) == target }
      end
    end

    def specific_designator_covered?(identifier, matches)
      tokens = identifier.to_s.scan(KbDocumentResolver::TOKEN_RE).uniq
                         .select { |raw| KbDocumentResolver.specific_token?(raw) }
      return false if tokens.empty?

      covered = matches.flat_map { |match| Array(match.matched_tokens) }.map { |token| token.to_s.downcase }
      tokens.all? { |raw| covered.include?(raw.downcase) }
    end

    def normalize_label(value)
      self.class.normalize_label(value)
    end

    def parse_ts(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
