# frozen_string_literal: true

# Opens the request capture. The durable trace is written for every account.
# The validation file is written only when RAG_VALIDATION_CAPTURE_RUN is set.
module WebValidationCapture
  extend ActiveSupport::Concern

  class_methods do
    def capture_web_validation_actions(*actions)
      around_action :capture_web_validation, only: actions
    end
  end

  private

  def capture_web_validation
    Rag::WebRequestCapture.wrap(controller: self) { yield }
  rescue Rag::LocalPassLedger::Stop
    raise if performed?

    render json: {
      status: "error",
      code: "local_pass_budget",
      message: "La pasada local alcanzó el cupo y no se llamó al modelo."
    }, status: :service_unavailable
  end
end
