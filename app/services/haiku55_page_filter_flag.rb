# frozen_string_literal: true

# Batch page filter on claude-haiku-5-5. Off unless HAIKU55_PAGE_FILTER=1.
# Unset the variable to roll back to claude-haiku-4-5-20251001. A one-page
# document stays on the existing per-page filter either way.
class Haiku55PageFilterFlag
  MODEL = "claude-haiku-5-5"
  TRACKING_MODEL_ID = "claude-haiku-5-5-direct"
  EFFORT = "low"

  def self.enabled?
    ENV["HAIKU55_PAGE_FILTER"] == "1"
  end
end
