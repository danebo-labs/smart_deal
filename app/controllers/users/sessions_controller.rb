# frozen_string_literal: true

module Users
  class SessionsController < Devise::SessionsController
    layout "devise"
    respond_to :html

    def after_sign_in_path_for(_resource)
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
