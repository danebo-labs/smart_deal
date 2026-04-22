# frozen_string_literal: true

# MVP: single shared conversation session across all WhatsApp numbers and web users.
# Flip SHARED_SESSION_ENABLED to "false" (or omit it) to revert to per-number/user isolation (Stage 1+).
module SharedSession
  # Test loads .env via dotenv-rails; default off here so the suite stays isolated.
  # Shared-mode tests toggle ENABLED with stub helpers.
  ENABLED    = Rails.env.test? ? false : ENV.fetch('SHARED_SESSION_ENABLED', 'false').casecmp?('true')
  IDENTIFIER = ENV.fetch('SHARED_SESSION_IDENTIFIER', 'mvp-shared').freeze
  CHANNEL    = ENV.fetch('SHARED_SESSION_CHANNEL',    'shared').freeze
end
