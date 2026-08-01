# frozen_string_literal: true

require 'test_helper'

class LocaleSwitchTest < ActionDispatch::IntegrationTest
  test 'defaults to Spanish on sign in page' do
    get new_user_session_path
    assert_response :success
    assert_select 'h2', text: I18n.t('auth.sessions.title', locale: :es)
    assert_select 'span[aria-current=true]', text: 'ES'
  end

  test 'switching locale to English updates sign in copy' do
    get switch_locale_path(:en), headers: { 'HTTP_REFERER' => new_user_session_url }
    assert_redirected_to new_user_session_path
    follow_redirect!
    assert_response :success
    assert_select 'h2', text: I18n.t('auth.sessions.title', locale: :en)
    assert_select 'span[aria-current=true]', text: 'EN'
  end

  test 'switching back to Spanish restores Spanish copy' do
    get switch_locale_path(:en), headers: { 'HTTP_REFERER' => new_user_session_url }
    follow_redirect!

    get switch_locale_path(:es), headers: { 'HTTP_REFERER' => new_user_session_url }
    follow_redirect!

    assert_select 'h2', text: I18n.t('auth.sessions.title', locale: :es)
  end

  test 'invalid locale is ignored' do
    get switch_locale_path(:en), headers: { 'HTTP_REFERER' => new_user_session_url }
    follow_redirect!

    assert_raises(ActionController::UrlGenerationError) do
      switch_locale_path(:fr)
    end
  end

  # H-05: a request with session[:locale]=:en must not leave I18n.locale=:en
  # for later tests in the same process (Puma thread reuse / shared suite process).
  test 'request locale does not leak after the request ends' do
    process_locale = I18n.locale
    assert_not_equal :en, process_locale, "precondition: process locale must not already be :en"

    get switch_locale_path(:en), headers: { 'HTTP_REFERER' => new_user_session_url }
    follow_redirect!
    assert_response :success
    assert_select 'span[aria-current=true]', text: 'EN'

    assert_equal process_locale, I18n.locale
  end
end
