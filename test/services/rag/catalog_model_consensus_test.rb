# frozen_string_literal: true

require "test_helper"

class Rag::CatalogModelConsensusTest < ActiveSupport::TestCase
  test "MonoSpace manuals collapse to one designator and MiniSpace does too" do
    catalog = Rag::DocumentIdentityCatalog.load

    mono = consensus_for(catalog, "MonoSpace")
    assert_equal "MonoSpace", mono["model"]
    assert_equal "KONE", mono["manufacturer"]

    mini = consensus_for(catalog, "MiniSpace")
    assert_equal "MiniSpace", mini["model"]
    assert_equal "KONE", mini["manufacturer"]
  end

  test "two designators for one span stay ambiguous and an unknown span does not" do
    catalog = Rag::DocumentIdentityCatalog.new({ "documents" => [
      row("a", "Shared X model A", %w[ModelA]),
      row("b", "Shared X model B", %w[ModelB])
    ] })
    assert_equal true, Rag::DocumentIdentityCatalog.consensus(catalog.entries, "X")["ambiguous"]
    assert_nil Rag::DocumentIdentityCatalog.consensus([], "ZzzUnknown99")
  end

  private

  def consensus_for(catalog, span)
    entries = catalog.entries.select do |entry|
      entry.display_name.match?(/\b#{Regexp.escape(span)}\b/i) ||
        entry.designators.any? { |item| item.casecmp?(span) }
    end
    assert entries.size > 1, span
    Rag::DocumentIdentityCatalog.consensus(entries, span)
  end

  def row(key, name, designators)
    {
      "account_id" => "3",
      "document_id" => key,
      "s3_key" => "#{key}.pdf",
      "display_name" => name,
      "designators" => designators,
      "brands" => [ "KONE" ]
    }
  end
end
