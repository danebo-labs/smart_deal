# frozen_string_literal: true

# https://github.com/rails/mission_control-jobs#authentication
case Rails.env
when 'development'
  MissionControl::Jobs.http_basic_auth_user = ENV.fetch('MISSION_CONTROL_JOBS_USER', 'dev')
  MissionControl::Jobs.http_basic_auth_password = ENV.fetch('MISSION_CONTROL_JOBS_PASSWORD', 'dev')
when 'test'
  # Engine not mounted in test; ActiveJob uses :test adapter (see test_helper).
else
  user = ENV['MISSION_CONTROL_JOBS_USER'].presence ||
    Rails.application.credentials.dig(:mission_control, :http_basic_auth_user)
  password = ENV['MISSION_CONTROL_JOBS_PASSWORD'].presence ||
    Rails.application.credentials.dig(:mission_control, :http_basic_auth_password)
  if user.present? && password.present?
    MissionControl::Jobs.http_basic_auth_user = user
    MissionControl::Jobs.http_basic_auth_password = password
  end
end
