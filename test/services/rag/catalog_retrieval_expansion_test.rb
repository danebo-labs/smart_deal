# frozen_string_literal: true

require "test_helper"

class Rag::CatalogRetrievalExpansionTest < ActiveSupport::TestCase
  DISPLAY = "Acme Freight Controller ZX Field Manual"
  CANONICAL = "Elemont Montacargas Hidraulico Modelo MH"
  INVESTIGATED = "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?"

  setup do
    @owner = accounts(:legacy)
    @other = accounts(:climb)
    @now = Time.current
    @acme = document_for(@owner, "Acme book")
    @marked = document_for(@owner, "Marked book")
    @prefix = document_for(@owner, "Prefix book")
    @elemont = document_for(@owner, CANONICAL)
    @catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        row(@acme, "Acme Freight Controller ZX Field Manual", [ "Acme" ], [ "ZX" ]),
        row(@marked, "Marked Plus Board", [ "Maker" ], [ "CEA15+" ]),
        row(@prefix, "Prefix Only Board", [ "Other" ], [ "ZX9000" ]),
        row(@elemont, CANONICAL, [ "Elemont" ], [ "MH" ])
      ]
    })
  end

  test "an exact brand and designator add the canonical name to the query" do
    episode = open_episode
    result = perceive(report([ assert_span("Acme ZX") ]), "Acme ZX no arranca", episode)
    decision = settle(episode, result, "Acme ZX no arranca")
    query = compose(episode, "Acme ZX no arranca", result, decision)

    span = episode.identifiers.find { |item| item["value"] == "Acme ZX" }
    expansion = episode.identifiers.find { |item| item["value"] == DISPLAY }

    assert_equal "user", span["source"]
    assert_equal "catalog", expansion["source"]
    assert_equal DISPLAY, result.identifiers.first.catalog_retrieval
    assert_includes query, "Acme ZX no arranca"
    assert_includes query, DISPLAY
    assert_nil episode.fact("model")
    assert_nil episode.fact("manufacturer")
    assert_operator query.length, :<=, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS

    reloaded = Rag::ActiveEpisode.parse(episode.to_h, now: @now)
    assert_equal DISPLAY, reloaded.identifiers.find { |item| item["source"] == "catalog" }["value"]
    assert_operator DISPLAY.length, :>, Rag::ActiveEpisode::MAX_IDENTIFIER_CHARS
  end

  test "the investigated span keeps the declared words and adds the canonical name" do
    episode = open_episode
    result = perceive(report([ assert_span("Elemont MH") ]), INVESTIGATED, episode)
    decision = settle(episode, result, INVESTIGATED)
    before = compose(open_episode, INVESTIGATED, result, decision)
    query = compose(episode, INVESTIGATED, result, decision)

    assert_equal INVESTIGATED, before
    assert_includes query, INVESTIGATED
    assert_includes query, CANONICAL
    assert_equal 1, query.scan("Elemont MH").size
    assert_not_includes query, "manual-cea15p"
    assert_nil episode.fact("manufacturer")
    assert_nil episode.fact("model")
  end

  test "two candidates, an unauthorized row, or an ambiguous bind do not expand" do
    twin_a = document_for(@owner, "Twin A")
    twin_b = document_for(@owner, "Twin B")
    twins = catalog_with(
      row(twin_a, "Twin A Manual", [ "Twin" ], [ "QQ" ]),
      row(twin_b, "Twin B Manual", [ "Twin" ], [ "QQ" ])
    )
    assert_nil twins.confirmed_retrieval_name("Twin QQ", viewer_account: @owner)

    foreign = document_for(@other, "Foreign book")
    hidden = catalog_with(row(foreign, "Foreign Manual", [ "Foreign" ], [ "QQ" ], account: @owner))
    assert_nil hidden.confirmed_retrieval_name("Foreign QQ", viewer_account: @owner)

    shared_key = "manuals/#{SecureRandom.uuid}.pdf"
    left = document_for(@owner, "Left", key: shared_key)
    document_for(@other, "Right", key: shared_key)
    ambiguous = catalog_with(row(left, "Ambiguous Manual", [ "Ambiguous" ], [ "QQ" ]))
    assert_nil ambiguous.confirmed_retrieval_name("Ambiguous QQ", viewer_account: @owner)
  end

  test "a brand alone and a designator alone keep their own results" do
    monarch = document_for(@owner, "Monarch book")
    catalog = catalog_with(row(
      monarch, "Monarch Controller Book", [ "MONARCH" ],
      [ { "value" => "NICE3000", "type" => "controller" } ]
    ))
    episode = open_episode

    brand = perceive(report([ assert_span("MONARCH", "manufacturer") ]), "MONARCH", episode, catalog)
    assert_equal "manufacturer", brand.facts.first.slot
    assert_equal "catalog", brand.facts.first.source
    assert_nil brand.facts.first.catalog_retrieval
    assert_empty brand.identifiers

    designator = perceive(report([ assert_span("NICE3000", "controller") ]), "NICE3000", episode, catalog)
    assert_equal "controller", designator.facts.first.slot
    assert_equal "NICE3000", designator.facts.first.value
    assert_nil designator.facts.first.catalog_retrieval

    plain = perceive(report([ assert_span("ZX") ]), "ZX", episode)
    assert_equal "identifier", plain.identities.first.kind
    assert_nil plain.identities.first.catalog_retrieval
  end

  test "a prefix or dropped punctuation is not the designator" do
    assert_nil @catalog.confirmed_retrieval_name("Other ZX", viewer_account: @owner)
    assert_nil @catalog.confirmed_retrieval_name("Maker CEA15", viewer_account: @owner)
    assert_equal "Marked Plus Board", @catalog.confirmed_retrieval_name("Maker CEA15+", viewer_account: @owner)
    assert_equal "Prefix Only Board", @catalog.confirmed_retrieval_name("Other ZX9000", viewer_account: @owner)

    episode = open_episode
    result = perceive(report([ assert_span("Maker CEA15") ]), "Maker CEA15 no responde", episode)
    settle(episode, result, "Maker CEA15 no responde")

    assert_nil result.identifiers.first.catalog_retrieval
    assert episode.identifiers.none? { |item| item["source"] == "catalog" }
  end

  test "the expansion does not make the equipment known or move the focus" do
    episode = open_episode
    focus_uris = [ "s3://bucket/pinned.pdf" ]
    focus_ids = [ 9 ]
    result = perceive(report([ assert_span("Acme ZX") ]), "Acme ZX no arranca", episode)
    decision = Rag::RoutePolicy.call(
      previous: episode, perception: result, focus_count: 1,
      focus_uris: focus_uris, focus_document_ids: focus_ids
    )
    bare = result.with(identities: result.identities.map { |item| item.with(catalog_retrieval: nil) })
    bare_decision = Rag::RoutePolicy.call(
      previous: episode, perception: bare, focus_count: 1,
      focus_uris: focus_uris, focus_document_ids: focus_ids
    )
    settle(episode, result, "Acme ZX no arranca")
    identity = Rag::EquipmentIdentity.from_episode(episode)

    assert_equal bare_decision.decision, decision.decision
    assert_equal focus_uris, decision.focus_uris
    assert_equal focus_ids, decision.focus_document_ids
    assert_not identity.known?
    assert_includes identity.needles, "Acme ZX"
    assert_not_includes identity.needles, DISPLAY
    assert_nil episode.to_h["document_focus"]
  end

  test "a later correction drops the previous canonical name" do
    episode = open_episode
    first = perceive(report([ assert_span("Acme ZX") ]), "Acme ZX no arranca", episode)
    settle(episode, first, "Acme ZX no arranca")
    assert_includes compose(episode, "¿Qué reviso?", first, decision_for), DISPLAY

    correction = perceive(
      correct_payload([ negate_span("Acme ZX"), assert_span("Otro dato") ]),
      "No, no es Acme ZX.",
      episode
    )
    settle(episode, correction, "No, no es Acme ZX.")
    query = compose(episode, "¿Qué reviso ahora?", correction, decision_for)

    assert_not_includes query.to_s, DISPLAY
    assert episode.identifiers.none? { |item| item["value"] == DISPLAY }
    assert episode.identifiers.none? { |item| item["value"] == "Acme ZX" }
    assert episode.rejected.none? { |item| item["value"] == DISPLAY }
  end

  test "a follow-up that does not correct the span keeps the canonical name" do
    episode = open_episode
    first = perceive(report([ assert_span("Acme ZX") ]), "Acme ZX no arranca", episode)
    settle(episode, first, "Acme ZX no arranca")
    follow = perceive(
      { "move" => "follow_up", "assertions" => [], "observations" => [], "pending_resolution" => nil, "clarification_target" => nil },
      "Sigue igual",
      episode
    )
    settle(episode, follow, "Sigue igual")

    assert_includes compose(episode, "Sigue igual", follow, decision_for), DISPLAY
  end

  test "the composed query stays inside the retrieval budget" do
    episode = open_episode
    episode.append_identifier!("Q" * 200, correlation_id: "seed", source: "catalog")
    episode.assign_goal!("G" * 200, correlation_id: "seed")
    3.times { |index| episode.append_observation!("O#{index} #{'x' * 150}", correlation_id: "seed") }
    query = compose(episode, "T" * 180, report_result, decision_for)

    assert_operator query.length, :<=, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS
    stored = episode.identifiers.find { |item| item["source"] == "catalog" }
    assert_equal Rag::ActiveEpisode::MAX_CATALOG_IDENTIFIER_CHARS, stored["value"].length
  end

  private

  def document_for(account, name, key: nil)
    uid = SecureRandom.uuid
    KbDocument.create!(
      account: account, s3_key: key || "manuals/#{uid}.pdf", display_name: name,
      document_uid: uid, aliases: []
    )
  end

  def row(document, display_name, brands, designators, account: document.account)
    {
      "account_id" => account.id.to_s,
      "document_id" => document.document_uid,
      "s3_key" => document.s3_key,
      "display_name" => display_name,
      "brands" => brands,
      "designators" => designators,
      "generic" => false,
      "confirmed" => true,
      "evidence_page" => 1,
      "evidence_text" => display_name
    }
  end

  def catalog_with(*rows)
    Rag::DocumentIdentityCatalog.new({ "documents" => rows })
  end

  def open_episode
    Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
  end

  def perceive(raw, turn, episode, catalog = @catalog)
    Rag::TurnPerception.build(
      raw, turn: turn, episode: episode, catalog: catalog, viewer_account: @owner
    )
  end

  def settle(episode, result, turn)
    decision = Rag::RoutePolicy.call(previous: episode, perception: result, focus_count: 0)
    Rag::WorkContextReducer.apply!(
      episode: episode, perception: result, decision: decision,
      turn: turn, correlation_id: "seed", now: @now
    )
    decision
  end

  def compose(episode, turn, perception, decision)
    Rag::QueryComposer.call(state: episode, turn: turn, perception: perception, decision: decision)
  end

  def report(assertions)
    { "move" => "report", "assertions" => assertions, "observations" => [], "pending_resolution" => nil, "clarification_target" => nil }
  end

  def report_result
    perceive(report([]), "turno", open_episode)
  end

  def decision_for
    Rag::RoutePolicy::Decision.new(
      decision: "ready", retrieval_query: nil, clarification: nil, pending_subject: nil,
      outside_discovery: false, owns_query: false, bare_identifier: false, ask_when: nil,
      mutations: [], dialogue_function: nil, context_carry: nil, focus_uris: [],
      focus_document_ids: [], pending_question: nil, fallback: nil
    )
  end

  def correct_payload(assertions)
    { "move" => "correct", "assertions" => assertions, "observations" => [], "pending_resolution" => nil, "clarification_target" => nil }
  end

  def assert_span(span, hint = nil)
    { "span" => span, "act" => "assert", "slot_hint" => hint }
  end

  def negate_span(span)
    { "span" => span, "act" => "negate", "slot_hint" => nil }
  end
end
