# frozen_string_literal: true

# MVP: optional shared conversation session across web users.
# Flip SHARED_SESSION_ENABLED to "true" to route all web requests through one session.
# WA channel is disabled for MVP — CHANNEL is always "web" or "shared" (never "whatsapp").
module SharedSession
  # Test loads .env via dotenv-rails; default off here so the suite stays isolated.
  # Shared-mode tests toggle ENABLED with stub helpers.
  ENABLED    = Rails.env.test? ? false : ENV.fetch('SHARED_SESSION_ENABLED', 'false').casecmp?('true')
  IDENTIFIER = ENV.fetch('SHARED_SESSION_IDENTIFIER', 'mvp-shared').freeze
  CHANNEL    = ENV.fetch('SHARED_SESSION_CHANNEL',    'web').freeze
end
