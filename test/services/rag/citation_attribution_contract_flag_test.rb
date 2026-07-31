# frozen_string_literal: true

require "test_helper"

class Rag::CitationAttributionContractFlagTest < ActiveSupport::TestCase
  test "is enabled only by the exact true string" do
    with_flag(nil) { assert_not Rag::CitationAttributionContractFlag.enabled? }
    with_flag("true") { assert Rag::CitationAttributionContractFlag.enabled? }
    with_flag("TRUE") { assert_not Rag::CitationAttributionContractFlag.enabled? }
    with_flag("1") { assert_not Rag::CitationAttributionContractFlag.enabled? }
    with_flag("") { assert_not Rag::CitationAttributionContractFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED", nil)
    if value.nil?
      ENV.delete("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED")
    else
      ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED")
    else
      ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = original
    end
  end
end
