# frozen_string_literal: true

module Rag
  # The photo has its own one-call assignment. Haiku in the same job
  # continues to use the text assignment in LocalPassLedger.
  module GuardedPhotoVision
    OPERATION = "photo_vision"
    MODEL_ID = "claude-sonnet-5-5"
    TRACKING_MODEL = "#{MODEL_ID}-direct"
    PATH_ENV = "RAG_PHOTO_VISION_SPEND_PATH"
    GRANT_ID = "field-photo-sonnet55-audit"
    TEXT_BYTES = 8_192
    REQUEST_OVERHEAD_TOKENS = 256
    WIDTH = 576
    HEIGHT = 448
    IMAGE_TOKENS = WIDTH.fdiv(28).ceil * HEIGHT.fdiv(28).ceil
    OUTPUT_TOKENS = BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS

    module_function

    def ceiling
      rates = BedrockQuery::BEDROCK_PRICING.fetch(TRACKING_MODEL)
      input_rate = BigDecimal(rates.fetch(:cache_creation).to_s)
      output_rate = BigDecimal(rates.fetch(:output).to_s)
      ((TEXT_BYTES + REQUEST_OVERHEAD_TOKENS + IMAGE_TOKENS) * input_rate + OUTPUT_TOKENS * output_rate) / 1_000
    end

    def assignment(path)
      AssignmentSpend.new(path: path, call_cap: 1, cost_cap_usd: ceiling)
    end

    def call(model:, system:, user_content:, output_tokens:)
      unless LocalPassLedger.armed? && model == MODEL_ID && output_tokens == OUTPUT_TOKENS
        raise LocalPassLedger::Stop, "photo_vision_contract"
      end
      LocalPassLedger.refuse_unlisted_call!(OPERATION, TRACKING_MODEL)
      validate_request!(system, user_content)
      path = ENV[PATH_ENV].presence
      raise LocalPassLedger::Stop, "photo_vision_grant_missing" unless path && File.file?(path)

      spend = assignment(path)
      id = spend.reserve!(ceiling_usd: ceiling, model_id: TRACKING_MODEL, turn: OPERATION, required_execution: GRANT_ID)
      ValidationCapture.record_model_boundary(OPERATION, "attempt_started")
      result = yield
      usage = result.usage
      actual = actual_cost(usage)
      if actual
        spend.settle!(id, actual_usd: actual)
      else
        spend.unknown!(id)
      end
      ValidationCapture.record_model_boundary(OPERATION, "returned")
      result
    rescue AssignmentSpend::Stop => error
      ValidationCapture.record("photo_vision_refusal", "reason" => error.message)
      raise LocalPassLedger::Stop, "photo_vision:#{error.message}"
    rescue Exception
      spend.unknown!(id) if id
      raise
    end

    def validate_request!(system, content)
      text = system + content.select { |part| part[:type] == "text" }
      images = content.reject { |part| part[:type] == "text" }
      unless text.all? { |part| part[:type] == "text" } &&
          text.sum { |part| part.fetch(:text).bytesize } <= TEXT_BYTES &&
          images.one? && images.first[:type] == "image"
        raise LocalPassLedger::Stop, "photo_vision_input"
      end

      source = images.first.fetch(:source)
      unless source[:type] == "base64" && source[:media_type] == "image/jpeg"
        raise LocalPassLedger::Stop, "photo_vision_media"
      end
      binary = Base64.strict_decode64(source.fetch(:data))
      image = Vips::Image.new_from_buffer(binary, "")
      return if image.width == WIDTH && image.height == HEIGHT && image.get("vips-loader") == "jpegload_buffer"

      raise LocalPassLedger::Stop, "photo_vision_dimensions"
    rescue ArgumentError, KeyError, Vips::Error
      raise LocalPassLedger::Stop, "photo_vision_media"
    end

    def actual_cost(usage)
      return unless usage&.input_tokens.is_a?(Integer) && usage.output_tokens.is_a?(Integer)

      BedrockQuery.new(
        model_id: TRACKING_MODEL, input_tokens: usage.input_tokens, output_tokens: usage.output_tokens,
        cache_creation_tokens: usage.try(:cache_creation_input_tokens),
        cache_read_tokens: usage.try(:cache_read_input_tokens)
      ).cost
    end
  end
end
