# frozen_string_literal: true

require "test_helper"

class Rag::AutoScopeFlagTest < ActiveSupport::TestCase
  test "is enabled by default and disabled only by exact false" do
    with_flag(nil) { assert Rag::AutoScopeFlag.enabled? }
    with_flag("false") { assert_not Rag::AutoScopeFlag.enabled? }
    with_flag("true") { assert Rag::AutoScopeFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("RAG_AUTO_SCOPE_ENABLED", nil)
    value.nil? ? ENV.delete("RAG_AUTO_SCOPE_ENABLED") : ENV["RAG_AUTO_SCOPE_ENABLED"] = value
    yield
  ensure
    original.nil? ? ENV.delete("RAG_AUTO_SCOPE_ENABLED") : ENV["RAG_AUTO_SCOPE_ENABLED"] = original
  end
end
