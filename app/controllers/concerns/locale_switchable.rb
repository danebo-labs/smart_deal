# frozen_string_literal: true

module LocaleSwitchable
  extend ActiveSupport::Concern

  ALLOWED_LOCALES = %i[es en].freeze

  included do
    before_action :set_locale
    helper_method :current_locale
  end

  private

  def set_locale
    stored = session[:locale]&.to_sym
    I18n.locale = ALLOWED_LOCALES.include?(stored) ? stored : I18n.default_locale
  end

  def current_locale
    I18n.locale
  end
end
