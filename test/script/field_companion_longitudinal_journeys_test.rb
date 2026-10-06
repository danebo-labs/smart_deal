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
    assert_equal "FAIL", packet.dig("verdict", "L1", "A_no_focus")
    assert_equal "FAIL", packet.dig("verdict", "L1", "A_selected_elemont")
    assert_equal "FAIL", packet.dig("verdict", "L1", "B")
    assert_equal "FAIL", packet.dig("verdict", "L2", "A_no_focus")
    assert_equal "FAIL", packet.dig("verdict", "L2", "A_selected_elemont")
    assert_equal "PASS", packet.dig("verdict", "L3", "no_focus")
    assert_equal "PASS", packet.dig("verdict", "L3", "selected_elemont")
    assert_equal "A11", packet.dig("first_eviction", "A_no_focus", "turn")
    assert_equal "A11", packet.dig("first_eviction", "A_selected_elemont", "turn")
    assert_equal "B10", packet.dig("first_eviction", "B", "turn")
    assert packet["turns"].all? { |turn| turn["error"].blank? }
    assert_nil packet["usefulness_score"]
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
end
