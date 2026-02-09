# frozen_string_literal: true

module Users
  class SessionsController < Devise::SessionsController
    respond_to :html

    private

    def auth_options
      { scope: resource_name, recall: "#{controller_path}#new" }
    end
  end
end
