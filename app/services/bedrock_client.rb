# frozen_string_literal: true

# app/services/bedrock_client.rb

require 'aws-sdk-bedrockruntime'
require 'aws-sdk-core/token_provider'
require 'aws-sdk-core/static_token_provider'
require 'json'

class BedrockClient
  include AwsClientInitializer

  # Fixed query model: Claude Haiku 4.5 (cost-effective, fast). Override via BEDROCK_MODEL_ID env var.
  QUERY_MODEL_ID = (ENV.fetch('BEDROCK_MODEL_ID', nil).presence ||
                    Rails.application.credentials.dig(:bedrock, :model_id) ||
                    'global.anthropic.claude-haiku-4-5-20251001-v1:0').freeze

  DEFAULT_MODEL_ID = QUERY_MODEL_ID

  def initialize(region: nil)
    client_options = build_aws_client_options(region: region)
    @client = Aws::BedrockRuntime::Client.new(client_options)
  end

  def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7, tracking: nil)
    model_id ||= DEFAULT_MODEL_ID

    body = {
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: max_tokens,
      temperature: temperature,
      messages: [{ role: 'user', content: prompt }]
    }

    start_time = Time.current
    capture_fields = generation_capture_fields(tracking)
    record_generation_request(model_id, max_tokens, temperature, prompt)
    # Armed only by the phase 1 process. defined? does not load that class.
    budget = phase1_model_budget
    budget.checkpoint!("generate_text") if budget&.armed?
    response = @client.invoke_model(
      model_id: model_id,
      content_type: 'application/json',
      body: body.to_json
    )

    result = JSON.parse(response.body.read)
    text = result.dig('content', 0, 'text') || result.to_s

    track_usage(result, model_id, prompt, start_time, max_tokens: max_tokens, tracking: tracking)
    record_generation_result(result, text, prompt, capture_fields)
    phase1_model_budget&.record_success!("generate_text") if budget&.armed?

    text
  rescue StandardError => e
    record_generation_error(e, prompt, capture_fields)
    budget = phase1_model_budget
    if budget&.armed?
      budget.record_error!("generate_text", e)
      raise budget::Stop, "generate_text stopped after #{e.class}"
    end

    Rails.logger.error("Bedrock error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end

  # Compatibility method for AiProvider
  def query(prompt, **opts)
    opts.delete(:images)
    generate_text(prompt, **opts)
  end

  # Shadow perception only. Zero retries and an 8s read timeout, separate from generate_text.
  CONVERSE_CLIENT_OPTIONS = {
    retry_limit: 0,
    max_attempts: 1,
    http_open_timeout: 2,
    http_read_timeout: 8
  }.freeze

  delegate :converse, to: :converse_client

  # Tool use on the primary runtime client. #converse stays the 8-second
  # shadow client used by perception. generate_text cannot send a tool schema.
  def converse_message(params)
    budget = phase1_model_budget
    budget.checkpoint!("converse_message") if budget&.armed?
    Rag::ValidationCapture.record("converse", params) if Rag::ValidationCapture.active?
    result = @client.converse(params)
    budget.record_success!("converse_message") if budget&.armed?
    result
  rescue StandardError => error
    budget = phase1_model_budget
    raise unless budget&.armed?

    budget.record_error!("converse_message", error)
    raise budget::Stop, "converse_message stopped after #{error.class}"
  end

  private

  def record_generation_request(model_id, max_tokens, temperature, prompt)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "generate_text",
      "stage" => "generate",
      "result" => "sent",
      "model_id" => model_id,
      "max_tokens" => max_tokens,
      "temperature" => temperature,
      "prompt" => prompt.to_s,
      "documentary_context" => Rag::ValidationCapture.documentary_context(prompt)
    )
  end

  def record_generation_result(result, text, prompt, capture_fields)
    return unless Rag::ValidationCapture.active?

    usage = result.is_a?(Hash) && result["usage"].is_a?(Hash) ? result["usage"] : {}
    input_tokens = usage["input_tokens"] || usage["inputTokens"]
    output_tokens = usage["output_tokens"] || usage["outputTokens"]
    Rag::ValidationCapture.record(
      "generation_result",
      {
        "stage" => "generate",
        "result" => "ok",
        "answer" => text,
        "input_tokens" => input_tokens.nil? ? "unavailable" : input_tokens,
        "output_tokens" => output_tokens.nil? ? "unavailable" : output_tokens,
        "error_class" => nil,
        "documentary_context" => Rag::ValidationCapture.documentary_context(prompt)
      }.merge(capture_fields)
    )
  end

  def record_generation_error(error, prompt, capture_fields)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "generation_result",
      {
        "stage" => "generate",
        "result" => "error",
        "answer" => nil,
        "error_class" => error.class.name,
        "documentary_context" => Rag::ValidationCapture.documentary_context(prompt)
      }.merge(capture_fields || {})
    )
  end

  def generation_capture_fields(tracking)
    return {} unless tracking.respond_to?(:to_h)

    fields = tracking.to_h.dup
    extra = {}
    correlation_id = fields[:correlation_id] || fields["correlation_id"]
    attempt = fields[:attempt] || fields["attempt"]
    extra["correlation_id"] = correlation_id if correlation_id.present?
    extra["attempt"] = attempt unless attempt.nil?
    extra
  end

  # Nil until the phase 1 service has loaded its budget. Does not autoload it.
  def phase1_model_budget
    return unless defined?(Rag::Phase1ModelBudget)

    Rag::Phase1ModelBudget
  end

  def converse_client
    @converse_client ||= Aws::BedrockRuntime::Client.new(
      build_aws_client_options.merge(CONVERSE_CLIENT_OPTIONS)
    )
  end

  def track_usage(result, model_id, prompt, start_time, max_tokens: nil, tracking: nil)
    usage = result['usage'] || {}
    input_tokens = (usage['input_tokens'] || usage['inputTokens']).to_i
    output_tokens = (usage['output_tokens'] || usage['outputTokens']).to_i

    return if input_tokens <= 0

    latency_ms = ((Time.current - start_time) * 1000).to_i

    # Enqueue tracking asynchronously — never block the response on DB writes.
    # tracking (account_id/user_id/conversation_session_id/correlation_id) lets
    # a caller's BedrockQuery row join back to its own request for cost
    # attribution; omitted by callers that don't have that context.
    extra = tracking.to_h
    # Callers that already name a retrieval route (rag_filtered / rag_global)
    # keep that attribution. A bare direct call stays query_direct.
    route = extra.delete(:route) || "query_direct"
    attempt = extra.delete(:attempt) || 1
    token_source = extra.delete(:token_source) || "provider_usage"
    TrackBedrockQueryJob.perform_later(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      token_source: token_source,
      user_query: prompt.to_s.truncate(500),
      latency_ms: latency_ms,
      route: route,
      attempt: attempt,
      max_tokens: max_tokens,
      stop_reason: result['stop_reason'].presence,
      source: "query",
      **extra
    )
    Rails.logger.info("BedrockClient: query tracking enqueued (#{input_tokens} in + #{output_tokens} out tokens)")
  rescue StandardError => e
    Rails.logger.error("BedrockClient: failed to enqueue tracking: #{e.message}")
  end
end
