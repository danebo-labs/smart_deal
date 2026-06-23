# frozen_string_literal: true

require 'test_helper'

class DeviseSessionsNewTest < ActionDispatch::IntegrationTest
  test 'sign in page renders app logo assets' do
    get new_user_session_path
    assert_response :success
    assert_select 'img[alt="' + I18n.t('auth.brand.logo_alt') + '"][src*="logo_desktop2"]', count: 1
    assert_select 'img[alt="' + I18n.t('auth.brand.logo_alt') + '"][src*="logo_mobile"]', count: 1
  end

  test 'sign in page includes png favicon asset' do
    get new_user_session_path
    assert_response :success
    assert_select 'link[rel="icon"][type="image/png"]' do |elements|
      assert(elements.any? { |e| e['href'].to_s.include?('favicon') })
    end
  end

  test 'sign in brand panel renders localized copy in Spanish' do
    get new_user_session_path
    assert_response :success
    assert_select 'h1', text: I18n.t('auth.brand.headline', locale: :es)
    assert_includes response.body, I18n.t('auth.brand.paragraph_1', locale: :es)
    assert_includes response.body, I18n.t('auth.brand.tagline', locale: :es)
  end

  test 'auth brand English translations are defined' do
    assert_equal "Turn your company's information and data into operational value.",
                 I18n.t('auth.brand.headline', locale: :en)
    assert_includes I18n.t('auth.brand.closing', locale: :en), 'productivity'
  end

  test 'sign in form panel renders localized copy in Spanish' do
    get new_user_session_path
    assert_response :success
    assert_select 'h2', text: I18n.t('auth.sessions.title', locale: :es)
    assert_select 'input[type=submit][value=?]', I18n.t('auth.sessions.submit', locale: :es)
    assert_includes response.body, I18n.t('auth.sessions.subtitle', locale: :es)
    assert_includes response.body, I18n.t('auth.legal.terms', locale: :es)
  end

  test 'auth form English translations are defined' do
    assert_equal 'Sign in', I18n.t('auth.sessions.title', locale: :en)
    assert_equal 'Continue', I18n.t('auth.sessions.submit', locale: :en)
    assert_equal 'Terms of Service', I18n.t('auth.legal.terms', locale: :en)
  end
end
