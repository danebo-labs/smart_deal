# frozen_string_literal: true

require "test_helper"
require_relative "../support/field_case_history_helper"
require_relative "../support/opening_chat_double"

class OpeningChatTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include FieldCaseHistoryHelper

  setup do
    enable_history!
    OpeningChatDouble.install!
    OpeningChatDouble.answer = "Respuesta:"
    @user = users(:one)
    @account = accounts(:legacy)
    sign_in @user
  end

  teardown do
    OpeningChatDouble.answer = nil
    disable_history!
  end

  test "the first text creates one case and a retry does not add another turn" do
    key = SecureRandom.uuid
    submission = SecureRandom.uuid

    assert_no_difference("FieldCase.count") { get root_path }
    assert_difference("FieldCase.count", 1) do
      assert_difference("FieldTurn.count", 1) { post_opening("primer aviso", key, submission) }
    end
    assert_response :ok
    body = response.parsed_body
    assert_equal "success", body.fetch("status")
    assert_equal "Respuesta: primer aviso", body.fetch("answer")
    case_id = body.fetch("field_case_id")
    assert_equal 1, OpeningChatDouble.calls

    assert_no_difference([ "FieldCase.count", "FieldTurn.count" ]) do
      post_opening("primer aviso", key, submission)
    end
    assert_response :ok
    assert_equal case_id, response.parsed_body.fetch("field_case_id")
    assert_equal "Respuesta: primer aviso", response.parsed_body.fetch("answer")
    assert_equal 1, OpeningChatDouble.calls

    assert_no_difference("FieldCase.count") do
      assert_difference("FieldTurn.count", 1) do
        post rag_ask_path, params: {
          question: "segundo aviso", field_case_id: case_id, client_submission_id: SecureRandom.uuid
        }, as: :json
      end
    end
    assert_response :ok
    assert_equal "Respuesta: segundo aviso", response.parsed_body.fetch("answer")
    assert_equal 2, OpeningChatDouble.calls

    stored = FieldCase.find(case_id)
    assert_equal @user.id, stored.user_id
    assert_equal [], stored.document_focus
    assert_equal [ "primer aviso", "segundo aviso" ], stored.field_turns.order(:sequence).pluck(:message)
    assert_equal [ "completed", "completed" ], stored.field_turns.order(:sequence).pluck(:status)
    assert_equal "Respuesta: primer aviso", stored.field_turns.order(:sequence).first.response.fetch("published_text")
    assert_equal "Respuesta: segundo aviso", stored.field_turns.order(:sequence).last.response.fetch("published_text")
  end

  test "the first text stores the manual selected on the empty chat" do
    document = KbDocument.create!(
      s3_key: "uploads/2026/thyssen-chat.pdf", display_name: "Thyssen", aliases: []
    )

    assert_difference("FieldCase.count", 1) do
      post_opening("con manual", SecureRandom.uuid, SecureRandom.uuid, kb_document_ids: [ document.id ])
    end
    assert_response :ok
    stored = FieldCase.find(response.parsed_body.fetch("field_case_id"))
    assert_equal [ document.id ], stored.document_focus.pluck("kb_document_id")

    assert_no_difference("FieldCase.count") do
      post_opening("sin manual", SecureRandom.uuid, SecureRandom.uuid, kb_document_ids: [ 9_000_000_001 ])
    end
    assert_response :not_found
  end

  test "a blank message, a file, and the flag off leave no case" do
    key = SecureRandom.uuid
    assert_no_difference("FieldCase.count") do
      post_opening("  ", key, SecureRandom.uuid)
      assert_response :unprocessable_entity

      post rag_ask_path, params: {
        question: "foto", creation_key: key, client_submission_id: SecureRandom.uuid,
        image: { data: "abc", media_type: "image/jpeg", filename: "a.jpg" }
      }, as: :json
      assert_response :unprocessable_entity
    end
    assert_equal 0, OpeningChatDouble.calls

    disable_history!
    assert_no_difference("FieldCase.count") do
      post_opening("hola", SecureRandom.uuid, SecureRandom.uuid)
    end
    assert_response :not_found
    assert_equal 0, OpeningChatDouble.calls
  end

  private

  def post_opening(question, key, submission, **extra)
    post rag_ask_path, params: {
      question:, creation_key: key, client_submission_id: submission, **extra
    }, as: :json
  end
end
