# frozen_string_literal: true

module Rag
  # Three model attempts for one pinned turn. Inactive until the phase 1
  # process calls arm!. A disarmed checkpoint does nothing. Retrieve stays
  # outside this cap. Stage2RunBudget is not this counter.
  class Phase1ModelBudget
    CAP = 3

    # Not a StandardError. generate_text and the interpreter rescue that
    # class and would otherwise continue.
    class Stop < Exception; end

    class << self
      def armed?
        !current.nil?
      end

      def arm!
        Thread.current[:phase1_model_budget] = {
          attempts: 0,
          stopped: false,
          ledger: []
        }
      end

      def disarm!
        Thread.current[:phase1_model_budget] = nil
      end

      def attempts
        current&.dig(:attempts).to_i
      end

      def stopped?
        current&.dig(:stopped) == true
      end

      def ledger
        Array(current&.dig(:ledger)).map(&:dup)
      end

      # Before the SDK call. At the cap, or after an error, this raises and
      # the caller must not invoke the client.
      def checkpoint!(name)
        state = current
        return unless state
        return block!(state, name) if state[:stopped] || state[:attempts] >= CAP

        state[:attempts] += 1
        state[:open] = name.to_s
        nil
      end

      def record_success!(name)
        state = current
        return unless state

        state[:open] = nil
        state[:ledger] << { "name" => name.to_s, "outcome" => "ok" }
        nil
      end

      def record_error!(name, error)
        state = current
        return unless state

        state[:stopped] = true
        state[:open] = nil
        state[:ledger] << {
          "name" => name.to_s,
          "outcome" => "error",
          "error_class" => error.class.name
        }
        nil
      end

      private

      def current
        Thread.current[:phase1_model_budget]
      end

      def block!(state, name)
        state[:stopped] = true
        state[:ledger] << { "name" => name.to_s, "outcome" => "blocked" }
        raise Stop, "#{name} blocked before the client"
      end
    end
  end

  # Process-local. The refusal is installed once and stays inert until
  # activate!. TrackBedrockQueryJob is inlined. Every other enqueue raises
  # before Active Job writes the queue.
  module Phase1QueueGuard
    class UnexpectedJob < StandardError; end

    module Refusal
      def perform_later(...)
        return super unless Rag::Phase1QueueGuard.active?

        raise UnexpectedJob, "phase 1 refused enqueue #{name}"
      end
    end

    module InlineTracking
      def perform_later(...)
        return super unless Rag::Phase1QueueGuard.active?

        perform_now(...)
      end
    end

    class << self
      def active?
        Thread.current[:phase1_queue_guard] == true
      end

      def install!
        return if @installed

        ApplicationJob.singleton_class.prepend(Refusal)
        TrackBedrockQueryJob.singleton_class.prepend(InlineTracking)
        @installed = true
      end

      def activate!
        install!
        Thread.current[:phase1_queue_guard] = true
      end

      def disarm!
        Thread.current[:phase1_queue_guard] = false
      end
    end
  end

  # One new web session, one pin, one turn. Refuses before a session or a
  # remote call when authorization, the environment snapshot, or the capture
  # URI does not match. Does not create accounts, users, or documents.
  class Phase1PinnedTurn
    AUTHORIZATION_ENV = "PHASE1_PINNED_TURN_AUTHORIZED"
    CAPTURE_ORIGINAL_SOURCE_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf"
    DOCUMENT_UID = "dcc8e046-037d-48a6-8913-1992aed28507"
    S3_KEY = "bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf"
    PROD_KB = "Y7RZWMFJSR"
    PROD_BUCKET = "multimodal-source-destination"
    HISTORICAL_USER_EMAIL = "stage2-journey-a@localhost.test"
    EXPECTED_ENVIRONMENT = {
      "primary" => "smart_deal_stage2_isolated",
      "cache" => "smart_deal_stage2_isolated_cache",
      "cable" => "smart_deal_stage2_isolated_cable",
      "queue" => "smart_deal_development_queue",
      "kb" => PROD_KB,
      "region" => "us-east-1",
      "aws_max_attempts" => "1",
      "kb_bucket" => PROD_BUCKET
    }.freeze

    Result = Struct.new(
      :status, :reason, :session_id, :document_id, :uris, :ledger, :capture,
      keyword_init: true
    )

    class QueryHost
      include RagQueryConcern

      def initialize(account)
        @current_account = account
      end

      attr_reader :current_account

      def execute(question, **)
        execute_rag_query(question, **)
      end
    end

    class BudgetedConverse
      def initialize(inner)
        @inner = inner
      end

      def converse(params)
        Phase1ModelBudget.checkpoint!("interpreter")
        result = @inner.converse(params)
        Phase1ModelBudget.record_success!("interpreter")
        result
      rescue Phase1ModelBudget::Stop
        raise
      rescue StandardError => error
        Phase1ModelBudget.record_error!("interpreter", error)
        raise Phase1ModelBudget::Stop, "interpreter stopped after #{error.class}"
      end
    end

    class << self
      def authorized?
        ENV[AUTHORIZATION_ENV] == "1"
      end

      def live_snapshot
        {
          "primary" => ActiveRecord::Base.connection.current_database,
          "cache" => SolidCache::Record.connection.current_database,
          "cable" => SolidCable::Record.connection.current_database,
          "queue" => SolidQueue::Record.connection_db_config.database,
          "kb" => ENV["BEDROCK_KNOWLEDGE_BASE_ID"].to_s,
          "region" => (ENV["AWS_REGION"].presence || ENV["AWS_DEFAULT_REGION"]).to_s,
          "aws_max_attempts" => ENV["AWS_MAX_ATTEMPTS"].to_s,
          "kb_bucket" => KbDocument::KB_BUCKET
        }
      end

      # Local databases only. Does not call AWS and does not enqueue.
      def connect_isolated!
        raise Phase1ModelBudget::Stop, "phase 1 connect refused outside development" unless Rails.env.development?

        ActiveRecord::Base.establish_connection(isolated_config("primary", "smart_deal_stage2_isolated"))
        SolidCache::Record.establish_connection(isolated_config("cache", "smart_deal_stage2_isolated_cache"))
        SolidCable::Record.establish_connection(isolated_config("cable", "smart_deal_stage2_isolated_cable"))
        SharedManualCorpus.reset_account_ids!
        live_snapshot
      end

      def call(account:, user:, document:, message:, connections:, executor: nil, interpreter_client: nil, run_id: nil, enforce_capture_uri: true)
        refusal = authorization_refusal || environment_refusal(connections)
        return refusal if refusal

        refusal = document_refusal(document, viewer_account: account, enforce_capture_uri: enforce_capture_uri)
        return refusal if refusal

        run_id = run_id.presence || Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        session = nil
        events = nil
        outcome = nil
        Phase1QueueGuard.activate!
        Phase1ModelBudget.arm!
        ValidationCapture.capture do |bucket|
          events = bucket
          session = open_session(account, user, run_id)
          pinned = session.pin_kb_document!(document)
          raise Phase1ModelBudget::Stop, "pin refused" unless pinned

          uris = SessionContextBuilder.entity_s3_uris(session)
          unless uris == [ document.canonical_uri ]
            raise Phase1ModelBudget::Stop, "pin uri #{uris.inspect}"
          end

          correlation_id = "phase1:#{session.id}"
          query_correlation = "#{correlation_id}:query"
          ValidationCapture.bind(
            session_id: session.id,
            account_id: account.id,
            user_id: user.id,
            correlation_root: correlation_id
          )
          ValidationCapture.correlation = correlation_id
          episode_turn = session.record_user_turn!(
            message,
            user_id: user.id,
            correlation_id: correlation_id,
            locale: :es,
            interpreter_client: BudgetedConverse.new(interpreter_client || BedrockClient.new)
          )
          ValidationCapture.bind(episode_id: session.live_episode_id)
          ValidationCapture.record(
            "phase1_turn",
            "session_id" => session.id,
            "episode_id" => session.live_episode_id,
            "technician_correlation_id" => correlation_id,
            "query_correlation_id" => query_correlation,
            "entity_s3_uris" => uris,
            "historical_session" => false
          )
          ValidationCapture.correlation = query_correlation
          host = executor || QueryHost.new(account)
          result = host.execute(
            message,
            conv_session: session,
            account: account,
            user_id: user.id,
            correlation_id: query_correlation,
            conversation_session_id: session.id,
            episode_turn: episode_turn,
            response_locale: :es,
            output_channel: :web,
            raw_question: message,
            session_context: SessionContextBuilder.build(session).to_s,
            entity_s3_uris: uris
          )
          if result.respond_to?(:success?) && result.success? && result.respond_to?(:answer)
            session.record_assistant_turn!(
              result.answer.to_s,
              user_id: user.id,
              correlation_id: query_correlation,
              pending_question: (result.pending_question if result.respond_to?(:pending_question)),
              expected_episode_id: session.live_episode_id,
              focus_ids: session.focus_document_ids
            )
          end
          outcome = Result.new(
            status: "ok",
            reason: nil,
            session_id: session.id,
            document_id: document.id,
            uris: uris,
            ledger: Phase1ModelBudget.ledger,
            capture: events
          )
        end
        outcome
      rescue Phase1ModelBudget::Stop => error
        Result.new(
          status: "stopped",
          reason: error.message.to_s,
          session_id: session&.id,
          document_id: document&.id,
          uris: [],
          ledger: Phase1ModelBudget.ledger,
          capture: events
        )
      ensure
        Phase1ModelBudget.disarm!
        Phase1QueueGuard.disarm!
      end

      private

      def authorization_refusal
        return if authorized?

        Result.new(status: "refused", reason: "authorization_absent")
      end

      def environment_refusal(connections)
        snapshot = connections.to_h.transform_keys(&:to_s)
        mismatch = EXPECTED_ENVIRONMENT.find { |key, value| snapshot[key].to_s != value }
        return if mismatch.nil?

        Result.new(status: "refused", reason: "environment:#{mismatch.first}")
      end

      def document_refusal(document, viewer_account:, enforce_capture_uri:)
        return Result.new(status: "refused", reason: "document_missing") if document.nil?
        if enforce_capture_uri && document.canonical_uri.to_s != CAPTURE_ORIGINAL_SOURCE_URI
          return Result.new(status: "refused", reason: "canonical_uri")
        end
        return if KnowledgeScopePolicy.authorized?(document, viewer_account: viewer_account)

        Result.new(status: "refused", reason: "document_not_authorized")
      end

      def open_session(account, user, run_id)
        ConversationSession.create!(
          account: account,
          user: user,
          identifier: "phase1:pinned:#{run_id}",
          channel: "web",
          expires_at: 30.days.from_now,
          conversation_history: [],
          active_episode: {}
        )
      end

      def isolated_config(role, database)
        source = if role == "primary"
          ActiveRecord::Base.connection_db_config.configuration_hash.dup
        else
          ActiveRecord::Base.configurations.configs_for(env_name: "development", name: role).configuration_hash.dup
        end
        if source.key?("database")
          source["database"] = database
        else
          source[:database] = database
        end
        source
      end
    end
  end
end
