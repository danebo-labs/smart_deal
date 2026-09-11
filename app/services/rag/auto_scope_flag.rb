# frozen_string_literal: true

module Rag
  # Kill switch for auto-scoping retrieval to the resolver's specific matches
  # (see RagQueryConcern#auto_scope_uris_from). Same pattern as PagePinFlag —
  # default enabled, one ENV flip to disable without a code change/deploy.
  module AutoScopeFlag
    module_function

    def enabled?
      ENV["RAG_AUTO_SCOPE_ENABLED"] != "false"
    end
  end
end
