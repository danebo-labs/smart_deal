# frozen_string_literal: true

module Users
  class RegistrationsController < Devise::RegistrationsController
    layout "devise"
    respond_to :html

    protected

    def after_sign_up_path_for(_resource)
      WarmBedrockKbJob.perform_later
      root_path
    end
  end
end
