# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/rag_wording_multilookup_gate_2026-09-29.rb")

class WordingMultilookupGateTest < ActiveSupport::TestCase
  Rules = WordingMultilookupGateRules
  URI = "s3://multimodal-source-destination/elemont.pdf"

  test "pinned document results stays at 3" do
    assert_equal 3, RagRetrievalProfile::PINNED_DOCUMENT_RESULTS
    assert_equal 3, Rules::PINNED_K
  end

  test "the gate pins the production bucket even when the local bucket differs" do
    document = WordingMultilookupProbe::PinnedDocument.new(
      id: nil,
      display_name: "SEGURIDADES 1.1-1",
      s3_key: "uploads/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/original.pdf",
      source_uri: "s3://smart-deal-dev-kb/uploads/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/original.pdf"
    )

    assert_equal(
      "s3://multimodal-source-destination/uploads/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/original.pdf",
      WordingMultilookupGate.new.send(:source_uri, document)
    )
  end

  test "a blocked row stays blocked when the association is missing" do
    verdict = Rules.judge(row: blocked_row, observed: observed(covered: false))

    assert_equal "BLOCKED", verdict[:disposition]
    assert_empty verdict[:failures]
    assert_nil verdict[:reopen_phase]
  end

  test "a blocked row is not promoted when the association is present" do
    verdict = Rules.judge(row: blocked_row, observed: observed(covered: true))

    assert_equal "BLOCKED", verdict[:disposition]
    assert_empty verdict[:failures]
  end

  test "an uncovered resolved row is deferred and names its phase" do
    verdict = Rules.judge(row: resolved_row, observed: observed(covered: false, oracle_ok: false))

    assert_equal "DEFERRED", verdict[:disposition]
    assert_includes verdict[:failures], "uncovered"
    assert_equal "P2", verdict[:reopen_phase]
  end

  test "three retrieves fail the budget" do
    calls = [ call("q1"), call("q2"), call("q3") ]
    problems = Rules.budget_failures(resolved_row, observed(calls: calls))

    assert_includes problems, "retrieve_count"
  end

  test "a second retrieve after a complete first window is an extra rescue" do
    problems = Rules.budget_failures(
      resolved_row,
      observed(calls: [ call("pregunta"), call("rescue") ], first_window_complete: true)
    )

    assert_includes problems, "extra_rescue"
  end

  test "an authorized rescue stays on the same uri with k 3 and the measured query" do
    row = resolved_row.merge(expected_rescue: "conectada Seguridad IN bornera tablero")
    problems = Rules.budget_failures(
      row,
      observed(
        calls: [ call("pregunta"), call("conectada Seguridad IN bornera tablero") ],
        first_window_complete: false
      )
    )

    assert_empty problems
  end

  test "a rescue against another uri or the global corpus fails" do
    other = observed(calls: [ call("pregunta", uris: [ "s3://other/manual.pdf" ]) ])
    global = observed(calls: [ call("pregunta", uris: []) ])

    assert_includes Rules.budget_failures(resolved_row, other), "uri"
    assert_includes Rules.budget_failures(resolved_row, global), "corpus"
  end

  test "a rescue that is not k 3 fails" do
    problems = Rules.budget_failures(
      resolved_row,
      observed(calls: [ call("pregunta"), call("rescue", k: 12) ], first_window_complete: false)
    )

    assert_includes problems, "rescue_k"
  end

  test "an elliptical follow-up is resolved when the composed goal is kept" do
    row = resolved_row.merge(
      episode: { decision: "continued_elliptical", composed_includes: [ "MH", "SUBE", "BAJA" ] }
    )
    verdict = Rules.judge(
      row: row,
      observed: observed(
        episode: {
          decision: "continued_elliptical",
          composed: "Elemont MH, ¿cuál es el relé de SUBE?\n¿Y para BAJA cuál es el relé?",
          drags: false
        }
      )
    )

    assert_equal "RESOLVED", verdict[:disposition]
    assert_empty verdict[:failures]
  end

  test "the gate passes only when resolved rows hold and blocked rows stay blocked" do
    rows = [
      result_row("plan", "RESOLVED", "RESOLVED"),
      result_row("plan", "BLOCKED", "BLOCKED", cause: "retrieval/ranking", expect_cause: "retrieval/ranking")
    ]

    assert Rules.gate_pass?(rows, knowledge_base_id: Rules::EXPECTED_KB, pinned_results: 3)
  end

  test "the gate fails when a resolved row is deferred or the pin constant moves" do
    rows = [ result_row("plan", "RESOLVED", "DEFERRED", failures: [ "uncovered" ]) ]

    assert_not Rules.gate_pass?(rows, knowledge_base_id: Rules::EXPECTED_KB, pinned_results: 3)
    assert_not Rules.gate_pass?(
      [ result_row("plan", "RESOLVED", "RESOLVED") ],
      knowledge_base_id: Rules::EXPECTED_KB,
      pinned_results: 4
    )
  end

  private

  def blocked_row
    { expect: "BLOCKED", expect_cause: "retrieval/ranking", kind: "plan", episode: nil, max_calls: nil, one_call_tokens: nil, expected_rescue: nil }
  end

  def resolved_row
    { expect: "RESOLVED", kind: "plan", reopen_phase: "P2", episode: nil, max_calls: nil, one_call_tokens: nil, expected_rescue: nil }
  end

  def observed(covered: true, oracle_ok: true, calls: nil, first_window_complete: false, measured: true, episode: nil)
    {
      measured: measured,
      covered: covered,
      oracle_ok: oracle_ok,
      calls: calls || [ call("pregunta") ],
      source_uri: URI,
      first_window_complete: first_window_complete,
      first_window_tokens: [],
      generation: "not_run",
      episode: episode
    }
  end

  def call(question, uris: [ URI ], k: 3)
    {
      question: question,
      entity_s3_uris: uris,
      entity_sources: [ "document" ],
      force_entity_filter: true,
      number_of_results: k
    }
  end

  def result_row(kind, expect, disposition, cause: nil, expect_cause: nil, failures: [])
    {
      kind: kind,
      expect: expect,
      disposition: disposition,
      cause: cause,
      expect_cause: expect_cause,
      failures: failures
    }
  end
end
