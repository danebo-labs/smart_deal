# frozen_string_literal: true

require "test_helper"

class Rag::Haiku55HttpRevisionTest < ActiveSupport::TestCase
  KEYS = %w[OPUS55_REQUIRE HTTP55_REQUIRE GUION2_DIRECT_REQUIRE].freeze

  setup do
    @saved = KEYS.index_with { |key| ENV[key] }
    ENV["HTTP55_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/run_haiku55_http.rb") unless defined?(Haiku55Http)
    account = accounts(:legacy)
    @elemont = document(account, Haiku55Http::ELEMONT_DOCUMENT_UID, "elemont.pdf")
    @cea = document(account, Haiku55Http::CEA_DOCUMENT_UID, "cea.pdf")
    @vf5 = document(account, Haiku55Http::VF5_DOCUMENT_UID, "vf5.pdf")
    @monarch = document(account, Haiku55Http::MONARCH_DOCUMENT_UID, "monarch.pdf")
  end

  teardown do
    @saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "an added manual replayed in the same episode inside the new focus passes" do
    focus = [ @elemont, @cea ]
    requests = [
      ask("01", "Leo CEA15+ en el rótulo de la placa.", "ep_1", after: [ @elemont.id ]),
      click("02", @cea, "add", "ep_1"),
      replay("03", "Leo CEA15+ en el rótulo de la placa.", "ep_1", before: focus.map(&:id), filter: uris(focus), cited: uris([ @cea ]))
    ]

    check = Haiku55Http.gui_checks("jesus", requests).sole

    assert check["ok"], check["reasons"].inspect
    assert_equal [ @elemont.id ], check["focus_before"]
    assert_equal "03", check["replay"]
  end

  test "a replace that kept the old manual, opened another episode and cited outside the focus fails" do
    question = Haiku55Http::MONARCH_TURNS.first
    requests = [
      ask("01", question, "ep_1", after: [ @vf5.id ]),
      click("02", @monarch, "replace", "ep_1"),
      replay("03", question, "ep_2", before: [ @vf5.id, @monarch.id ], filter: uris([ @monarch ]), cited: uris([ @cea ]))
    ]

    reasons = Haiku55Http.gui_checks("monarch_replace", requests).sole["reasons"]

    assert_equal %w[replay:focus_replace replay:other_episode replay:filter_outside_focus replay:cited_outside_focus].sort, reasons.sort
  end

  test "a planned card that was never clicked is reported" do
    check = Haiku55Http.gui_checks("monarch_add", [ ask("01", Haiku55Http::MONARCH_TURNS.first, "ep_1", after: []) ]).sole

    assert_not check["ok"]
    assert_equal "no_click", check["reason"]
  end

  test "only the Retrieves before the generator request scope the answer" do
    cea = uris([ @cea ])
    body = { "citations" => [ { "metadata" => { "original_source_uri" => cea.first } } ] }
    discovery = [ retrieve(cea), retrieve(cea), { "kind" => "converse" }, retrieve([]) ]
    leaked = [ retrieve(cea), retrieve([]), { "kind" => "converse" } ]

    assert Haiku55Http.scope_view(discovery, body, [ @cea ])["ok"]
    assert_not Haiku55Http.scope_view(leaked, body, [ @cea ])["ok"]
  end

  test "a replay must not reinterpret the turn" do
    ok = [ { status: 200 }, { "status" => "success", "answer" => "Respuesta." } ]

    assert_equal "interpreter_not_sent", Haiku55Http.block_reason("jesus", *ok, [], [ @cea ])
    assert_equal "generator_not_sent", Haiku55Http.block_reason("jesus", *ok, [], [ @cea ], replay: true)
    assert_equal "replay_reinterpreted", Haiku55Http.block_reason("jesus", *ok, [ { "kind" => "interpreter_request" } ], [ @cea ], replay: true)
  end

  test "a replay's question is the generator's turn line" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      root.join("bodies").mkpath
      root.join("bodies/b0006.txt").write("Mensaje de este turno:\nLeo CEA15+ en el rótulo de la placa.\n\nFuentes de este turno:\n[1] manual")
      events = [ { "kind" => "converse", "messages" => [ { "role" => "user", "content" => [ { "type" => "text", "text" => { "path" => "bodies/b0006.txt" } } ] } ] } ]

      assert_equal "Leo CEA15+ en el rótulo de la placa.", Haiku55Http.answered_question(root, events)
      assert_equal "Hola", Haiku55Http.answered_question(root, [ { "kind" => "user_message", "original" => "Hola" } ] + events)
      assert_nil Haiku55Http.answered_question(root, [])
    end
  end

  test "the revision reservation counts the replay as a turn" do
    turn = { "interpreter" => BigDecimal("0.01"), "generation" => BigDecimal("0.02") }

    assert_equal 3, Haiku55Http.reservation("jesus", turn)["turns"]
    assert_equal 7, Haiku55Http.reservation("jesus", turn)["calls"]
  end

  private

  def document(account, uid, key)
    KbDocument.find_by(document_uid: uid) ||
      KbDocument.create!(account: account, document_uid: uid, s3_key: "bulk_uploads/1/test/#{key}", display_name: key, aliases: [])
  end

  def uris(documents)
    documents.map { |item| item.display_s3_uri(KbDocument::KB_BUCKET) }.sort
  end

  def ask(label, question, episode, after:)
    { "label" => label, "request" => { "controller" => "rag", "action" => "ask", "question" => question },
      "question" => question, "episode_id" => episode, "focus_before" => after, "focus_after" => after, "filter" => [], "cited" => [] }
  end

  def click(label, document, mode, episode)
    { "label" => label, "request" => {
      "controller" => "pinned_documents", "action" => "create", "kb_document_id" => document.id.to_s,
      "document_uid" => document.document_uid, "focus_mode" => mode, "episode_id" => episode, "correlation_id" => "corr-1"
    } }
  end

  def replay(label, question, episode, before:, filter:, cited:)
    { "label" => label, "request" => { "controller" => "rag", "action" => "ask", "replay_correlation_id" => "corr-1" },
      "question" => question, "episode_id" => episode, "focus_before" => before, "focus_after" => before,
      "filter" => filter, "filters" => [ filter ], "cited" => cited }
  end

  def retrieve(uris)
    { "kind" => "retrieve", "knowledge_base_id" => Haiku55Http::KB_ID, "retrieval_configuration" => {
      "vector_search_configuration" => { "filter" => { "or_all" => uris.map { |uri| { "equals" => { "key" => "original_source_uri", "value" => uri } } } } }
    } }
  end
end
