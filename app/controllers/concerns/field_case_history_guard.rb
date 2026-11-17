# frozen_string_literal: true

# 404 while FIELD_CASE_HISTORY_ENABLED is off, same switch as the certifier
# module: the tables can ship and the routes stay dark.
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
