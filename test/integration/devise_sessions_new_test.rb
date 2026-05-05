# frozen_string_literal: true

require 'test_helper'

class DeviseSessionsNewTest < ActionDispatch::IntegrationTest
  test 'sign in page renders app logo asset' do
    get new_user_session_path
    assert_response :success
    assert_select 'img[alt="danebo"][src*="logo"]', count: 2
  end
end
