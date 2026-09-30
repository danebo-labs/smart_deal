# frozen_string_literal: true

require "test_helper"

class KnowledgeScopeChangeTest < ActiveSupport::TestCase
  setup do
    @owner = accounts(:legacy)
    @owner.update!(danebo_controlled: true)
    @document = KbDocument.create!(
      account: @owner,
      s3_key: "manuals/scope-change.pdf",
      display_name: "Scope change",
      aliases: []
    )
    index_manual_for_retrieval!(@document)
  end

  test "a new document is tenant_private and an existing row is not inferred general" do
    assert_equal "tenant_private", @document.knowledge_scope
    assert_equal 0, KbDocument.where.not(knowledge_scope: "tenant_private").where.not(id: @document.id).count
    assert_equal false, accounts(:climb).danebo_controlled
    assert_equal false, accounts(:pilot).danebo_controlled
  end

  test "apply approves and revoke writes a second audit row" do
    approved = KnowledgeScopeChange.apply!(
      kb_document: @document, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )
    revoked = KnowledgeScopeChange.apply!(
      kb_document: approved, to_scope: "tenant_private", actor: "ops", reason: "withdrawn"
    )

    assert_equal "tenant_private", revoked.reload.knowledge_scope
    changes = KnowledgeScopeChange.order(:id).pluck(:from_scope, :to_scope, :actor, :reason)
    assert_equal [
      [ "tenant_private", "danebo_general", "ops", "approved manual" ],
      [ "danebo_general", "tenant_private", "ops", "withdrawn" ]
    ], changes
  end

  test "a failed audit does not change scope and a failed update does not keep the audit" do
    assert_raises(ArgumentError) do
      KnowledgeScopeChange.apply!(kb_document: @document, to_scope: "danebo_general", actor: " ", reason: "approved manual")
    end
    assert_equal "tenant_private", @document.reload.knowledge_scope
    assert_equal 0, KnowledgeScopeChange.count

    original_create = KnowledgeScopeChange.method(:create!)
    KnowledgeScopeChange.define_singleton_method(:create!) { |*| raise ActiveRecord::RecordNotSaved, "audit failed" }
    begin
      assert_raises(ActiveRecord::RecordNotSaved) do
        KnowledgeScopeChange.apply!(
          kb_document: @document, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
        )
      end
    ensure
      KnowledgeScopeChange.define_singleton_method(:create!) { |*args, **kwargs| original_create.call(*args, **kwargs) }
    end
    assert_equal "tenant_private", @document.reload.knowledge_scope
    assert_equal 0, KnowledgeScopeChange.count

    @document.define_singleton_method(:update!) { |**| raise ActiveRecord::RecordInvalid.new(self) }
    begin
      assert_raises(ActiveRecord::RecordInvalid) do
        KnowledgeScopeChange.apply!(
          kb_document: @document, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
        )
      end
    ensure
      @document.singleton_class.remove_method(:update!)
    end
    assert_equal "tenant_private", @document.reload.knowledge_scope
    assert_equal 0, KnowledgeScopeChange.count
  end

  test "direct writes and audit mutation are rejected" do
    assert_not KbDocument.new(
      account: @owner, s3_key: "manuals/direct.pdf", aliases: [], knowledge_scope: "danebo_general"
    ).valid?

    assert_raises(ActiveRecord::RecordInvalid) do
      @document.update!(knowledge_scope: "danebo_general")
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      @document.update_columns(knowledge_scope: "danebo_general") # rubocop:disable Rails/SkipsModelValidations -- the assertion is that this write is rejected
    end
    assert_equal "tenant_private", @document.reload.knowledge_scope

    assert_raises(ActiveRecord::StatementInvalid) do
      KbDocument.transaction(requires_new: true) do
        KbDocument.connection.execute(
          "UPDATE kb_documents SET knowledge_scope = 'legacy' WHERE id = #{@document.id.to_i}"
        )
      end
    end
    assert_equal "tenant_private", @document.reload.knowledge_scope

    KnowledgeScopeChange.apply!(
      kb_document: @document, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )
    change = KnowledgeScopeChange.order(:id).last
    assert_raises(ActiveRecord::RecordNotSaved) do
      KnowledgeScopeChange.create!(
        kb_document: @document, from_scope: "tenant_private", to_scope: "danebo_general",
        actor: "intruder", reason: "forged"
      )
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      change.update!(reason: "tampered")
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      change.destroy!
    end
    assert_equal "approved manual", change.reload.reason
    assert_equal 1, KnowledgeScopeChange.where(kb_document: @document).count
  end

  test "blank actor, blank reason, and an unchanged scope do not write" do
    assert_raises(ArgumentError) do
      KnowledgeScopeChange.apply!(kb_document: @document, to_scope: "danebo_general", actor: "ops", reason: " ")
    end
    assert_raises(ArgumentError) do
      KnowledgeScopeChange.apply!(kb_document: @document, to_scope: "nope", actor: "ops", reason: "approved manual")
    end
    assert_raises(ArgumentError) do
      KnowledgeScopeChange.apply!(
        kb_document: @document, to_scope: "tenant_private", actor: "ops", reason: "same scope"
      )
    end
    assert_equal 0, KnowledgeScopeChange.count
  end
end
