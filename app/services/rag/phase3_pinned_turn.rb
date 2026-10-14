# frozen_string_literal: true

module Rag
  # Six model attempts for the three phase 3 turns together. Inactive until
  # that harness calls arm!. A disarmed checkpoint does nothing. This is not
  # Phase2ModelBudget and it does not read Stage2RunBudget.
  class Phase3ModelBudget
    CAP = 6

    # Not a StandardError. generate_text and the interpreter rescue that
    # class and would otherwise continue.
    class Stop < Exception; end

    class << self
      def armed?
        !current.nil?
      end

      def arm!
        Thread.current[:phase3_model_budget] = { attempts: 0, stopped: false, ledger: [] }
      end

      def disarm!
        Thread.current[:phase3_model_budget] = nil
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
        Thread.current[:phase3_model_budget]
      end

      def block!(state, name)
        state[:stopped] = true
        state[:ledger] << { "name" => name.to_s, "outcome" => "blocked" }
        raise Stop, "#{name} blocked before the client"
      end
    end
  end

  # Physical Retrieve cap for one phase 3 run. AuroraColdStartRetry still
  # decides whether a second request is an Aurora resume. This limit only
  # stops the call before the client. A disarmed limit does not run.
  class Phase3RetrieveLimit
    LOGICAL_CAP = 1
    PHYSICAL_PER_LOGICAL = 2
    RUN_PHYSICAL_CAP = 6

    class Stop < Exception; end

    class << self
      def armed?
        !current.nil?
      end

      def arm!
        Thread.current[:phase3_retrieve_limit] = {
          run_physical: 0,
          turn_logical: 0,
          logical_physical: 0
        }
      end

      def disarm!
        Thread.current[:phase3_retrieve_limit] = nil
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

      def begin_turn!
        state = current
        return unless state

        state[:turn_logical] = 0
        state[:logical_physical] = 0
        nil
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
        Thread.current[:phase3_retrieve_limit]
      end

      def block!
        raise Stop, "retrieve blocked before the client"
      end
    end
  end

  # Three turns on one cloned session. Session 13 is the provenance of the
  # episode and the pin. This class does not update that row, does not write
  # its evidence directory, and does not repeat its model or Retrieve calls.
  class Phase3PinnedTurn
    AUTHORIZATION_ENV = "PHASE3_PINNED_TURN_AUTHORIZED"
    SYSTEM_ROLE_ENV = "RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"
    SOURCE_RUN_ID = "20261014T175449Z"
    SOURCE_SESSION_ID = 13
    SOURCE_EPISODE_ID = "ep_063f3f66656047d2"
    SOURCE_QUERY_CORRELATION = "phase2:13:t2:query"
    DOCUMENT_ID = 213
    FOLLOW_UP = "¿Dónde queda entonces la etiqueta Chapa nivel 2?"
    CORRECTION = "Me equivoqué de etiqueta: estoy siguiendo Chapa nivel 3, no Chapa nivel 2."
    SUMMARY = "Resumí el caso vigente y lo que falta comprobar."
    MESSAGES = [ FOLLOW_UP, CORRECTION, SUMMARY ].freeze
    INHERITED_SHA256 = "a13141fe7586c9013d698aa29f2b6809f112702e98f4da99d9a47c3ba01d7779"
    INHERITED_BYTES = 9193
    INHERITED_PAGE = 5
    GOAL_TEXT = "En el plano seleccionado veo referencias a seguridad de puerta y a chapa"

    Result = Struct.new(
      :status, :reason, :session_id, :document_id, :uris, :answer, :evidence_path,
      :attempts, :model_budget, :retrieve_budget, :capture,
      :state_before, :state_after, :technician_correlation_id, :query_correlation_id,
      keyword_init: true
    )

    class BudgetedConverse
      def initialize(inner)
        @inner = inner
      end

      def converse(params)
        if Phase3ModelBudget.armed?
          begin
            Phase3ModelBudget.checkpoint!("interpreter")
          rescue Phase3ModelBudget::Stop
            ValidationCapture.record_model_boundary("interpreter", "blocked")
            raise
          end
          TurnInterpreter.record_attempt_started
        end
        result = @inner.converse(params)
        Phase3ModelBudget.record_success!("interpreter") if Phase3ModelBudget.armed?
        result
      rescue Phase3ModelBudget::Stop
        raise
      rescue StandardError => error
        raise unless Phase3ModelBudget.armed?

        Phase3ModelBudget.record_error!("interpreter", error)
        raise Phase3ModelBudget::Stop, "interpreter stopped after #{error.class}"
      end
    end

    class << self
      def authorized?
        ENV[AUTHORIZATION_ENV] == "1"
      end

      def run_authorized(source_root: nil, evidence_root: nil)
        return Result.new(status: "refused", reason: "authorization_absent") unless authorized?

        source = Pathname(source_root.presence || Rails.root.join("tmp/phase2_pinned_turn/runs/#{SOURCE_RUN_ID}"))
        snapshot = load_source(source)
        return Result.new(status: "refused", reason: "source_missing", evidence_path: source.to_s) if snapshot.nil?

        Phase1PinnedTurn.connect_isolated!
        account = Account.find_by(id: 1)
        user = User.find_by(email: Phase1PinnedTurn::HISTORICAL_USER_EMAIL)
        document = account && KbDocument.find_by(account_id: account.id, document_uid: Phase1PinnedTurn::DOCUMENT_UID)
        environment = Phase1PinnedTurn.effective_environment
        environment["kb_effective"] = Phase1PinnedTurn.send(:effective_knowledge_base_id, account_kb_id(account))
        run(
          account: account, user: user, document: document, snapshot: snapshot,
          connections: environment, evidence_root: evidence_root, source_root: source,
          enforce_capture_uri: true
        )
      end

      def load_source(root)
        directory = Pathname(root.to_s)
        pause_path = directory.join("pause.json")
        state_path = directory.join("turn_2", "state_after.json")
        return nil unless pause_path.file? && state_path.file?

        pause = JSON.parse(pause_path.read)
        state = JSON.parse(state_path.read)
        episode = state["active_episode"]
        focus = Array(state["document_focus"]).first
        return nil unless episode.is_a?(Hash) && focus.is_a?(Hash)

        {
          "source_run_id" => pause["run_id"].to_s,
          "source_session_id" => pause["session_id"].to_i,
          "source_episode_id" => episode["episode_id"].to_s,
          "source_document_id" => state.dig("document_focus", 0, "kb_document_id").to_i,
          "source_uri" => focus["source_uri"].to_s,
          "pause_status" => pause["status"].to_s,
          "active_episode" => episode,
          "messages" => source_messages(pause)
        }
      rescue JSON::ParserError
        nil
      end

      def run(account:, user:, document:, snapshot:, connections:, executor: nil, interpreter_client: nil, run_id: nil, enforce_capture_uri: true, evidence_root: nil, source_root: nil)
        run_id = run_id.presence || Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        directory = evidence_directory(evidence_root, run_id)
        refusal = authorization_refusal || mode_refusal ||
                  Phase1PinnedTurn.send(:environment_refusal, connections) ||
                  Phase1PinnedTurn.send(:actor_refusal, account, user) ||
                  generation_config_refusal ||
                  Phase1PinnedTurn.send(:document_refusal, document, viewer_account: account, enforce_capture_uri: enforce_capture_uri) ||
                  document_id_refusal(document, enforce_capture_uri) ||
                  snapshot_refusal(snapshot) ||
                  path_refusal(directory, source_root)
        return refusal if refusal

        armed = false
        provenance = nil
        session = nil
        last = nil
        Phase3ModelBudget.arm!
        Phase3RetrieveLimit.arm!
        Phase2RetrievedBodyGate.arm!
        Phase1QueueGuard.activate!
        armed = true
        now = Time.current
        session = open_clone(account, user, document, snapshot, run_id, now)
        provenance = initial_provenance(session, snapshot, directory)
        write_provenance(directory, provenance)
        MESSAGES.each_with_index do |message, index|
          Phase3RetrieveLimit.begin_turn!
          last = perform_turn(
            account: account, user: user, document: document, session: session,
            message: message, turn_index: index + 1, run_id: run_id,
            executor: executor, interpreter_client: interpreter_client,
            snapshot: snapshot
          )
          export_turn(last, directory, turn: index + 1, message: message)
          remember_turn_hash!(provenance, index + 1, directory.join("turn_#{index + 1}"))
          provenance["status"] = last.status
          provenance["model_budget"] = Phase3ModelBudget.export
          provenance["retrieve_budget"] = Phase3RetrieveLimit.export
          write_provenance(directory, provenance)
          break unless last.status == "completed"
        end
        if last&.status == "completed"
          last.status = "turns_recorded"
          provenance["status"] = "turns_recorded"
          write_provenance(directory, provenance)
        end
        last.evidence_path = directory.to_s if last
        last
      rescue Phase3ModelBudget::Stop, Phase3RetrieveLimit::Stop, Phase2RetrievedBodyGate::Stop, Phase1QueueGuard::UnexpectedJob => error
        stopped = stopped_result(session, document, nil, error.message)
        stopped.evidence_path = directory.to_s
        stopped
      ensure
        if armed
          Phase3ModelBudget.disarm!
          Phase3RetrieveLimit.disarm!
          Phase2RetrievedBodyGate.disarm!
          Phase1QueueGuard.disarm!
        end
      end

      private

      def source_messages(pause)
        [
          message_row("user", pause["first_message"], "phase2:13:t1"),
          message_row("assistant", pause["published_answer"], "phase2:13:t1:query"),
          message_row("user", pause["candidate_reply"], "phase2:13:t2"),
          message_row("assistant", pause["second_published_answer"], SOURCE_QUERY_CORRELATION)
        ]
      end

      def message_row(role, text, correlation_id)
        { "role" => role, "text" => text.to_s, "correlation_id" => correlation_id }
      end

      def perform_turn(account:, user:, document:, session:, message:, turn_index:, run_id:, executor:, interpreter_client:, snapshot:)
        outcome = nil
        events = nil
        observed_before = nil
        correlation_id = "phase3:#{session.id}:t#{turn_index}"
        query_correlation = "#{correlation_id}:query"
        ValidationCapture.capture do |bucket|
          events = bucket
          ValidationCapture.bind(run_id: run_id, session_id: session.id, account_id: account.id, user_id: user.id, correlation_root: correlation_id)
          ValidationCapture.correlation = correlation_id
          observed_before = observe_state(session)
          uris = SessionContextBuilder.entity_s3_uris(session)
          unless uris == [ document.canonical_uri ]
            outcome = failed_result(session, document, events, "pin_uri", uris: uris)
            next
          end
          record_simulation(message, turn_index)
          record_inherited_evidence(snapshot) if turn_index == 1
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
            entity_s3_uris: SessionContextBuilder.entity_s3_uris(session)
          )
          outcome = application_result(session, document, events, result, query_correlation, user, uris)
        end
        remember_observation(outcome, session, observed_before, correlation_id, query_correlation)
        outcome
      rescue Phase3ModelBudget::Stop, Phase3RetrieveLimit::Stop, Phase2RetrievedBodyGate::Stop => error
        outcome = stopped_result(session, document, events, error.message)
        remember_observation(outcome, session, observed_before, correlation_id, query_correlation)
        outcome
      rescue Phase1QueueGuard::UnexpectedJob => error
        outcome = stopped_result(session, document, events, error.message)
        remember_observation(outcome, session, observed_before, correlation_id, query_correlation)
        outcome
      rescue StandardError => error
        outcome = failed_result(session, document, events, "#{error.class}: #{error.message}")
        remember_observation(outcome, session, observed_before, correlation_id, query_correlation)
        outcome
      end

      def application_result(session, document, events, result, query_correlation, user, uris)
        published = result.respond_to?(:answer) ? result.answer : nil
        answer = published.nil? ? nil : published.to_s
        ValidationCapture.record("published_answer", "answer" => answer) unless answer.nil?
        current_uris = SessionContextBuilder.entity_s3_uris(session)
        unless current_uris == uris && current_uris == [ document.canonical_uri ]
          return failed_result(session, document, events, "pin_uri", answer: answer, uris: current_uris)
        end
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
            uris: current_uris,
            answer: answer,
            capture: events
          )
        end

        failed_result(session, document, events, application_failure_reason(result), answer: answer, uris: uris)
      end

      def open_clone(account, user, document, snapshot, run_id, now)
        session = ConversationSession.create!(
          account: account,
          user: user,
          identifier: "phase3:pinned:#{run_id}",
          channel: "web",
          expires_at: 30.days.from_now,
          conversation_history: cloned_history(snapshot, user, now),
          active_episode: restamped_episode(snapshot.fetch("active_episode"), now)
        )
        pinned = session.pin_kb_document!(document)
        raise Phase3ModelBudget::Stop, "pin_refused" unless pinned

        session
      end

      def restamped_episode(episode, now)
        data = episode.deep_dup
        data["updated_at"] = now.iso8601
        data
      end

      def cloned_history(snapshot, user, now)
        Array(snapshot["messages"]).map do |message|
          {
            "role" => message["role"].to_s,
            "content" => TurnText.truncate(message["text"]),
            "ts" => now.iso8601,
            "user_id" => user.id,
            "correlation_id" => message["correlation_id"].to_s
          }
        end
      end

      def initial_provenance(session, snapshot, directory)
        {
          "status" => "cloned",
          "source_run_id" => snapshot["source_run_id"],
          "source_session_id" => snapshot["source_session_id"],
          "source_episode_id" => snapshot["source_episode_id"],
          "source_document_id" => snapshot["source_document_id"],
          "source_uri" => snapshot["source_uri"],
          "clone_session_id" => session.id,
          "continuation" => "cloned_session",
          "continuation_limit" => "session_13_row_not_continued",
          "updated_at_restamped" => true,
          "history_timestamps" => "clone_time",
          "history_truncated" => true,
          "phase2_calls_repeated" => false,
          "real_interpreter_correct" => "pending",
          "phase3_acceptance" => "not_accepted",
          "documentary_acceptance" => "pending",
          "evaluator_simulation" => true,
          "inherited_evidence" => inherited_evidence(snapshot),
          "messages" => MESSAGES.map { |text| { "role" => "user", "text" => text, "mark" => "evaluator_simulation" } },
          "evidence_path" => directory.to_s,
          "turn_directory_sha256" => {}
        }
      end

      def inherited_evidence(snapshot)
        {
          "document_id" => DOCUMENT_ID,
          "uri" => snapshot["source_uri"],
          "page" => INHERITED_PAGE,
          "key" => Phase2RetrievedBodyGate::CHUNK_KEY,
          "sha256" => INHERITED_SHA256,
          "bytes" => INHERITED_BYTES,
          "source_run_id" => SOURCE_RUN_ID,
          "source_correlation_id" => SOURCE_QUERY_CORRELATION,
          "retrieved_in_this_run" => false
        }
      end

      def record_simulation(message, turn_index)
        ValidationCapture.record(
          "evaluator_simulation",
          "mark" => "evaluator_simulation",
          "text" => message,
          "turn_index" => turn_index
        )
      end

      def record_inherited_evidence(snapshot)
        ValidationCapture.record("inherited_evidence", inherited_evidence(snapshot).merge("result" => "inherited", "remote" => false))
      end

      def export_turn(result, run_directory, turn:, message:)
        return if result.nil?

        turn_directory = Pathname(run_directory).join("turn_#{turn}")
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
          "phase3_acceptance" => "not_accepted",
          "real_interpreter_correct" => "pending",
          "evaluator_simulation" => true,
          "message" => { "text" => message.to_s, "mark" => "evaluator_simulation" }
        }
        payload["technician_correlation_id"] = result.technician_correlation_id if result.technician_correlation_id
        payload["query_correlation_id"] = result.query_correlation_id if result.query_correlation_id
        File.write(turn_directory.join("result.json"), JSON.pretty_generate(ValidationCapture.sanitize(payload)))
        return unless result.capture

        capture = ValidationCapture.export_capture(result.capture, turn_directory, run_id: Pathname(run_directory).basename.to_s)
        File.write(turn_directory.join("capture.json"), JSON.pretty_generate(capture))
      end

      def remember_turn_hash!(provenance, turn, directory)
        provenance["turn_directory_sha256"] ||= {}
        key = "turn_#{turn}"
        provenance["turn_directory_sha256"][key] ||= directory_sha(directory)
      end

      def directory_sha(directory)
        directory = Pathname(directory)
        digest = Digest::SHA256.new
        directory.glob("**/*").select(&:file?).sort.each do |path|
          digest << path.relative_path_from(directory).to_s
          digest << Digest::SHA256.file(path).hexdigest
        end
        digest.hexdigest
      end

      def write_provenance(directory, provenance)
        FileUtils.mkdir_p(directory)
        File.write(Pathname(directory).join("provenance.json"), JSON.pretty_generate(provenance))
      end

      def remember_observation(outcome, session, before, correlation, query_correlation)
        return if outcome.nil?

        outcome.model_budget = Phase3ModelBudget.export
        outcome.retrieve_budget = Phase3RetrieveLimit.export
        outcome.attempts = outcome.model_budget&.dig("attempts").to_i if outcome.model_budget
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
          "counters" => {
            "model_attempts" => Phase3ModelBudget.attempts,
            "retrieve_physical" => Phase3RetrieveLimit.run_physical
          }
        }
      end

      def authorization_refusal
        return if authorized?

        Result.new(status: "refused", reason: "authorization_absent")
      end

      def mode_refusal
        return if HaikuQueryAnalysisFlag.owner? && FieldCompanionEpisodeFlag.enabled? && FieldCompanionTurnFlag.enabled?

        Result.new(status: "refused", reason: "owner_mode_absent")
      end

      def generation_config_refusal
        return if ENV[SYSTEM_ROLE_ENV] == "1"

        Result.new(status: "refused", reason: "environment:system_role")
      end

      def document_id_refusal(document, enforce_capture_uri)
        return unless enforce_capture_uri
        return if document&.id == DOCUMENT_ID

        Result.new(status: "refused", reason: "document_id")
      end

      def snapshot_refusal(snapshot)
        return Result.new(status: "refused", reason: "snapshot_missing") unless snapshot.is_a?(Hash)
        return Result.new(status: "refused", reason: "snapshot_run") unless snapshot["source_run_id"] == SOURCE_RUN_ID
        return Result.new(status: "refused", reason: "snapshot_session") unless snapshot["source_session_id"] == SOURCE_SESSION_ID
        return Result.new(status: "refused", reason: "snapshot_episode") unless snapshot["source_episode_id"] == SOURCE_EPISODE_ID
        return Result.new(status: "refused", reason: "snapshot_document") unless snapshot["source_document_id"] == DOCUMENT_ID
        return Result.new(status: "refused", reason: "snapshot_uri") unless snapshot["source_uri"] == Phase1PinnedTurn::CAPTURE_ORIGINAL_SOURCE_URI
        return Result.new(status: "refused", reason: "snapshot_status") unless snapshot["pause_status"] == "second_turn_recorded"

        episode = snapshot["active_episode"]
        return Result.new(status: "refused", reason: "snapshot_episode") unless episode.is_a?(Hash)
        return Result.new(status: "refused", reason: "snapshot_goal") unless episode.dig("goal", "text") == GOAL_TEXT

        values = Array(episode["identifiers"]).pluck("value")
        return Result.new(status: "refused", reason: "snapshot_identifier") unless values.include?("Elemont MH") && values.include?("Chapa nivel 2")
        return Result.new(status: "refused", reason: "snapshot_manufacturer") unless episode.dig("facts", "manufacturer", "value") == "Elemont"

        texts = Array(snapshot["messages"]).pluck("text")
        return Result.new(status: "refused", reason: "snapshot_messages") unless texts.all?(&:present?)

        nil
      end

      def path_refusal(directory, source_root)
        return if source_root.blank?

        evidence = Pathname(directory).expand_path
        source = Pathname(source_root).expand_path
        return unless evidence == source || evidence.to_s.start_with?("#{source}/")

        Result.new(status: "refused", reason: "evidence_overlaps_source")
      end

      def failed_result(session, document, events, reason, answer: nil, uris: [])
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

      def stopped_result(session, document, events, reason)
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

      def write_json(path, payload)
        File.write(path, JSON.pretty_generate(payload))
      end

      def evidence_directory(root, run_id)
        Pathname(root.presence || Rails.root.join("tmp/phase3_pinned_turn/runs")).join(run_id)
      end

      def account_kb_id(account)
        return if account.nil? || !account.respond_to?(:bedrock_config)

        account.bedrock_config&.knowledge_base_id
      end
    end
  end
end
