# frozen_string_literal: true

require 'test_helper'

class MissionControlJobsTest < ActionDispatch::IntegrationTest
  test 'jobs UI is not mounted in test (ActiveJob stays on :test adapter)' do
    get '/jobs'
    assert_response :not_found
  end
end
