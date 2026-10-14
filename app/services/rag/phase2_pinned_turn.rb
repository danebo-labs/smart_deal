# frozen_string_literal: true

module Rag
  # Four model attempts for the whole phase 2 run. Inactive until that
  # harness calls arm! or restore!. A disarmed checkpoint does nothing.
  # This is not Phase1ModelBudget and it does not read Stage2RunBudget.
  class Phase2ModelBudget
    CAP = 4

    # Not a StandardError. generate_text and the interpreter rescue that
    # class and would otherwise continue.
    class Stop < Exception; end

    class << self
      def armed?
        !current.nil?
      end

      def arm!
        Thread.current[:phase2_model_budget] = { attempts: 0, stopped: false, ledger: [] }
      end

      def restore!(exported)
        data = exported.to_h
        Thread.current[:phase2_model_budget] = {
          attempts: data["attempts"].to_i,
          stopped: data["stopped"] == true,
          ledger: Array(data["ledger"]).map { |row| row.to_h.stringify_keys },
          open: nil
        }
      end

      def disarm!
        Thread.current[:phase2_model_budget] = nil
      end

      def export
        state = current
        return nil unless state

        {
          "attempts" => state[:attempts].to_i,
          "stopped" => state[:stopped] == true,
          "ledger" => Array(state[:ledger]).map(&:dup)
        }
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
        Thread.current[:phase2_model_budget]
      end

      def block!(state, name)
        state[:stopped] = true
        state[:ledger] << { "name" => name.to_s, "outcome" => "blocked" }
        raise Stop, "#{name} blocked before the client"
      end
    end
  end

  # Physical Retrieve cap for one phase 2 run. AuroraColdStartRetry still
  # decides whether a second request is an Aurora resume. This limit only
  # stops the call before the client. A disarmed limit does not run.
  class Phase2RetrieveLimit
    LOGICAL_CAP = 1
    PHYSICAL_PER_LOGICAL = 2
    RUN_PHYSICAL_CAP = 4

    class Stop < Exception; end

    class << self
      def armed?
        !current.nil?
      end

      def arm!
        Thread.current[:phase2_retrieve_limit] = {
          run_physical: 0,
          turn_logical: 0,
          logical_physical: 0
        }
      end

      def restore!(exported)
        data = exported.to_h
        Thread.current[:phase2_retrieve_limit] = {
          run_physical: data["run_physical"].to_i,
          turn_logical: data["turn_logical"].to_i,
          logical_physical: data["logical_physical"].to_i
        }
      end

      def begin_turn!
        state = current
        return unless state

        state[:turn_logical] = 0
        state[:logical_physical] = 0
        nil
      end

      def disarm!
        Thread.current[:phase2_retrieve_limit] = nil
      end

      def export
        state = current
        return nil unless state

        {
          "run_physical" => state[:run_physical].to_i,
          "turn_logical" => state[:turn_logical].to_i,
          "logical_physical" => state[:logical_physical].to_i
        }
      end

      def run_physical
        current&.dig(:run_physical).to_i
      end

      def begin_logical!
        state = current
        return unless state
        return block! if state[:turn_logical] >= LOGICAL_CAP

        state[:turn_logical] += 1
        state[:logical_physical] = 0
        nil
      end

      def before_physical!
        state = current
        return unless state
        if state[:logical_physical] >= PHYSICAL_PER_LOGICAL || state[:run_physical] >= RUN_PHYSICAL_CAP
          block!
        end

        state[:logical_physical] += 1
        state[:run_physical] += 1
        nil
      end

      private

      def current
        Thread.current[:phase2_retrieve_limit]
      end

      def block!
        raise Stop, "retrieve blocked before the client"
      end
    end
  end

  # One new session, two turns, one pin. The second turn is a local decision:
  # the caller says whether the candidate answers the saved reply. This class
  # does not read that reply to decide.
  class Phase2PinnedTurn
    AUTHORIZATION_ENV = "PHASE2_PINNED_TURN_AUTHORIZED"
    DOCUMENT_ID = 213
    FIRST_MESSAGE = "Estoy revisando una puerta del nivel 2 de un Elemont MH. En el plano seleccionado veo referencias a seguridad de puerta y a chapa, pero no tengo claro cuál corresponde a lo que estoy siguiendo. ¿Qué dato necesitas para orientarme?"
    CANDIDATE_REPLY = "La etiqueta Chapa nivel 2"
    AWAITING = "awaiting_decision"

    Result = Struct.new(
      :status, :reason, :session_id, :document_id, :uris, :answer, :evidence_path,
      :pause_path, :attempts, :model_budget, :retrieve_budget, :capture,
      :state_before, :state_after, :technician_correlation_id, :query_correlation_id,
      keyword_init: true
    )

    class BudgetedConverse
      def initialize(inner)
        @inner = inner
      end

      def converse(params)
        if Phase2ModelBudget.armed?
          begin
            Phase2ModelBudget.checkpoint!("interpreter")
          rescue Phase2ModelBudget::Stop
            ValidationCapture.record_model_boundary("interpreter", "blocked")
            raise
          end
          TurnInterpreter.record_attempt_started
        end
        result = @inner.converse(params)
        Phase2ModelBudget.record_success!("interpreter") if Phase2ModelBudget.armed?
        result
      rescue Phase2ModelBudget::Stop
        raise
      rescue StandardError => error
        raise unless Phase2ModelBudget.armed?

        Phase2ModelBudget.record_error!("interpreter", error)
        raise Phase2ModelBudget::Stop, "interpreter stopped after #{error.class}"
      end
    end

    class << self
      def authorized?
        ENV[AUTHORIZATION_ENV] == "1"
      end

      def run_start(evidence_root: nil)
        unless authorized?
          return start(account: nil, user: nil, document: nil, connections: {}, evidence_root: evidence_root)
        end

        Phase1PinnedTurn.connect_isolated!
        account = Account.find_by(id: 1)
        user = User.find_by(email: Phase1PinnedTurn::HISTORICAL_USER_EMAIL)
        document = account && KbDocument.find_by(account_id: account.id, document_uid: Phase1PinnedTurn::DOCUMENT_UID)
        environment = Phase1PinnedTurn.effective_environment
        environment["kb_effective"] = Phase1PinnedTurn.send(:effective_knowledge_base_id, account_kb_id(account))
        start(
          account: account, user: user, document: document,
          connections: environment, evidence_root: evidence_root, enforce_capture_uri: true
        )
      end

      def run_continue(pause_path:, accept_candidate:, evidence_root: nil)
        unless authorized?
          return Result.new(status: "refused", reason: "authorization_absent")
        end

        Phase1PinnedTurn.connect_isolated!
        account = Account.find_by(id: 1)
        environment = Phase1PinnedTurn.effective_environment
        environment["kb_effective"] = Phase1PinnedTurn.send(:effective_knowledge_base_id, account_kb_id(account))
        continue(
          pause_path: pause_path, accept_candidate: accept_candidate,
          connections: environment, evidence_root: evidence_root
        )
      end

      def start(account:, user:, document:, connections:, executor: nil, interpreter_client: nil, run_id: nil, enforce_capture_uri: true, evidence_root: nil)
        run_id = run_id.presence || Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        directory = evidence_directory(evidence_root, run_id)
        result = perform_turn(
          mode: :start, account: account, user: user, document: document,
          connections: connections, executor: executor, interpreter_client: interpreter_client,
          run_id: run_id, enforce_capture_uri: enforce_capture_uri, session_id: nil,
          message: FIRST_MESSAGE
        )
        FileUtils.mkdir_p(directory)
        write_pause(directory, result, turn: 1) if result.status == "completed" && result.session_id
        export_turn(result, directory, turn: 1, message: FIRST_MESSAGE) if result.session_id
        result.evidence_path ||= directory.to_s
        result
      end

      def continue(pause_path:, accept_candidate:, executor: nil, interpreter_client: nil, connections: nil, evidence_root: nil)
        unless accept_candidate == true || accept_candidate == false
          return Result.new(status: "refused", reason: "decision_absent")
        end

        path = Pathname(pause_path.to_s)
        return Result.new(status: "refused", reason: "pause_missing") unless path.file?

        pause = JSON.parse(path.read)
        if pause["status"] != AWAITING
          return Result.new(
            status: "refused",
            reason: "budget_closed",
            session_id: pause["session_id"],
            attempts: pause.dig("model_budget", "attempts").to_i,
            pause_path: path.to_s
          )
        end

        if accept_candidate == false
          return withhold(path, pause)
        end

        session = ConversationSession.find_by(id: pause["session_id"])
        return Result.new(status: "refused", reason: "session_missing", pause_path: path.to_s) if session.nil?
        unless session.focus_document_ids.map(&:to_i).include?(pause["document_id"].to_i)
          return Result.new(status: "refused", reason: "pin_missing", session_id: session.id, pause_path: path.to_s)
        end

        document = KbDocument.find_by(id: pause["document_id"])
        result = perform_turn(
          mode: :continue, account: session.account, user: session.user, document: document,
          connections: connections || Phase1PinnedTurn.stub_environment, executor: executor,
          interpreter_client: interpreter_client, run_id: pause["run_id"],
          enforce_capture_uri: false, session_id: session.id, message: CANDIDATE_REPLY,
          model_budget: pause["model_budget"], retrieve_budget: pause["retrieve_budget"]
        )
        directory = Pathname(pause["evidence_path"].presence || evidence_root || path.dirname)
        FileUtils.mkdir_p(directory)
        write_pause(directory, result, turn: 2, previous: pause) if result.session_id
        export_turn(result, directory, turn: 2, message: CANDIDATE_REPLY) if result.session_id
        result.pause_path = directory.join("pause.json").to_s
        result.evidence_path = directory.to_s
        result
      end

      private

      def perform_turn(mode:, account:, user:, document:, connections:, executor:, interpreter_client:, run_id:, enforce_capture_uri:, session_id:, message:, model_budget: nil, retrieve_budget: nil)
        outcome = nil
        events = nil
        held_session = nil
        observed_before = nil
        held_correlation = nil
        held_query = nil
        refusal = authorization_refusal || Phase1PinnedTurn.send(:environment_refusal, connections) ||
                  Phase1PinnedTurn.send(:actor_refusal, account, user)
        if refusal
          outcome = refusal
          return outcome
        end

        refusal = Phase1PinnedTurn.send(
          :document_refusal, document, viewer_account: account, enforce_capture_uri: enforce_capture_uri
        )
        if refusal
          outcome = refusal
          return outcome
        end
        if enforce_capture_uri && document.id != DOCUMENT_ID
          outcome = Result.new(status: "refused", reason: "document_id")
          return outcome
        end

        if mode == :start
          Phase2ModelBudget.arm!
          Phase2RetrieveLimit.arm!
        else
          Phase2ModelBudget.restore!(model_budget || {})
          Phase2RetrieveLimit.restore!(retrieve_budget || {})
        end
        Phase2RetrieveLimit.begin_turn!
        Phase2RetrievedBodyGate.arm!
        Phase1QueueGuard.activate!
        ValidationCapture.capture do |bucket|
          events = bucket
          ValidationCapture.bind(run_id: run_id)
          session = if mode == :start
            open_session(account, user, run_id)
          else
            ConversationSession.find(session_id)
          end
          held_session = session
          if mode == :start
            pinned = session.pin_kb_document!(document)
            unless pinned
              outcome = failed(session, document, events, "pin_refused")
              next
            end
          end

          uris = SessionContextBuilder.entity_s3_uris(session)
          unless uris == [ document.canonical_uri ]
            outcome = failed(session, document, events, "pin_uri")
            next
          end

          turn_index = mode == :start ? 1 : 2
          correlation_id = "phase2:#{session.id}:t#{turn_index}"
          query_correlation = "#{correlation_id}:query"
          held_correlation = correlation_id
          held_query = query_correlation
          observed_before = observe_state(session)
          ValidationCapture.bind(
            session_id: session.id, account_id: account.id, user_id: user.id, correlation_root: correlation_id
          )
          ValidationCapture.correlation = correlation_id
          ValidationCapture.record(
            "evaluator_simulation",
            "mark" => "evaluator_simulation",
            "text" => message,
            "turn_index" => turn_index
          )
          episode_turn = session.record_user_turn!(
            message,
            user_id: user.id,
            correlation_id: correlation_id,
            locale: :es,
            interpreter_client: BudgetedConverse.new(interpreter_client || BedrockClient.new)
          )
          host = executor || Phase1PinnedTurn::QueryHost.new(account)
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
        remember_observation(outcome, held_session, observed_before, held_correlation, held_query)
        outcome
      rescue Phase2ModelBudget::Stop, Phase2RetrieveLimit::Stop, Phase2RetrievedBodyGate::Stop => error
        outcome = stopped(held_session, document, events, error.message)
        remember_observation(outcome, held_session, observed_before, held_correlation, held_query)
        outcome
      rescue Phase1QueueGuard::UnexpectedJob => error
        outcome = stopped(held_session, document, events, error.message)
        remember_observation(outcome, held_session, observed_before, held_correlation, held_query)
        outcome
      rescue StandardError => error
        outcome = failed(held_session, document, events, "#{error.class}: #{error.message}")
        remember_observation(outcome, held_session, observed_before, held_correlation, held_query)
        outcome
      ensure
        stamp(outcome)
        Phase2ModelBudget.disarm!
        Phase2RetrieveLimit.disarm!
        Phase2RetrievedBodyGate.disarm!
        Phase1QueueGuard.disarm!
      end

      def application_result(session, document, events, uris, result, query_correlation, user)
        published = result.respond_to?(:answer) ? result.answer : nil
        answer = published.nil? ? nil : published.to_s
        ValidationCapture.record("published_answer", "answer" => answer) unless answer.nil?
        if result.respond_to?(:success?) && result.success?
          session.record_assistant_turn!(
            answer.to_s,
            user_id: user.id,
            correlation_id: query_correlation,
            pending_question: (result.pending_question if result.respond_to?(:pending_question)),
            expected_episode_id: session.live_episode_id,
            focus_ids: session.focus_document_ids
          )
          return Result.new(
            status: "completed",
            session_id: session.id,
            document_id: document.id,
            uris: uris,
            answer: answer,
            capture: events
          )
        end

        failed(session, document, events, application_failure_reason(result), answer: answer, uris: uris)
      end

      def withhold(path, pause)
        pause["status"] = "withheld"
        pause["decision"] = "withheld"
        pause["candidate_sent"] = false
        File.write(path, JSON.pretty_generate(pause))
        Result.new(
          status: "withheld",
          reason: "candidate_not_sent",
          session_id: pause["session_id"],
          document_id: pause["document_id"],
          answer: pause["published_answer"],
          attempts: pause.dig("model_budget", "attempts").to_i,
          model_budget: pause["model_budget"],
          retrieve_budget: pause["retrieve_budget"],
          pause_path: path.to_s,
          evidence_path: pause["evidence_path"]
        )
      end

      def stamp(outcome)
        return if outcome.nil?

        outcome.model_budget ||= Phase2ModelBudget.export
        outcome.retrieve_budget ||= Phase2RetrieveLimit.export
        outcome.attempts = outcome.model_budget&.dig("attempts").to_i if outcome.model_budget
      end

      def write_pause(directory, result, turn:, previous: nil)
        pause = previous ? previous.dup : {}
        if turn == 1 && result.status == "completed"
          pause["status"] = AWAITING
          pause["decision"] = nil
          pause["candidate_sent"] = false
          result.status = AWAITING
        elsif turn == 2 && result.status == "completed"
          pause["status"] = "second_turn_recorded"
          pause["decision"] = "sent"
          pause["candidate_sent"] = true
          result.status = "second_turn_recorded"
        else
          pause["status"] = result.status
          pause["decision"] = result.status
          pause["candidate_sent"] = false
        end
        pause["session_id"] = result.session_id
        pause["document_id"] = result.document_id
        pause["run_id"] = directory.basename.to_s
        pause["evidence_path"] = directory.to_s
        pause["evaluator_simulation"] = true
        pause["first_message"] = FIRST_MESSAGE
        pause["candidate_reply"] = CANDIDATE_REPLY
        pause["published_answer"] = previous ? previous["published_answer"] : result.answer
        pause["second_published_answer"] = result.answer if turn == 2
        pause["model_budget"] = result.model_budget
        pause["retrieve_budget"] = result.retrieve_budget
        messages = [
          { "role" => "user", "text" => FIRST_MESSAGE, "mark" => "evaluator_simulation" }
        ]
        if pause["candidate_sent"]
          messages << { "role" => "user", "text" => CANDIDATE_REPLY, "mark" => "evaluator_simulation" }
        end
        pause["messages"] = messages
        path = directory.join("pause.json")
        File.write(path, JSON.pretty_generate(pause))
        result.pause_path = path.to_s
      end

      def export_turn(result, run_directory, turn:, message:)
        run_directory = Pathname(run_directory)
        turn_directory = run_directory.join("turn_#{turn}")
        FileUtils.mkdir_p(turn_directory)
        File.write(turn_directory.join("message.txt"), message.to_s)
        File.binwrite(turn_directory.join("answer.txt"), result.answer) unless result.answer.nil?
        write_json(turn_directory.join("state_before.json"), result.state_before) if result.state_before
        write_json(turn_directory.join("state_after.json"), result.state_after) if result.state_after
        payload = {
          "status" => result.status,
          "reason" => result.reason,
          "session_id" => result.session_id,
          "documentary_acceptance" => "pending",
          "evaluator_simulation" => true,
          "message" => { "text" => message.to_s, "mark" => "evaluator_simulation" }
        }
        payload["technician_correlation_id"] = result.technician_correlation_id if result.technician_correlation_id
        payload["query_correlation_id"] = result.query_correlation_id if result.query_correlation_id
        File.write(turn_directory.join("result.json"), JSON.pretty_generate(ValidationCapture.sanitize(payload)))
        if result.capture
          capture = ValidationCapture.export_capture(
            result.capture, turn_directory, run_id: run_directory.basename.to_s
          )
          File.write(turn_directory.join("capture.json"), JSON.pretty_generate(capture))
        end
        result.evidence_path = run_directory.to_s
        result
      rescue StandardError => error
        result.status = "failed"
        result.reason = [ result.reason, "evidence_export:#{error.class}" ].compact.join(" ")
        result.evidence_path = Pathname(run_directory).to_s
        result
      end

      def remember_observation(outcome, session, before, correlation, query_correlation)
        return if outcome.nil?

        outcome.state_before = before if before
        outcome.technician_correlation_id = correlation if correlation
        outcome.query_correlation_id = query_correlation if query_correlation
        return unless session

        outcome.state_after = observe_state(session.reload)
        outcome.session_id ||= session.id
      end

      def observe_state(session)
        stored = session.active_episode
        stored = stored.as_json if stored.respond_to?(:as_json)
        pending = stored.is_a?(Hash) ? stored["pending_question"] : nil
        {
          "session_id" => session.id,
          "active_episode" => stored,
          "live_episode_id" => session.live_episode_id,
          "document_focus" => session.document_focus_entries.map(&:as_json),
          "pending_question" => pending,
          "counters" => consumed_counters
        }
      end

      def consumed_counters
        {
          "model_attempts" => Phase2ModelBudget.attempts,
          "retrieve_physical" => Phase2RetrieveLimit.run_physical
        }
      end

      def write_json(path, payload)
        File.write(path, JSON.pretty_generate(payload))
      end

      def authorization_refusal
        return if authorized?

        Result.new(status: "refused", reason: "authorization_absent")
      end

      def open_session(account, user, run_id)
        ConversationSession.create!(
          account: account,
          user: user,
          identifier: "phase2:pinned:#{run_id}",
          channel: "web",
          expires_at: 30.days.from_now,
          conversation_history: [],
          active_episode: {}
        )
      end

      def failed(session, document, events, reason, answer: nil, uris: [])
        Result.new(
          status: "failed",
          reason: Phase1PinnedTurn.send(:clean_reason, reason),
          session_id: session&.id,
          document_id: document&.id,
          uris: uris,
          answer: answer,
          capture: events
        )
      end

      def stopped(session, document, events, reason)
        Result.new(
          status: "stopped",
          reason: Phase1PinnedTurn.send(:clean_reason, reason),
          session_id: session&.id,
          document_id: document&.id,
          capture: events
        )
      end

      def application_failure_reason(result)
        parts = []
        parts << result.error_class if result.respond_to?(:error_class)
        parts << result.error_message if result.respond_to?(:error_message)
        text = parts.compact.map(&:to_s).reject(&:empty?).join(" ")
        text.presence || "application_failed"
      end

      def evidence_directory(root, run_id)
        Pathname(root.presence || Rails.root.join("tmp/phase2_pinned_turn/runs")).join(run_id)
      end

      def account_kb_id(account)
        return if account.nil? || !account.respond_to?(:bedrock_config)

        account.bedrock_config&.knowledge_base_id
      end
    end
  end
end
