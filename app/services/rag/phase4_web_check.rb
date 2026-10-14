# frozen_string_literal: true

module Rag
  # Exclusive gate for one phase 4 web check. Habitual development and
  # production do not arm it. The process must export PHASE4_WEB_CHECK=1;
  # that key must not be assigned in .env. A refusal aborts before Puma
  # accepts. This is not Stage2RunBudget and it does not change the closed
  # phase 1, 2, or 3 caps.
  class Phase4WebCheck
    ACTIVATION_ENV = "PHASE4_WEB_CHECK"
    ACTIVATION_VALUE = "1"

    # Process-wide counters for the two POSTs of this server. arm! does not
    # reset an existing ledger. An error does not return the attempt it
    # already took. Stop is not a StandardError, so a blocked call does not
    # continue into the client.
    class Budget
      MODEL_CAP = 4
      LOGICAL_CAP = 2
      PHYSICAL_PER_LOGICAL = 4
      MUTEX = Mutex.new

      class Stop < Exception; end

      class << self
        def armed?
          MUTEX.synchronize { !@state.nil? }
        end

        def arm!
          MUTEX.synchronize { @state ||= empty_state }
          nil
        end

        def disarm!
          MUTEX.synchronize { @state = nil }
          nil
        end

        def model_attempts
          read(:model_attempts)
        end

        def logical
          read(:logical)
        end

        def logical_physical
          read(:logical_physical)
        end

        def stopped?
          MUTEX.synchronize { @state&.dig(:stopped) == true }
        end

        def ledger
          MUTEX.synchronize { Array(@state&.dig(:ledger)).map(&:dup) }
        end

        def export
          MUTEX.synchronize do
            next nil unless @state

            {
              "model_attempts" => @state[:model_attempts].to_i,
              "logical" => @state[:logical].to_i,
              "logical_physical" => @state[:logical_physical].to_i,
              "stopped" => @state[:stopped] == true,
              "ledger" => @state[:ledger].map(&:dup)
            }
          end
        end

        # Before a model SDK call. At the cap, or after an error, this raises
        # and the caller must not invoke the client.
        def checkpoint!(name)
          decision = MUTEX.synchronize do
            next :disarmed unless @state
            if @state[:stopped] || @state[:model_attempts] >= MODEL_CAP
              block_locked!(name, "model")
              :blocked
            else
              @state[:model_attempts] += 1
              @state[:ledger] << entry(name, "model", "attempt")
              :allowed
            end
          end
          raise_blocked!(name, "model") if decision == :blocked
          nil
        end

        def record_success!(name)
          MUTEX.synchronize do
            next unless @state

            @state[:ledger] << entry(name, "model", "ok")
          end
          nil
        end

        # The attempt counted by checkpoint! stays counted.
        def record_error!(name, error)
          MUTEX.synchronize do
            next unless @state

            @state[:stopped] = true
            @state[:ledger] << entry(name, "model", "error", error_class: error.class.name)
          end
          Rails.logger.warn(
            "phase4_web_check error kind=model name=#{name} error_class=#{error.class.name} " \
            "model_attempts=#{model_attempts}"
          )
          nil
        end

        def begin_logical!
          decision = MUTEX.synchronize do
            next :disarmed unless @state
            if @state[:stopped] || @state[:logical] >= LOGICAL_CAP
              block_locked!(nil, "logical")
              :blocked
            else
              @state[:logical] += 1
              @state[:logical_physical] = 0
              @state[:ledger] << entry(nil, "logical", "attempt")
              :allowed
            end
          end
          raise_blocked!("logical", "logical") if decision == :blocked
          nil
        end

        def before_physical!
          decision = MUTEX.synchronize do
            next :disarmed unless @state
            over = @state[:stopped] || @state[:logical] <= 0 ||
                   @state[:logical_physical] >= PHYSICAL_PER_LOGICAL
            if over
              block_locked!(nil, "physical")
              :blocked
            else
              @state[:logical_physical] += 1
              @state[:ledger] << entry(nil, "physical", "attempt")
              :allowed
            end
          end
          raise_blocked!("physical", "physical") if decision == :blocked
          nil
        end

        private

        def read(key)
          MUTEX.synchronize { @state ? @state[key].to_i : 0 }
        end

        def empty_state
          {
            model_attempts: 0,
            logical: 0,
            logical_physical: 0,
            stopped: false,
            ledger: []
          }
        end

        def block_locked!(name, kind)
          @state[:stopped] = true
          @state[:ledger] << entry(name, kind, "blocked")
          nil
        end

        def entry(name, kind, outcome, error_class: nil)
          row = { "kind" => kind, "outcome" => outcome }
          row["name"] = name.to_s if name
          row["error_class"] = error_class if error_class
          row
        end

        def raise_blocked!(name, kind)
          Rails.logger.warn(
            "phase4_web_check blocked kind=#{kind} name=#{name} " \
            "model_attempts=#{model_attempts} logical=#{logical} physical=#{logical_physical}"
          )
          raise Stop, "#{name} blocked before the client"
        end
      end
    end

    ClientView = Struct.new(
      :max_attempts, :retry_limit, :retry_mode, :legacy_handler, :standard_handler,
      keyword_init: true
    )

    class << self
      # Aborts the process when isolation, the budget gate, or retry config
      # is incomplete. Registers nothing when the activation env is absent.
      def boot!
        reason = activate!(**boot_inputs)
        abort("phase4 web check refused: #{reason}") if reason
      end

      # Returns a refusal code, or nil after arming. Does not reset a budget
      # that was already armed. Tests pass doubles; boot! passes the process.
      def activate!(env:, dotenv:, rails_env:, queue_adapter:, queue_guard_active:, clients:, snapshot:, connector:)
        reason = refusal(
          env: env, dotenv: dotenv, rails_env: rails_env, queue_adapter: queue_adapter,
          queue_guard_active: queue_guard_active, clients: clients, snapshot: snapshot,
          connector: connector
        )
        return reason if reason

        Budget.arm!
        nil
      end

      def refusal(env:, dotenv:, rails_env:, queue_adapter:, queue_guard_active:, clients:, snapshot:, connector:)
        reason = process_refusal(
          env: env, dotenv: dotenv, rails_env: rails_env,
          queue_adapter: queue_adapter, queue_guard_active: queue_guard_active
        )
        return reason if reason

        reason = clients_refusal(clients)
        return reason if reason

        isolation_refusal(connector: connector, snapshot: snapshot)
      end

      def activation_in_dotenv?(text)
        text.to_s.each_line.any? do |line|
          stripped = line.strip
          next false if stripped.empty? || stripped.start_with?("#")

          stripped.sub(/\Aexport\s+/, "").match?(/\A#{ACTIVATION_ENV}\s*=/)
        end
      end

      private

      def boot_inputs
        {
          env: ENV.to_h,
          dotenv: dotenv_text,
          rails_env: Rails.env.to_s,
          queue_adapter: ActiveJob::Base.queue_adapter.class.name,
          queue_guard_active: queue_guard_active?,
          clients: observe_clients,
          snapshot: nil,
          connector: -> { Rag::Phase1PinnedTurn.connect_isolated! }
        }
      end

      def process_refusal(env:, dotenv:, rails_env:, queue_adapter:, queue_guard_active:)
        return "not_development" unless rails_env.to_s == "development"
        return "activation_in_dotenv" if activation_in_dotenv?(dotenv)
        return "activation_absent" unless env[ACTIVATION_ENV] == ACTIVATION_VALUE
        return "aws_retry_mode" unless env["AWS_RETRY_MODE"] == "standard"
        return "aws_max_attempts" unless env["AWS_MAX_ATTEMPTS"] == "1"
        return "web_concurrency" unless env["WEB_CONCURRENCY"] == "0"
        return "solid_queue_in_puma" unless env["SOLID_QUEUE_IN_PUMA"].to_s.strip.empty?

        adapter = queue_adapter.to_s.downcase
        return "inline_jobs" if adapter.include?("inline") || adapter.include?("async")
        return "queue_guard" if queue_guard_active

        nil
      end

      def clients_refusal(clients)
        return "clients_missing" unless clients.is_a?(Hash)

        %i[invoke_model retrieve converse].each do |name|
          reason = client_refusal(name, clients[name] || clients[name.to_s])
          return reason if reason
        end
        nil
      end

      def client_refusal(name, view)
        return "#{name}:missing" if view.nil?
        return "#{name}:retry_mode" unless view.retry_mode.to_s == "standard"
        return "#{name}:max_attempts" unless view.max_attempts == 1
        return "#{name}:legacy_handler" if view.legacy_handler
        return "#{name}:standard_handler" unless view.standard_handler
        return "#{name}:retry_limit" if name == :converse && view.retry_limit != 0

        nil
      end

      def isolation_refusal(connector:, snapshot:)
        connected = connector.call
        observed = snapshot.respond_to?(:call) ? snapshot.call : snapshot
        observed = connected if observed.nil?
        Rag::Phase1PinnedTurn.send(:environment_refusal, observed || {})&.reason
      end

      def dotenv_text
        path = Rails.root.join(".env")
        return "" unless path.file?

        path.readlines.reject { |line| line.lstrip.start_with?("#") }.join
      end

      def queue_guard_active?
        return false unless defined?(Rag::Phase1QueueGuard)

        Rag::Phase1QueueGuard.active?
      end

      def observe_clients
        probe = Class.new { include AwsClientInitializer }.new
        base = probe.send(:build_aws_client_options)
        {
          invoke_model: observe(Aws::BedrockRuntime::Client.new(base)),
          retrieve: observe(Aws::BedrockAgentRuntime::Client.new(base)),
          converse: observe(Aws::BedrockRuntime::Client.new(base.merge(BedrockClient::CONVERSE_CLIENT_OPTIONS)))
        }
      end

      def observe(client)
        names = client.handlers.entries.map { |entry| entry.handler_class.name }
        ClientView.new(
          max_attempts: client.config.max_attempts,
          retry_limit: client.config.retry_limit,
          retry_mode: client.config.retry_mode,
          legacy_handler: names.any? { |name| name.end_with?("::LegacyHandler") },
          standard_handler: names.any? { |name| name.end_with?("::RetryErrors::Handler") }
        )
      end
    end
  end
end
