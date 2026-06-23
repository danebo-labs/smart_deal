# frozen_string_literal: true

require 'test_helper'

class PinnedDocumentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user   = users(:one)
    @kb_doc = KbDocument.create!(s3_key: "uploads/2026/pin_ctl.pdf", display_name: "Pin Ctl", aliases: [], account: @user.account)
    sign_in @user
  end

  test "create pins the document into the session" do
    post pinned_documents_path, params: { kb_document_id: @kb_doc.id }
    assert_response :no_content

    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: "web")
    assert_includes SessionContextBuilder.entity_s3_uris(session), @kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
  end

  test "create is idempotent" do
    2.times { post pinned_documents_path, params: { kb_document_id: @kb_doc.id } }
    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: "web")
    assert_equal 1, session.active_entities.size
  end

  test "destroy unpins the document" do
    post pinned_documents_path, params: { kb_document_id: @kb_doc.id }
    delete pinned_document_path(@kb_doc.id)
    assert_response :no_content

    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: "web")
    assert_empty session.active_entities
  end

  test "create returns 404 for unknown document" do
    post pinned_documents_path, params: { kb_document_id: 999_999 }
    assert_response :not_found
  end

  test "create returns 404 for another account document" do
    other_doc = KbDocument.create!(
      s3_key: "uploads/2026/other_account_pin_ctl.pdf",
      display_name: "Other Account",
      aliases: [],
      account: accounts(:climb)
    )

    post pinned_documents_path, params: { kb_document_id: other_doc.id }
    assert_response :not_found
  end

  test "destroy returns 404 for another account document" do
    other_doc = KbDocument.create!(
      s3_key: "uploads/2026/other_account_unpin_ctl.pdf",
      display_name: "Other Account",
      aliases: [],
      account: accounts(:climb)
    )

    delete pinned_document_path(other_doc.id)
    assert_response :not_found
  end

  test "redirects unauthenticated user to login" do
    sign_out @user
    post pinned_documents_path, params: { kb_document_id: @kb_doc.id }
    assert_response :redirect
  end
end
