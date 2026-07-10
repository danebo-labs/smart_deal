# frozen_string_literal: true

require 'test_helper'

class AccountBrandingTest < ActiveSupport::TestCase
  test 'default (non-branded) account resolves Danebo assets' do
    branding = AccountBranding.for(accounts(:legacy))

    assert_equal 'Danebo', branding.display_name
    assert_equal 'logo_mobile.png', branding.logo_path
    assert_equal 'logo_desktop2.jpg', branding.desktop_logo_path
    assert_equal 'favicon.png', branding.favicon_path
    assert_equal '/icon-180.png', branding.apple_touch_href
    assert_equal 'danebo.ai', branding.logo_alt
    assert branding.show_danebo_wordmark?
    assert_not branding.branded?
  end

  test 'branded account resolves per-slug assets and hides the Danebo wordmark' do
    branding = AccountBranding.for(accounts(:climb))

    assert_equal 'Ascensores Climb', branding.display_name
    assert_equal 'accounts/elevadores-climb/logo.png', branding.logo_path
    assert_equal 'accounts/elevadores-climb/logo.png', branding.desktop_logo_path
    assert_equal 'accounts/elevadores-climb/favicon.png', branding.favicon_path
    assert_equal '/brands/elevadores-climb/icon-180.png', branding.apple_touch_href
    assert_equal 'Ascensores Climb', branding.logo_alt
    assert_not branding.show_danebo_wordmark?
    assert branding.branded?
  end
end
