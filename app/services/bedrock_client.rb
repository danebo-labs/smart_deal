# frozen_string_literal: true

# app/services/bedrock_client.rb

require 'aws-sdk-bedrockruntime'
require 'aws-sdk-core/token_provider'
require 'aws-sdk-core/static_token_provider'
require 'digest'
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

  def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7, tracking: nil, system: nil)
    model_id ||= DEFAULT_MODEL_ID

    body = {
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: max_tokens,
      temperature: temperature,
      messages: [{ role: 'user', content: prompt }]
    }
    body[:system] = system if system.present?

    start_time = Time.current
    capture_fields = generation_capture_fields(tracking)
    record_generation_request(
      model_id, max_tokens, temperature, prompt, system: system, linkage: capture_fields
    )
    # Armed by the phase 1 or phase 2 process. defined? does not load either
    # class. A disarmed phase 2 leaves the phase 1 cap in place.
    budget = armed_validation_budget
    if budget&.armed?
      begin
        budget.checkpoint!("generate_text")
      rescue budget::Stop
        Rag::ValidationCapture.record_model_boundary("generate_text", "blocked", capture_fields)
        raise
      end
    end
    Rag::ValidationCapture.record_model_boundary("generate_text", "attempt_started", capture_fields)
    response = @client.invoke_model(
      model_id: model_id,
      content_type: 'application/json',
      body: body.to_json
    )

    result = JSON.parse(response.body.read)
    text = result.dig('content', 0, 'text') || result.to_s

    track_usage(result, model_id, prompt, start_time, max_tokens: max_tokens, tracking: tracking)
    record_generation_result(
      result, text, prompt, capture_fields,
      system: system, model_id: model_id, max_tokens: max_tokens, temperature: temperature
    )
    budget&.record_success!("generate_text") if budget&.armed?

    text
  rescue StandardError => e
    record_generation_error(
      e, prompt, capture_fields,
      system: system, model_id: model_id, max_tokens: max_tokens, temperature: temperature
    )
    budget = armed_validation_budget
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
    record_converse_prepared(params)
    budget = armed_validation_budget
    if budget&.armed?
      begin
        budget.checkpoint!("converse_message")
      rescue budget::Stop
        Rag::ValidationCapture.record_model_boundary("converse_message", "blocked")
        raise
      end
    end
    Rag::ValidationCapture.record_model_boundary("converse_message", "attempt_started")
    result = @client.converse(params)
    budget&.record_success!("converse_message") if budget&.armed?
    result
  rescue StandardError => error
    budget = armed_validation_budget
    raise unless budget&.armed?

    budget.record_error!("converse_message", error)
    raise budget::Stop, "converse_message stopped after #{error.class}"
  end

  private

  def record_converse_prepared(params)
    return unless Rag::ValidationCapture.active?

    body = params.is_a?(Hash) ? params.dup : { "params" => "unavailable" }
    body["stage"] = "converse"
    body["result"] = "prepared"
    body["operation"] = "converse_message"
    Rag::ValidationCapture.record("converse", body)
  end

  def record_generation_request(model_id, max_tokens, temperature, prompt, system: nil, linkage: nil)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "generate_text",
      {
        "stage" => "generate",
        "result" => "prepared",
        "operation" => "generate_text",
        "documentary_context" => Rag::ValidationCapture.documentary_context(prompt)
      }.merge(generation_request_fields(model_id, max_tokens, temperature, prompt, system))
       .merge(linkage || {})
    )
  end

  def record_generation_result(result, text, prompt, capture_fields, system:, model_id:, max_tokens:, temperature:)
    return unless Rag::ValidationCapture.active?

    usage = result.is_a?(Hash) && result["usage"].is_a?(Hash) ? result["usage"] : {}
    input_tokens = usage["input_tokens"] || usage["inputTokens"]
    output_tokens = usage["output_tokens"] || usage["outputTokens"]
    Rag::ValidationCapture.record(
      "generation_result",
      {
        "stage" => "generate",
        "result" => "returned",
        "operation" => "generate_text",
        "answer" => text,
        "input_tokens" => input_tokens.nil? ? "unavailable" : input_tokens,
        "output_tokens" => output_tokens.nil? ? "unavailable" : output_tokens,
        "error_class" => nil,
        "documentary_context" => Rag::ValidationCapture.documentary_context(prompt)
      }.merge(generation_result_fields(model_id, max_tokens, temperature, prompt, system))
       .merge(capture_fields || {})
    )
  end

  def record_generation_error(error, prompt, capture_fields, system:, model_id:, max_tokens:, temperature:)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "generation_result",
      {
        "stage" => "generate",
        "result" => "error",
        "operation" => "generate_text",
        "answer" => nil,
        "error_class" => error.class.name,
        "documentary_context" => Rag::ValidationCapture.documentary_context(prompt)
      }.merge(generation_result_fields(model_id, max_tokens, temperature, prompt, system))
       .merge(capture_fields || {})
    )
  end

  # The user message stays in prompt. system is a separate field. Neither is
  # the concatenation of the two roles.
  def generation_request_fields(model_id, max_tokens, temperature, prompt, system)
    generation_result_fields(model_id, max_tokens, temperature, prompt, system)
      .merge("prompt" => prompt.to_s)
  end

  def generation_result_fields(model_id, max_tokens, temperature, prompt, system)
    user = prompt.to_s
    {
      "model_id" => model_id,
      "max_tokens" => max_tokens,
      "temperature" => temperature,
      "anthropic_version" => "bedrock-2023-05-31",
      "messages" => [ { "role" => "user" } ],
      "user_sha256" => Digest::SHA256.hexdigest(user)
    }.merge(generation_system_fields(system))
  end

  # Absent unless generate_text received a system message. The SHA is the
  # system text alone, so the capture keeps the instructions that left the
  # user message.
  def generation_system_fields(system)
    return {} if system.blank?

    text = system.to_s
    { "system" => text, "system_sha256" => Digest::SHA256.hexdigest(text) }
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

  # Nil until the phase 2 harness has loaded its budget. Does not autoload it.
  def phase2_model_budget
    return unless defined?(Rag::Phase2ModelBudget)

    Rag::Phase2ModelBudget
  end

  # Phase 2 applies only while that run is armed. Otherwise this is the
  # phase 1 budget, or nil when neither run is armed.
  def armed_validation_budget
    phase2 = phase2_model_budget
    return phase2 if phase2&.armed?

    phase1 = phase1_model_budget
    return phase1 if phase1&.armed?

    nil
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
