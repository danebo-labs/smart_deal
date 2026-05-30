# frozen_string_literal: true

class LocalesController < ApplicationController
  def switch
    locale = params[:locale]&.to_sym
    session[:locale] = locale.to_s if LocaleSwitchable::ALLOWED_LOCALES.include?(locale)

    redirect_back fallback_location: root_path, allow_other_host: false
  end
end
