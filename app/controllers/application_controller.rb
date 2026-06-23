# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include LocaleSwitchable
  helper_method :current_account

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def current_account
    @current_account ||= current_user&.account ||
      raise(ActiveRecord::RecordNotFound, "No account for user #{current_user&.id}")
  end
end
