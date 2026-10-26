# frozen_string_literal: true

module Rag
  # Opens ValidationCapture for the request that renders the browser response.
  # The bucket is thread-local. A Solid Queue job does not inherit it, and a
  # later request on the same thread starts empty. Export happens before the
  # wrapper returns, including when the action raises.
  module WebRequestCapture
    RUN_ENV = "RAG_VALIDATION_CAPTURE_RUN"
    ACCOUNTS_ENV = "RAG_VALIDATION_CAPTURE_ACCOUNT_IDS"
    ROOT = "tmp/field_companion/validation_captures"

    module_function

    def enabled?
      run_id.present? && LocalPassLedger.local_process?
    end

    # A local pass captures every request of that process. Outside it, the
    # same capture opens only for an account id named in ACCOUNTS_ENV. An
    # empty list does not open production. This does not arm LocalPassLedger.
    def enabled_for(account_id)
      return false unless run_id
      return true if LocalPassLedger.local_process?

      selected_account?(account_id)
    end

    def selected_account?(account_id)
      ids = account_ids
      return false if ids.empty? || account_id.nil?

      ids.include?(account_id.to_s)
    end

    def account_ids
      ENV[ACCOUNTS_ENV].to_s.split(",").filter_map { |item| item.strip.presence }
    end

    def run_id
      value = ENV[RUN_ENV].to_s
      return nil unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\z/)

      value
    end

    def wrap(controller:)
      account_id = controller.try(:current_account)&.id
      unless enabled_for(account_id)
        yield
        return
      end

      request_key = request_key_for(controller)
      failure = nil
      events = ValidationCapture.capture do |bucket|
        ValidationCapture.bind(
          run_id: run_id,
          user_id: controller.try(:current_user)&.id,
          account_id: controller.try(:current_account)&.id
        )
        ValidationCapture.record("web_request", request_meta(controller, request_key))
        ValidationCapture.record("process_contract", process_contract)
        begin
          yield
        rescue Exception => error # rubocop:disable Lint/RescueException
          failure = error
        end
        if LocalPassLedger.guard_requested?
          ValidationCapture.record("local_pass_ledger", LocalPassLedger.snapshot)
        end
        bucket
      end
      begin
        export!(events, request_key)
      rescue StandardError => error
        Rails.logger.error("web_request_capture export_failed #{error.class}")
        failure ||= error
      end
      raise failure if failure
      nil
    ensure
      LocalPassLedger.release_thread!
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
        "generation_model_id" => BedrockClient::QUERY_MODEL_ID,
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
        "validation_capture_accounts" => account_ids.join(","),
        "capture_scope" => LocalPassLedger.local_process? ? "local_process" : "account"
      }
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
        "capture_scope" => LocalPassLedger.local_process? ? "local_process" : "account",
        "question" => params[:question].presence&.to_s,
        "replay_correlation_id" => params[:replay_correlation_id].presence,
        "correlation_id" => params[:correlation_id].presence,
        "episode_id" => params[:episode_id].presence,
        "document_uid" => params[:document_uid].presence,
        "kb_document_id" => params[:kb_document_id].presence
      }.compact
    end
  end
end
