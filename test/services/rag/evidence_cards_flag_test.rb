# frozen_string_literal: true

require "test_helper"

class Rag::EvidenceCardsFlagTest < ActiveSupport::TestCase
  test "is disabled by default" do
    with_flag(nil) { assert_not Rag::EvidenceCardsFlag.enabled? }
  end

  test "is enabled only by the exact true value" do
    with_flag("true") { assert Rag::EvidenceCardsFlag.enabled? }
    with_flag("false") { assert_not Rag::EvidenceCardsFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("RAG_EVIDENCE_CARDS_ENABLED", nil)
    value.nil? ? ENV.delete("RAG_EVIDENCE_CARDS_ENABLED") : ENV["RAG_EVIDENCE_CARDS_ENABLED"] = value
    yield
  ensure
    original.nil? ? ENV.delete("RAG_EVIDENCE_CARDS_ENABLED") : ENV["RAG_EVIDENCE_CARDS_ENABLED"] = original
  end
end
