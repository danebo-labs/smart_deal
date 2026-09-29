# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/field_companion/discovery_score")

class FieldCompanionDiscoveryScoreTest < ActiveSupport::TestCase
  Score = FieldCompanion::DiscoveryScore

  test "correct brand wins and another brand does not enter" do
    result = Score.rank("Estoy en un OTIS y tengo este problema.", [
      row("schindler-doc", "Manual Schindler", [ "Schindler" ]),
      row("otis-doc", "Manual Otis", [ "Otis" ])
    ])

    assert_nil result.reason
    assert_equal [ "otis-doc" ], result.candidates.map(&:document_id)
    assert_equal [ "BRAND_ONLY" ], result.candidates.map(&:label)
    assert_equal 100, result.candidates.first.score
    assert_equal false, result.tie_at_top
  end

  test "exact designator adds 80 and ranks above brand only" do
    result = Score.rank("Otis modelo ZX9", [
      row("brand-only", "Manual Otis", [ "Otis" ]),
      row("exact", "Manual ZX9", [ "OTIS" ], designators: [ "ZX9" ])
    ])

    assert_equal [ "exact", "brand-only" ], result.candidates.map(&:document_id)
    assert_equal 180, result.candidates.first.score
    assert_equal "EXACT_DESIGNATOR", result.candidates.first.label
    assert_equal 100, result.candidates.last.score
    assert_equal "BRAND_ONLY", result.candidates.last.label
  end

  test "equal scores set tie_at_top and order by normalized display name" do
    result = Score.rank("Otis", [
      row("b", "Beta", [ "Otis" ]),
      row("a", "Alpha", [ "Otis" ])
    ])

    assert_equal [ "a", "b" ], result.candidates.map(&:document_id)
    assert_equal true, result.tie_at_top
    assert_equal [ 100, 100 ], result.candidates.map(&:score)
  end

  test "zero manufacturers returns an empty list" do
    result = Score.rank("Tengo un problema en la puerta.", [
      row("otis-doc", "Manual Otis", [ "Otis" ])
    ])

    assert_empty result.candidates
    assert_equal "no_manufacturer", result.reason
    assert_equal false, result.tie_at_top
  end

  test "two manufacturers return multiple_manufacturers" do
    result = Score.rank("Schindler y OTIS en el mismo hueco.", [
      row("otis-doc", "Manual Otis", [ "Otis" ]),
      row("schindler-doc", "Manual Schindler", [ "Schindler" ])
    ])

    assert_empty result.candidates
    assert_equal "multiple_manufacturers", result.reason
    assert_nil result.manufacturer
  end

  test "the same entry keeps its score when knowledge_scope changes" do
    text = "Otis modelo ZX9"
    private_entry = row("d", "Manual ZX9", [ "Otis" ], designators: [ "ZX9" ], knowledge_scope: "tenant_private")
    general_entry = row("d", "Manual ZX9", [ "Otis" ], designators: [ "ZX9" ], knowledge_scope: "danebo_general")

    left = Score.rank(text, [ private_entry ])
    right = Score.rank(text, [ general_entry ])

    assert_equal left.candidates.map(&:score), right.candidates.map(&:score)
    assert_equal left.candidates.map(&:label), right.candidates.map(&:label)
    assert_equal left.candidates.map(&:document_id), right.candidates.map(&:document_id)
  end

  test "yaml confirmed true without evidence_text is not catalog_confirmed and does not add 40" do
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        {
          "account_id" => "9",
          "document_id" => "doc-yaml",
          "display_name" => "Sin evidencia",
          "brands" => [ "Otis" ],
          "confirmed" => true
        }
      ]
    })
    entry = catalog.entries.first

    assert_equal true, entry.confirmed
    assert_nil entry.evidence_text
    assert_equal false, Rag::DocumentIdentityCatalog.effectively_confirmed?(entry)

    result = Score.rank("Otis", [ entry ])
    assert_equal 100, result.candidates.first.score
    assert_equal "BRAND_ONLY", result.candidates.first.label
  end

  test "effectively confirmed evidence adds 40" do
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        {
          "account_id" => "9",
          "document_id" => "doc-evidence",
          "display_name" => "Con evidencia",
          "brands" => [ "Otis" ],
          "confirmed" => true,
          "evidence_page" => 1,
          "evidence_text" => "OTIS"
        }
      ]
    })
    entry = catalog.entries.first

    assert_equal true, Rag::DocumentIdentityCatalog.effectively_confirmed?(entry)
    result = Score.rank("Otis", [ entry ])
    assert_equal 140, result.candidates.first.score
  end

  test "a hyphenated model capture matches the normalized designator" do
    result = Score.rank("Otis modelo ZX-9", [
      row("exact", "Manual ZX-9", [ "Otis" ], designators: [ "ZX-9" ])
    ])

    assert_equal 180, result.candidates.first.score
    assert_equal "EXACT_DESIGNATOR", result.candidates.first.label
    assert_equal [ "zx 9" ], result.model_tokens
  end

  test "at most three candidates are returned" do
    entries = 4.times.map { |index| row("id-#{index}", "Manual #{index}", [ "Otis" ]) }
    result = Score.rank("Otis", entries)

    assert_equal 3, result.candidates.size
  end

  private

  def row(document_id, display_name, brands, designators: [], knowledge_scope: nil)
    payload = {
      document_id: document_id,
      display_name: display_name,
      brands: brands,
      designators: designators
    }
    payload[:knowledge_scope] = knowledge_scope if knowledge_scope
    payload
  end
end
