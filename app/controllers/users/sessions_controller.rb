# frozen_string_literal: true

module Users
  class SessionsController < Devise::SessionsController
    layout "devise"
    respond_to :html

    def create
      self.resource = warden.authenticate!(auth_options)

      if resource.account_id != host_account.id
        sign_out(resource)
        flash[:alert] = t("errors.host_account_mismatch")
        redirect_to new_user_session_path and return
      end

      set_flash_message!(:notice, :signed_in) if is_flashing_format?
      sign_in(resource_name, resource)
      respond_with resource, location: after_sign_in_path_for(resource)
    end

    def after_sign_in_path_for(_resource)
      WarmBedrockKbJob.perform_later
      root_path
    end

    def after_sign_out_path_for(_resource_or_scope)
      new_user_session_path
    end

    private

    def auth_options
      { scope: resource_name, recall: "#{controller_path}#new" }
    end
  end
end
