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

    def run_id
      value = ENV[RUN_ENV].to_s
      return nil unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\z/)

      value
    end

    def wrap(controller:)
      unless enabled?
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
      directory
    end

    def request_key_for(controller)
      raw = controller.request.request_id.to_s
      key = raw.gsub(/[^A-Za-z0-9_-]/, "")
      key = SecureRandom.hex(8) if key.blank?
      key = "#{key}-#{SecureRandom.hex(4)}" if Rails.root.join(ROOT, run_id, key).exist?
      key
    end

    def request_meta(controller, request_key)
      params = controller.params
      {
        "stage" => "request",
        "controller" => controller.controller_path,
        "action" => controller.action_name,
        "request_key" => request_key,
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
