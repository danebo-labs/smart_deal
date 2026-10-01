# frozen_string_literal: true

require 'test_helper'

class PinnedDocumentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

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

  test "create enqueues DocumentOverviewWarmJob exactly once" do
    assert_enqueued_with(job: DocumentOverviewWarmJob, args: [ { account_id: @user.account_id, kb_document_id: @kb_doc.id } ]) do
      post pinned_documents_path, params: { kb_document_id: @kb_doc.id }
    end
    assert_enqueued_jobs 1, only: DocumentOverviewWarmJob
  end

  test "create is idempotent" do
    2.times { post pinned_documents_path, params: { kb_document_id: @kb_doc.id } }
    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: "web")
    assert_equal 1, session.document_focus_entries.size
  end

  test "create renews added_at when the checkbox pins the same document again" do
    first_at = Time.zone.parse("2026-09-30 09:00:00")
    second_at = first_at + 1.hour

    travel_to(first_at) { post pinned_documents_path, params: { kb_document_id: @kb_doc.id } }
    travel_to(second_at) { post pinned_documents_path, params: { kb_document_id: @kb_doc.id } }

    session = ConversationSession.find_by!(identifier: @user.id.to_s, channel: "web")
    entity = session.document_focus_entries.sole
    assert_equal 1, session.document_focus_entries.size
    assert_equal second_at.to_i, Time.zone.parse(entity["added_at"]).to_i
    assert_equal @kb_doc.display_s3_uri(KbDocument::KB_BUCKET), entity["source_uri"]
  end

  test "destroy unpins the document" do
    post pinned_documents_path, params: { kb_document_id: @kb_doc.id }
    delete pinned_document_path(@kb_doc.id)
    assert_response :no_content

    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: "web")
    assert_empty session.document_focus_entries
  end

  test "create returns 404 for unknown document" do
    post pinned_documents_path, params: { kb_document_id: 999_999 }
    assert_response :not_found
  end

  test "a card adds the manual and keeps the ones already selected" do
    first = focused_card("uploads/2026/focus-add-a.pdf", "Manual A")
    second = focused_card("uploads/2026/focus-add-b.pdf", "Manual B")
    post pinned_documents_path, params: card_params(first, "query:add"), as: :json
    post pinned_documents_path, params: card_params(second, "query:add", focus_mode: "add"), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["replay"]
    assert_equal [ first.id, second.id ].sort, body["focus_ids"].sort
    session = web_focus_session
    assert_equal [ first.id, second.id ].sort, session.focus_document_ids.sort
  end

  test "replace keeps only the accepted manual" do
    first = focused_card("uploads/2026/focus-replace-a.pdf", "Manual A")
    second = focused_card("uploads/2026/focus-replace-b.pdf", "Manual B")
    post pinned_documents_path, params: card_params(first, "query:replace"), as: :json
    post pinned_documents_path, params: card_params(second, "query:replace", focus_mode: "replace"), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["replay"]
    assert_equal [ second.id ], body["focus_ids"]
    assert_equal [ second.id ], web_focus_session.focus_document_ids
  end

  test "an unauthorized card does not change focus and does not ask for a replay" do
    selected = focused_card("uploads/2026/focus-keep.pdf", "Selected")
    post pinned_documents_path, params: card_params(selected, "query:deny"), as: :json
    foreign = KbDocument.create!(
      s3_key: "uploads/2026/focus-foreign.pdf",
      display_name: "Foreign",
      document_uid: SecureRandom.uuid,
      aliases: [],
      account: accounts(:climb)
    )

    post pinned_documents_path, params: card_params(foreign, "query:deny"), as: :json

    assert_response :not_found
    assert_equal [ selected.id ], web_focus_session.focus_document_ids
    assert_equal false, response.parsed_body.key?("replay")
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

  test "create pins a danebo_general document owned by another account" do
    owner = accounts(:legacy)
    owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(
      s3_key: "manuals/shared-general.pdf",
      display_name: "Shared general",
      aliases: [],
      account: owner
    )
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(
      kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )
    viewer = users(:two)
    host! "ascensoresclimb.localhost"
    sign_in viewer

    post pinned_documents_path, params: { kb_document_id: shared.id }

    assert_response :no_content
    session = ConversationSession.find_by!(identifier: viewer.id.to_s, channel: "web", account_id: viewer.account_id)
    assert_includes SessionContextBuilder.entity_s3_uris(session), shared.display_s3_uri(KbDocument::KB_BUCKET)
  end

  test "destroy unpins a danebo_general document owned by another account" do
    owner = accounts(:legacy)
    owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(
      s3_key: "manuals/shared-general-unpin.pdf",
      display_name: "Shared general",
      aliases: [],
      account: owner
    )
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(
      kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )
    viewer = users(:two)
    host! "ascensoresclimb.localhost"
    sign_in viewer
    post pinned_documents_path, params: { kb_document_id: shared.id }

    delete pinned_document_path(shared.id)

    assert_response :no_content
    session = ConversationSession.find_by!(identifier: viewer.id.to_s, channel: "web", account_id: viewer.account_id)
    assert_empty session.document_focus_entries
  end

  test "a revoked general pin can be removed and then cannot be retrieved" do
    owner = accounts(:legacy)
    owner.update!(danebo_controlled: true)
    shared = KbDocument.create!(
      s3_key: "manuals/revoked-unpin.pdf",
      display_name: "Revoked",
      aliases: [],
      account: owner
    )
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(
      kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )
    viewer = users(:two)
    host! "ascensoresclimb.localhost"
    sign_in viewer
    post pinned_documents_path, params: { kb_document_id: shared.id }
    assert_response :no_content
    KnowledgeScopeChange.apply!(
      kb_document: shared, to_scope: "tenant_private", actor: "ops", reason: "withdrawn"
    )

    delete pinned_document_path(shared.id)

    assert_response :no_content
    session = ConversationSession.find_by!(identifier: viewer.id.to_s, channel: "web", account_id: viewer.account_id)
    assert_empty session.document_focus_entries
    decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set(
      [ shared.canonical_uri ], viewer_account: viewer.account
    )
    assert decision.denied?
    assert_not Rag::KnowledgeScopePolicy.authorized?(shared.reload, viewer_account: viewer.account)
  end

  private

  def focused_card(key, name)
    KbDocument.create!(
      s3_key: key,
      display_name: name,
      document_uid: SecureRandom.uuid,
      aliases: [],
      account: @user.account
    )
  end

  def card_params(document, correlation_id, focus_mode: "add")
    {
      kb_document_id: document.id,
      document_uid: document.document_uid,
      correlation_id: correlation_id,
      focus_mode: focus_mode
    }
  end

  def web_focus_session
    ConversationSession.find_by!(identifier: @user.id.to_s, channel: "web", account_id: @user.account_id)
  end
end
