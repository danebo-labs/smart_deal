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
    viewer = accounts(:climb)
    owner = accounts(:legacy)
    owner.update!(danebo_controlled: true)
    foreign_uid = SecureRandom.uuid
    general_uid = SecureRandom.uuid
    own_uid = SecureRandom.uuid
    KbDocument.create!(account: owner, document_uid: foreign_uid, s3_key: "manuals/foreign-exact.pdf", display_name: "AAA", aliases: [])
    general = KbDocument.create!(account: owner, document_uid: general_uid, s3_key: "manuals/general-brand.pdf", display_name: "BBB", aliases: [])
    index_manual_for_retrieval!(general)
    KnowledgeScopeChange.apply!(kb_document: general, to_scope: "danebo_general", actor: "ops", reason: "approved manual")
    KbDocument.create!(account: viewer, document_uid: own_uid, s3_key: "manuals/own-exact.pdf", display_name: "CCC", aliases: [])
    entries = [
      row(foreign_uid, "AAA", [ "Otis" ], designators: [ "ZX9" ], owner_account_id: "4", classification: "PRIVATE", s3_key: "manuals/foreign-exact.pdf"),
      row(general_uid, "BBB", [ "Otis" ], owner_account_id: "4", classification: "GENERAL_APPROVED", s3_key: "manuals/general-brand.pdf"),
      row(own_uid, "CCC", [ "Otis" ], designators: [ "ZX9" ], owner_account_id: "5", classification: "UNCLASSIFIED", s3_key: "manuals/own-exact.pdf")
    ]
    scored = Ranker.score(text, entries)
    suggestion = Ranker.suggest(text, entries, viewer_account: viewer, documents_for: method(:suggestion_documents))

    assert_equal [ own_uid, general_uid ], suggestion.cards.map(&:document_uid)
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
    viewer = accounts(:climb)
    entries = 4.times.map { |index|
      uid = SecureRandom.uuid
      KbDocument.create!(account: viewer, document_uid: uid, s3_key: "manuals/#{uid}.pdf", display_name: "Manual #{index}", aliases: [])
      row(uid, "Manual #{index}", [ "Otis" ], owner_account_id: viewer.id.to_s, classification: "UNCLASSIFIED", s3_key: "manuals/#{uid}.pdf")
    }
    suggestion = Ranker.suggest("Otis", entries, viewer_account: viewer, documents_for: method(:suggestion_documents))

    assert_equal 3, suggestion.cards.size
    assert_equal true, suggestion.tie_at_top
    assert_nil suggestion.selected_document_uid
    assert_nil suggestion.chat_payload[:selected_document_uid]
    assert_equal [ 100, 100, 100 ], suggestion.cards.map(&:score)
  end

  test "scope does not backfill past the scored top three" do
    viewer = accounts(:climb)
    foreign = accounts(:legacy)
    uids = {}
    [
      [ "blocked", "AAA", foreign ],
      [ "kept-b", "BBB", viewer ],
      [ "kept-c", "CCC", viewer ],
      [ "not-backfilled", "ZZZ", viewer ]
    ].each do |key, name, account|
      uids[key] = SecureRandom.uuid
      KbDocument.create!(account: account, document_uid: uids[key], s3_key: "manuals/#{key}.pdf", display_name: name, aliases: [])
    end
    entries = [
      row(uids["blocked"], "AAA", [ "Otis" ], owner_account_id: "4", classification: "PRIVATE", s3_key: "manuals/blocked.pdf"),
      row(uids["kept-b"], "BBB", [ "Otis" ], owner_account_id: "5", classification: "UNCLASSIFIED", s3_key: "manuals/kept-b.pdf"),
      row(uids["kept-c"], "CCC", [ "Otis" ], owner_account_id: "5", classification: "UNCLASSIFIED", s3_key: "manuals/kept-c.pdf"),
      row(uids["not-backfilled"], "ZZZ", [ "Otis" ], owner_account_id: "5", classification: "UNCLASSIFIED", s3_key: "manuals/not-backfilled.pdf")
    ]
    suggestion = Ranker.suggest("Otis", entries, viewer_account: viewer, documents_for: method(:suggestion_documents))

    assert_equal [ uids["kept-b"], uids["kept-c"] ], suggestion.cards.map(&:document_uid)
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
        documents_for: lambda { |_uids|
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

  test "the same document_uid resolves each physical catalog row" do
    viewer = accounts(:climb)
    owner = accounts(:legacy)
    owner.update!(danebo_controlled: true)
    uid = SecureRandom.uuid
    general = KbDocument.create!(account: owner, document_uid: uid, s3_key: "manuals/a-general.pdf", display_name: "Manual A", aliases: [])
    index_manual_for_retrieval!(general)
    KnowledgeScopeChange.apply!(kb_document: general, to_scope: "danebo_general", actor: "ops", reason: "approved manual")
    private_row = KbDocument.create!(account: viewer, document_uid: uid, s3_key: "manuals/b-private.pdf", display_name: "Manual B", aliases: [])
    entries = [
      row(uid, "Manual A", [ "Otis" ], s3_key: general.s3_key, account_id: "1"),
      row(uid, "Manual B", [ "Otis" ], s3_key: private_row.s3_key, account_id: viewer.id.to_s)
    ]

    rows = suggestion_documents(Ranker.score("Otis", entries).candidates)
    bound = entries.map { |entry|
      Rag::KnowledgeScopePolicy.bind_catalog_candidate(entry, rows: rows, viewer_account: viewer)
    }

    suggestion = Ranker.suggest("Otis", entries, viewer_account: viewer, documents_for: method(:suggestion_documents))

    assert_equal [ general, private_row ], bound
    assert_equal [ [ "Manual A", "danebo_general" ], [ "Manual B", "tenant_private" ] ],
      suggestion.cards.map { |card| [ card.display_name, card.knowledge_scope ] }.sort
  end

  test "two general rows that share a document_uid stay distinct" do
    viewer = accounts(:climb)
    owner = accounts(:legacy)
    other = accounts(:pilot)
    owner.update!(danebo_controlled: true)
    other.update!(danebo_controlled: true)
    uid = SecureRandom.uuid
    first = KbDocument.create!(account: owner, document_uid: uid, s3_key: "manuals/general-a.pdf", display_name: "Manual A", aliases: [])
    second = KbDocument.create!(account: other, document_uid: SecureRandom.uuid, s3_key: "manuals/general-b.pdf", display_name: "Manual B", aliases: [])
    index_manual_for_retrieval!(first)
    index_manual_for_retrieval!(second)
    KnowledgeScopeChange.apply!(kb_document: first, to_scope: "danebo_general", actor: "ops", reason: "approved manual")
    KnowledgeScopeChange.apply!(kb_document: second, to_scope: "danebo_general", actor: "ops", reason: "approved manual")
    second.update!(document_uid: uid)
    entries = [
      row(uid, "Manual A", [ "Otis" ], s3_key: first.s3_key, account_id: "1"),
      row(uid, "Manual B", [ "Otis" ], s3_key: second.s3_key, account_id: "3")
    ]

    rows = suggestion_documents(Ranker.score("Otis", entries).candidates)
    bound = entries.map { |entry|
      Rag::KnowledgeScopePolicy.bind_catalog_candidate(entry, rows: rows, viewer_account: viewer)
    }

    suggestion = Ranker.suggest("Otis", entries, viewer_account: viewer, documents_for: method(:suggestion_documents))

    assert_equal [ first, second ], bound
    assert_equal [ "Manual A", "Manual B" ], suggestion.cards.map(&:display_name).sort
    assert suggestion.cards.all? { |card| card.knowledge_scope == "danebo_general" }
  end

  test "an ambiguous canonical object denies the catalog candidate" do
    viewer = accounts(:climb)
    owner = accounts(:legacy)
    uid = SecureRandom.uuid
    key = "manuals/ambiguous.pdf"
    KbDocument.create!(account: viewer, document_uid: uid, s3_key: key, display_name: "Manual", aliases: [])
    KbDocument.create!(account: owner, document_uid: SecureRandom.uuid, s3_key: "s3://#{KbDocument::KB_BUCKET}/#{key}", display_name: "Manual", aliases: [])

    suggestion = Ranker.suggest(
      "Otis",
      [ row(uid, "Manual", [ "Otis" ], s3_key: key) ],
      viewer_account: viewer,
      documents_for: method(:suggestion_documents)
    )

    assert_empty suggestion.cards
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

  def suggestion_documents(candidates)
    Rag::KnowledgeScopePolicy.rows_for_catalog_candidates(candidates)
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
