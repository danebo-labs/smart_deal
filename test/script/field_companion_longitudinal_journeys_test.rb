# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/field_companion/longitudinal_journeys")

class FieldCompanionLongitudinalJourneysTest < ActiveSupport::TestCase
  Journeys = FieldCompanion::LongitudinalJourneys
  Score = Journeys::Score

  test "live mode refuses without a spend cap and ledger path" do
    error = assert_raises(Journeys::LiveRefused) do
      with_env("MVP_JOURNEY_LIVE" => "1", "MVP_JOURNEY_SPEND_CAP" => nil, "MVP_JOURNEY_LEDGER" => nil) do
        Journeys.run!(account: accounts(:legacy), user: users(:one))
      end
    end
    assert_match(/MVP_JOURNEY_SPEND_CAP/, error.message)
  end

  test "live mode does not execute even when the cap and ledger are set" do
    error = assert_raises(Journeys::LiveRefused) do
      with_env("MVP_JOURNEY_LIVE" => "1", "MVP_JOURNEY_SPEND_CAP" => "0.50", "MVP_JOURNEY_LEDGER" => "tmp/mvp_continuity/f1/live.json") do
        Journeys.run!(account: accounts(:legacy), user: users(:one))
      end
    end
    assert_match(/does not execute live mode/, error.message)
  end

  test "seeded wrong episode ids are detected" do
    result = Score.evaluate([
      base_turn("A1", 1, episode: "ep-a"),
      base_turn("A2", 2, episode: "ep-b")
    ])
    assert_includes result["faults"], "wrong_episode_id"
    assert_equal "FAIL", result.dig("L1", "A_no_focus")
  end

  test "a seeded episode open at turn 11 is detected" do
    result = Score.evaluate([
      base_turn("A10", 10, episode: "ep-a", checkpoint: "L1"),
      base_turn("A11", 11, episode: "ep-b", checkpoint: "L2", episode_changed: true)
    ])
    assert_includes result["faults"], "episode_opened_at_turn_count"
    assert_equal "FAIL", result.dig("L2", "A_no_focus")
  end

  test "a seeded episode open at the first history eviction is detected" do
    result = Score.evaluate([
      base_turn("A11", 11, checkpoint: "L2", episode_changed: true, first_eviction: true, rollover: true)
    ])
    assert_includes result["faults"], "episode_opened_at_history_eviction"
  end

  test "a seeded lost fact is detected and a pre-rollover miss is not history rollover" do
    item = present_text("door", "puerta 1 no termina de cerrar")
    result = Score.evaluate([ base_turn("A1", 1, expect: [ item ]) ])
    miss = result["absences"].find { |row| row["fact"] == "door" }
    assert_equal "lost_fact", miss["fault"]
    assert_equal "composition or reducer loss", miss["cause"]
    assert_not_equal "conversation-history rollover", miss["cause"]
    assert_not_equal "observation FIFO eviction", miss["cause"]
    assert_not_equal "400-character problem projection", miss["cause"]
  end

  test "a seeded corrected fact that is still current is detected" do
    item = { "id" => "code_8", "kind" => "fact", "slot" => "fault_code", "value" => "8", "polarity" => "absent", "weight" => "critical" }
    state = empty_state.merge("facts" => { "fault_code" => { "value" => "8", "status" => "known", "source" => "user" } })
    result = Score.evaluate([ base_turn("A5", 5, state: state, expect: [ item ]) ])
    assert_includes result["faults"], "superseded_fact_current"
  end

  test "a seeded superseded fact resurfacing is detected" do
    item = { "id" => "code_8", "kind" => "fact", "slot" => "fault_code", "value" => "8", "polarity" => "absent", "weight" => "critical" }
    gone = base_turn("A5", 5, expect: [ item ])
    back = base_turn("A6", 6, state: empty_state.merge("facts" => { "fault_code" => { "value" => "8", "status" => "known", "source" => "user" } }), expect: [ item ])
    result = Score.evaluate([ gone, back ])
    assert_includes result["faults"], "superseded_fact_resurfaced"
  end

  test "a seeded repeated critical request is detected" do
    result = Score.evaluate([ base_turn("A4", 4, repeated_critical_request: true) ])
    assert_includes result["faults"], "repeated_critical_request"
  end

  test "a seeded foreign applicability is detected" do
    result = Score.evaluate([ base_turn("B3", 3, journey: "B", foreign_applicability: true) ])
    assert_includes result["faults"], "foreign_applicability"
  end

  test "a seeded stale write is detected" do
    result = Score.evaluate([ base_turn("A14", 14, checkpoint: "L2", stale_mutated: true) ])
    assert_includes result["faults"], "stale_write"
  end

  test "history rollover is classified only when an evicted message held the fact" do
    text = "guía de la puerta"
    item = present_text("visual", text, "diagnostic")
    earlier = base_turn("A6", 6, state: empty_state.merge("observations" => [ text ]))
    rolled = base_turn(
      "A11", 11, checkpoint: "L2", rollover: true,
      evicted: [ { "role" => "user", "content" => "Ya comprobé visualmente la guía de la puerta" } ],
      expect: [ item ]
    )
    result = Score.evaluate([ earlier, rolled ])
    miss = result["absences"].find { |row| row["fact"] == "visual" }
    assert_equal "conversation-history rollover", miss["cause"]
  end

  test "observation FIFO and the 400-character projection are different causes" do
    text = "guía de la puerta"
    fifo_item = present_text("visual", text)
    earlier = base_turn("A6", 6, state: empty_state.merge("observations" => [ text ]))
    fifo = base_turn(
      "A9", 9,
      state: empty_state.merge("observations" => [ "uno largo", "dos largo", "tres largo" ]),
      expect: [ fifo_item ]
    )
    truncated = base_turn(
      "A10", 10,
      context_truncated: true,
      state: empty_state.merge("observations" => [ text ], "goal" => "puerta"),
      generator_input: "Active Field Problem without the check",
      expect: [ present_text("visual", text) ]
    )
    fifo_cause = Score.evaluate([ earlier, fifo ])["absences"].find { |row| row["fact"] == "visual" }["cause"]
    cut_cause = Score.evaluate([ truncated ])["absences"].find { |row| row["fact"] == "visual" }["cause"]
    assert_equal "observation FIFO eviction", fifo_cause
    assert_equal "400-character problem projection", cut_cause
    assert_not_equal fifo_cause, cut_cause
  end

  test "owner baseline records L1 L2 and L3 without a usefulness score" do
    packet = harness_packet
    assert_nil packet["usefulness_score"]
    assert_match(/\A[0-9a-f]{64}\z/, packet["fixture_sha256"])
    assert_match(/\A[0-9a-f]{64}\z/, packet["known_prompt_sha256"])
    assert packet["verdict"]["L1"].key?("A_no_focus")
    assert packet["verdict"]["L1"].key?("B")
    assert packet["verdict"]["L2"].key?("A_no_focus")
    assert packet["verdict"]["L3"].key?("no_focus")
    assert packet["verdict"]["L3"].key?("selected_elemont")
    assert_includes %w[PASS FAIL], packet.dig("verdict", "L1", "A_no_focus")
    assert_includes %w[PASS FAIL DEGRADED], packet.dig("verdict", "L2", "A_no_focus")
    assert_includes %w[PASS FAIL], packet.dig("verdict", "L3", "no_focus")
    assert_includes %w[PASS FAIL], packet.dig("verdict", "L3", "selected_elemont")
    assert packet["l3"].all? { |row| row["resolver"].key?("reads_replaced_episode") }
    assert_equal false, packet["turns"].any? { |turn| turn["answer_is_stub"] && turn["usefulness_score"].present? }
    assert Rails.root.join("tmp/mvp_continuity/f1/ledger.json").exist?
  end

  test "known controls capture managed and structured prompts without a model call" do
    packet = harness_packet
    text = Rails.root.join("tmp/mvp_continuity/f1/known_prompts.txt").read
    sections = known_control_sections(text)
    assert_equal KNOWN_CONTROL_SECTIONS, sections.keys
    KNOWN_CONTROL_SECTIONS.each do |name|
      body = sections[name]
      assert body.present?, name
      assert_not_equal "EMPTY", body.strip, name
      assert_not_includes body, "ERROR ArgumentError", name
      assert_not_includes body, "LiveRefused", name
    end
    assert_equal "PASS", packet.dig("verdict", "L1", "A_no_focus")
    assert_equal "PASS", packet.dig("verdict", "L1", "A_selected_elemont")
    assert_equal "PASS", packet.dig("verdict", "L1", "B")
    assert_equal "PASS", packet.dig("verdict", "L2", "A_no_focus")
    assert_equal "PASS", packet.dig("verdict", "L2", "A_selected_elemont")
    assert_equal "PASS", packet.dig("verdict", "L3", "no_focus")
    assert_equal "PASS", packet.dig("verdict", "L3", "selected_elemont")
    assert_equal "A11", packet.dig("first_eviction", "A_no_focus", "turn")
    assert_equal "A11", packet.dig("first_eviction", "A_selected_elemont", "turn")
    assert_equal "B10", packet.dig("first_eviction", "B", "turn")
    assert packet["turns"].all? { |turn| turn["error"].blank? }
    assert_nil packet["usefulness_score"]
  end

  test "state_only accepts absent_confirmed and rejects a missing or known fault code" do
    marker = state_only_fact("no_code_fact", "absent_confirmed")

    passed = Score.check([ base_turn("B2", 2, state: fault_state("absent_confirmed"), expect: [ marker ]) ], 0, marker)
    assert_nil passed["miss"]
    assert_equal true, passed["state"]
    assert_equal "n/a", passed["generator"]

    missing = Score.check([ base_turn("B2", 2, state: empty_state, expect: [ marker ]) ], 0, marker)
    assert_equal "lost_fact", missing["miss"]["fault"]
    assert_equal false, missing["state"]
    assert_equal "n/a", missing["generator"]

    known = Score.check([ base_turn("B2", 2, state: fault_state("known", "18"), expect: [ marker ]) ], 0, marker)
    assert_equal "lost_fact", known["miss"]["fault"]
    assert_equal "n/a", known["generator"]
  end

  test "the no-code sentence without the fact does not satisfy the state-only marker" do
    marker = state_only_fact("no_code_fact", "absent_confirmed")
    state = empty_state.merge("observations" => [ "No aparece código de falla" ])
    result = Score.check([ base_turn("B2", 2, state: state, expect: [ marker ]) ], 0, marker)

    assert_equal "lost_fact", result["miss"]["fault"]
    assert_equal "n/a", result["generator"]
  end

  test "no_code_text fails when the sentence leaves the generator and the retrieval query" do
    item = present_text("no_code_text", "No aparece código de falla")
    state = fault_state("absent_confirmed").merge("observations" => [ "No aparece código de falla" ])
    lost = Score.check([
      base_turn("B10", 10, state: state, generator_input: "Puedes seguir.", retrieval_query: "¿Y ahora?", expect: [ item ])
    ], 0, item)
    kept = Score.check([
      base_turn("B10", 10, state: state, generator_input: "", retrieval_query: "No aparece código de falla", expect: [ item ])
    ], 0, item)

    assert_equal true, lost["state"]
    assert_equal false, lost["generator"]
    assert_equal "lost_fact", lost["miss"]["fault"]
    assert_nil kept["miss"]
    assert_equal true, kept["generator"]
  end

  test "a meta acknowledgement keeps state facts without repeating them and a later turn still requires them" do
    orona = present_text("orona", "Orona").merge("expectation_scope" => "state_only")
    photo = {
      "id" => "test_ok", "kind" => "visible_text", "text" => "TEST OK",
      "polarity" => "present", "weight" => "critical", "expectation_scope" => "state_only"
    }
    state = fault_state("absent_confirmed").merge(
      "goal" => "queda mal nivelado en planta 3",
      "facts" => {
        "fault_code" => { "status" => "absent_confirmed", "source" => "user" },
        "manufacturer" => { "status" => "known", "value" => "Orona", "source" => "photo" },
        "model" => { "status" => "known", "value" => "PBCM-V3", "source" => "photo" }
      },
      "observations" => [ "2 o 3 cm por arriba del nivel" ],
      "active_photo" => { "visible_text" => [ "TEST OK" ] }
    )
    meta = base_turn(
      "B5", 5, state: state,
      generator_input: "Puedes seguir con lo que ya me contaste.",
      retrieval_query: "Adjunto una foto de la placa de este mismo equipo.",
      generation_mode: "meta", route: "deterministic", model_invoked: false,
      expectation_contract: { "generation_mode" => "meta", "route" => "deterministic", "model_invoked" => false },
      expect: [ orona, photo ]
    )

    assert_nil Score.check([ meta ], 0, orona)["miss"]
    assert_equal "n/a", Score.check([ meta ], 0, orona)["generator"]
    assert_nil Score.check([ meta ], 0, photo)["miss"]
    assert_nil Score.contract_miss(meta)

    later = present_text("orona", "Orona")
    later_turn = base_turn("B6", 6, state: state, generator_input: "guidance", retrieval_query: "Confirmo la placa", expect: [ later ])
    later_check = Score.check([ later_turn ], 0, later)
    assert_equal false, later_check["generator"]
    assert_equal "lost_fact", later_check["miss"]["fault"]

    invoked = meta.merge("model_invoked" => true)
    mismatch = Score.contract_miss(invoked)
    assert_equal "contract_mismatch", mismatch["fault"]
    assert_equal "n/a", mismatch["generator"]
  end

  private

  KNOWN_CONTROL_SECTIONS = [
    "c18 managed",
    "c18 structured",
    "c19 managed",
    "c19 structured",
    "c20 managed",
    "c20 structured"
  ].freeze

  def harness_packet
    @@longitudinal_packet ||= Journeys.run!(account: accounts(:legacy), user: users(:one))
  end

  def known_control_sections(text)
    sections = {}
    current = nil
    text.each_line do |line|
      header = line.match(/\A## (c(?:18|19|20) (?:managed|structured))\n\z/)
      if header
        current = header[1]
        sections[current] = +""
      elsif current
        sections[current] << line
      end
    end
    sections.transform_values { |body| body.sub(/\A\n/, "").sub(/\n+\z/, "") }
  end

  def with_env(values)
    previous = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def base_turn(id, n, episode: "ep-a", journey: "A_no_focus", checkpoint: "L1", **extra)
    {
      "id" => id,
      "n" => n,
      "journey" => journey,
      "checkpoint" => checkpoint,
      "episode_id" => episode,
      "episode_changed" => false,
      "first_eviction" => false,
      "rollover" => false,
      "evicted" => [],
      "text" => "turno",
      "state" => empty_state,
      "generator_input" => "",
      "retrieval_query" => "",
      "context_truncated" => false,
      "recent_user" => [],
      "repeated_critical_request" => false,
      "foreign_applicability" => false,
      "stale_mutated" => false,
      "expect" => []
    }.merge(extra.stringify_keys)
  end

  def empty_state
    { "facts" => {}, "goal" => "", "observations" => [], "identifiers" => [], "rejected" => [], "active_photo" => {} }
  end

  def present_text(id, text, weight = "critical")
    { "id" => id, "kind" => "text", "text" => text, "polarity" => "present", "weight" => weight }
  end

  def fault_state(status, value = nil)
    fact = { "status" => status, "source" => "user" }
    fact["value"] = value if value
    empty_state.merge("facts" => { "fault_code" => fact })
  end

  def state_only_fact(id, status)
    {
      "id" => id, "kind" => "fact", "slot" => "fault_code", "value" => "",
      "status" => status, "polarity" => "present", "weight" => "critical",
      "expectation_scope" => "state_only"
    }
  end
end
