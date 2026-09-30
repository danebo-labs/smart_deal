# frozen_string_literal: true

# Append-only record of a knowledge_scope transition.
# The rows do not grant access. The current scope is kb_documents.knowledge_scope.
# apply! is the only writer of both this table and that column.
class KnowledgeScopeChange < ApplicationRecord
  belongs_to :kb_document

  validates :from_scope, :to_scope, inclusion: { in: ->(_) { KbDocument::KNOWLEDGE_SCOPES } }
  validates :actor, :reason, presence: true

  before_create :require_apply
  before_update :reject_mutation
  before_destroy :reject_mutation

  def self.applying?
    Thread.current[:knowledge_scope_applying] == true
  end

  # lock → validate → audit insert → scope update → commit.
  # A failed audit leaves the scope unchanged. A failed update rolls the audit back.
  # actor is an operator label. It is not an authentication check.
  def self.apply!(kb_document:, to_scope:, actor:, reason:)
    document = kb_document.is_a?(KbDocument) ? kb_document : KbDocument.find(kb_document)
    raise ArgumentError, "kb_document must be persisted" unless document.persisted?

    to_scope = to_scope.to_s
    actor = actor.to_s.strip
    reason = reason.to_s.strip
    raise ArgumentError, "actor is required" if actor.blank?
    raise ArgumentError, "reason is required" if reason.blank?
    unless KbDocument::KNOWLEDGE_SCOPES.include?(to_scope)
      raise ArgumentError, "unknown knowledge_scope"
    end

    document.with_lock do
      from_scope = document.knowledge_scope
      raise ArgumentError, "knowledge_scope is unchanged" if from_scope == to_scope

      if to_scope == KbDocument::KNOWLEDGE_SCOPE_GENERAL
        blocked = KnowledgeScopeEligibility.blocking_reasons(document)
        raise KnowledgeScopeEligibility::Denied, blocked if blocked.any?
      elsif from_scope != KbDocument::KNOWLEDGE_SCOPE_GENERAL
        raise ArgumentError, "invalid knowledge_scope transition"
      end

      transaction do
        with_authority do
          create!(
            kb_document: document,
            from_scope: from_scope,
            to_scope: to_scope,
            actor: actor,
            reason: reason
          )
          document.update!(knowledge_scope: to_scope)
        end
      end
      document
    end
  end

  def self.with_authority
    previous = Thread.current[:knowledge_scope_applying]
    Thread.current[:knowledge_scope_applying] = true
    yield
  ensure
    Thread.current[:knowledge_scope_applying] = previous
  end
  private_class_method :with_authority

  def update_columns(_attributes)
    raise ActiveRecord::ReadOnlyRecord, "knowledge_scope_changes is append-only"
  end

  private

  def require_apply
    return if self.class.applying?

    errors.add(:base, "append through KnowledgeScopeChange.apply!")
    throw :abort
  end

  def reject_mutation
    raise ActiveRecord::ReadOnlyRecord, "knowledge_scope_changes is append-only"
  end
end
