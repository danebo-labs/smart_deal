# frozen_string_literal: true

require "test_helper"

class Rag::PartialAbstentionContractFlagTest < ActiveSupport::TestCase
  test "is disabled by default and enabled only by exact true" do
    with_flag(nil) { assert_not Rag::PartialAbstentionContractFlag.enabled? }
    with_flag("true") { assert Rag::PartialAbstentionContractFlag.enabled? }
    with_flag("false") { assert_not Rag::PartialAbstentionContractFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil)
    if value.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = original
    end
  end
end
