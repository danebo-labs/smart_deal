# frozen_string_literal: true

require "test_helper"

class ActivityDashboardFlagTest < ActiveSupport::TestCase
  test "disabled by default" do
    isolate_env("ACTIVITY_DASHBOARD_ENABLED", nil) do
      assert_not ActivityDashboardFlag.enabled?
    end
  end

  test "enabled only when the ENV var is exactly the string true" do
    isolate_env("ACTIVITY_DASHBOARD_ENABLED", "true") do
      assert ActivityDashboardFlag.enabled?
    end
  end

  test "any other value stays disabled" do
    isolate_env("ACTIVITY_DASHBOARD_ENABLED", "1") do
      assert_not ActivityDashboardFlag.enabled?
    end
  end
end
