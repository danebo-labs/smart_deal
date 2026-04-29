# frozen_string_literal: true

# app/services/anthropic_token_counter.rb
#
# Calls Anthropic's count_tokens endpoint to get exact BPE token counts
# for prompts sent to Claude models via Bedrock.
#
# Anthropic's count_tokens is free (no model invocation cost) and returns
# the same BPE count the model uses internally — unlike Bedrock's
# retrieve_and_generate which does NOT return usage in the response struct.
#
# Fallback hierarchy (never raises):
#   1. Anthropic API (exact, ~100-300ms network)
#   2. LocalTokenizer.estimate (chars/3.5, ±5%, zero-latency)
#
# Cache: SHA1(text) → token count, TTL 1h via Solid Cache.
# Identical repeated prompts pay no network cost.
class AnthropicTokenCounter
  ANTHROPIC_API_URL    = "https://api.anthropic.com/v1/messages/count_tokens"
  ANTHROPIC_API_VERSION = "2023-06-01"
  REQUEST_TIMEOUT_SECS  = 8

  # Model IDs to use for the count_tokens call (must be Anthropic API model IDs,
  # not Bedrock ARNs — they serve the same tokenizer).
  TOKENIZER_MODEL = {
    haiku:  "claude-haiku-4-5-20251001",
    opus:   "claude-opus-4-5-20251101",
    sonnet: "claude-sonnet-4-5-20250929"
  }.freeze

  CACHE_TTL = 1.hour

  # Returns input + output token counts for a query/answer pair.
  # Uses 2 count_tokens calls (input prompt → input_tokens; answer → output_tokens).
  # @param prompt [String]  full assembled prompt (template + chunks + question)
  # @param answer [String]  model answer text
  # @param model  [Symbol]  :haiku (default), :opus, :sonnet
  # @return [Hash] { input_tokens: Integer, output_tokens: Integer }
  def self.count_query(prompt:, answer:, model: :haiku)
    input_tokens  = count(text: prompt.to_s, model: model)
    output_tokens = count(text: answer.to_s,  model: model)
    { input_tokens: input_tokens, output_tokens: output_tokens }
  end

  # Returns token count for a single text string.
  # @param text  [String]
  # @param model [Symbol] :haiku (default)
  # @return [Integer]
  def self.count(text:, model: :haiku)
    return 0 if text.blank?

    cache_key = "atc/v1/#{Digest::SHA1.hexdigest(text)}"
    cached = Rails.cache.read(cache_key)
    return cached if cached.is_a?(Integer)

    result = call_api(text: text, model: model)

    if result
      Rails.cache.write(cache_key, result, expires_in: CACHE_TTL)
      result
    else
      LocalTokenizer.estimate(text)
    end
  end

  # Exposed for testing — not for direct use by callers.
  def self.api_key
    ENV["ANTHROPIC_API_KEY"].presence ||
      Rails.application.credentials.dig(:anthropic, :api_key).presence
  end

  private_class_method def self.call_api(text:, model:)
    key = api_key
    unless key
      Rails.logger.debug { "[ATC] fallback reason=no_api_key" }
      return nil
    end

    model_id = TOKENIZER_MODEL[model.to_sym] || TOKENIZER_MODEL[:haiku]
    body     = { model: model_id, messages: [ { role: "user", content: text } ] }.to_json

    uri  = URI(ANTHROPIC_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = true
    http.read_timeout = REQUEST_TIMEOUT_SECS
    http.open_timeout = REQUEST_TIMEOUT_SECS

    request = Net::HTTP::Post.new(uri.path)
    request["x-api-key"]         = key
    request["anthropic-version"]  = ANTHROPIC_API_VERSION
    request["content-type"]       = "application/json"
    request.body = body

    response = http.request(request)

    if response.code.to_i == 200
      JSON.parse(response.body)["input_tokens"].to_i
    else
      Rails.logger.warn("[ATC] fallback reason=http_#{response.code}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.warn("[ATC] fallback reason=timeout msg=#{e.message}")
    nil
  rescue StandardError => e
    Rails.logger.warn("[ATC] fallback reason=#{e.class} msg=#{e.message}")
    nil
  end

  # Simple heuristic tokenizer — used as fallback when Anthropic API is unavailable.
  # chars/3.5 is tighter than the old chars/4, calibrated to Claude's Spanish/English mix.
  module LocalTokenizer
    def self.estimate(text)
      return 0 if text.blank?
      (text.length / 3.5).ceil
    end
  end
end
