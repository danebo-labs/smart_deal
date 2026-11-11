# frozen_string_literal: true

module Rag
  # One Haiku 5.5 Messages call for the turn interpreter. The canonical
  # converse hash stays what TurnInterpreter builds. This client translates
  # it, forces turn_perception, and sends effort high without temperature
  # or a thinking block.
  class InterpreterAnthropicClient
    TIMEOUT = 30
    OUTPUT_CAP = 2_048

    def self.body_for(params)
      requested = inference_max_tokens(params)
      translated = InterpreterAnthropicAdapter.translate(
        params,
        model_id: TurnInterpreter::MODEL_ID,
        output_cap: [ requested, OUTPUT_CAP ].min
      )
      body = translated.fetch("body")
      body["output_config"] = { "effort" => TurnInterpreter::EFFORT }
      body
    end

    def self.inference_max_tokens(params)
      inference = params[:inference_config] || params["inference_config"] || {}
      (inference[:max_tokens] || inference["max_tokens"]).to_i
    end

    def initialize(client: nil)
      @client = client || build_client
    end

    def converse(params)
      body = self.class.body_for(params)
      observed = Rag::LocalPassLedger.protect!(
        operation: "converse",
        model_id: TurnInterpreter::TRACKING_MODEL_ID,
        input_tokens: Rag::LocalPassLedger.text_chars(body),
        output_tokens: body["max_tokens"].to_i
      ) do
        native = @client.messages.create(**body.deep_symbolize_keys)
        InterpreterAnthropicAdapter.normalize(self.class.native_hash(native))
      end
      Rag::LocalPassLedger.settle_usage!(observed, model_id: TurnInterpreter::TRACKING_MODEL_ID)
      observed
    end

    # The SDK keeps nested blocks as model objects and enums as symbols;
    # its JSON is the wire shape the adapter reads.
    def self.native_hash(response)
      return InterpreterAnthropicAdapter.scrub(response) if response.is_a?(Hash)

      InterpreterAnthropicAdapter.scrub(JSON.parse(response.to_json))
    end

    private

    def build_client
      key = ENV["ANTHROPIC_API_KEY"].presence || Rails.application.credentials.dig(:anthropic, :api_key)
      raise BedrockRagService::BedrockServiceError, "anthropic_api_key_missing" if key.blank?

      Anthropic::Client.new(api_key: key, max_retries: 0, timeout: TIMEOUT)
    end
  end
end
