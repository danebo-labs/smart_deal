# frozen_string_literal: true

require "test_helper"

class ActivityDashboardFlagTest < ActiveSupport::TestCase
  test "disabled by default" do
    ENV.delete("ACTIVITY_DASHBOARD_ENABLED")
    assert_not ActivityDashboardFlag.enabled?
  end

  test "enabled only when the ENV var is exactly the string true" do
    ENV["ACTIVITY_DASHBOARD_ENABLED"] = "true"
    assert ActivityDashboardFlag.enabled?
  ensure
    ENV.delete("ACTIVITY_DASHBOARD_ENABLED")
  end

  test "any other value stays disabled" do
    ENV["ACTIVITY_DASHBOARD_ENABLED"] = "1"
    assert_not ActivityDashboardFlag.enabled?
  ensure
    ENV.delete("ACTIVITY_DASHBOARD_ENABLED")
  end
end
