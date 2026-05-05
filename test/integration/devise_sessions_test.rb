# frozen_string_literal: true

require "test_helper"

class DeviseSessionsTest < ActionDispatch::IntegrationTest
  test "login page renders password field with visibility toggle" do
    get new_user_session_path

    assert_response :success
    assert_select "div[data-controller=password-visibility]", 1
    assert_select "input#user_password[type=password]", 1
    assert_select "button[type=button][aria-controls=user_password]", 1
    assert_select "button[aria-label='Mostrar contraseña'][aria-pressed=false]", 1
  end
end
