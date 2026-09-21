# frozen_string_literal: true

module Rag
  # Resolves which stored user question a short turn continues.
  # One recoverable thread is joined verbatim. Two or three ask with the
  # existing quick-reply chips. No HTTP, no model, no persistence.
  class EpisodeThreadResolver
    Result = Data.define(:outcome, :composed, :options, :reason, :recoverable_count)

    MAX_MENU_OPTIONS = 4
    MAX_LABEL_CHARS = 48

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

      case kept.size
      when 0
        pass("no_recoverable", 0)
      when 1
        Result.new(
          outcome: :join,
          composed: compose(kept.first),
          options: nil,
          reason: "joined",
          recoverable_count: 1
        )
      else
        return pass("already_asked", kept.size) if already_asked?(rows)

        visible = kept.last(MAX_MENU_OPTIONS - 1)
        Result.new(
          outcome: :menu,
          composed: nil,
          options: menu_options(visible),
          reason: "menu",
          recoverable_count: kept.size
        )
      end
    end

    private

    def pass(reason, count = 0)
      Result.new(outcome: :pass, composed: nil, options: nil, reason: reason, recoverable_count: count)
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

    def already_asked?(rows)
      last_assistant = rows.reverse_each.find { |row| row["role"] == "assistant" }
      return false unless last_assistant
      return false unless menu_prompts.include?(last_assistant["content"])

      previous_user = rows.reverse_each.find do |row|
        row["role"] == "user" && row["index"] < last_assistant["index"]
      end
      return false unless previous_user

      Rag::FollowupQueryRewriter.normalize_label(previous_user["content"]) ==
        Rag::FollowupQueryRewriter.normalize_label(@question)
    end

    def menu_prompts
      %i[es en].map do |locale|
        I18n.t("rag.thread_menu_prompt", locale: locale).truncate(ConversationSession::MAX_MSG_LENGTH)
      end
    end

    def menu_options(segments)
      options = segments.map do |segment|
        { label: menu_label(segment), query: compose(segment) }
      end
      options << {
        label: I18n.t("rag.thread_menu_new_query", locale: @locale),
        query: @question
      }
      options
    end

    def menu_label(segment)
      segment.lines.map(&:strip).reject(&:empty?).join(" — ").truncate(MAX_LABEL_CHARS)
    end

    def parse_ts(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
