# frozen_string_literal: true

module Rag
  # Kill switch for answering the technician's question (not just describing
  # the photo) after a field-photo upload. Default OFF — merges without
  # changing today's demo script. Same pattern as AutoScopeFlag, inverted.
  module PhotoQuestionFlag
    module_function

    def enabled?
      ENV["PHOTO_QUESTION_RAG_ENABLED"] == "true"
    end
  end
end
