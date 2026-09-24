# frozen_string_literal: true

module Rag
  # Resolves which stored user question a short turn continues.
  # One recoverable thread is joined verbatim. With several, the clarification
  # follows the answer that is already on screen: the most recent thread
  # (CG-D19). The chat never publishes a menu, chips, or a composed turn.
  # No HTTP, no model, no persistence.
  class EpisodeThreadResolver
    Result = Data.define(:outcome, :composed, :reason, :recoverable_count)

    def self.call(question:, conversation_session:, correlation_id:, locale:, now: Time.current)
      new(
        question: question,
        conversation_session: conversation_session,
        correlation_id: correlation_id,
        locale: locale,
        now: now
      ).call
    end

    def initialize(question:, conversation_session:, correlation_id:, locale:, now:)
      @question = question.to_s.strip
      @conversation_session = conversation_session
      @correlation_id = correlation_id
      @locale = locale
      @now = now
    end

    def call
      return pass("passthrough") unless Rag::ThreadMenuFlag.enabled?
      return pass("passthrough") if @conversation_session.nil? || !allowed_channel?
      return pass("not_followup_shape") if Rag::FollowupQueryRewriter.new_question?(@question) ||
                                           !Rag::FollowupQueryRewriter.closed_followup_shape?(@question)

      rows = episode_rows
      status, current = find_current(rows)
      # The current turn is already stored. Without a unique row there is no
      # index to exclude, so the turn is searched as written.
      return pass("passthrough") unless status == :found

      users = previous_users(rows, current)
      segments = segments_for(users)
      kept = dedupe(segments)
      if segments.any? { |segment| compose(segment).length > Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS }
        return pass("budget_exceeded", kept.size)
      end

      return pass("no_recoverable", 0) if kept.empty?

      Result.new(
        outcome: :join,
        composed: compose(kept.last),
        reason: kept.one? ? "joined" : "joined_latest",
        recoverable_count: kept.size
      )
    end

    private

    def pass(reason, count = 0)
      Result.new(outcome: :pass, composed: nil, reason: reason, recoverable_count: count)
    end

    def allowed_channel?
      session = @conversation_session
      return false unless session.respond_to?(:channel)

      session.channel == "web" ||
        (SharedSession::ENABLED && session.channel == SharedSession::CHANNEL)
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

      hits = rows.select { |row| row["role"] == "user" && row["content"].strip == @question }
      return [ :ambiguous, nil ] if hits.size > 1
      return [ :found, hits.first ] if hits.size == 1

      [ :absent, nil ]
    end

    def previous_users(rows, current)
      users = rows.select { |row| row["role"] == "user" && row["index"] < current["index"] }
      users.last(ConversationSession::EPISODE_MAX_USER_MESSAGES)
    end

    def segments_for(users)
      segments = []
      users.each do |row|
        text = row["content"].to_s.strip
        next if text.blank?

        if recoverable?(text)
          segments << text
        elsif segments.any? && !Rag::FollowupQueryRewriter.explicit_question?(text)
          segments[-1] = "#{segments[-1]}\n#{text}"
        end
      end
      segments
    end

    def recoverable?(text)
      Rag::FollowupQueryRewriter.explicit_question?(text) &&
        Rag::FollowupQueryRewriter.stored_whole?(text)
    end

    def dedupe(segments)
      kept = {}
      segments.each { |segment| kept[Rag::FollowupQueryRewriter.normalize_label(segment)] = segment }
      kept.values
    end

    def compose(segment)
      return segment if segment.include?(@question)

      "#{segment}\n#{@question}"
    end

    def parse_ts(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
