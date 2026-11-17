# frozen_string_literal: true

module Rag
  # Opens ValidationCapture for the request that renders the browser response.
  # The bucket is thread-local. A Solid Queue job does not inherit it, and a
  # later request on the same thread starts empty. Export happens before the
  # wrapper returns, including when the action raises.
  module WebRequestCapture
    RUN_ENV = "RAG_VALIDATION_CAPTURE_RUN"
    ROOT = "tmp/field_companion/validation_captures"

    module_function

    def enabled?
      run_id.present? && LocalPassLedger.local_process?
    end

    # A local pass captures every request of that process. Outside it, a run
    # id opens the file capture for every account. The account list is not a
    # gate. This does not arm LocalPassLedger. The durable trace is separate
    # and does not need the run id.
    def enabled_for(account_id)
      return false unless run_id
      return true if LocalPassLedger.local_process?

      account_id.present?
    end

    def run_id
      value = ENV[RUN_ENV].to_s
      return nil unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\z/)

      value
    end

    def wrap(controller:)
      account = controller_record(controller, :current_account)
      user = controller_record(controller, :current_user)
      account_id = account&.id
      file_export = enabled_for(account_id)
      durable = account_id.present?
      unless file_export || durable
        yield
        return
      end

      request_key = file_export ? request_key_for(controller) : request_token(controller)
      if ValidationCapture.active?
        keep_open_capture(
          controller, request_key,
          account_id: account_id, user: user, durable: durable, file_export: file_export
        ) { yield }
        return
      end

      failure = nil
      events = nil
      Rag::DurableTrace.with_context(
        account_id: account_id,
        user_id: user&.id,
        request_id: request_key,
        attempt: 1
      ) do
        events = ValidationCapture.capture do |bucket|
          ValidationCapture.bind(
            run_id: run_id,
            user_id: user&.id,
            account_id: account_id
          )
          ValidationCapture.record("web_request", request_meta(controller, request_key))
          ValidationCapture.record("process_contract", process_contract)
          begin
            yield
          rescue Exception => error # rubocop:disable Lint/RescueException
            failure = error
            Rag::DurableTrace.record_failure!(
              account_id: account_id,
              user_id: user&.id,
              correlation_id: controller.params[:correlation_id].presence || request_key,
              stage: "request",
              error: error
            )
          end
          if LocalPassLedger.guard_requested?
            ValidationCapture.record("local_pass_ledger", LocalPassLedger.snapshot)
          end
          bucket
        end
      end
      if durable
        begin
          Rag::DurableTrace.persist_capture!(
            events,
            account_id: account_id,
            user_id: user&.id,
            request_id: request_key
          )
        rescue StandardError => error
          Rails.logger.error("web_request_capture durable_failed #{error.class}")
        end
      end
      if file_export
        begin
          export!(events, request_key)
        rescue StandardError => error
          Rails.logger.error("web_request_capture export_failed #{error.class}")
          failure ||= error
        end
      end
      raise failure if failure
      nil
    ensure
      LocalPassLedger.release_thread!
    end

    # A caller already opened the bucket. A second capture would hide
    # companion_publication and the rest of this request from that caller.
    # Events stay in the open bucket. The durable row and the file keep only
    # the events this request added.
    def keep_open_capture(controller, request_key, account_id:, user:, durable:, file_export:)
      bucket = Thread.current[:rag_validation_capture]
      start = bucket.size
      ValidationCapture.record("web_request", request_meta(controller, request_key))
      ValidationCapture.record("process_contract", process_contract)
      failure = nil
      begin
        yield
      rescue Exception => error # rubocop:disable Lint/RescueException
        failure = error
        if durable
          Rag::DurableTrace.record_failure!(
            account_id: account_id,
            user_id: user&.id,
            correlation_id: controller.params[:correlation_id].presence || request_key,
            stage: "request",
            error: error
          )
        end
      end
      if LocalPassLedger.guard_requested?
        ValidationCapture.record("local_pass_ledger", LocalPassLedger.snapshot)
      end
      added = bucket.drop(start)
      if durable
        begin
          Rag::DurableTrace.persist_capture!(
            added,
            account_id: account_id,
            user_id: user&.id,
            request_id: request_key
          )
        rescue StandardError => error
          Rails.logger.error("web_request_capture durable_failed #{error.class}")
        end
      end
      if file_export
        begin
          export!(added, request_key)
        rescue StandardError => error
          Rails.logger.error("web_request_capture export_failed #{error.class}")
          failure ||= error
        end
      end
      raise failure if failure
      nil
    end

    def request_token(controller)
      raw = controller.request.request_id.to_s
      key = raw.gsub(/[^A-Za-z0-9_-]/, "")
      key.presence || SecureRandom.hex(8)
    end

    def export!(events, request_key)
      directory = Pathname(Rails.root.join(ROOT, run_id, request_key))
      FileUtils.mkdir_p(directory)
      document = ValidationCapture.export_capture(Array(events), directory, run_id: run_id)
      File.write(directory.join("capture.json"), JSON.generate(document))
      File.write(directory.join("ledger.json"), JSON.generate(LocalPassLedger.snapshot))
      restrict!(directory)
      directory
    end

    # current_account is private on ApplicationController. try uses
    # respond_to? without private methods and returns nil, so a real request
    # never opened the account capture. send reaches the private reader.
    # current_user is public today; the same reader keeps its id if that changes.
    def controller_record(controller, name)
      return nil unless controller.respond_to?(name, true)

      controller.send(name)
    end

    def request_key_for(controller)
      raw = controller.request.request_id.to_s
      key = raw.gsub(/[^A-Za-z0-9_-]/, "")
      key = SecureRandom.hex(8) if key.blank?
      key = "#{key}-#{SecureRandom.hex(4)}" if Rails.root.join(ROOT, run_id, key).exist?
      key
    end

    def process_contract
      method = TurnPerception.instance_method(:bound_lengths)
      file, line = method.source_location
      iseq = RubyVM::InstructionSequence.of(method)
      {
        "pid" => Process.pid,
        "interpreter_model_id" => TurnInterpreter::MODEL_ID,
        "interpreter_effort" => TurnInterpreter::EFFORT,
        "interpreter_max_tokens" => TurnInterpreter.max_output_tokens,
        "generation_model_id" => BedrockClient::QUERY_MODEL_ID,
        "companion_generation" => ENV["RAG_COMPANION_GENERATION"].to_s,
        "companion_direct_model_id" => companion_direct_model_id,
        "companion_direct_max_tokens" => CompanionDirectAnswer.generation_max_tokens,
        "companion_direct_thinking" => CompanionDirectAnswer.thinking_mode,
        "companion_direct_effort" => CompanionDirectAnswer.effort,
        "bedrock_inference" => ENV["BEDROCK_INFERENCE"].to_s,
        "haiku_mode" => HaikuQueryAnalysisFlag.mode,
        "knowledge_base_id" => ENV["BEDROCK_KNOWLEDGE_BASE_ID"].to_s,
        "knowledge_base_bucket" => ENV["KNOWLEDGE_BASE_S3_BUCKET"].to_s,
        "episode_enabled" => ENV["FIELD_COMPANION_EPISODE_ENABLED"].to_s,
        "turn_enabled" => ENV["FIELD_COMPANION_TURN_ENABLED"].to_s,
        "episode_scope_enabled" => ENV["RAG_EPISODE_SCOPE_ENABLED"].to_s,
        "identity_scope_enabled" => ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"].to_s,
        "shared_session_enabled" => ENV["SHARED_SESSION_ENABLED"].to_s,
        "aws_max_attempts" => ENV[LocalPassLedger::ATTEMPTS_ENV].to_s,
        "ledger" => LocalPassLedger.status,
        "bound_lengths_file" => file.to_s,
        "bound_lengths_line" => line,
        "bound_lengths_iseq_sha256" => (Digest::SHA256.hexdigest(iseq.disasm) if iseq),
        "kamal_version" => ENV["KAMAL_VERSION"].to_s,
        "validation_capture_run" => run_id.to_s,
        "capture_scope" => LocalPassLedger.local_process? ? "local_process" : "all_accounts"
      }
    end

    def companion_direct_model_id
      CompanionDirectAnswer.configured_model_id
    rescue BedrockRagService::BedrockServiceError => error
      error.message
    end

    def restrict!(directory)
      directory.find do |path|
        if path.file?
          path.chmod(0o600)
        elsif path.directory?
          path.chmod(0o700)
        end
      end
      nil
    end

    def request_meta(controller, request_key)
      params = controller.params
      {
        "stage" => "request",
        "controller" => controller.controller_path,
        "action" => controller.action_name,
        "request_key" => request_key,
        "capture_scope" => LocalPassLedger.local_process? ? "local_process" : "all_accounts",
        "question" => params[:question].presence&.to_s,
        "replay_correlation_id" => params[:replay_correlation_id].presence,
        "correlation_id" => params[:correlation_id].presence,
        "episode_id" => params[:episode_id].presence,
        "document_uid" => params[:document_uid].presence,
        "kb_document_id" => params[:kb_document_id].presence,
        "focus_mode" => params[:focus_mode].presence
      }.compact
    end
  end
end
