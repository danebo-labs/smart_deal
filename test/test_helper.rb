# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

# Load vips (or mock) before environment—image_processing may require it during boot.
begin
  require 'vips'
rescue LoadError
  require_relative 'support/mock_vips'
end

require_relative '../config/environment'
require 'rails/test_help'

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers.
    # - CI: single worker (avoids connection-pool exhaustion in the GH runner).
    # - Local: capped at 2 by default to limit Postgres test-DB proliferation
    #   (Rails creates 4 DBs × N workers: smart_deal_test{,_cache,_queue,_cable}-N).
    #   Override with TEST_WORKERS=N when you need a faster local run.
    if ENV['CI']
      parallelize(workers: 1)
    else
      parallelize(workers: ENV.fetch('TEST_WORKERS', 2).to_i)
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

# WA channel is disabled for MVP. Flip to false to re-enable dormant WA test files.
WHATSAPP_CHANNEL_DISABLED = ENV.fetch("WHATSAPP_CHANNEL_DISABLED", "true").casecmp?("true")

module WhatsappDisabledSkip
  def setup
    super
    if WHATSAPP_CHANNEL_DISABLED &&
        (self.class.name.match?(/Whatsapp|Twilio/i) || name.to_s.match?(/whatsapp/i))
      skip "WhatsApp channel disabled for MVP (WHATSAPP_CHANNEL_DISABLED=true)"
    end
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include WhatsappDisabledSkip
end
