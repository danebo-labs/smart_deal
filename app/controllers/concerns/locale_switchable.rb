# frozen_string_literal: true

module LocaleSwitchable
  extend ActiveSupport::Concern

  ALLOWED_LOCALES = %i[es en].freeze

  included do
    around_action :with_request_locale
    helper_method :current_locale
  end

  private

  def with_request_locale(&block)
    stored = session[:locale]&.to_sym
    locale = ALLOWED_LOCALES.include?(stored) ? stored : I18n.default_locale
    I18n.with_locale(locale, &block)
  end

  def current_locale
    I18n.locale
  end
end
