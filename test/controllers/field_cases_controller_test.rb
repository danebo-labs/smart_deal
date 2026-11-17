# frozen_string_literal: true

require "test_helper"
require_relative "../support/field_case_history_helper"

class FieldCasesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include FieldCaseHistoryHelper

  setup do
    enable_history!
    @user = users(:one)
    @account = accounts(:legacy)
  end

  teardown { disable_history! }

  test "redirects an unauthenticated visitor" do
    get field_cases_path
    assert_response :redirect
  end

  test "index, show and create respond 404 when the flag is off" do
    sign_in @user
    kase = open_case
    disable_history!

    get field_cases_path
    assert_response :not_found

    get field_case_path(kase)
    assert_response :not_found

    assert_no_difference("FieldCase.count") do
      post field_cases_path, params: { creation_key: SecureRandom.uuid }, as: :json
    end
    assert_response :not_found
  end

  test "create starts without pins and a repeated key returns the same case" do
    sign_in @user
    key = SecureRandom.uuid

    post field_cases_path, params: { creation_key: key }, as: :json
    assert_response :created
    assert_equal "private, no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal [], body["document_focus"]
    assert_equal "resumable", body["mode"]
    assert_equal 0, body["state_revision"]
    assert_nil body["title"]
    assert_match(/\Aep_[0-9a-f]{16}\z/, body["episode_id"])

    post field_cases_path, params: { creation_key: key }, as: :json
    assert_response :ok
    assert_equal body["id"], response.parsed_body["id"]
    assert_equal 1, FieldCase.where(user: @user, creation_key: key).count
  end

  test "create rejects pins" do
    sign_in @user

    assert_no_difference("FieldCase.count") do
      post field_cases_path, params: { pins: [ { kb_document_id: 1 } ] }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "index and show stay inside the signed in technician" do
    sign_in @user
    own = open_case
    turn = admit(own, message: "mio", client_submission_id: "sub-http").turn
    close_turn(own, turn, published_text: "guardado", citations: [ { "page" => 7 } ])
    other = open_case(account: accounts(:climb), user: users(:two))
    hidden = open_case(user: colleague)

    get field_cases_path
    assert_response :success
    ids = response.parsed_body.fetch("cases").pluck("id")
    assert_includes ids, own.id
    assert_not_includes ids, other.id
    assert_not_includes ids, hidden.id

    get field_case_path(own)
    assert_response :success
    shown = response.parsed_body
    assert_equal "guardado", shown.dig("turns", 0, "response", "published_text")
    assert_equal [ { "page" => 7 } ], shown.dig("turns", 0, "response", "citations")
    assert_equal "completed", shown.dig("turns", 0, "status")
    assert_not shown.dig("turns", 0).key?("execution_token")

    get field_case_path(hidden)
    assert_response :not_found

    get turn_field_case_path(own, turn)
    assert_response :success
    assert_equal "guardado", response.parsed_body.dig("turn", "response", "published_text")

    sign_in users(:two)
    host! "ascensoresclimb.localhost"
    get field_case_path(own)
    assert_response :not_found
  end
end
