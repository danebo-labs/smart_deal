# frozen_string_literal: true

require "test_helper"

class Rag::StructuredEvidenceRouteFlagTest < ActiveSupport::TestCase
  test "is disabled by default and enabled only by exact true" do
    with_flag(nil) { assert_not Rag::StructuredEvidenceRouteFlag.enabled? }
    with_flag("true") { assert Rag::StructuredEvidenceRouteFlag.enabled? }
    with_flag("false") { assert_not Rag::StructuredEvidenceRouteFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    value.nil? ? ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED") : ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = value
    yield
  ensure
    original.nil? ? ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED") : ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = original
  end
end
