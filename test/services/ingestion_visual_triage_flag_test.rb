# frozen_string_literal: true

require "test_helper"

class IngestionVisualTriageFlagTest < ActiveSupport::TestCase
  test "is enabled only by the exact true string" do
    with_flag(nil)    { assert_not IngestionVisualTriageFlag.enabled? }
    with_flag("true") { assert IngestionVisualTriageFlag.enabled? }
    with_flag("TRUE") { assert_not IngestionVisualTriageFlag.enabled? }
    with_flag("1")    { assert_not IngestionVisualTriageFlag.enabled? }
    with_flag("")     { assert_not IngestionVisualTriageFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("INGESTION_VISUAL_TRIAGE_ENABLED", nil)
    if value.nil?
      ENV.delete("INGESTION_VISUAL_TRIAGE_ENABLED")
    else
      ENV["INGESTION_VISUAL_TRIAGE_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("INGESTION_VISUAL_TRIAGE_ENABLED")
    else
      ENV["INGESTION_VISUAL_TRIAGE_ENABLED"] = original
    end
  end
end
