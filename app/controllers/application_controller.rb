# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :set_locale

  private

  def set_locale
    I18n.locale = locale_from_accept_language || I18n.default_locale
  end

  def locale_from_accept_language
    return nil if request.env["HTTP_ACCEPT_LANGUAGE"].blank?

    # Parse "es-CO,es;q=0.9,en;q=0.8" — take first language code
    lang = request.env["HTTP_ACCEPT_LANGUAGE"].split(",").first&.split("-")&.first&.downcase
    lang.to_sym if lang.present? && I18n.available_locales.map(&:to_s).include?(lang)
  end
end
