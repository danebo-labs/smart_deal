# frozen_string_literal: true

require "test_helper"

class Rag::DocumentIdentityCatalogTenantTest < ActiveSupport::TestCase
  setup do
    @owner = accounts(:legacy)
    @other = accounts(:climb)
    @private_uid = SecureRandom.uuid
    @private_key = "manuals/#{@private_uid}.pdf"
    @private_doc = KbDocument.create!(
      account: @owner,
      s3_key: @private_key,
      display_name: "Private controller",
      document_uid: @private_uid,
      aliases: []
    )
    @catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        entry(@owner, @private_uid, @private_key, "SecretCo", "PRIVATE900", "controller")
      ]
    })
  end

  test "a private designator is unresolved for a tenant that cannot read the document" do
    resolution = @catalog.resolve_designator("PRIVATE900", viewer_account: @other)

    assert_equal :none, resolution.status
    assert_nil resolution.value
    assert_nil resolution.type
    assert_nil resolution.manufacturer
    assert_empty resolution.candidates
  end

  test "the owning tenant resolves its private designator and manufacturer" do
    resolution = @catalog.resolve_designator("PRIVATE900", viewer_account: @owner)

    assert_equal :exact, resolution.status
    assert_equal "PRIVATE900", resolution.value
    assert_equal "controller", resolution.type
    assert_equal "SecretCo", resolution.manufacturer
  end

  test "a private brand does not leak to another tenant" do
    resolution = @catalog.resolve_brand("SecretCo", viewer_account: @other)

    assert_equal :none, resolution.status
    assert_nil resolution.manufacturer
    assert_empty resolution.candidates
  end

  test "the owning tenant resolves its private brand" do
    resolution = @catalog.resolve_brand("SecretCo", viewer_account: @owner)

    assert_equal :exact, resolution.status
    assert_equal "SecretCo", resolution.manufacturer
  end

  test "an authorized general designator resolves for another tenant" do
    @owner.update!(danebo_controlled: true)
    index_manual_for_retrieval!(@private_doc)
    KnowledgeScopeChange.apply!(
      kb_document: @private_doc, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )

    resolution = @catalog.resolve_designator("PRIVATE900", viewer_account: @other)

    assert_equal :exact, resolution.status
    assert_equal "controller", resolution.type
    assert_equal "SecretCo", resolution.manufacturer
  end

  test "an authorized general brand resolves for another tenant" do
    @owner.update!(danebo_controlled: true)
    index_manual_for_retrieval!(@private_doc)
    KnowledgeScopeChange.apply!(
      kb_document: @private_doc, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )

    resolution = @catalog.resolve_brand("secretco", viewer_account: @other)

    assert_equal :exact, resolution.status
    assert_equal "SecretCo", resolution.manufacturer
  end

  test "unauthorized prefix candidates are not returned" do
    second_uid = SecureRandom.uuid
    second_key = "manuals/#{second_uid}.pdf"
    KbDocument.create!(
      account: @owner, s3_key: second_key, display_name: "Private longer", document_uid: second_uid, aliases: []
    )
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        entry(@owner, @private_uid, @private_key, "SecretCo", "PRIVATE900", "controller"),
        entry(@owner, second_uid, second_key, "SecretCo", "PRIVATE900X", "controller")
      ]
    })

    resolution = catalog.resolve_designator("PRIVATE9", viewer_account: @other)

    assert_equal :none, resolution.status
    assert_empty resolution.candidates
    assert_nil resolution.manufacturer
  end

  test "the unscoped lookup still resolves a yaml designator for the legacy caller" do
    resolution = Rag::DocumentIdentityCatalog.current.resolve_designator("NICE3000")

    assert_equal :exact, resolution.status
    assert_equal "controller", resolution.type
    assert_equal "MONARCH", resolution.manufacturer
  end

  private

  def entry(account, uid, key, brand, designator, type)
    {
      "account_id" => account.id.to_s,
      "document_id" => uid,
      "s3_key" => key,
      "display_name" => designator,
      "brands" => [ brand ],
      "designators" => [ { "value" => designator, "type" => type } ],
      "generic" => false,
      "confirmed" => true
    }
  end
end
