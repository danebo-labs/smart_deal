# frozen_string_literal: true

require "test_helper"

class Rag::KnowledgeScopePolicyTest < ActiveSupport::TestCase
  setup do
    @owner = accounts(:legacy)
    @viewer = accounts(:climb)
    @private_doc = KbDocument.create!(
      account: @owner, s3_key: "manuals/private.pdf", display_name: "Private", aliases: []
    )
  end

  test "the owner is authorized and another account is not" do
    assert_equal "tenant_private", Rag::KnowledgeScopePolicy.scope_for(@private_doc, viewer_account: @owner)
    assert_nil Rag::KnowledgeScopePolicy.scope_for(@private_doc, viewer_account: @viewer)
    assert_equal({ @private_doc.id => "tenant_private" }, Rag::KnowledgeScopePolicy.scopes_for([ @private_doc ], viewer_account: @owner))
    assert_equal({ @private_doc.id => nil }, Rag::KnowledgeScopePolicy.scopes_for([ @private_doc ], viewer_account: @viewer))
  end

  test "danebo_general is authorized for another account without copying the row" do
    @owner.update!(danebo_controlled: true)
    index_manual_for_retrieval!(@private_doc)
    KnowledgeScopeChange.apply!(
      kb_document: @private_doc, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )

    assert_equal "danebo_general", Rag::KnowledgeScopePolicy.scope_for(@private_doc, viewer_account: @viewer)
    assert_equal "danebo_general", Rag::KnowledgeScopePolicy.scope_for(@private_doc, viewer_account: @owner)
    assert_equal 1, KbDocument.where(s3_key: @private_doc.s3_key).count
  end

  test "a uri is retrieval scope only when it binds to one authorized row" do
    uri = @private_doc.display_s3_uri(KbDocument::KB_BUCKET)

    assert_equal [ uri ], Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ uri ], viewer_account: @owner)
    assert_empty Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ uri ], viewer_account: @viewer)
    assert_empty Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ "s3://bucket/missing.pdf" ], viewer_account: @owner)

    KbDocument.create!(
      account: @viewer, s3_key: @private_doc.s3_key, display_name: "Collision", aliases: []
    )

    assert_empty Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ uri ], viewer_account: @owner)
  end

  test "a relative s3 key resolves the display uri for the owner only" do
    uri = "s3://#{KbDocument::KB_BUCKET}/manuals/private.pdf"

    assert_equal [ uri ], Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ uri ], viewer_account: @owner)
    assert_empty Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ uri ], viewer_account: @viewer)
  end

  test "manual_corpus and the legacy slug do not authorize another account" do
    assert_nil Rag::KnowledgeScopePolicy.scope_for(@private_doc, viewer_account: @viewer)
    assert_equal false, @owner.danebo_controlled
  end

  test "a relative key and its full KB uri are the same canonical object" do
    relative = @private_doc.s3_key
    full = @private_doc.canonical_uri

    assert_equal [ full ], Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ relative ], viewer_account: @owner)
    assert_equal [ full ], Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ full ], viewer_account: @owner)
    assert_empty Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ full ], viewer_account: @viewer)
  end

  test "the same object key in another bucket does not authorize the KB row" do
    other = "s3://other-bucket/#{@private_doc.s3_key}"

    assert_empty Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ other ], viewer_account: @owner)
    assert_equal [ @private_doc.canonical_uri ],
      Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ @private_doc.s3_key ], viewer_account: @owner)
  end

  test "two rows with the same canonical identity deny even the owner" do
    KbDocument.create!(
      account: @viewer,
      s3_key: @private_doc.canonical_uri,
      display_name: "Same object",
      aliases: []
    )
    decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set(
      [ @private_doc.s3_key ], viewer_account: @owner
    )

    assert decision.denied?
    assert_empty decision.uris
  end

  test "one denied uri denies the whole requested set" do
    own = KbDocument.create!(
      account: @viewer, s3_key: "manuals/viewer-set.pdf", display_name: "Viewer", aliases: []
    )
    decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set(
      [ own.canonical_uri, @private_doc.canonical_uri ], viewer_account: @viewer
    )

    assert decision.denied?
    assert_empty decision.uris
    assert_equal [ own.canonical_uri ],
      Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ own.canonical_uri ], viewer_account: @viewer)
  end
end
