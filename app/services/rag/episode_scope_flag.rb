# frozen_string_literal: true

module Rag
  # Retrieval no longer inherits a document from prior turns. The flag still
  # gates the pin-name selection prompt and the episode history window.
  module EpisodeScopeFlag
    module_function

    def enabled?
      ENV["RAG_EPISODE_SCOPE_ENABLED"] != "false"
    end
  end
end
