# frozen_string_literal: true

module Rag
  # Retired for retrieval. A question that names a page does not narrow the
  # search: a field technician does not remember a page among the manuals.
  # The ENV remains so an old setting does not change retrieve.
  module PagePinFlag
    module_function

    def enabled?
      ENV["RAG_PAGE_PIN_ENABLED"] == "true"
    end
  end
end
