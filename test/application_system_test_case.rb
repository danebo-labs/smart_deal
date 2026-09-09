# frozen_string_literal: true

require 'test_helper'

# IPv4 only. Binding "localhost" makes Puma listen on [::1] too; Chrome (and
# Cursor's Simple Browser) then send Host: [::1], which Rails blocks.
Capybara.server_host = "127.0.0.1"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400]

  teardown do
    restore_chrome_network
  end

  private

  # CDP network emulation survives Capybara.reset_sessions! (the browser is
  # reused, not quit). A test that goes offline must not leave later classes
  # with visit → ERR_INTERNET_DISCONNECTED.
  def restore_chrome_network
    driver = Capybara.current_session.driver
    return unless driver.is_a?(Capybara::Selenium::Driver)
    return unless driver.instance_variable_get(:@browser)

    driver.browser.delete_network_conditions
  rescue Selenium::WebDriver::Error::WebDriverError, NoMethodError
    nil
  end
end
