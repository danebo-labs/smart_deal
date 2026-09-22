# frozen_string_literal: true

module Rag
  # Retired. Retrieval no longer turns a catalog token into a URI filter.
  # The ENV remains so an old setting is a no-op for retrieve.
  module AutoScopeFlag
    module_function

    def enabled?
      ENV["RAG_AUTO_SCOPE_ENABLED"] != "false"
    end
  end
end
