# frozen_string_literal: true

Rails.application.config.after_initialize do
  Rag::DirectInferenceBoot.check! if Rails.env.production?
end
