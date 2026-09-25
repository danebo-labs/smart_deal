# frozen_string_literal: true

module Rag
  # Observational Haiku perception. A failure returns nil and never writes state.
  class SemanticQueryAnalyzer
    MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    TOOL_NAME = "semantic_perception"
    MAX_TOKENS = 300
    RELATIONS = %w[continue answer_pending correct switch new unclear].freeze
    ROLES = %w[equipment component other].freeze
    REQUIRED_KEYS = %w[relation mentions refers_to ambiguous].freeze
    PROMPT = <<~PROMPT.freeze
      You return semantic perception for one technician turn. You are not a technical authority. You do not answer the procedure, invent measurements, or decide safety.

      relation definitions:
      continue
      = mismo equipo y misma tarea/problema; continúa el estado existente.

      answer_pending
      = el turno responde directamente a state.pending_question.

      correct
      = corrige un fact o identidad expresada previamente.
        El fact corregido no se hereda.

      switch
      = cambia a otro equipo, pero puede conservar el marco/tarea técnica.

      new
      = nueva tarea/problema.
        No se hereda contexto semántico previo.

      unclear
      = no existe evidencia suficiente para decidir de forma segura.
        Se comporta fail-closed igual que ambiguous=true.

      ambiguous=true implies fail-closed. relation=unclear also implies fail-closed.

      Span normalization for comparison:
      1. Unicode NFC
      2. Unicode lowercase/downcase
      3. collapse internal whitespace to one space
      4. trim whitespace
      5. trim punctuation only at the edges of the candidate span
      6. DO NOT fold accents

      Every span must be a literal substring of the turn after that normalization. No invented strings. No paraphrases. No canonicalization that leaves the input.

      refers_to.slot must be one of the slots in the user message. Do not invent a slot id.

      Output schema, returned only as the semantic_perception tool input:
      {"relation":"continue|answer_pending|correct|switch|new|unclear","mentions":[{"span":"MonoSpace","role":"equipment|component|other"}],"refers_to":[{"span":"el otro","slot":"obs_2"}],"ambiguous":false}
    PROMPT

    def self.observe(turn:, episode:, correlation_id:, client: nil)
      return nil unless HaikuQueryAnalysisFlag.shadow?
      return nil unless gated?(episode)

      new(turn: turn, episode: episode, correlation_id: correlation_id, client: client).call
    end

    def self.observe_ownership(turn:, episode:, correlation_id:, client: nil)
      return nil unless HaikuQueryAnalysisFlag.conditional?
      return nil unless gated?(episode)

      new(turn: turn, episode: episode, correlation_id: correlation_id, client: client).call
    end

    def self.gated?(episode)
      hash = episode.is_a?(Hash) ? episode : {}
      hash["episode_id"].present? || hash["pending_fact"].present? || hash["active_photo"].present?
    end

    def initialize(turn:, episode:, correlation_id:, client: nil)
      @turn = turn.to_s
      @episode = episode.is_a?(Hash) ? episode : {}
      @correlation_id = correlation_id
      @client = client
    end

    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = converse_client.converse(converse_params)
      elapsed_ms = elapsed_since(started)
      usage = response.usage
      input_tokens = usage&.input_tokens.to_i
      output_tokens = usage&.output_tokens.to_i
      tool_input = extract_tool_input(response.output&.message&.content)
      error = tool_input.nil? ? :invalid_schema : validate_output(tool_input)
      analysis = error ? nil : build_analysis(tool_input)
      log_shadow(
        status: error ? error.to_s : "ok",
        analysis: analysis,
        elapsed_ms: elapsed_ms,
        input_tokens: input_tokens,
        output_tokens: output_tokens
      )
      analysis
    rescue StandardError => error
      log_shadow(
        status: transport_status(error),
        analysis: nil,
        elapsed_ms: elapsed_since(started),
        input_tokens: 0,
        output_tokens: 0
      )
      nil
    end

    private

    def converse_client
      @client || BedrockClient.new
    end

    def elapsed_since(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    def perception_state
      facts = @episode["facts"].is_a?(Hash) ? @episode["facts"] : {}
      manufacturer = facts.dig("manufacturer", "value")
      model = facts.dig("model", "value")
      equipment = if manufacturer.nil? && model.nil?
        nil
      else
        { "manufacturer" => manufacturer, "model" => model }
      end
      pending = @episode["pending_fact"]
      pending_question = if pending.is_a?(Hash) && pending["subject"].present?
        { "type" => pending["subject"].to_s }
      end
      {
        "equipment" => equipment,
        "goal" => @episode.dig("goal", "text"),
        "active_referent" => nil,
        "pending_question" => pending_question,
        "observations" => []
      }
    end

    def slots
      state = perception_state
      list = []
      list << "pending_question" unless state["pending_question"].nil?
      list
    end

    def converse_params
      {
        model_id: MODEL_ID,
        system: [ { text: PROMPT } ],
        messages: [
          {
            role: "user",
            content: [ { text: JSON.generate("turn" => @turn, "state" => perception_state, "slots" => slots) } ]
          }
        ],
        inference_config: { temperature: 0, max_tokens: MAX_TOKENS },
        tool_config: tool_config
      }
    end

    def tool_config
      {
        tools: [
          {
            tool_spec: {
              name: TOOL_NAME,
              description: "Return semantic perception for one technician turn.",
              input_schema: {
                json: {
                  type: "object",
                  properties: {
                    relation: { type: "string", enum: RELATIONS },
                    mentions: {
                      type: "array",
                      items: {
                        type: "object",
                        properties: {
                          span: { type: "string" },
                          role: { type: "string", enum: ROLES }
                        },
                        required: %w[span role]
                      }
                    },
                    refers_to: {
                      type: "array",
                      items: {
                        type: "object",
                        properties: {
                          span: { type: "string" },
                          slot: { type: "string" }
                        },
                        required: %w[span slot]
                      }
                    },
                    ambiguous: { type: "boolean" }
                  },
                  required: REQUIRED_KEYS
                }
              }
            }
          }
        ],
        tool_choice: { tool: { name: TOOL_NAME } }
      }
    end

    def extract_tool_input(content)
      block = Array(content).find do |item|
        tool = item.respond_to?(:tool_use) ? item.tool_use : item["tool_use"] || item[:tool_use]
        name = tool.respond_to?(:name) ? tool.name : tool && (tool["name"] || tool[:name])
        name == TOOL_NAME
      end
      return nil unless block

      tool = block.respond_to?(:tool_use) ? block.tool_use : block["tool_use"] || block[:tool_use]
      input = tool.respond_to?(:input) ? tool.input : tool["input"] || tool[:input]
      input.is_a?(Hash) ? input : nil
    end

    def validate_output(output)
      output = output.transform_keys(&:to_s)
      return :invalid_schema if REQUIRED_KEYS.any? { |key| !output.key?(key) }
      return :invalid_schema unless RELATIONS.include?(output["relation"])
      return :invalid_schema unless output["ambiguous"] == true || output["ambiguous"] == false
      return :invalid_schema unless output["mentions"].is_a?(Array) && output["refers_to"].is_a?(Array)

      output["mentions"].each do |mention|
        return :invalid_schema unless mention.is_a?(Hash)

        mention = mention.transform_keys(&:to_s)
        return :invalid_schema unless mention.key?("span") && ROLES.include?(mention["role"])
        return :hallucinated_spans unless literal_span?(mention["span"])
      end

      allowed = slots
      output["refers_to"].each do |ref|
        return :invalid_schema unless ref.is_a?(Hash)

        ref = ref.transform_keys(&:to_s)
        return :invalid_schema unless ref.key?("span") && ref.key?("slot")
        return :invalid_schema unless allowed.include?(ref["slot"].to_s)
        return :hallucinated_spans unless literal_span?(ref["span"])
      end

      nil
    end

    def literal_span?(span)
      candidate = normalize_turn(span).sub(/\A\p{P}+/u, "").sub(/\p{P}+\z/u, "")
      return false if candidate.empty?

      normalize_turn(@turn).include?(candidate)
    end

    def normalize_turn(value)
      value.to_s.unicode_normalize(:nfc).downcase.gsub(/[[:space:]]+/, " ").strip
    end

    def build_analysis(output)
      output = output.transform_keys(&:to_s)
      ConversationalTurnAnalysis.new(
        relation: output["relation"],
        mentions: output["mentions"],
        refers_to: output["refers_to"],
        ambiguous: output["ambiguous"]
      )
    end

    def transport_status(error)
      name = error.class.name.to_s
      return "timeout" if error.is_a?(Timeout::Error) || name.include?("Timeout")
      return "throttle" if name.include?("Throttl") || name.include?("TooManyRequests")

      status = error.respond_to?(:context) ? error.context&.http_response&.status_code : nil
      return "http_5xx" if status.to_i >= 500
      return "http_5xx" if name.include?("InternalServer") || name.include?("ServiceUnavailable")

      "transport_error"
    end

    def log_shadow(status:, analysis:, elapsed_ms:, input_tokens:, output_tokens:)
      pricing = BedrockQuery::BEDROCK_PRICING.fetch(MODEL_ID)
      cost = (input_tokens / 1000.0) * pricing[:input] + (output_tokens / 1000.0) * pricing[:output]
      Rails.logger.info(
        {
          event: "haiku_query_analysis_shadow",
          correlation_id: @correlation_id,
          analyzer_status: status,
          relation: analysis&.relation,
          ambiguous: analysis&.ambiguous,
          semantic_analysis_ms: elapsed_ms,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_usd: cost
        }.to_json
      )
    end
  end
end
