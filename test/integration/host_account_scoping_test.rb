# frozen_string_literal: true

require "test_helper"

class HostAccountScopingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @legacy = accounts(:legacy)
    @climb  = accounts(:climb)
    @legacy_user = users(:one)
    @climb_user  = users(:two)

    @legacy_doc = KbDocument.create!(
      s3_key: "uploads/2026/legacy_only.pdf",
      display_name: "Legacy Only Manual",
      aliases: [],
      account: @legacy
    )
    @climb_doc = KbDocument.create!(
      s3_key: "uploads/2026/climb_only.pdf",
      display_name: "Climb Only Manual",
      aliases: [],
      account: @climb
    )
  end

  test "climb user on ascensoresclimb host sees only climb KB docs" do
    host! "ascensoresclimb.danebo.ai"
    sign_in @climb_user

    get root_path

    assert_response :success
    assert_select '[data-doc-name="Climb Only Manual"]'
    assert_select '[data-doc-name="Legacy Only Manual"]', count: 0
  end

  test "legacy user on elevator host sees only legacy KB docs" do
    host! "elevator.danebo.ai"
    sign_in @legacy_user

    get root_path

    assert_response :success
    assert_select '[data-doc-name="Legacy Only Manual"]'
    assert_select '[data-doc-name="Climb Only Manual"]', count: 0
  end

  test "cross-account login is rejected" do
    host! "ascensoresclimb.danebo.ai"

    post user_session_path, params: {
      user: { email: @legacy_user.email, password: "password123" }
    }

    assert_redirected_to new_user_session_path
    follow_redirect!
    assert_match(/no pertenece a este sitio|does not belong to this site/i, flash[:alert].to_s)
    assert_nil controller.current_user
  end

  test "existing session for other account is signed out on host mismatch" do
    host! "elevator.danebo.ai"
    sign_in @climb_user

    get root_path

    assert_redirected_to new_user_session_path
    follow_redirect!
    assert_match(/no pertenece a este sitio|does not belong to this site/i, flash[:alert].to_s)
  end
end
