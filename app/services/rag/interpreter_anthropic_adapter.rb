# frozen_string_literal: true

module Rag
  # Messages API adapter for the isolated interpreter experiment.
  # Both models are Anthropic API ids: claude-haiku-5-5 and
  # claude-haiku-4-5-20251001. TurnInterpreter keeps BedrockClient.
  # This class does not call Bedrock and does not open a socket.
  # normalize keeps the provider payload in memory. Export scrubs a copy.
  class InterpreterAnthropicAdapter
    HAIKU_55 = "claude-haiku-5-5"
    HAIKU_45 = "claude-haiku-4-5-20251001"
    ACCEPTED_MODELS = [ HAIKU_55, HAIKU_45 ].freeze
    BEDROCK_IDS = %w[
      anthropic.claude-haiku-5-5
      us.anthropic.claude-haiku-5-5
      eu.anthropic.claude-haiku-5-5
      au.anthropic.claude-haiku-5-5
      jp.anthropic.claude-haiku-5-5
      global.anthropic.claude-haiku-5-5
      anthropic.claude-haiku-4-5
      global.anthropic.claude-haiku-4-5-20251001-v1:0
    ].freeze
    ANTHROPIC_VERSION = "2023-06-01"
    ENDPOINT = "https://api.anthropic.com/v1/messages"
    LONG_PROMPT_TOKENS = 100_000
    SOURCES = {
      "model" => "https://platform.claude.com/docs/en/models/haiku-5-5/overview",
      "migration" => "https://platform.claude.com/docs/en/models/haiku-5-5/migration-guide",
      "haiku_45" => "https://platform.claude.com/docs/en/models/haiku-4-5/overview",
      "pricing" => "https://platform.claude.com/docs/en/about-claude/pricing",
      "residency" => "https://platform.claude.com/docs/en/build-with-claude/data-residency",
      "service_tiers" => "https://platform.claude.com/docs/en/api/service-tiers",
      "usage" => "https://platform.claude.com/docs/en/api/messages/create",
      "stop_reasons" => "https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons",
      "messages" => "https://platform.claude.com/docs/en/build-with-claude/working-with-messages"
    }.freeze
    CONSULTED_ON = "2026-10-10"
    TARIFF_VERSION = "2026-10-10"
    # USD per token. Short-prompt Haiku 5.5 rates apply at or below 100_000
    # input tokens. Long-prompt rates are selected only from reported usage.
    RATES = {
      HAIKU_55 => {
        input: BigDecimal("0.10") / 1_000_000,
        output: BigDecimal("0.50") / 1_000_000,
        cache_read: BigDecimal("0.01") / 1_000_000,
        cache_write_5m: BigDecimal("0.125") / 1_000_000,
        cache_write_1h: BigDecimal("0.20") / 1_000_000,
        long_input: BigDecimal("0.50") / 1_000_000,
        long_output: BigDecimal("2.50") / 1_000_000,
        long_cache_read: BigDecimal("0.05") / 1_000_000,
        long_cache_write_5m: BigDecimal("0.625") / 1_000_000,
        long_cache_write_1h: BigDecimal("1") / 1_000_000
      }.freeze,
      HAIKU_45 => {
        input: BigDecimal("1") / 1_000_000,
        output: BigDecimal("5") / 1_000_000,
        cache_read: BigDecimal("0.10") / 1_000_000,
        cache_write_5m: BigDecimal("1.25") / 1_000_000,
        cache_write_1h: BigDecimal("2") / 1_000_000
      }.freeze
    }.freeze
    PRICED_USAGE_KEYS = %w[
      input_tokens output_tokens
      cache_creation_input_tokens cache_read_input_tokens cache_creation
    ].freeze
    USAGE_BREAKDOWN_KEYS = %w[output_tokens_details].freeze
    INTERPRETED_USAGE_KEYS = %w[service_tier inference_geo].freeze
    # Haiku 4.5 does not take an inference_geo request. The documented usage
    # value is not_available and the token rate stays standard.
    # Haiku 5.5: global stays standard, us is 1.1x on every token category.
    GEO_MULTIPLIERS = {
      HAIKU_45 => { "not_available" => BigDecimal("1.0") }.freeze,
      HAIKU_55 => { "global" => BigDecimal("1.0"), "us" => BigDecimal("1.1") }.freeze
    }.freeze
    # Direct Messages response values that do not change the token price.
    SERVICE_TIER_MULTIPLIERS = {
      "standard" => BigDecimal("1.0"),
      "priority" => BigDecimal("1.0")
    }.freeze
    SK_ANT = /sk-ant-[A-Za-z0-9_-]{6,}/
    BEARER = /Bearer\s+\S+/i

    Message = Struct.new(:content)
    Output = Struct.new(:message)
    Usage = Struct.new(:input_tokens, :output_tokens)
    Observed = Struct.new(
      :usage, :output, :native, :normalized, :stop_reason, :returned_model, :empty,
      keyword_init: true
    )

    class Error < StandardError
      attr_reader :code

      def initialize(code, message = nil)
        @code = code
        super(message || code)
      end
    end

    class ProviderError < Error
      attr_reader :error_type, :native

      def initialize(native)
        @native = native
        err = native.is_a?(Hash) ? native["error"] : nil
        @error_type = err.is_a?(Hash) ? err["type"].to_s : "provider_error"
        text = err.is_a?(Hash) ? err["message"].to_s : @error_type
        super("provider_error", InterpreterAnthropicAdapter.scrub_text(text).truncate(180))
      end
    end

    def self.translate(params, model_id:)
      new.translate(params, model_id: model_id)
    end

    def self.normalize(native)
      new.normalize(native)
    end

    def self.tool_input(content)
      TurnInterpreter.new(
        turn: ".",
        episode: ActiveEpisode.new,
        viewer_account: nil,
        correlation_id: "interpreter-experiment:extract",
        attribution: nil,
        client: :closed,
        catalog: :closed
      ).send(:extract_tool_input, content)
    end

    def self.price(model_id, usage)
      new.price(model_id, usage)
    end

    def self.scrub(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          name = key.to_s
          next if secret_key?(name)

          out[name] = scrub(item)
        end
      when Array
        value.map { |item| scrub(item) }
      when String
        scrub_text(value)
      when Numeric, TrueClass, FalseClass, NilClass
        value
      else
        { "unmodeled_type" => value.class.name }
      end
    end

    def self.scrub_text(text)
      ValidationCapture.scrub_text(text.to_s).gsub(SK_ANT, "[redacted]").gsub(BEARER, "Bearer [redacted]")
    end

    def self.secret_key?(name)
      compact = name.to_s.downcase.gsub(/[^a-z0-9]/, "")
      return true if ValidationCapture::SECRET_KEYS.include?(compact)

      compact.include?("apikey") || compact == "authorization"
    end

    def translate(params, model_id:)
      accepted = accept_model!(model_id)
      inference = hash_at(params, :inference_config)
      max_tokens = inference[:max_tokens] || inference["max_tokens"]
      raise Error, "max_tokens_missing" unless max_tokens.is_a?(Integer)
      raise Error, "max_tokens_above_interpreter" if max_tokens > TurnInterpreter::MAX_TOKENS

      temperature = inference.key?(:temperature) ? inference[:temperature] : inference["temperature"]
      adjustments = []
      body = {
        "model" => accepted,
        "max_tokens" => max_tokens,
        "system" => [ { "type" => "text", "text" => system_text(params) } ],
        "messages" => [
          { "role" => "user", "content" => [ { "type" => "text", "text" => message_text(params) } ] }
        ],
        "tools" => anthropic_tools(hash_at(params, :tool_config)),
        "tool_choice" => { "type" => "tool", "name" => forced_tool_name(hash_at(params, :tool_config)) }
      }
      apply_sampling!(body, adjustments, model_id: accepted, temperature: temperature)
      {
        "provider" => "anthropic",
        "api" => "messages",
        "endpoint" => ENDPOINT,
        "anthropic_version" => ANTHROPIC_VERSION,
        "model_id" => accepted,
        "headers" => {
          "content-type" => "application/json",
          "anthropic-version" => ANTHROPIC_VERSION,
          "x-api-key" => { "present" => false }
        },
        "adjustments" => adjustments,
        "thinking" => "unset",
        "body" => body
      }
    end

    def normalize(native)
      original = duplicate_payload(native)
      return empty_observed(original) unless original.is_a?(Hash) && original.any?
      raise ProviderError, original if error_payload?(original)

      raw_content = original["content"]
      blocks = raw_content.is_a?(Array) ? raw_content.map { |block| normalize_block(block) } : []
      usage = original["usage"].is_a?(Hash) ? duplicate_payload(original["usage"]) : nil
      Observed.new(
        usage: usage_struct(usage),
        output: Output.new(Message.new(blocks)),
        native: original,
        normalized: {
          "provenance" => "normalized",
          "source" => "anthropic_message",
          "transformations" => [ "stringify_keys", "map_content_blocks" ],
          "model" => original["model"],
          "stop_reason" => original["stop_reason"],
          "stop_sequence" => original["stop_sequence"],
          "content" => blocks,
          "usage" => usage
        },
        stop_reason: original["stop_reason"],
        returned_model: original["model"],
        empty: blocks.empty?
      )
    end

    def price(model_id, usage)
      rates = RATES[model_id]
      tariff = tariff_for(model_id, rates)
      return tariff.merge("cost_usd" => nil, "cost_status" => "usage_absent") unless usage.is_a?(Hash)
      if unpriced_usage?(model_id, usage)
        return tariff.merge("cost_usd" => nil, "cost_status" => "unpriced_usage_field", "usage" => usage)
      end

      input = usage["input_tokens"]
      output = usage["output_tokens"]
      unless input.is_a?(Integer) && output.is_a?(Integer)
        return tariff.merge("cost_usd" => nil, "cost_status" => "usage_incomplete", "usage" => usage)
      end

      long = model_id == HAIKU_55 && input > LONG_PROMPT_TOKENS
      total = (BigDecimal(input) * rate(rates, :input, long)) + (BigDecimal(output) * rate(rates, :output, long))
      total += cache_read_cost(usage, rates, long)
      total += cache_write_cost(usage, rates, long)
      geo = geo_multiplier(model_id, usage)
      tier = service_tier_multiplier(usage)
      total *= geo * tier
      tariff.merge(
        "cost_usd" => format("%.6f", total),
        "cost_status" => "priced",
        "prompt_band" => long ? "over_100000" : "up_to_100000",
        "pricing_api" => "messages",
        "inference_geo" => usage["inference_geo"],
        "inference_geo_multiplier" => format_multiplier(geo),
        "service_tier" => usage["service_tier"],
        "service_tier_multiplier" => format_multiplier(tier),
        "usage" => usage
      )
    end

    private

    def accept_model!(model_id)
      text = model_id.to_s
      raise Error, "bedrock_model_rejected" if BEDROCK_IDS.include?(text) || text.include?("anthropic.claude")
      raise Error, "model_rejected" unless ACCEPTED_MODELS.include?(text)

      text
    end

    def apply_sampling!(body, adjustments, model_id:, temperature:)
      if model_id == HAIKU_55
        adjustments << {
          "parameter" => "temperature",
          "action" => "omit",
          "source_value" => temperature,
          "source" => SOURCES["migration"],
          "impact" => "Haiku 5.5 returns 400 for temperature other than 1, including 0. " \
                      "The prompt is unchanged. This call is not temperature-locked. " \
                      "Haiku 4.5 on the same matrix still sends temperature 0."
        }
        adjustments << thinking_adjustment
        return
      end

      raise Error, "haiku_45_temperature" unless temperature == 0

      body["temperature"] = 0
      adjustments << {
        "parameter" => "temperature",
        "action" => "send",
        "value" => 0,
        "source" => SOURCES["haiku_45"],
        "impact" => "Haiku 4.5 accepts temperature 0. top_p and top_k are not sent."
      }
    end

    def thinking_adjustment
      {
        "parameter" => "thinking",
        "action" => "unset",
        "source" => SOURCES["migration"],
        "impact" => "Adaptive thinking is on by default. A forced named tool_choice " \
                    "returns the tool call and no thinking block, so max_tokens stays " \
                    "#{TurnInterpreter::MAX_TOKENS}. The limit is not raised. effort is not set. " \
                    "A max_tokens stop is recorded and is not a pass."
      }
    end

    def anthropic_tools(tool_config)
      Array(tool_config[:tools] || tool_config["tools"]).map { |tool|
        spec = tool[:tool_spec] || tool["tool_spec"] || tool
        schema = spec.dig(:input_schema, :json) || spec.dig("input_schema", "json")
        {
          "name" => (spec[:name] || spec["name"]).to_s,
          "description" => (spec[:description] || spec["description"]).to_s,
          "input_schema" => schema.deep_dup
        }
      }
    end

    def forced_tool_name(tool_config)
      choice = tool_config[:tool_choice] || tool_config["tool_choice"] || {}
      name = choice.dig(:tool, :name) || choice.dig("tool", "name")
      raise Error, "tool_choice" unless name == TurnInterpreter::TOOL_NAME

      name
    end

    def system_text(params)
      system = params[:system] || params["system"]
      Array(system).map { |block|
        block.is_a?(Hash) ? (block[:text] || block["text"]).to_s : block.to_s
      }.join
    end

    def message_text(params)
      messages = Array(params[:messages] || params["messages"])
      first = messages.first
      return "" unless first.is_a?(Hash)

      content = Array(first[:content] || first["content"])
      block = content.first
      return "" unless block.is_a?(Hash)

      (block[:text] || block["text"]).to_s
    end

    def hash_at(params, key)
      value = params[key] || params[key.to_s]
      value.is_a?(Hash) ? value : {}
    end

    def error_payload?(hash)
      return true if hash["type"] == "error"

      hash.key?("error") && !hash.key?("content") && !hash.key?("stop_reason")
    end

    def duplicate_payload(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key.to_s] = duplicate_payload(item) }
      when Array
        value.map { |item| duplicate_payload(item) }
      else
        value
      end
    end

    def empty_observed(original)
      Observed.new(
        usage: nil,
        output: Output.new(Message.new([])),
        native: original,
        normalized: {
          "provenance" => "normalized",
          "source" => "anthropic_message",
          "transformations" => [ "empty" ],
          "content" => [],
          "usage" => nil,
          "stop_reason" => nil
        },
        stop_reason: nil,
        returned_model: nil,
        empty: true
      )
    end

    def normalize_block(block)
      return { "unmodeled_block" => { "type" => block.class.name } } unless block.is_a?(Hash)

      case block["type"].to_s
      when "text"
        block.key?("text") ? { "text" => block["text"] } : { "unmodeled_block" => { "type" => "text" } }
      when "tool_use"
        tool = {}
        tool["tool_use_id"] = block["id"] if block.key?("id")
        tool["name"] = block["name"] if block.key?("name")
        tool["input"] = block["input"] if block.key?("input")
        { "tool_use" => tool }
      when "thinking"
        thinking = {}
        thinking["thinking"] = block["thinking"] if block.key?("thinking")
        thinking["signature"] = block["signature"] if block.key?("signature")
        { "thinking" => thinking }
      when "redacted_thinking"
        redacted = {}
        redacted["data"] = block["data"] if block.key?("data")
        { "redacted_thinking" => redacted }
      else
        { "unmodeled_block" => { "type" => block["type"].to_s } }
      end
    end

    def usage_struct(usage)
      return nil unless usage.is_a?(Hash)

      input = usage["input_tokens"]
      output = usage["output_tokens"]
      return nil unless input.is_a?(Integer) && output.is_a?(Integer)

      Usage.new(input, output)
    end

    def unpriced_usage?(model_id, usage)
      return true if usage.keys.any? { |key|
        PRICED_USAGE_KEYS.exclude?(key) && USAGE_BREAKDOWN_KEYS.exclude?(key) && INTERPRETED_USAGE_KEYS.exclude?(key)
      }
      return true unless cache_consistent?(usage)
      return true unless service_tier_priced?(usage)
      return true unless inference_geo_priced?(model_id, usage)

      false
    end

    def cache_consistent?(usage)
      creation = usage["cache_creation"]
      flat = usage["cache_creation_input_tokens"]
      if creation.is_a?(Hash)
        known = %w[ephemeral_5m_input_tokens ephemeral_1h_input_tokens]
        return false if creation.keys.any? { |key| known.exclude?(key) }
        return false unless creation.each_value.all? { |value| value.is_a?(Integer) && value >= 0 }
      elsif usage.key?("cache_creation") && !creation.nil?
        return false
      end
      return true unless creation.is_a?(Hash) && flat.is_a?(Integer)

      flat == creation.values.sum
    end

    def service_tier_priced?(usage)
      return true unless usage.key?("service_tier")

      value = usage["service_tier"]
      return false if value.nil?

      SERVICE_TIER_MULTIPLIERS.key?(value)
    end

    def inference_geo_priced?(model_id, usage)
      return true unless usage.key?("inference_geo")

      value = usage["inference_geo"]
      return false if value.nil?

      GEO_MULTIPLIERS.fetch(model_id, {}).key?(value)
    end

    def geo_multiplier(model_id, usage)
      return BigDecimal("1") unless usage.key?("inference_geo")

      GEO_MULTIPLIERS.fetch(model_id).fetch(usage["inference_geo"])
    end

    def service_tier_multiplier(usage)
      return BigDecimal("1") unless usage.key?("service_tier")

      SERVICE_TIER_MULTIPLIERS.fetch(usage["service_tier"])
    end

    def format_multiplier(value)
      format("%.1f", value)
    end

    def tariff_for(model_id, rates)
      {
        "model_id" => model_id,
        "input_usd_per_mtok" => mtok(rates[:input]),
        "output_usd_per_mtok" => mtok(rates[:output]),
        "source" => SOURCES["pricing"],
        "geo_source" => SOURCES["residency"],
        "service_tier_source" => SOURCES["service_tiers"],
        "usage_source" => SOURCES["usage"],
        "consulted_on" => CONSULTED_ON,
        "tariff_version" => TARIFF_VERSION,
        "pricing_api" => "messages"
      }
    end

    def rate(rates, name, long)
      return rates[name] unless long

      rates[:"long_#{name}"] || rates[name]
    end

    def cache_read_cost(usage, rates, long)
      tokens = usage["cache_read_input_tokens"]
      return BigDecimal("0") unless tokens.is_a?(Integer)

      BigDecimal(tokens) * rate(rates, :cache_read, long)
    end

    def cache_write_cost(usage, rates, long)
      creation = usage["cache_creation"]
      if creation.is_a?(Hash)
        five = creation["ephemeral_5m_input_tokens"]
        hour = creation["ephemeral_1h_input_tokens"]
        total = BigDecimal("0")
        total += BigDecimal(five) * rate(rates, :cache_write_5m, long) if five.is_a?(Integer)
        total += BigDecimal(hour) * rate(rates, :cache_write_1h, long) if hour.is_a?(Integer)
        return total
      end

      flat = usage["cache_creation_input_tokens"]
      return BigDecimal("0") unless flat.is_a?(Integer)

      BigDecimal(flat) * rate(rates, :cache_write_5m, long)
    end

    def mtok(per_token)
      format("%.2f", per_token * 1_000_000)
    end
  end
end
