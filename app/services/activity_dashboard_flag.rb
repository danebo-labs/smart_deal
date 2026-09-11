# frozen_string_literal: true

# Rails-native kill switch for the activity dashboard (query-volume view for
# the demo). Flipping ENV["ACTIVITY_DASHBOARD_ENABLED"] off in production
# hides the nav entry, 404s /actividad and restores /dashboard — zero deploy.
module ActivityDashboardFlag
  module_function

  def enabled?
    ENV["ACTIVITY_DASHBOARD_ENABLED"] == "true"
  end
end
