# frozen_string_literal: true

# Local pass only. Inactive unless RAG_VALIDATION_CAPTURE_RUN is set in a
# local process. The answer text is whatever the action rendered.
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
