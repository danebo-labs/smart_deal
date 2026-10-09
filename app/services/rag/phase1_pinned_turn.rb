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
    EXPECTED_MODEL = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    HISTORICAL_USER_EMAIL = "stage2-journey-a@localhost.test"
    # The natural question. It does not carry the evaluator reference.
    NATURAL_MESSAGE = "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta y cómo se relaciona con las demás seguridades?"
    LOCAL_HOSTS = %w[localhost 127.0.0.1].freeze
    HOST_KEYS = %w[primary_host cache_host cable_host queue_host].freeze
    EXPECTED_ENVIRONMENT = {
      "primary_database" => "smart_deal_stage2_isolated",
      "primary_adapter" => "postgresql",
      "cache_database" => "smart_deal_stage2_isolated_cache",
      "cache_adapter" => "postgresql",
      "cable_database" => "smart_deal_stage2_isolated_cable",
      "cable_adapter" => "postgresql",
      "queue_database" => "smart_deal_development_queue",
      "kb_env" => PROD_KB,
      "kb_effective" => PROD_KB,
      "region_env" => "us-east-1",
      "region_effective" => "us-east-1",
      "aws_max_attempts" => "1",
      "kb_bucket_env" => PROD_BUCKET,
      "kb_bucket_effective" => PROD_BUCKET,
      "shared_session_effective" => false,
      "haiku_mode" => "owner",
      "episode_enabled" => true,
      "turn_enabled" => true,
      "document_identity_scope" => true,
      "grounded_synthesis" => true,
      "grounded_synthesis_account_ids" => "",
      "pilot_audit_capture" => "true",
      "interpreter_model" => EXPECTED_MODEL,
      "generation_model" => EXPECTED_MODEL
    }.freeze

    Result = Struct.new(
      :status, :reason, :session_id, :document_id, :uris, :ledger, :capture,
      :answer, :evidence_path, :episode_id,
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
        effective_environment
      end

      # Values the process will actually use. ENV and the already-loaded
      # constant are both recorded. A credential or an account KB id is an
      # identifier, not a secret.
      def stub_environment
        EXPECTED_ENVIRONMENT.merge(
          "primary_host" => "localhost",
          "cache_host" => "localhost",
          "cable_host" => "localhost",
          "queue_host" => "localhost"
        )
      end

      def effective_environment
        primary = ActiveRecord::Base.connection_db_config
        cache = SolidCache::Record.connection_db_config
        cable = SolidCable::Record.connection_db_config
        queue = SolidQueue::Record.connection_db_config
        account_kb = nil
        {
          "primary_database" => ActiveRecord::Base.connection.current_database,
          "primary_host" => primary.host.to_s,
          "primary_adapter" => primary.adapter.to_s,
          "cache_database" => SolidCache::Record.connection.current_database,
          "cache_host" => cache.host.to_s,
          "cache_adapter" => cache.adapter.to_s,
          "cable_database" => SolidCable::Record.connection.current_database,
          "cable_host" => cable.host.to_s,
          "cable_adapter" => cable.adapter.to_s,
          "queue_database" => queue.database.to_s,
          "queue_host" => queue.host.to_s,
          "kb_env" => ENV["BEDROCK_KNOWLEDGE_BASE_ID"].to_s,
          "kb_effective" => effective_knowledge_base_id(account_kb),
          "region_env" => ENV["AWS_REGION"].to_s,
          "region_effective" => effective_region,
          "aws_max_attempts" => ENV["AWS_MAX_ATTEMPTS"].to_s,
          "kb_bucket_env" => ENV["KNOWLEDGE_BASE_S3_BUCKET"].to_s,
          "kb_bucket_effective" => KbDocument::KB_BUCKET,
          "shared_session_env" => ENV["SHARED_SESSION_ENABLED"].to_s,
          "shared_session_effective" => SharedSession::ENABLED,
          "haiku_mode" => HaikuQueryAnalysisFlag.mode,
          "episode_enabled" => FieldCompanionEpisodeFlag.enabled?,
          "turn_enabled" => FieldCompanionTurnFlag.enabled?,
          "document_identity_scope" => DocumentIdentityScopeFlag.enabled?,
          "grounded_synthesis" => GroundedSynthesisFlag.enabled?,
          "grounded_synthesis_account_ids" => GroundedSynthesisFlag.configured_account_ids.join(","),
          "pilot_audit_capture" => ENV["PILOT_AUDIT_CAPTURE"].to_s,
          "interpreter_model" => TurnInterpreter::MODEL_ID,
          "generation_model" => BedrockClient::QUERY_MODEL_ID,
          "generation_model_env" => ENV["BEDROCK_MODEL_ID"].to_s
        }
      end

      def run(evidence_root: nil)
        unless authorized?
          return call(
            account: nil, user: nil, document: nil, message: NATURAL_MESSAGE,
            connections: {}, evidence_root: evidence_root
          )
        end

        connect_isolated!
        account = Account.find_by(id: 1)
        user = User.find_by(email: HISTORICAL_USER_EMAIL)
        document = account && KbDocument.find_by(account_id: account.id, document_uid: DOCUMENT_UID)
        environment = effective_environment
        environment["kb_effective"] = effective_knowledge_base_id(account_kb_id(account))
        call(
          account: account, user: user, document: document, message: NATURAL_MESSAGE,
          connections: environment, evidence_root: evidence_root
        )
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

      def call(account:, user:, document:, message:, connections:, executor: nil, interpreter_client: nil, run_id: nil, enforce_capture_uri: true, evidence_root: nil)
        run_id = run_id.presence || Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        directory = evidence_directory(evidence_root, run_id)
        result = turn_result(
          account: account, user: user, document: document, message: message,
          connections: connections, executor: executor, interpreter_client: interpreter_client,
          run_id: run_id, enforce_capture_uri: enforce_capture_uri
        )
        publish_evidence(result, directory, message: message, connections: connections)
      end

      private

      def turn_result(account:, user:, document:, message:, connections:, executor:, interpreter_client:, run_id:, enforce_capture_uri:)
        refusal = authorization_refusal || environment_refusal(connections) || actor_refusal(account, user)
        return refusal if refusal

        refusal = document_refusal(document, viewer_account: account, enforce_capture_uri: enforce_capture_uri)
        return refusal if refusal

        session = nil
        events = nil
        outcome = nil
        Phase1QueueGuard.activate!
        Phase1ModelBudget.arm!
        ValidationCapture.capture do |bucket|
          events = bucket
          session = open_session(account, user, run_id)
          pinned = session.pin_kb_document!(document)
          unless pinned
            outcome = failed_result(session, document, events, "pin_refused")
            next
          end

          uris = SessionContextBuilder.entity_s3_uris(session)
          unless uris == [ document.canonical_uri ]
            outcome = failed_result(session, document, events, "pin_uri")
            next
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
          outcome = application_result(session, document, events, uris, result, query_correlation, user)
        end
        outcome
      rescue Phase1ModelBudget::Stop => error
        stopped_result(session, document, events, error.message)
      rescue StandardError => error
        failed_result(session, document, events, "#{error.class}: #{error.message}")
      ensure
        Phase1ModelBudget.disarm!
        Phase1QueueGuard.disarm!
      end

      def application_result(session, document, events, uris, result, query_correlation, user)
        answer = result.respond_to?(:answer) ? result.answer.to_s : ""
        if result.respond_to?(:success?) && result.success?
          session.record_assistant_turn!(
            answer,
            user_id: user.id,
            correlation_id: query_correlation,
            pending_question: (result.pending_question if result.respond_to?(:pending_question)),
            expected_episode_id: session.live_episode_id,
            focus_ids: session.focus_document_ids
          )
          return Result.new(
            status: "completed",
            reason: nil,
            session_id: session.id,
            episode_id: session.live_episode_id,
            document_id: document.id,
            uris: uris,
            ledger: Phase1ModelBudget.ledger,
            capture: events,
            answer: answer
          )
        end

        failed_result(session, document, events, application_failure_reason(result), answer: answer, uris: uris)
      end

      def authorization_refusal
        return if authorized?

        Result.new(status: "refused", reason: "authorization_absent")
      end

      def actor_refusal(account, user)
        return Result.new(status: "refused", reason: "account_missing") if account.nil?
        return Result.new(status: "refused", reason: "user_missing") if user.nil?
        return if user.account_id == account.id

        Result.new(status: "refused", reason: "user_account")
      end

      def environment_refusal(connections)
        snapshot = connections.to_h.transform_keys(&:to_s)
        if snapshot["generation_model_env"].present? && snapshot["generation_model_env"] != EXPECTED_MODEL
          return Result.new(status: "refused", reason: "environment:generation_model_env")
        end
        if snapshot["shared_session_env"].to_s == "true" || snapshot["shared_session_effective"] == true
          return Result.new(status: "refused", reason: "environment:shared_session_effective")
        end

        EXPECTED_ENVIRONMENT.each do |key, expected|
          actual = snapshot[key]
          next if actual == expected
          next if actual.to_s == expected.to_s && [ true, false ].exclude?(expected)

          return Result.new(status: "refused", reason: "environment:#{key}")
        end
        HOST_KEYS.each do |key|
          return Result.new(status: "refused", reason: "environment:#{key}") unless local_host?(snapshot[key])
        end
        nil
      end

      def document_refusal(document, viewer_account:, enforce_capture_uri:)
        return Result.new(status: "refused", reason: "document_missing") if document.nil?
        if enforce_capture_uri && document.canonical_uri.to_s != CAPTURE_ORIGINAL_SOURCE_URI
          return Result.new(status: "refused", reason: "canonical_uri")
        end
        return if KnowledgeScopePolicy.authorized?(document, viewer_account: viewer_account)

        Result.new(status: "refused", reason: "document_not_authorized")
      end

      def failed_result(session, document, events, reason, answer: nil, uris: [])
        Result.new(
          status: "failed",
          reason: clean_reason(reason),
          session_id: session&.id,
          episode_id: session&.live_episode_id,
          document_id: document&.id,
          uris: uris,
          ledger: Phase1ModelBudget.ledger,
          capture: events,
          answer: answer
        )
      end

      def stopped_result(session, document, events, reason)
        Result.new(
          status: "stopped",
          reason: clean_reason(reason),
          session_id: session&.id,
          episode_id: session&.live_episode_id,
          document_id: document&.id,
          uris: [],
          ledger: Phase1ModelBudget.ledger,
          capture: events
        )
      end

      def application_failure_reason(result)
        parts = []
        parts << result.error_class if result.respond_to?(:error_class)
        parts << result.error_type if result.respond_to?(:error_type)
        parts << result.error_message if result.respond_to?(:error_message)
        text = parts.compact.map(&:to_s).reject(&:empty?).join(" ")
        text.presence || "application_failed"
      end

      def publish_evidence(result, directory, message:, connections:)
        write_evidence(result, directory, message: message, connections: connections)
        result.evidence_path = directory.to_s
        result
      rescue StandardError => error
        result.status = "failed" if result.status == "completed"
        extra = "evidence_export:#{error.class}"
        result.reason = [ result.reason, extra ].compact.join(" ")
        result
      end

      def write_evidence(result, directory, message:, connections:)
        FileUtils.mkdir_p(directory)
        session = result.session_id && ConversationSession.find_by(id: result.session_id)
        focus = session&.document_focus_entries
        payload = {
          "environment" => connections,
          "message" => message.to_s,
          "turn" => {
            "session_id" => result.session_id,
            "episode_id" => result.episode_id,
            "technician_correlation_id" => (result.session_id && "phase1:#{result.session_id}"),
            "query_correlation_id" => (result.session_id && "phase1:#{result.session_id}:query"),
            "document_id" => result.document_id,
            "document_focus" => focus,
            "uris" => result.uris
          },
          "capture" => result.capture,
          "result" => {
            "status" => result.status,
            "reason" => result.reason,
            "answer" => result.answer,
            "documentary_acceptance" => "pending"
          },
          "ledger" => {
            "attempts" => result.ledger,
            "cost" => attempt_cost(session)
          }
        }
        safe = ValidationCapture.sanitize(payload)
        File.write(directory.join("environment.json"), JSON.pretty_generate(safe["environment"]))
        File.write(directory.join("message.txt"), safe["message"].to_s)
        File.write(directory.join("turn.json"), JSON.pretty_generate(safe["turn"]))
        File.write(directory.join("capture.json"), JSON.pretty_generate(safe["capture"]))
        File.write(directory.join("result.json"), JSON.pretty_generate(safe["result"]))
        File.write(directory.join("ledger.json"), JSON.pretty_generate(safe["ledger"]))
      end

      def attempt_cost(session)
        return { "rows" => [], "cost_usd" => "unavailable" } if session.nil?

        rows = BedrockQuery.where(conversation_session_id: session.id).map { |row|
          {
            "id" => row.id,
            "source" => row.source,
            "attempt" => row.attempt,
            "input_tokens" => row.input_tokens,
            "output_tokens" => row.output_tokens,
            "correlation_id" => row.correlation_id,
            "cost_usd" => row.cost
          }
        }
        { "rows" => rows, "cost_usd" => rows.empty? ? "unavailable" : rows.sum { |row| row["cost_usd"].to_f } }
      rescue StandardError
        { "rows" => [], "cost_usd" => "unavailable" }
      end

      def evidence_directory(root, run_id)
        Pathname(root.presence || Rails.root.join("tmp/phase1_pinned_turn/runs")).join(run_id)
      end

      def local_host?(value)
        LOCAL_HOSTS.include?(value.to_s)
      end

      def clean_reason(text)
        ValidationCapture.scrub_text(text.to_s).squish.truncate(500)
      end

      def effective_region
        ENV["AWS_REGION"].presence ||
          Rails.application.credentials.dig(:aws, :region) ||
          "us-east-1"
      end

      def account_kb_id(account)
        return if account.nil? || !account.respond_to?(:bedrock_config)

        account.bedrock_config&.knowledge_base_id
      end

      def effective_knowledge_base_id(account_kb)
        account_kb.presence ||
          ENV["BEDROCK_KNOWLEDGE_BASE_ID"].presence ||
          Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
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
