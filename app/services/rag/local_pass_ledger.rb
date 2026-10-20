# frozen_string_literal: true

module Rag
  # Process-local ceiling for one explicit local pass. Disarmed unless the
  # process exported the guard and is on a local, non-production database.
  # Does not replace Stage2RunBudget and does not change a disarmed call.
  #
  # A refused call is not sent. An admitted call counts even when it fails.
  # Provider usage replaces the pre-call ceiling. A call without usage keeps
  # that ceiling as a hold so a later call cannot assume the spend was zero.
  # Prices come from BedrockQuery::BEDROCK_PRICING. Token ceilings are bounds,
  # not a second price list: one token per character when the text is local,
  # and ContractualLimits::QUERY when retrieve_and_generate adds chunks later.
  class LocalPassLedger
    GUARD_ENV = "RAG_LOCAL_PASS_GUARD"
    CALL_CAP_ENV = "RAG_LOCAL_PASS_CALL_CAP"
    COST_CAP_ENV = "RAG_LOCAL_PASS_COST_CAP_USD"
    ATTEMPTS_ENV = "AWS_MAX_ATTEMPTS"
    TICKETS = :rag_local_pass_tickets
    LOCAL_HOSTS = [ "", "localhost", "127.0.0.1", "::1" ].freeze
    MUTEX = Mutex.new

    # Not a StandardError. Callers that rescue provider failures must not
    # turn a refusal into another model call.
    class Stop < Exception; end

    class << self
      def armed?
        guard_requested? && single_attempt_process? && local_process?
      end

      def guard_requested?
        ENV[GUARD_ENV] == "1" && call_cap && cost_cap
      end

      def single_attempt_process?
        ENV[ATTEMPTS_ENV] == "1"
      end

      def local_process?
        return @local_process unless @local_process.nil?

        @local_process = compute_local_process
      end

      def reset_local_process!
        @local_process = nil
      end

      def call_cap
        integer_env(CALL_CAP_ENV)
      end

      def cost_cap
        raw = ENV[COST_CAP_ENV].to_s
        return nil unless raw.match?(/\A(?:0|[1-9]\d*)(?:\.\d{1,6})?\z/)

        BigDecimal(raw)
      end

      def status
        {
          "armed" => armed?,
          "guard_requested" => guard_requested?,
          "single_attempt_process" => single_attempt_process?,
          "local_process" => local_process?,
          "aws_max_attempts" => ENV[ATTEMPTS_ENV].to_s,
          "call_cap" => call_cap,
          "cost_cap_usd" => cost_cap&.to_s("F")
        }
      end

      def snapshot
        state = MUTEX.synchronize do
          current = @state || empty_state
          current.merge(open: current[:open].dup)
        end
        open = state[:open] || {}
        {
          "stage" => "ledger",
          "attempts" => state[:attempts].to_i,
          "blocked" => state[:blocked].to_i,
          "priced" => state[:priced].to_i,
          "committed_usd" => money(state[:committed]),
          "held_usd" => money(open.values.sum(BigDecimal("0"))),
          "call_cap" => call_cap,
          "cost_cap_usd" => cost_cap&.to_s("F"),
          "aws_max_attempts" => ENV[ATTEMPTS_ENV].to_s
        }
      end

      def reset!
        MUTEX.synchronize { @state = nil }
        Thread.current[TICKETS] = nil
        nil
      end

      # Raises Stop before yield when this call would pass a cap. The yielded
      # call is the one invocation that counts. The caller settles provider
      # usage on the same thread. Another thread does not see these tickets.
      def protect!(operation:, model_id:, input_tokens:, output_tokens:)
        return yield unless armed?

        ticket = nil
        ceiling = nil
        decision = MUTEX.synchronize do
          state = (@state ||= empty_state)
          ceiling = price(model_id, input_tokens, output_tokens)
          if state[:attempts] + 1 > call_cap || exposure_locked(state) + ceiling > cost_cap
            state[:blocked] += 1
            :blocked
          else
            state[:attempts] += 1
            ticket = (state[:seq] += 1)
            state[:open][ticket] = ceiling
            :admitted
          end
        end
        if decision == :blocked
          note(operation, "blocked", ceiling)
          raise Stop, operation.to_s
        end

        note(operation, "admitted", ceiling)
        (Thread.current[TICKETS] ||= []) << ticket
        yield
      end

      def settle_usage!(response, model_id:)
        return unless armed?

        ticket = Array(Thread.current[TICKETS]).pop
        Thread.current[TICKETS] = Array(Thread.current[TICKETS])
        return unless ticket

        tokens = read_usage(response)
        return unless tokens

        commit(ticket, price(model_id, tokens[0], tokens[1]))
      rescue StandardError
        nil
      end

      # Drops this thread's unsettled tickets from the stack. Their ceilings
      # stay held on the process ledger. The next request must not settle them.
      def release_thread!
        Thread.current[TICKETS] = nil
        nil
      end

      def single_attempt!(client)
        return unless armed?
        return unless client.respond_to?(:config)

        config = client.config
        return unless config.respond_to?(:max_attempts)
        return if config.max_attempts == 1

        raise Stop, "max_attempts"
      end

      def price(model_id, input_tokens, output_tokens)
        priced = priced_model_id(model_id)
        pricing = BedrockQuery.new(model_id: priced, input_tokens: 1, output_tokens: 0).pricing_for(priced)
        input = (input_tokens.to_i / 1000.0) * pricing[:input].to_f
        output = (output_tokens.to_i / 1000.0) * pricing[:output].to_f
        BigDecimal((input + output).round(6).to_s)
      end

      def priced_model_id(model_id)
        text = model_id.to_s
        keys = BedrockQuery::BEDROCK_PRICING.keys - [ "default" ]
        return text if keys.any? { |key| text == key || text.start_with?(key) }

        keys.find { |key| text.include?(key) } || BedrockClient::QUERY_MODEL_ID
      end

      def text_chars(value)
        case value
        when String
          value.length
        when Hash
          value.sum(0) { |pair| text_chars(pair[0]) + text_chars(pair[1]) }
        when Array
          value.sum(0) { |item| text_chars(item) }
        else
          0
        end
      end

      def model_id_from(*objects)
        objects.each do |object|
          found = dig_model_id(object)
          return found if found.present?
        end
        BedrockClient::QUERY_MODEL_ID
      end

      def output_tokens_from(*objects)
        objects.each do |object|
          found = dig_output_tokens(object)
          return found if found
        end
        ContractualLimits::QUERY[:max_output_tokens]
      end

      private

      def compute_local_process
        return false unless Rails.env.local?

        rows = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
        return false if rows.empty?

        rows.all? do |config|
          hash = config.configuration_hash
          database = hash[:database].to_s
          host = hash[:host].to_s
          database.present? && database.downcase.exclude?("production") && LOCAL_HOSTS.include?(host)
        end
      end

      def integer_env(key)
        raw = ENV[key].to_s
        return nil unless raw.match?(/\A[1-9]\d*\z/)

        raw.to_i
      end

      def empty_state
        { attempts: 0, blocked: 0, priced: 0, seq: 0, committed: BigDecimal("0"), open: {} }
      end

      def exposure_locked(state)
        state[:committed] + state[:open].values.sum(BigDecimal("0"))
      end

      def commit(ticket, actual)
        MUTEX.synchronize do
          state = @state
          return unless state&.dig(:open)&.delete(ticket)

          state[:committed] += actual
          state[:priced] += 1
        end
        nil
      end

      def note(operation, result, ceiling)
        return unless ValidationCapture.active?

        ValidationCapture.record(
          "local_pass_ledger",
          snapshot.merge(
            "operation" => operation.to_s,
            "result" => result,
            "ceiling_usd" => money(ceiling)
          )
        )
      end

      def money(value)
        format("%.6f", BigDecimal(value.to_s))
      end

      def read_usage(response)
        usage = if response.is_a?(Hash)
          response["usage"] || response[:usage]
        elsif response.respond_to?(:usage)
          response.usage
        end
        return nil unless usage

        input = token_of(usage, :input_tokens)
        return nil if input.nil?

        [ input, token_of(usage, :output_tokens).to_i ]
      end

      def token_of(usage, name)
        if usage.is_a?(Hash)
          return nil unless usage.key?(name) || usage.key?(name.to_s)

          (usage[name] || usage[name.to_s]).to_i
        elsif usage.respond_to?(name)
          value = usage.public_send(name)
          value.nil? ? nil : value.to_i
        end
      end

      def dig_model_id(object)
        case object
        when Hash
          object[:model_id] || object["model_id"] || object.values.lazy.filter_map { |item| dig_model_id(item) }.first
        when Array
          object.lazy.filter_map { |item| dig_model_id(item) }.first
        end
      end

      def dig_output_tokens(object)
        case object
        when Hash
          direct = object[:max_tokens] || object["max_tokens"]
          return direct.to_i if direct
          nested = object[:inference_config] || object["inference_config"] || object[:inferenceConfig] || object["inferenceConfig"]
          found = dig_output_tokens(nested) if nested
          return found if found

          object.each_value do |item|
            found = dig_output_tokens(item)
            return found if found
          end
          nil
        when Array
          object.each do |item|
            found = dig_output_tokens(item)
            return found if found
          end
          nil
        end
      end
    end
  end
end
