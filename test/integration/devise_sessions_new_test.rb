# frozen_string_literal: true

require 'test_helper'

class DeviseSessionsNewTest < ActionDispatch::IntegrationTest
  test 'sign in page renders app logo assets' do
    get new_user_session_path
    assert_response :success
    assert_select 'img[alt="danebo"][src*="logo_desktop2"]', count: 1
    assert_select 'img[alt="danebo"][src*="logo_mobile"]', count: 1
  end

  test 'sign in page includes png favicon asset' do
    get new_user_session_path
    assert_response :success
    assert_select 'link[rel="icon"][type="image/png"]' do |elements|
      assert(elements.any? { |e| e['href'].to_s.include?('favicon') })
    end
  end
end
