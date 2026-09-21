# frozen_string_literal: true

module Rag
  # Kill switch for joining one recoverable thread or asking which thread a
  # short turn continues. Default on. RAG_THREAD_MENU_ENABLED=false restores
  # the literal-question path without a deploy.
  module ThreadMenuFlag
    module_function

    def enabled?
      ENV["RAG_THREAD_MENU_ENABLED"] != "false"
    end
  end
end
