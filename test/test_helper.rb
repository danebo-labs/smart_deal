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

    # Completed non-photo ledger with a chunk prefix. Promotion to
    # danebo_general requires this evidence. A row without it stays private.
    def index_manual_for_retrieval!(document)
      WebManualBatch.create!(
        account: document.account,
        kb_document: document,
        s3_key: document.s3_key,
        filename: File.basename(document.s3_key.to_s),
        sha256: SecureRandom.hex(32),
        ingestion_contract_version: "v1",
        status: "complete",
        chunks_s3_prefix: "bulk_chunks/#{document.id}"
      )
    end
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

# Kill-switches such as ACTIVITY_DASHBOARD_ENABLED live in ENV. dotenv loads a
# local `.env` into the test process, and Minitest cases in the same worker
# share that process. Tests that care about a flag must pin it and restore.
module EnvIsolation
  def isolate_env(key, value)
    previous = ENV[key]
    assign_env(key, value)
    yield
  ensure
    assign_env(key, previous)
  end

  def assign_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include EnvIsolation
end

# N0 multimodal contracts stay in the suite as skipped examples.
# N0_CONTRACTS=1 runs the asserts against current code.
module N0Contract
  def n0_contract!(phase)
    return if ENV["N0_CONTRACTS"] == "1"

    skip "N0 contract — expected to become green in #{phase}"
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include N0Contract
end
