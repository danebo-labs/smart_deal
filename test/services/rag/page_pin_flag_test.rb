# frozen_string_literal: true

require "test_helper"

class Rag::PagePinFlagTest < ActiveSupport::TestCase
  test "is disabled by default and enabled only by exact true" do
    with_flag(nil) { assert_not Rag::PagePinFlag.enabled? }
    with_flag("true") { assert Rag::PagePinFlag.enabled? }
    with_flag("false") { assert_not Rag::PagePinFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("RAG_PAGE_PIN_ENABLED", nil)
    value.nil? ? ENV.delete("RAG_PAGE_PIN_ENABLED") : ENV["RAG_PAGE_PIN_ENABLED"] = value
    yield
  ensure
    original.nil? ? ENV.delete("RAG_PAGE_PIN_ENABLED") : ENV["RAG_PAGE_PIN_ENABLED"] = original
  end
end
