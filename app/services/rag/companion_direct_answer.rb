# frozen_string_literal: true

module Rag
  # One companion turn as text. The same limited chunks go to the prompt and
  # to the existing publication gate. There is no tool schema.
  class CompanionDirectAnswer
    MAX_TOKENS = 700
    HISTORY_MAX_CHARS = 8_000
    TEMPERATURE = 0
    SYSTEM_PROMPT_PATH = Rails.root.join("app/prompts/bedrock/companion_direct.txt")
    SYSTEM_PROMPT = SYSTEM_PROMPT_PATH.read.freeze
    HISTORICAL_MARKER = /\[\d+\]/
    ASLEEP_STATUS = [ 500, 502, 503, 504 ].freeze

    Prepared = Data.define(:params, :system, :user, :chunks, :messages, :omitted, :history_chars)
    Composed = Data.define(:text, :stop_reason, :rejected)

    class << self
      def prepare(raw_question:, chunks:, episode:, session:, correlation_id: nil)
        kept = CompanionPlan.limit_statement_chunks(chunks)
        history, omitted = fit_history(history_turns(session, correlation_id, episode))
        current = current_text(raw_question, kept)
        messages = converse_messages(history, current)
        system = SYSTEM_PROMPT
        Prepared.new(
          params: params(system, messages),
          system: system,
          user: current,
          chunks: kept,
          messages: messages,
          omitted: omitted,
          history_chars: packed_length(history)
        ).tap { |prepared| record_history(prepared) }
      end

      def compose(response)
        stop_reason = response.respond_to?(:stop_reason) ? response.stop_reason.to_s : ""
        blocks = Array(response&.output&.message&.content)
        if blocks.any? { |block| tool_use?(block) }
          return Composed.new(text: "", stop_reason: stop_reason, rejected: "tool_use")
        end

        text = blocks.filter_map { |block| block.text if block.respond_to?(:text) }.join
        Composed.new(text: text, stop_reason: stop_reason, rejected: nil)
      end

      # A sleeping model or a paused store. Validation and access errors are not this.
      def asleep?(error)
        return false if error.is_a?(LocalPassLedger::Stop)

        name = error.class.name.to_s
        message = error.message.to_s
        return true if message.match?(Bedrock::AuroraColdStartRetry::AURORA_RESUME_PATTERN)
        return true if name.include?("ServiceUnavailable") || name.include?("InternalServer")
        return true if name.include?("Timeout") || error.is_a?(Timeout::Error)

        ASLEEP_STATUS.include?(http_status(error))
      end

      def http_status(error)
        response = error.context.http_response if error.respond_to?(:context) && error.context.respond_to?(:http_response)
        response&.status_code
      rescue StandardError
        nil
      end

      private

      def params(system, messages)
        {
          model_id: BedrockClient::QUERY_MODEL_ID,
          system: [ { text: system } ],
          messages: messages,
          inference_config: { temperature: TEMPERATURE, max_tokens: MAX_TOKENS }
        }
      end

      def current_text(raw_question, chunks)
        [
          "Mensaje de este turno:\n#{raw_question.to_s.strip}",
          sources_block(chunks)
        ].compact_blank.join("\n\n")
      end

      def sources_block(chunks)
        lines = [ "Fuentes de este turno:" ]
        Array(chunks).each_with_index do |chunk, index|
          lines << CompanionPlan.source_heading(chunk, index + 1)
          lines << DocumentIdentityScope.omit_terminal_evidence_records(chunk_body(chunk)).strip
        end
        lines.join("\n")
      end

      def chunk_body(chunk)
        (chunk[:content] || chunk["content"]).to_s
      end

      def history_turns(session, correlation_id, episode)
        return [] unless session.respond_to?(:conversation_history)

        cutoff = history_cutoff(session, episode)
        Array(session.conversation_history).filter_map do |message|
          next unless message.is_a?(Hash)
          role = message["role"].to_s
          next unless role == "user" || role == "assistant"
          next if correlation_id.present? && message["correlation_id"].to_s == correlation_id.to_s
          next if cutoff && !inside_cutoff?(message, cutoff)

          text = history_text(message)
          next if text.blank?

          turn = {
            role: role,
            text: text,
            correlation_id: message["correlation_id"],
            chars: text.length
          }
          turn[:text_provenance] = message["text_provenance"] if message["text_provenance"].present?
          turn
        end
      end

      def history_cutoff(session, episode)
        return session.episode_history_cutoff if session.respond_to?(:episode_history_cutoff)
        return nil if episode.nil?

        opened = episode.respond_to?(:opened_at) ? episode.opened_at : episode.to_h["opened_at"]
        opened.present? ? SessionContextBuilder.companion_message_ts(opened) : nil
      end

      def inside_cutoff?(message, cutoff)
        ts = SessionContextBuilder.companion_message_ts(message["ts"])
        ts && ts >= cutoff
      end

      def history_text(message)
        raw = if message["role"].to_s == "assistant"
          message["prompt_reply"].presence || message["full_content"].presence || message["content"].to_s
        else
          message["full_content"].presence || message["content"].to_s
        end
        text = raw.to_s.gsub(HISTORICAL_MARKER, "").strip
        return text if message["text_provenance"].blank?

        "[procedencia: #{message['text_provenance']}] #{text}"
      end

      def fit_history(turns)
        kept = turns.dup
        omitted = []
        while packed_length(kept) > HISTORY_MAX_CHARS
          index = kept.index { |turn| turn[:role] == "assistant" }
          if index
            omitted << kept.delete_at(index)
          elsif kept.any?
            omitted << kept.shift
          else
            break
          end
        end
        while kept.first && kept.first[:role] != "user"
          omitted << kept.shift
        end
        [ kept, omitted ]
      end

      def packed_length(turns)
        list = Array(turns).drop_while { |turn| turn[:role] != "user" }
        return 0 if list.empty?

        length = 0
        previous = nil
        list.each do |turn|
          length += 2 if previous == turn[:role]
          length += turn[:text].to_s.length
          previous = turn[:role]
        end
        length
      end

      def converse_messages(turns, current_text)
        messages = []
        Array(turns).each { |turn| append_message(messages, turn[:role], turn[:text]) }
        messages.shift while messages.first && messages.first[:role] != "user"
        append_message(messages, "user", current_text)
        messages
      end

      def append_message(messages, role, text)
        return if text.blank?

        if messages.last && messages.last[:role] == role
          messages.last[:content][0][:text] = "#{messages.last[:content][0][:text]}\n\n#{text}"
        else
          messages << { role: role, content: [ { text: text } ] }
        end
      end

      def tool_use?(block)
        return false unless block.respond_to?(:tool_use)

        use = block.tool_use
        !use.nil? && !(use.respond_to?(:empty?) && use.empty?)
      end

      def record_history(prepared)
        return unless ValidationCapture.active?

        ValidationCapture.record(
          "companion_direct_history",
          "history_chars" => prepared.history_chars,
          "omitted" => prepared.omitted.map { |turn|
            {
              "role" => turn[:role],
              "correlation_id" => turn[:correlation_id],
              "chars" => turn[:chars]
            }
          }
        )
      end
    end
  end
end
