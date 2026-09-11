# frozen_string_literal: true

require "test_helper"

class ActivityControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    ENV["ACTIVITY_DASHBOARD_ENABLED"] = "true"
    BedrockQuery.destroy_all
    sign_in users(:one), scope: :user
  end

  teardown do
    ENV.delete("ACTIVITY_DASHBOARD_ENABLED")
  end

  test "responds 404 when the flag is disabled" do
    ENV.delete("ACTIVITY_DASHBOARD_ENABLED")

    get activity_path
    assert_response :not_found
  end

  test "requires an authenticated user" do
    sign_out :user

    get activity_path
    assert_redirected_to new_user_session_path
  end

  test "renders with no dollar signs or token mentions — contract assertion" do
    get activity_path
    assert_response :success
    assert_no_match(/\$/, response.body)
    assert_no_match(/tok/i, response.body)
  end

  test "shows only the host account's documents and queries" do
    own_doc = kb_documents(:manual_uno)
    other_doc = KbDocument.create!(
      s3_key: "uploads/2026/otra_cuenta.pdf",
      display_name: "Manual de otra cuenta",
      account: accounts(:climb)
    )

    BedrockQuery.create!(
      account_id: accounts(:legacy).id, user_id: users(:one).id,
      model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      input_tokens: 100, output_tokens: 50, latency_ms: 300,
      source: :query, created_at: Time.current
    )
    BedrockQuery.create!(
      account_id: accounts(:climb).id, user_id: users(:two).id,
      model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      input_tokens: 100, output_tokens: 50, latency_ms: 300,
      source: :query, created_at: Time.current
    )

    get activity_path
    assert_response :success
    assert_match own_doc.display_name, response.body
    assert_no_match(/#{Regexp.escape(other_doc.display_name)}/, response.body)
    assert_match users(:one).email, response.body
    assert_no_match(/#{Regexp.escape(users(:two).email)}/, response.body)
  end
end
