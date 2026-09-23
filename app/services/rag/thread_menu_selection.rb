# frozen_string_literal: true

module Rag
  # Identifies a query submitted by a legacy thread-menu chip. The chip sends
  # either the original clarification ("new query") or a stored segment joined
  # to it. Those are UI selections, not another technician statement, so the
  # ActiveEpisode shadow must not apply the correction/reset twice.
  class ThreadMenuSelection
    def self.call(question:, conversation_history:)
      rows = Array(conversation_history)
      menu = rows.last
      return false unless menu&.fetch("role", nil) == "assistant"

      prompts = %i[es en].map do |locale|
        I18n.t("rag.thread_menu_prompt", locale: locale).truncate(ConversationSession::MAX_MSG_LENGTH)
      end
      return false unless prompts.include?(menu["content"])

      original = rows.reverse_each.drop(1).find { |row| row["role"] == "user" }&.dig("content").to_s.strip
      selected = question.to_s.strip
      return false if original.blank? || selected.blank?

      selected == original || selected.end_with?("\n#{original}")
    end
  end
end
