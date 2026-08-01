# frozen_string_literal: true

require "test_helper"

class IngestionLayoutFlagTest < ActiveSupport::TestCase
  test "is enabled only by the exact true string" do
    with_flag(nil)    { assert_not IngestionLayoutFlag.enabled? }
    with_flag("true") { assert IngestionLayoutFlag.enabled? }
    with_flag("TRUE") { assert_not IngestionLayoutFlag.enabled? }
    with_flag("1")    { assert_not IngestionLayoutFlag.enabled? }
    with_flag("")     { assert_not IngestionLayoutFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("INGESTION_LAYOUT_DIGEST_ENABLED", nil)
    if value.nil?
      ENV.delete("INGESTION_LAYOUT_DIGEST_ENABLED")
    else
      ENV["INGESTION_LAYOUT_DIGEST_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("INGESTION_LAYOUT_DIGEST_ENABLED")
    else
      ENV["INGESTION_LAYOUT_DIGEST_ENABLED"] = original
    end
  end
end
