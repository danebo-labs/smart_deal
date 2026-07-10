# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include LocaleSwitchable
  helper_method :current_account

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :ensure_user_belongs_to_host_account!, if: :user_signed_in?

  private

  def host_account
    @host_account ||= AccountHostResolver.account_for(request.host) ||
      raise(ActiveRecord::RecordNotFound, "Unknown host: #{request.host}")
  end

  def current_account
    @current_account ||= host_account
  end

  def ensure_user_belongs_to_host_account!
    return if current_user.account_id == host_account.id

    sign_out(current_user)
    redirect_to new_user_session_path, alert: t("errors.host_account_mismatch")
  end
end
