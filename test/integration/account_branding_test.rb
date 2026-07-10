# frozen_string_literal: true

require 'test_helper'

class AccountBrandingIntegrationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test 'climb host renders climb logo/favicon/apple-touch icon and hides the Danebo wordmark' do
    host! 'ascensoresclimb.danebo.ai'
    sign_in users(:two), scope: :user

    get root_path
    assert_response :success

    assert_select 'title', text: 'Ascensores Climb'
    assert_select 'meta[name="application-name"][content="Ascensores Climb"]'
    assert_select 'link[rel="icon"][type="image/png"]' do |elements|
      assert(elements.any? { |e| e['href'].to_s.include?('accounts/elevadores-climb/favicon') })
    end
    assert_select 'link[rel="apple-touch-icon"][href="/brands/elevadores-climb/icon-180.png"][sizes="180x180"]', count: 1
    assert_select 'img[alt="Ascensores Climb"][src*="accounts/elevadores-climb/logo"]', minimum: 1
    assert_select '.brand-wordmark', count: 0
    assert_select 'footer p', text: '© 2026 Ascensores Climb'
  end

  test 'danebo host keeps default branding on login page' do
    host! 'elevator.danebo.ai'

    get new_user_session_path
    assert_response :success

    assert_select 'title', text: 'Danebo'
    assert_select 'link[rel="apple-touch-icon"][href="/icon-180.png"][sizes="180x180"]', count: 1
    assert_select 'img[alt="danebo.ai"][src*="logo_desktop2"]', count: 1
  end
end
