# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/field_companion/discovery_score")

class Rag::ManualCandidateRankerTest < ActiveSupport::TestCase
  Ranker = Rag::ManualCandidateRanker
  SCORE_PATH = Rails.root.join("tmp/field_companion/f0_discovery.json")
  ELIGIBLE_PATH = Rails.root.join("tmp/field_companion/f0_discovery_eligible.json")
  SCORE_SHA = "0119f27bd05a86efe5371008bd1886f9791bf5d427eea1364682adad9b9e5ee0"
  ELIGIBLE_SHA = "47efb001265ee5985fd33cee156054acd81b9fad8736e111ac4291914cbeff36"

  test "pre-scope ranking matches the frozen F0 score artifact" do
    artifact = load_artifact(SCORE_PATH, SCORE_SHA)
    catalog = Rag::DocumentIdentityCatalog.load

    %w[fixture holdout].each do |set_name|
      artifact.dig(set_name, "phrases").each do |phrase|
        result = Ranker.score(phrase["text"], catalog.entries)

        assert_equal phrase["document_ids"], result.candidates.map(&:document_id), phrase["text"]
        assert_equal phrase["labels"], result.candidates.map(&:label), phrase["text"]
        assert_equal phrase["scores"], result.candidates.map(&:score), phrase["text"]
        assert_equal phrase["tie_at_top"], result.tie_at_top, phrase["text"]
        assert_optional phrase["reason"], result.reason, phrase["text"]
        assert_optional phrase["manufacturer"], result.manufacturer, phrase["text"]
        assert_equal phrase["model_tokens"], result.model_tokens, phrase["text"]
      end
    end
  end

  test "runtime score matches DiscoveryScore before the scope filter" do
    entries = [
      row("exact", "Manual ZX9", [ "Otis" ], designators: [ "ZX9" ], confirmed: true, evidence_page: 1, evidence_text: "OTIS"),
      row("brand", "Manual Otis", [ "Otis" ]),
      row("other", "Manual Schindler", [ "Schindler" ])
    ]
    phrases = [
      "Otis modelo ZX9",
      "Otis modelo ZX-9",
      "Estoy en un OTIS y tengo este problema.",
      "Tengo un problema en la puerta.",
      "Schindler y OTIS en el mismo hueco."
    ]

    phrases.each do |text|
      original = FieldCompanion::DiscoveryScore.rank(text, entries)
      runtime = Ranker.score(text, entries)

      assert_equal original.candidates.map(&:document_id), runtime.candidates.map(&:document_id), text
      assert_equal original.candidates.map(&:score), runtime.candidates.map(&:score), text
      assert_equal original.candidates.map(&:label), runtime.candidates.map(&:label), text
      assert_equal original.tie_at_top, runtime.tie_at_top, text
      assert_optional original.reason, runtime.reason, text
    end
  end

  test "a non-owner with zero general approvals receives none of the technical ranking" do
    eligible = load_artifact(ELIGIBLE_PATH, ELIGIBLE_SHA)
    technical = load_artifact(SCORE_PATH, SCORE_SHA)
    catalog = Rag::DocumentIdentityCatalog.load

    assert_equal "5", eligible.dig("viewer", "account_id")
    assert_equal "elevadores-climb", eligible.dig("viewer", "account_slug")
    assert_equal 0, eligible["general_approved_count"]

    eligible.dig("fixture", "phrases").each do |phrase|
      suggestion = Ranker.suggest(phrase["text"], catalog.entries, viewer_account_id: "5")
      technical_phrase = technical.dig("fixture", "phrases").find { |row| row["text"] == phrase["text"] }

      assert_equal phrase["document_ids"], suggestion.cards.map(&:document_uid), phrase["text"]
      assert_empty suggestion.cards.map(&:document_uid) & technical_phrase["document_ids"]
      assert suggestion.cards.none? { |card| card.knowledge_scope == "danebo_general" }
    end
  end

  test "a private document from another account does not enter" do
    suggestion = Ranker.suggest("Otis", [
      row("foreign", "Manual Otis", [ "Otis" ], owner_account_id: "4", classification: "PRIVATE")
    ], viewer_account_id: "5")

    assert_empty suggestion.cards
    assert_equal Ranker::EMPTY_TEXT, suggestion.chat_payload[:message]
    assert_nil suggestion.selected_document_uid
  end

  test "an unclassified legacy or pilot document does not enter for another tenant" do
    entries = [
      row("legacy-index", "Manual Legacy", [ "Otis" ], account_id: "1", classification: "UNCLASSIFIED"),
      row("pilot-index", "Manual Pilot", [ "Otis" ], account_id: "3"),
      row("legacy-row", "Manual Fila", [ "Otis" ], owner_account_id: "4", classification: "UNCLASSIFIED")
    ]

    suggestion = Ranker.suggest("Otis", entries, viewer_account_id: "5")

    assert_empty suggestion.cards
    assert suggestion.cards.none? { |card| card.knowledge_scope == "danebo_general" }
  end

  test "an explicit general approval enters in score order with the general library text" do
    text = "Otis modelo ZX9"
    entries = [
      row("foreign-exact", "AAA", [ "Otis" ], designators: [ "ZX9" ], owner_account_id: "4", classification: "PRIVATE"),
      row("general-brand", "BBB", [ "Otis" ], owner_account_id: "4", classification: "GENERAL_APPROVED"),
      row("own-exact", "CCC", [ "Otis" ], designators: [ "ZX9" ], owner_account_id: "5", classification: "UNCLASSIFIED")
    ]
    scored = Ranker.score(text, entries)
    suggestion = Ranker.suggest(text, entries, viewer_account_id: "5")

    assert_equal [ "own-exact", "general-brand" ], suggestion.cards.map(&:document_uid)
    assert_equal [ 180, 100 ], suggestion.cards.map(&:score)
    assert_equal scored.candidates.select { |candidate| suggestion.cards.map(&:document_uid).include?(candidate.document_id) }.map(&:score),
      suggestion.cards.map(&:score)
    assert_equal [ "EXACT_DESIGNATOR", "BRAND_ONLY" ], suggestion.cards.map(&:label)
    assert_equal Ranker::EXACT_DESIGNATOR_TEXT, suggestion.cards.first.text
    assert_equal Ranker::BRAND_ONLY_TEXT, suggestion.cards.last.text
    assert_equal [ "tenant_private", "danebo_general" ], suggestion.cards.map(&:knowledge_scope)
    assert_equal Ranker::PRIVATE_PROVENANCE, suggestion.cards.first.provenance
    assert_equal Ranker::GENERAL_PROVENANCE, suggestion.cards.last.provenance
    assert_nil suggestion.selected_document_uid
  end

  test "attaching scope does not change section 5 points" do
    text = "Otis modelo ZX9"
    base = row("d", "Manual ZX9", [ "Otis" ], designators: [ "ZX9" ], confirmed: true, evidence_page: 1, evidence_text: "OTIS")
    plain = Ranker.score(text, [ base ])
    scoped = Ranker.score(text, [
      base.merge(knowledge_scope: "danebo_general", classification: "GENERAL_APPROVED", manual_corpus: "general")
    ])

    assert_equal plain.candidates.map(&:score), scoped.candidates.map(&:score)
    assert_equal plain.candidates.map(&:label), scoped.candidates.map(&:label)
    assert_equal [ 220 ], plain.candidates.map(&:score)
  end

  test "approval is not inferred from corpus, catalog account, filename, or scope" do
    suggestion = Ranker.suggest("Otis", [
      row(
        "inferred",
        "Manual Otis",
        [ "Otis" ],
        account_id: "1",
        s3_key: "legacy/otis.pdf",
        knowledge_scope: "danebo_general",
        manual_corpus: "general"
      )
    ], viewer_account_id: "5")

    assert_empty suggestion.cards
  end

  test "tie_at_top shows up to three cards and does not choose one" do
    entries = 4.times.map { |index|
      row("id-#{index}", "Manual #{index}", [ "Otis" ], owner_account_id: "5", classification: "UNCLASSIFIED")
    }
    suggestion = Ranker.suggest("Otis", entries, viewer_account_id: "5")

    assert_equal 3, suggestion.cards.size
    assert_equal true, suggestion.tie_at_top
    assert_nil suggestion.selected_document_uid
    assert_nil suggestion.chat_payload[:selected_document_uid]
    assert_equal [ 100, 100, 100 ], suggestion.cards.map(&:score)
  end

  test "scope does not backfill past the scored top three" do
    entries = [
      row("blocked", "AAA", [ "Otis" ], owner_account_id: "4", classification: "PRIVATE"),
      row("kept-b", "BBB", [ "Otis" ], owner_account_id: "5", classification: "UNCLASSIFIED"),
      row("kept-c", "CCC", [ "Otis" ], owner_account_id: "5", classification: "UNCLASSIFIED"),
      row("not-backfilled", "ZZZ", [ "Otis" ], owner_account_id: "5", classification: "UNCLASSIFIED")
    ]
    suggestion = Ranker.suggest("Otis", entries, viewer_account_id: "5")

    assert_equal [ "kept-b", "kept-c" ], suggestion.cards.map(&:document_uid)
  end

  test "a symptom without a recognized manufacturer builds no cards and does not retrieve" do
    lookup_called = false
    suggestion = nil
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*_args, **_kwargs| flunk "discovery must not retrieve" }
    begin
      suggestion = Ranker.suggest(
        "Tengo un problema en la puerta.",
        [ row("otis", "Manual Otis", [ "Otis" ], owner_account_id: "5") ],
        viewer_account_id: "5",
        owner_lookup: lambda { |_uids|
          lookup_called = true
          flunk "discovery must not look up documents"
        }
      )
    ensure
      BedrockRagService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
    end

    assert_empty suggestion.cards
    assert_equal "no_manufacturer", suggestion.reason
    assert_equal false, suggestion.tie_at_top
    assert_equal Ranker::EMPTY_TEXT, suggestion.message
    assert_nil suggestion.chat_payload
    assert_nil suggestion.selected_document_uid
    assert_equal false, lookup_called
  end

  test "more than one manufacturer returns the frozen empty text and no cards" do
    suggestion = Ranker.suggest(
      "Schindler y OTIS en el mismo hueco.",
      [
        row("otis", "Manual Otis", [ "Otis" ], owner_account_id: "5"),
        row("schindler", "Manual Schindler", [ "Schindler" ], owner_account_id: "5")
      ],
      viewer_account_id: "5"
    )

    assert_empty suggestion.cards
    assert_equal "multiple_manufacturers", suggestion.reason
    assert_equal Ranker::EMPTY_TEXT, suggestion.chat_payload[:message]
    assert_nil suggestion.chat_payload[:selected_document_uid]
    assert_equal false, suggestion.tie_at_top
  end

  private

  def assert_optional(expected, actual, message)
    if expected.nil?
      assert_nil actual, message
    else
      assert_equal expected, actual, message
    end
  end

  def load_artifact(path, expected_sha)
    skip "F0 artifact #{path.basename} is local-only under tmp/" unless File.file?(path)

    digest = Digest::SHA256.file(path).hexdigest
    assert_equal expected_sha, digest, path.basename
    JSON.parse(File.read(path))
  end

  def row(document_id, display_name, brands, designators: [], owner_account_id: nil, classification: nil, **extra)
    {
      document_id: document_id,
      display_name: display_name,
      brands: brands,
      designators: designators,
      owner_account_id: owner_account_id,
      classification: classification
    }.merge(extra)
  end
end
