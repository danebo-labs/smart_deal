# frozen_string_literal: true

# 404 for a shared session. A personal workspace keeps the history routes
# open without FIELD_CASE_HISTORY_ENABLED.
module FieldCaseHistoryGuard
  extend ActiveSupport::Concern

  included do
    before_action :ensure_field_case_history_enabled!
  end

  private

  def ensure_field_case_history_enabled!
    head :not_found unless FieldCaseHistoryFlag.enabled?
  end
end
