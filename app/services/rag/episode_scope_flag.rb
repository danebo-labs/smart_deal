# frozen_string_literal: true

module Rag
  # Kill switch for inheriting retrieval scope from recent user turns in the
  # same episode (see RagQueryConcern#execute_rag_query). Same pattern as
  # AutoScopeFlag — default enabled, one ENV flip to disable without a deploy.
  module EpisodeScopeFlag
    module_function

    def enabled?
      ENV["RAG_EPISODE_SCOPE_ENABLED"] != "false"
    end
  end
end
