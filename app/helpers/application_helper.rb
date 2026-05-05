# frozen_string_literal: true

module ApplicationHelper
  # Wraps +form.password_field+ with a show/hide toggle (type="button", aria, touch target).
  def password_field_with_toggle(form, field, **html_options)
    render "shared/password_field_toggle", form: form, field: field, html_options: html_options
  end

  def number_to_human_size(size)
    return '0 B' if size.nil? || size.zero?

    units = %w[B KB MB GB TB]
    unit = 0
    size_float = size.to_f

    while size_float >= 1024 && unit < units.length - 1
      size_float /= 1024.0
      unit += 1
    end

    "#{size_float.round(2)} #{units[unit]}"
  end
end
