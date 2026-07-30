# frozen_string_literal: true

require "test_helper"

class Rag::EvidenceExpansionFlagTest < ActiveSupport::TestCase
  test "is disabled by default and enabled only by exact true" do
    with_flag(nil) { assert_not Rag::EvidenceExpansionFlag.enabled? }
    with_flag("true") { assert Rag::EvidenceExpansionFlag.enabled? }
    with_flag("false") { assert_not Rag::EvidenceExpansionFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("RAG_EVIDENCE_EXPANSION_ENABLED", nil)
    value.nil? ? ENV.delete("RAG_EVIDENCE_EXPANSION_ENABLED") : ENV["RAG_EVIDENCE_EXPANSION_ENABLED"] = value
    yield
  ensure
    original.nil? ? ENV.delete("RAG_EVIDENCE_EXPANSION_ENABLED") : ENV["RAG_EVIDENCE_EXPANSION_ENABLED"] = original
  end
end
