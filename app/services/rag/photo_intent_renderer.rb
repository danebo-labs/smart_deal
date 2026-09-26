# frozen_string_literal: true

module Rag
  # Opening paragraph for a blank-question photo that carried an intent.
  # The standalone vision reading is appended unchanged.
  class PhotoIntentRenderer
    def self.prose(reading:, locale:)
      reading = reading.to_h.deep_symbolize_keys
      visible = reading[:target_visible]
      visible = nil unless visible == true || visible == false
      missing = reading[:missing_view_or_detail].to_s.squish
      analysis = reading[:analysis].to_s
      opening = I18n.with_locale(locale) { opening_paragraph(visible, missing) }
      "#{opening}\n\n#{analysis}"
    end

    def self.opening_paragraph(visible, missing)
      case visible
      when false
        if missing.present?
          I18n.t("rag.photo_intent.target_hidden", missing: missing)
        else
          I18n.t("rag.photo_intent.target_hidden_default")
        end
      when true
        sentence = I18n.t("rag.photo_intent.target_visible")
        missing.present? ? "#{sentence} #{missing}" : sentence
      else
        extra = missing.presence || I18n.t("rag.photo_intent.close_up_request")
        "#{I18n.t('rag.photo_intent.target_uncertain')} #{extra}"
      end
    end
    private_class_method :opening_paragraph
  end
end
