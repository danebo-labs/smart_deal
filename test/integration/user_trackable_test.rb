# frozen_string_literal: true

require "test_helper"

class UserTrackableTest < ActionDispatch::IntegrationTest
  # www.example.com, the default integration-test host, maps to danebo-legacy,
  # which is the account users(:one) belongs to.
  setup do
    @user = users(:one)
  end

  test "a successful login populates the trackable columns" do
    login_at = Time.utc(2026, 8, 25, 9, 0, 0)

    travel_to(login_at) { post_login(@user) }

    assert_redirected_to root_path
    @user.reload
    assert_equal 1, @user.sign_in_count
    assert_equal login_at, @user.current_sign_in_at
    assert_equal login_at, @user.last_sign_in_at
    assert_equal "127.0.0.1", @user.current_sign_in_ip
    assert_equal "127.0.0.1", @user.last_sign_in_ip

    login_event = PilotEvent.find_by(event: "user_signed_in", user_id: @user.id)
    assert login_event, "a successful host-matched login must emit a durable series event"
    assert_equal @user.account_id, login_event.account_id
    assert_equal login_at, login_event.occurred_at
    assert_equal "web", login_event.payload.deep_symbolize_keys[:route]
  end

  test "a second login increments the counter and rotates current into last" do
    first_login  = Time.utc(2026, 8, 25, 9, 0, 0)
    second_login = Time.utc(2026, 8, 26, 7, 30, 0)

    travel_to(first_login) { post_login(@user) }
    delete destroy_user_session_path
    travel_to(second_login) { post_login(@user) }

    @user.reload
    assert_equal 2, @user.sign_in_count
    assert_equal second_login, @user.current_sign_in_at
    assert_equal first_login, @user.last_sign_in_at
  end

  test "a wrong password leaves the trackable columns untouched" do
    post user_session_path, params: {
      user: { email: @user.email, password: "not-the-password" }
    }

    @user.reload
    assert_equal 0, @user.sign_in_count
    assert_nil @user.current_sign_in_at
    assert_nil @user.last_sign_in_at
    assert_nil @user.current_sign_in_ip
    assert_not PilotEvent.exists?(event: "user_signed_in", user_id: @user.id)
  end

  # Documents a limitation of the counter, not a desired behaviour: Warden has
  # already authenticated the credentials (and Devise has already tracked them)
  # by the time Users::SessionsController#create rejects the host mismatch. A
  # sign_in_count of N is "credentials accepted N times", which is not the same
  # as N sessions on this host.
  test "a login rejected by host mismatch still counts as a sign-in" do
    other_account_user = users(:two)

    post_login(other_account_user)

    assert_redirected_to new_user_session_path
    assert_equal 1, other_account_user.reload.sign_in_count
    assert_not PilotEvent.exists?(event: "user_signed_in", user_id: other_account_user.id),
               "host mismatch is a credentials-accepted Devise count, not a session on this host"
  end

  private

  def post_login(user)
    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }
  end
end
