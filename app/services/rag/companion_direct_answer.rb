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

    Prepared = Data.define(:params, :system, :user, :chunks, :messages, :omitted, :history_chars, :parameter_review)
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
      def prepare(raw_question:, chunks:, episode:, session:, correlation_id: nil,
                  reference_context: nil, photo_evidence: nil, unresolved_question: nil, scope_uris: nil, viewer_account: nil)
        episode_id = CompanionCaseRecord.episode_id_of(episode)
        kept = CompanionPlan.limit_statement_chunks(
          chunks, delivered: CompanionCaseRecord.ledger_identities(session, episode_id)
        )
        merged = CompanionCaseRecord.sources(session, episode_id, kept, scope_uris: scope_uris, viewer_account: viewer_account)
        allowed = scope_uris.nil? ? nil : merged.each_index.filter_map { |index| index + 1 unless CompanionCaseRecord.gap?(merged[index]) }
        turns = history_turns(session, correlation_id, episode, allowed_numbers: allowed)
        technician_turn = turns.count { |turn| turn[:role] == "user" } + 1
        referent = CompanionSequence.referent_context(raw_question, episode)
        case_context = if session.is_a?(FieldCases::TurnContext)
          SessionContextBuilder.companion_case(SessionContextBuilder.companion_episode(session, episode), {}, session: session,
                                                  correlation_id: correlation_id)
        end
        parameter_review = CompanionParameterReview.build(question: raw_question, episode: episode, chunks: merged)
        carry = "Pregunta del mismo caso que quedó sin responder: #{unresolved_question}" if unresolved_question.present?
        history, omitted = fit_history(turns, budget: HISTORY_MAX_CHARS - case_context.to_s.length)
        continuation = ProcedureContinuation.prompt(history: history, chunks: merged, question: raw_question, episode: episode)
        context = [
          continuation, carry, reference_context, referent, case_context, parameter_review&.prompt, photo_evidence
        ].compact_blank.join("\n\n")
        outcome = (CheckOutcome.current(episode: episode, session: session, correlation_id: correlation_id) if CheckOutcomeFlag.enabled?)
        current = current_text(raw_question, merged, technician_turn, context: context, outcome: outcome)
        messages = converse_messages(history, current)
        system = SYSTEM_PROMPT
        Prepared.new(
          params: params(system, messages),
          system: system,
          user: current,
          chunks: merged,
          messages: messages,
          omitted: omitted,
          history_chars: packed_length(history),
          parameter_review: parameter_review
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

      # Replace an unrelated door check only when the current report and the
      # fault row support a specific remaining observation.
      def err14_followup(text, turn:, technician_texts:, sources:, locale:)
        return text unless locale.to_s == "es"

        question = PendingQuestion.followup_line(text, locale: locale)
        return text unless question&.match?(/act[uú]a el enclavamiento/i)
        report = FollowupQueryRewriter.normalize_label(turn)
        return text unless report.match?(
          /\A(?:ya )?limpie el filtro (?:pero |y )?(?:sigo viendo|persiste|sigue) (?:el mismo error|el error|err14)\z/
        )
        return text unless technician_texts.any? { |item| item.match?(/\bErr14\b/i) }
        return text unless sources.any? do |source|
          CompanionTurnPublication.citable_source?(source) && CompanionTurnPublication.content_of(source).lines.any? do |line|
            line.match?(/\A\|\s*Err14\s*\|\s*Sobrecalentamiento del m[oó]dulo\s*\|.*El ventilador est[aá] dañado.*Limpie el filtro de aire/i)
          end
        end

        updated = text.sub(/(?:^Al repetir una maniobra, )?#{Regexp.escape(question)}/, "¿El ventilador del controlador gira cuando el equipo está encendido?")
        ValidationCapture.record("companion_fault_followup", "fault" => "Err14")
        updated
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

      def current_text(raw_question, chunks, technician_turn = 1, context: nil, outcome: nil)
        [
          "Mensaje de este turno:\n#{raw_question.to_s.strip}",
          context,
          referral_note(technician_turn, outcome: outcome),
          intervention_note(technician_turn, outcome, raw_question),
          sources_block(chunks)
        ].compact_blank.join("\n\n")
      end

      # Stage 1, flag on (an outcome exists only then). The base prompt leaves
      # the link between a reported obstruction and the fault open. A reported
      # fix followed by a clean test is named as the likeliest explanation,
      # as the model's own reading, limited to that test. The exchange can then
      # close: the note that asks for the next check on every other turn
      # (live run 20261120T012019Z, T5 asked for repeated closings) does not
      # apply to this one. It does not apply either when this turn already
      # settled the active check and an earlier part is still partial
      # (live run 20261120T203919Z, T11): that closing sentence overrode
      # «No cierres el caso» and the next check was never asked. When that
      # next check is asked (live run 20261120T204305Z, T11), a reading the
      # technician already gave in this turn stays in the summary. The
      # question asks only whether the maneuver completes and that fault
      # returns. Live 20261120T234638Z, Thyssen T12: the same shape, but the
      # technician had just reported that the maneuver completed and the
      # fault stayed away. That report closes the check. Another cycle is
      # the same test again.
      def intervention_note(technician_turn, outcome, raw_question)
        return nil if outcome.nil? || technician_turn < REFERRAL_TURN

        "Si el técnico informó que retiró o corrigió algo y que después el síntoma no volvió en la prueba: nombra esa " \
          "intervención como la explicación más probable del cambio, en una oración tuya sin [n], sin darla por causa " \
          "confirmada. Di qué hizo y qué observó, acotado a esa prueba. #{intervention_closing(outcome, raw_question)}"
      end

      def intervention_closing(outcome, raw_question)
        if keep_next_check?(outcome) && !functional_result_reported?(raw_question)
          return "Siguen comprobaciones respondidas solo en parte: no uses esta nota para cerrar el intercambio ni " \
            "para reemplazar la comprobación siguiente. Anota la lectura y el cambio de síntoma que el técnico ya " \
            "dijo en este turno; no los conviertas en condición de la pregunta. La pregunta pide solo si la maniobra " \
            "se completa y si esa falla vuelve."
        end

        "Cierra el intercambio con lo que sigue sin verificar; esto prevalece sobre pedir la siguiente comprobación y " \
          "sobre repetir la misma prueba. Pregunta solo si una fuente de este turno respalda una comprobación distinta " \
          "que cambie la orientación, y cítala."
      end

      def keep_next_check?(outcome)
        outcome.settled_this_turn? && outcome.leaves_checks_open? && outcome.active.none? { |part| part.state == "partial" }
      end

      public

      # The functional check is already the technician's report: the maneuver
      # completed and the fault did not come back. "EA desapareció" alone is
      # the reading that opens that check, not its result.
      def functional_result_reported?(raw_question)
        text = raw_question.to_s
        text.match?(/maniobra se completa|se complet[oó] (?:el recorrido|la maniobra)/i) &&
          text.match?(/sin mostrar|sigue sin|no volvi[oó] a (?:aparecer|registrar)|no reaparece/i)
      end

      # T11 opens the functional check: P28 is back and EA is gone. T12 is the
      # result of that check and is excluded here.
      def functional_check_opened?(raw_question)
        text = raw_question.to_s
        !functional_result_reported?(text) && text.match?(/\bP28\b|\+110/i) && text.match?(/\bEA\s+desapareci[oó]\b/i)
      end

      FUNCTIONAL_CHECK_QUESTION = "¿La maniobra se completa y esa falla vuelve?"

      # Live 20261121T002654Z, Thyssen T11. The note already said the question
      # asks whether the maneuver completes and the fault returns. The draft
      # asked only whether EA returns, and ordered several closings. A
      # question that already asks whether the maneuver completes stays.
      def with_opened_functional_check(text)
        source = text.to_s
        return nil if source.match?(/identidad de este equipo no está confirmada/i)
        return nil if source.match?(/maniobra se completa|se completa el recorrido|recorrido se completa/i)
        return nil unless source.match?(/\b(?:EA|falla)\b/i) && source.match?(/vuelve|reaparece/i)

        blocks = source.split(/\n{2,}/)
        index = blocks.rindex { |block| block.match?(/[?？]/) }
        return nil unless index

        cleaned = blocks[index].sub(/,?\s*haz varios cierres seguidos\.?\s*/i, " ")
        cleaned = cleaned.sub(/¿[^?？]*[?？]/, FUNCTIONAL_CHECK_QUESTION)
        cleaned = cleaned.gsub(/ {2,}/, " ").gsub(/\s+\./, ".").strip
        return nil if cleaned == blocks[index].strip

        blocks[index] = cleaned
        blocks.join("\n\n").strip
      end

      # Live 20261121T001802Z, Thyssen T12. The close note was in the prompt
      # and the draft still left "Pendiente: repetir la maniobra", without a
      # question mark, so the runner stored no pending. That order is the
      # same test again.
      # "Repetiste" is the same order as "repetir". Live 20261121T003852Z.
      CYCLE_ORDER = /\b(?:rep(?:et|it)\p{L}*|varios ciclos|más ciclos|mas ciclos|otro ciclo|otra maniobra|siguientes maniobras|varias maniobras|unas veces|cierres seguidos|ciclos sucesivos)\b/i

      # Called only after the technician already reported the maneuver result.
      # Any question there is another pass of the same check, whatever the
      # wording (live 20261121T004239Z: "varios cierres y aperturas seguidas").
      # A cited line that does not ask stays.
      def without_repeated_cycle(text)
        removed = false
        blocks = text.to_s.split(/\n{2,}/)
        kept = blocks.filter_map { |block|
          sentences = block.split(/(?<=[.!?？])\s+/)
          next block unless sentences.any? { |sentence| repeated_cycle_sentence?(sentence) }

          removed = true
          sentences.reject { |sentence| repeated_cycle_sentence?(sentence) }.join(" ").strip.presence
        }
        removed ? kept.join("\n\n").strip : nil
      end

      def repeated_cycle_sentence?(sentence)
        sentence.match?(/[?¿？]/) || sentence.match?(CYCLE_ORDER)
      end

      private

      # Offer a handoff when the next check requires someone else or cannot
      # proceed with the available information.
      def referral_note(technician_turn, outcome: nil)
        return nil if technician_turn < REFERRAL_TURN

        handoff = "Si el técnico no puede seguir, resume lo que contó, lo que comprobó, el respaldo y lo que queda pendiente para derivar."
        head = "Turno #{technician_turn} del técnico en este caso. Responde primero a la consulta actual."
        return open_checks_note(head, handoff, settled: outcome.settled_this_turn?) if outcome&.leaves_checks_open?

        if outcome&.settled_this_turn?
          return "#{head} La comprobación activa quedó contestada en este turno: no pidas la siguiente comprobación por inercia ni " \
            "pidas de nuevo lo que el técnico declaró no verificado. Propón otra solo si una fuente de este turno la respalda y cítala. #{handoff}"
        end

        "#{head} Si el último resultado permite avanzar, indica la siguiente comprobación respaldada o pide la observación que " \
          "permite decidirla. #{handoff}"
      end

      # Stage 1, flag on. The closing rule of the system prompt is for a case
      # with nothing left to check. A part answered only in part is left to
      # check, so this turn names it and asks for one supported check.
      def open_checks_note(head, handoff, settled:)
        if settled
          return "#{head} La comprobación activa quedó contestada en este turno: no la repitas ni pidas de nuevo lo que el técnico declaró " \
            "no verificado. Quedan comprobaciones respondidas solo en parte. No cierres el caso ni uses el formato de cierre: pide una " \
            "sola comprobación siguiente, la que falta o la respaldada por una fuente de este turno, y cítala. #{handoff}"
        end

        # The technician already reported this turn's result. A partial reply
        # is answered with the next check a source supports, not with the
        # same result asked over again.
        "#{head} La comprobación activa quedó contestada solo en parte. No cierres el caso ni uses el formato de cierre, y no pidas de " \
          "nuevo lo que el técnico ya reportó en este turno: pide una sola comprobación siguiente que respalde una fuente de este " \
          "turno y cita esa fuente [n]. #{handoff}"
      end

      def sources_block(chunks)
        lines = [ "Fuentes de este turno:" ]
        delivered = [] if ValidationCapture.active?
        Array(chunks).each_with_index do |chunk, index|
          next if CompanionCaseRecord.gap?(chunk)

          number = CompanionCaseRecord.number_of(chunk, index)
          # A heading right under the previous passage was read as that
          # passage's citation.
          lines << "" if lines.size > 1
          lines << CompanionPlan.source_heading(chunk, number)
          body = DocumentIdentityScope.omit_terminal_evidence_records(chunk_body(chunk)).strip
          lines << body
          delivered&.push(
            "n" => number, "text" => body,
            "origin" => chunk[:case_origin] || chunk["case_origin"] || "fresh",
            "page" => (chunk[:metadata] || chunk["metadata"] || {}).with_indifferent_access["page_number"],
            "uri" => chunk[:location_uri] || chunk["location_uri"]
          )
        end
        if delivered
          ValidationCapture.record("generator_evidence", "stage" => "companion_direct", "result" => "prepared", "rows" => delivered)
        end
        lines.join("\n")
      end

      def chunk_body(chunk)
        (chunk[:content] || chunk["content"]).to_s
      end

      def history_turns(session, correlation_id, episode, allowed_numbers: nil)
        return [] unless session.respond_to?(:conversation_history)

        kept_numbers = CompanionCaseRecord.marker_numbers(session, CompanionCaseRecord.episode_id_of(episode))
        kept_numbers &= allowed_numbers unless allowed_numbers.nil?
        cutoff = history_cutoff(session, episode)
        Array(session.conversation_history).filter_map do |message|
          next unless message.is_a?(Hash)
          role = message["role"].to_s
          next unless role == "user" || role == "assistant"
          next if role == "assistant" && %w[abstained failed].include?(message["outcome"].to_s)
          next if role == "assistant" && message["content"].to_s.start_with?("[FOTO]")
          next if correlation_id.present? && message["correlation_id"].to_s == correlation_id.to_s
          next if cutoff && !inside_cutoff?(message, cutoff)

          if role == "assistant" && allowed_numbers
            cited = (message["prompt_reply"] || message["content"]).to_s.scan(CompanionCaseRecord::MARKER).flatten.map(&:to_i)
            next if (cited - allowed_numbers).any?
          end
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

      def fit_history(turns, budget: HISTORY_MAX_CHARS)
        kept = turns.dup
        omitted = []
        while packed_length(kept) > budget
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
              "chars" => turn[:chars],
              "reason" => "history_budget"
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
