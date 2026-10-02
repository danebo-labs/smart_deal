# frozen_string_literal: true

module Rag
  # One truncation for the technician turn. Haiku, span checks, and the
  # persisted history message all use this cut, including the "..." omission.
  module TurnText
    module_function

    def truncate(content)
      content.to_s.truncate(ConversationSession::MAX_MSG_LENGTH)
    end
  end
end
