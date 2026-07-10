# frozen_string_literal: true

require "test_helper"

class HostAuthorizationTest < ActionDispatch::IntegrationTest
  test "rejects unknown host with 403" do
    host! "chat.danebo.ai"
    get new_user_session_path

    assert_response :forbidden
  end

  test "allows /up on unknown host" do
    host! "chat.danebo.ai"
    get "/up"

    assert_response :success
  end

  test "allows elevator tenant host" do
    host! "elevator.danebo.ai"
    get new_user_session_path

    assert_response :success
  end

  test "allows default Rails test host" do
    host! "www.example.com"
    get new_user_session_path

    assert_response :success
  end
end
