# frozen_string_literal: true

module Rag
  # Switch for the unified photo answer bubble.
  # Default OFF. Phase 1 does not read it.
  module FieldCompanionPhotoFlag
    module_function

    def enabled?
      ENV["FIELD_COMPANION_PHOTO_ENABLED"] == "true"
    end
  end
end
