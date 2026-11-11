# frozen_string_literal: true

module Rag
  # One companion turn as text. The same limited chunks go to the prompt and
  # to the existing publication gate. There is no tool schema.
  # Persisted case passages keep their numbers and sit outside the fresh
  # 16_000-character window. The model, the token cap, and the thinking mode
  # stay on the captured defaults unless the direct-run environment is set.
  class CompanionDirectAnswer
    MAX_TOKENS = 700
    GENERATION_MAX_TOKENS = 4_000
    ANTHROPIC_MODEL_ID = "claude-haiku-5-5"
    GENERATOR_TIMEOUT = 60
    HISTORY_MAX_CHARS = 8_000
    REFERRAL_TURN = 4
    TEMPERATURE = 0
    SYSTEM_PROMPT_PATH = Rails.root.join("app/prompts/bedrock/companion_direct.txt")
    SYSTEM_PROMPT = SYSTEM_PROMPT_PATH.read.freeze
    HISTORICAL_MARKER = /\[\d+\]/
    ASLEEP_STATUS = [ 500, 502, 503, 504, 529 ].freeze

    Prepared = Data.define(:params, :system, :user, :chunks, :messages, :omitted, :history_chars)
    Composed = Data.define(:text, :stop_reason, :rejected)

    class AnthropicMessage
      def initialize(response)
        @response = response
      end

      def stop_reason
        value = @response.respond_to?(:stop_reason) ? @response.stop_reason : @response["stop_reason"]
        value.to_s
      end

      def usage
        @response.respond_to?(:usage) ? @response.usage : @response["usage"]
      end

      def output
        self
      end

      def message
        self
      end

      def content
        Array(blocks).filter_map { |block| text_block(block) }
      end

      # Non-text blocks consume output tokens without reaching the answer.
      def block_types
        Array(blocks).map { |block| block_type(block).presence || "unknown" }.tally
      end

      def thinking_text
        Array(blocks).filter_map { |block|
          next unless block_type(block) == "thinking"

          block.respond_to?(:thinking) ? block.thinking.to_s : (block[:thinking] || block["thinking"]).to_s
        }.join("\n")
      end

      def blocks
        @response.respond_to?(:content) ? @response.content : @response["content"]
      end

      def block_type(block)
        value = if block.respond_to?(:type)
          block.type
        elsif block.is_a?(Hash)
          block[:type] || block["type"]
        end
        value.to_s
      end

      def text_block(block)
        type = block_type(block)
        return nil if type.present? && type != "text"

        text = if block.respond_to?(:text)
          block.text
        elsif block.is_a?(Hash)
          block[:text] || block["text"]
        end
        return nil if text.nil?

        TextBlock.new(text.to_s)
      end
    end

    TextBlock = Struct.new(:text) do
      def tool_use
        nil
      end
    end

    class << self
      def prepare(raw_question:, chunks:, episode:, session:, correlation_id: nil)
        kept = CompanionPlan.limit_statement_chunks(chunks)
        episode_id = CompanionCaseRecord.episode_id_of(episode)
        merged = CompanionCaseRecord.sources(session, episode_id, kept)
        turns = history_turns(session, correlation_id, episode)
        history, omitted = fit_history(turns)
        technician_turn = turns.count { |turn| turn[:role] == "user" } + 1
        current = current_text(raw_question, merged, technician_turn)
        messages = converse_messages(history, current)
        system = SYSTEM_PROMPT
        Prepared.new(
          params: params(system, messages),
          system: system,
          user: current,
          chunks: merged,
          messages: messages,
          omitted: omitted,
          history_chars: packed_length(history)
        ).tap { |prepared|
          record_history(prepared)
          record_case_sources(merged)
        }
      end

      def compose(response)
        stop_reason = response.respond_to?(:stop_reason) ? response.stop_reason.to_s : ""
        if response.respond_to?(:block_types) && response.block_types.key?("tool_use")
          return Composed.new(text: "", stop_reason: stop_reason, rejected: "tool_use")
        end
        blocks = Array(response&.output&.message&.content)
        if blocks.any? { |block| tool_use?(block) }
          return Composed.new(text: "", stop_reason: stop_reason, rejected: "tool_use")
        end

        text = blocks.filter_map { |block| block.text if block.respond_to?(:text) }.join
        return Composed.new(text: "", stop_reason: stop_reason, rejected: "truncated") if stop_reason == "max_tokens"

        Composed.new(text: text, stop_reason: stop_reason, rejected: nil)
      end

      def provider
        "anthropic"
      end

      def configured_model_id
        raw = ENV["COMPANION_DIRECT_MODEL_ID"].to_s.strip
        return ANTHROPIC_MODEL_ID if raw.empty?
        raise BedrockRagService::BedrockServiceError, "companion_direct_model_rejected" unless anthropic_model_id?(raw)

        raw
      end

      def anthropic_model_id?(raw)
        return false if raw.include?("anthropic.claude") || raw.include?("bedrock")
        return false if raw.include?("haiku-4-5") || raw.include?("haiku-4.5")

        raw == ANTHROPIC_MODEL_ID
      end

      def tracking_model_id
        model = configured_model_id
        return model unless provider == "anthropic"
        return "claude-haiku-5-5-direct" if model == "claude-haiku-5-5" || model.include?("haiku-5-5")

        model
      end

      def generation_max_tokens
        raw = ENV["COMPANION_DIRECT_MAX_TOKENS"].to_s.strip
        return GENERATION_MAX_TOKENS if raw.empty?

        value = Integer(raw)
        value.positive? ? value : GENERATION_MAX_TOKENS
      rescue ArgumentError
        GENERATION_MAX_TOKENS
      end

      def effort
        ENV["COMPANION_DIRECT_EFFORT"].to_s.strip.presence
      end

      def adaptive_thinking?
        thinking_mode == "adaptive"
      end

      # Adaptive summarized thinking is the product default. disabled is the only off switch.
      def thinking_mode
        value = ENV["COMPANION_DIRECT_THINKING"].to_s.strip
        return value if %w[adaptive disabled].include?(value)

        "adaptive"
      end

      # Capture shape. The live call uses params or anthropic_payload, not this
      # hash, so the provider label never leaves with the credentials.
      def outbound_request(prepared)
        if provider == "anthropic"
          anthropic_payload(prepared.params).merge(provider: "anthropic")
        else
          prepared.params.merge(provider: "bedrock")
        end
      end

      # Measured Anthropic messages shape. Temperature is omitted while
      # adaptive thinking is on. No tools.
      def anthropic_payload(params)
        params = params.to_h
        system = Array(params[:system] || params["system"]).filter_map { |block|
          block = block.to_h if block.respond_to?(:to_h) && !block.is_a?(Hash)
          block[:text] || block["text"]
        }.join("\n\n")
        messages = Array(params[:messages] || params["messages"]).map { |message|
          message = message.to_h if message.respond_to?(:to_h) && !message.is_a?(Hash)
          role = (message[:role] || message["role"]).to_s
          text = Array(message[:content] || message["content"]).map { |block|
            block = block.to_h if block.respond_to?(:to_h) && !block.is_a?(Hash)
            block[:text] || block["text"]
          }.join
          { role: role, content: [ { type: "text", text: text } ] }
        }
        config = params[:inference_config] || params["inference_config"] || {}
        config = config.to_h if config.respond_to?(:to_h) && !config.is_a?(Hash)
        body = {
          model: (params[:model_id] || params["model_id"] || configured_model_id).to_s,
          max_tokens: (config[:max_tokens] || config["max_tokens"] || generation_max_tokens).to_i,
          system: system,
          messages: messages
        }
        body[:output_config] = { effort: effort } if effort
        body[:thinking] = { type: "adaptive", display: "summarized" } if adaptive_thinking?
        body[:thinking] = { type: "disabled" } if thinking_mode == "disabled"
        body
      end

      def anthropic_client
        return Thread.current[:companion_direct_anthropic] if Thread.current[:companion_direct_anthropic]

        key = ENV["ANTHROPIC_API_KEY"].presence || Rails.application.credentials.dig(:anthropic, :api_key)
        raise BedrockRagService::BedrockServiceError, "anthropic_api_key_missing" if key.blank?

        Anthropic::Client.new(api_key: key, max_retries: 0, timeout: GENERATOR_TIMEOUT)
      end

      def wrap_anthropic(response)
        AnthropicMessage.new(response)
      end

      # A sleeping model or a paused store. Validation and access errors are not this.
      def asleep?(error)
        return false if error.is_a?(LocalPassLedger::Stop)

        name = error.class.name.to_s
        message = error.message.to_s
        return true if message.match?(Bedrock::AuroraColdStartRetry::AURORA_RESUME_PATTERN)
        return true if name.include?("ServiceUnavailable") || name.include?("InternalServer")
        return true if name.include?("Overloaded")
        return true if name.include?("Timeout") || error.is_a?(Timeout::Error)

        ASLEEP_STATUS.include?(http_status(error))
      end

      def http_status(error)
        return error.status if error.respond_to?(:status) && error.status.is_a?(Integer)

        response = error.context.http_response if error.respond_to?(:context) && error.context.respond_to?(:http_response)
        response&.status_code
      rescue StandardError
        nil
      end

      private

      def params(system, messages)
        inference = { max_tokens: generation_max_tokens }
        inference[:temperature] = TEMPERATURE unless adaptive_thinking?
        body = {
          model_id: configured_model_id,
          system: [ { text: system } ],
          messages: messages,
          inference_config: inference
        }
        extra = bedrock_extra_fields
        body[:additional_model_request_fields] = extra if extra.any? && provider == "bedrock"
        body
      end

      # Bedrock field names for effort and adaptive thinking are confirmed by
      # the preflight payload before any call. The Anthropic payload above is
      # the shape already measured for Haiku 5.5.
      def bedrock_extra_fields
        fields = {}
        fields["thinking"] = { "type" => "adaptive", "display" => "summarized" } if adaptive_thinking?
        fields["output_config"] = { "effort" => effort } if effort
        fields
      end

      def current_text(raw_question, chunks, technician_turn = 1)
        [
          "Mensaje de este turno:\n#{raw_question.to_s.strip}",
          referral_note(technician_turn),
          sources_block(chunks)
        ].compact_blank.join("\n\n")
      end

      # Past the third exchange a manual rarely adds more; an open case is
      # handed over instead of extended.
      def referral_note(technician_turn)
        return nil if technician_turn < REFERRAL_TURN

        "Turno #{technician_turn} del técnico en este caso. Si la consulta sigue abierta, termina con un resumen " \
          "para derivar: lo que contó el técnico, lo que ya comprobó, lo que respalda la fuente con [n] y lo que falta. " \
          "Lo que falta no incluye un componente, ajuste o modo cuya condición o ejemplo documentado depende de algo " \
          "que el técnico ya descartó. Sin pregunta nueva salvo que su respuesta cierre el caso."
      end

      def sources_block(chunks)
        lines = [ "Fuentes de este turno:" ]
        Array(chunks).each_with_index do |chunk, index|
          next if CompanionCaseRecord.gap?(chunk)

          number = CompanionCaseRecord.number_of(chunk, index)
          lines << CompanionPlan.source_heading(chunk, number)
          lines << DocumentIdentityScope.omit_terminal_evidence_records(chunk_body(chunk)).strip
        end
        lines.join("\n")
      end

      def chunk_body(chunk)
        (chunk[:content] || chunk["content"]).to_s
      end

      def history_turns(session, correlation_id, episode)
        return [] unless session.respond_to?(:conversation_history)

        kept_numbers = CompanionCaseRecord.marker_numbers(session, CompanionCaseRecord.episode_id_of(episode))
        cutoff = history_cutoff(session, episode)
        Array(session.conversation_history).filter_map do |message|
          next unless message.is_a?(Hash)
          role = message["role"].to_s
          next unless role == "user" || role == "assistant"
          next if role == "assistant" && message["outcome"].to_s == "abstained"
          next if correlation_id.present? && message["correlation_id"].to_s == correlation_id.to_s
          next if cutoff && !inside_cutoff?(message, cutoff)

          text = history_text(message, kept_numbers)
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

      def history_text(message, kept_numbers)
        raw = if message["role"].to_s == "assistant" && message.key?("prompt_reply")
          message["prompt_reply"].to_s
        elsif message["role"].to_s == "assistant"
          message["full_content"].presence || message["content"].to_s
        else
          message["full_content"].presence || message["content"].to_s
        end
        kept = Array(kept_numbers)
        text = raw.to_s.gsub(HISTORICAL_MARKER) { |marker|
          number = marker[/\d+/].to_i
          kept.include?(number) ? marker : ""
        }.strip
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

      def record_case_sources(chunks)
        return unless ValidationCapture.active?

        ValidationCapture.record(
          "case_record_sources",
          "sources" => Array(chunks).filter_map.with_index { |chunk, index|
            next if CompanionCaseRecord.gap?(chunk)

            metadata = chunk[:metadata] || chunk["metadata"] || {}
            page = metadata["page_number"]
            page = metadata[:page_number] if page.nil?
            {
              "n" => CompanionCaseRecord.number_of(chunk, index),
              "sha256" => (chunk[:chunk_sha256] || chunk["chunk_sha256"]).to_s,
              "origin" => (chunk[:case_origin] || chunk["case_origin"] || "fresh").to_s,
              "location_uri" => (chunk[:location_uri] || chunk["location_uri"]).to_s,
              "page" => page
            }
          }
        )
      end
    end
  end
end
