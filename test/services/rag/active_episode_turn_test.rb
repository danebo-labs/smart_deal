# frozen_string_literal: true

require "test_helper"

class Rag::ActiveEpisodeTurnTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-09-23 14:00:00 -03:00")
  CASES = YAML.load_file(Rails.root.join("test/fixtures/files/field_companion/cases.yml")).index_by { |row| row["id"] }
  CASE_IDS = %w[T-A T-B T-C T-D T-E T-F T-G T-H X-1 X-2 X-3 X-4 X-5 X-6 X-7 X-9 X-11 X-13 X-14 X-15].freeze
  SPRINGS = "Cómo se ajustan los resortes de la fijación de cables ?"
  ELEMONT_GOAL = "Elemont MH con placa CEA15, falla en puerta 1: el imán no magnetiza. ¿Qué reviso?"

  CASE_IDS.each do |case_id|
    test "case #{case_id}" do
      replay(CASES.fetch(case_id))
    end
  end

  test "annex B springs question opens an episode" do
    result = classify(SPRINGS)
    assert_equal :opened, result.decision
  end

  test "annex B Fuji Yida continues and fills the brand" do
    result = classify("Fuji Yida", prior: episode_state(goal: SPRINGS))
    assert_equal :continued_elliptical, result.decision
    assert_equal "Fuji Yida", fact_value(result, "manufacturer")
  end

  test "annex B a KONE subject with no known brand opens a new episode" do
    text = "Estoy revisando un KONE que no nivela en planta 3"
    result = classify(text, prior: episode_state(goal: SPRINGS))
    assert_equal :new_episode, result.decision
    assert_equal text, result.state.dig("goal", "text")
    assert_equal "KONE", fact_value(result, "manufacturer")
  end

  test "annex B Es un KONE answers a manufacturer question without opening" do
    result = classify("Es un KONE", prior: episode_state(goal: SPRINGS, pending: "manufacturer"))
    assert_equal :continued_elliptical, result.decision
    assert_equal "KONE", fact_value(result, "manufacturer")
  end

  test "annex B el modelo no lo se confirms the model is unknown" do
    result = classify("el modelo no lo sé", prior: episode_state(goal: SPRINGS, manufacturer: "Fuji Yida"))
    assert_equal :continued_elliptical, result.decision
    assert_equal "unknown_confirmed", fact_status(result, "model")
  end

  test "annex B y el LED 7 stays on the episode" do
    result = classify("¿y el LED 7?", prior: episode_state(goal: ELEMONT_GOAL, manufacturer: "Elemont"))
    assert_equal :continued_elliptical, result.decision
    assert_equal "Elemont", fact_value(result, "manufacturer")
  end

  test "annex B a self contained CEA15 question replaces the goal" do
    text = "¿Qué significa el código 8 en una placa CEA15?"
    result = classify(text, prior: episode_state(goal: SPRINGS, manufacturer: "Elemont"))
    assert_equal :continued_self_contained, result.decision
    assert_equal text, result.state.dig("goal", "text")
    assert_equal "8", fact_value(result, "fault_code")
    assert_includes result.state["identifiers"].pluck("value"), "CEA15"
  end

  test "annex B No no es Fuji Yida Es KONE corrects the brand" do
    prior = episode_state(goal: SPRINGS, manufacturer: "Fuji Yida", model_status: "unknown_confirmed")
    result = classify("No, no es Fuji Yida. Es KONE", prior: prior)
    assert_equal :corrected, result.decision
    assert_equal "KONE", fact_value(result, "manufacturer")
    assert_nil result.state.dig("facts", "model")
    assert_equal SPRINGS, result.state.dig("goal", "text")
    assert_equal prior["episode_id"], result.state["episode_id"]
  end

  test "annex B Ahora estoy revisando un KONE opens a new episode" do
    text = "Ahora estoy revisando un KONE que no nivela en planta 3"
    prior = episode_state(goal: ELEMONT_GOAL, manufacturer: "Elemont", identifiers: %w[MH CEA15], fault_code: "8")
    result = classify(text, prior: prior)
    assert_equal :new_episode, result.decision
    assert_equal text, result.state.dig("goal", "text")
    assert_not_equal prior["episode_id"], result.state["episode_id"]
    assert_equal "KONE", fact_value(result, "manufacturer")
    assert_not_includes JSON.generate(result.state), "Elemont"
  end

  # CG-D19 #D: measured 23-sep (medición 9, paso 5). After «No, no es Fuji
  # Yida. Es KONE», the KONE fault opened nothing and rode on the springs goal.
  test "a new subject on the already known brand opens a new episode" do
    text = "Ahora estoy revisando un KONE que no nivela en planta 3"
    prior = episode_state(goal: SPRINGS, manufacturer: "KONE", model_status: "unknown_confirmed")
    result = classify(text, prior: prior)
    assert_equal :new_episode, result.decision
    assert_equal text, result.state.dig("goal", "text")
    assert_not_equal prior["episode_id"], result.state["episode_id"]
    assert_equal "KONE", fact_value(result, "manufacturer")
  end

  test "a short KONE mention on the known brand still continues the episode" do
    prior = episode_state(goal: SPRINGS, manufacturer: "KONE", model_status: "unknown_confirmed")
    result = classify("y en el KONE el LED 7?", prior: prior)
    assert_not_equal :new_episode, result.decision
    assert_equal prior["episode_id"], result.state["episode_id"]
  end

  test "annex B ahora da 18 does not restart" do
    prior = episode_state(goal: ELEMONT_GOAL, manufacturer: "Elemont")
    result = classify("ahora da 18", prior: prior)
    assert_equal :continued_elliptical, result.decision
    assert_equal prior["episode_id"], result.state["episode_id"]
  end

  test "annex B a KONE comparison does not change the brand" do
    prior = episode_state(goal: ELEMONT_GOAL, manufacturer: "Elemont")
    result = classify("¿es igual que en el KONE?", prior: prior)
    assert_equal :continued_mention, result.decision
    assert_equal "brand_mention_ignored", result.reason
    assert_equal "Elemont", fact_value(result, "manufacturer")
  end

  private

  def replay(row)
    if row["id"] == "X-11"
      replay_invalid(row)
      return
    end

    state = {}
    ctx = { first_episode_id: nil, first_goal: nil, previous_episode_id: nil, previous_state: {} }
    last = nil
    Array(row["turns"]).each do |turn|
      ctx[:previous_state] = state.deep_dup
      ctx[:previous_episode_id] = state["episode_id"]
      state = state.deep_dup
      if turn["inactive_hours_before"]
        state["updated_at"] = (NOW - turn["inactive_hours_before"].to_i.hours).iso8601
      end
      last = step(row, turn, state)
      state = last.state
      ctx[:first_episode_id] ||= state["episode_id"]
      ctx[:first_goal] ||= state.dig("goal", "text")
      assert_outcome(turn["expect"], last, ctx.merge(turn_text: turn["content"])) if turn["expect"]
    end
    last = classify("código 8", prior: {}, shared: true) if row["id"] == "X-9"
    last = classify_selection if row["id"] == "X-6" && row.dig("turns", 0, "expect")
    assert_outcome(row["expect"], last, ctx.merge(turn_text: row.dig("turns", -1, "content"))) if row["expect"]
  end

  def replay_invalid(row)
    row["active_episode_payloads"].each do |raw|
      result = nil
      assert_nothing_raised do
        result = Rag::ActiveEpisodeTurn.call(state: raw, text: "ok", now: NOW, enabled: true, correlation_id: "query:x11")
      end
      assert_outcome(row["expect"], result, { turn_text: "ok", previous_state: {}, previous_episode_id: nil, first_episode_id: nil, first_goal: nil })
    end
  end

  def step(row, turn, state)
    if turn["role"] == "assistant"
      return Rag::ActiveEpisodeTurn.apply_assistant(state: state, text: turn["content"], now: NOW, correlation_id: "query:assistant")
    end

    classify(
      turn["content"],
      prior: state,
      selection_turn: row["id"] == "X-6",
      shared: row["shared_session"] == true
    )
  end

  def classify(text, prior: {}, selection_turn: false, shared: false)
    Rag::ActiveEpisodeTurn.call(
      state: prior,
      text: text,
      now: NOW,
      enabled: true,
      selection_turn: selection_turn,
      shared: shared,
      correlation_id: "query:turn"
    )
  end

  def classify_selection
    prior = episode_state(goal: ELEMONT_GOAL, manufacturer: "Elemont")
    result = classify("Manual KONE MonoSpace", prior: prior, selection_turn: true)
    assert_equal prior["episode_id"], result.state["episode_id"]
    assert_equal "Elemont", fact_value(result, "manufacturer")
    result
  end

  def assert_outcome(expect, result, ctx)
    return if expect.blank?

    assert_equal expect["decision"], result.decision.to_s if expect.key?("decision")
    assert_equal expect["outcome_reason"], result.reason if expect.key?("outcome_reason")
    assert_equal({}, result.state) if expect["state"] == {}
    assert_not result.nil? if expect["raises"] == false
    assert_manufacturer(expect, result)
    assert_model(expect, result)
    assert_fault_code(expect, result)
    assert_identifiers(expect, result)
    assert_composed(expect, result, ctx)
    assert_equal ctx[:first_episode_id], result.state["episode_id"] if expect["same_episode_id"]
    assert_not_equal ctx[:previous_episode_id], result.state["episode_id"] if expect["new_episode_id"]
    assert_equal ctx[:previous_episode_id], result.state["episode_id"] if expect["restarts"] == false && ctx[:previous_episode_id]
    assert_equal ctx[:first_goal], result.state.dig("goal", "text") if expect["goal_unchanged"]
    assert_equal expect["goal"], result.state.dig("goal", "text") if expect["goal"].is_a?(String)
    Array(expect["absent"]).each { |text| assert_not_includes JSON.generate(result.state), text.to_s }
    assert_unchanged_facts(result, ctx) if expect["new_fields"] == false
    assert ctx[:previous_state].dig("pending_fact", "subject").present? if expect["via"] == "pending_fact"
    assert_nil result.state["pending_fact"] if expect.key?("pending_fact") && expect["pending_fact"].nil?
    assert_equal :no_episode, result.decision if expect["chain"] == "current"
    return unless expect["state_unchanged"]

    assert_same ctx[:previous_state]["episode_id"], result.state["episode_id"]
    assert_same ctx[:previous_state]["facts"], result.state["facts"]
    assert_same ctx[:previous_state]["identifiers"], result.state["identifiers"]
  end

  def assert_same(expected, actual, message = nil)
    if expected.nil?
      assert_nil actual, message
    else
      assert_equal expected, actual, message
    end
  end

  def assert_manufacturer(expect, result)
    return unless expect.key?("manufacturer")

    if expect["manufacturer"] == "unknown_confirmed"
      assert_equal "unknown_confirmed", fact_status(result, "manufacturer")
    else
      assert_equal expect["manufacturer"], fact_value(result, "manufacturer")
    end
    assert_not_equal expect["never_manufacturer"], fact_value(result, "manufacturer") if expect["never_manufacturer"]
  end

  def assert_model(expect, result)
    return unless expect.key?("model")

    if expect["model"] == "empty"
      assert_nil result.state.dig("facts", "model")
    elsif expect["model"] == "unknown_confirmed"
      assert_equal "unknown_confirmed", fact_status(result, "model")
    else
      assert_equal expect["model"], fact_value(result, "model")
    end
  end

  def assert_fault_code(expect, result)
    return unless expect.key?("fault_code")

    if expect["fault_code"] == "absent_confirmed"
      assert_equal "absent_confirmed", fact_status(result, "fault_code")
    else
      assert_equal expect["fault_code"].to_s, fact_value(result, "fault_code")
    end
  end

  def assert_identifiers(expect, result)
    return unless expect["identifiers"]

    values = Array(result.state["identifiers"]).pluck("value")
    expect["identifiers"].each { |identifier| assert_includes values, identifier.to_s }
  end

  def assert_composed(expect, result, ctx)
    if expect["composed_parts"]
      cursor = 0
      expect["composed_parts"].each do |part|
        text = part == "goal" ? result.state.dig("goal", "text") : part == "turn" ? ctx[:turn_text] : part.to_s
        index = result.composed.to_s.index(text, cursor)
        assert index, "#{expect_label(part)} missing from #{result.composed.inspect}"
        cursor = index + text.length
      end
    end
    Array(expect["composed_contains"]).each do |text|
      assert_includes result.composed.to_s, text.to_s
    end
  end

  def expect_label(part)
    part.to_s
  end

  def assert_unchanged_facts(result, ctx)
    %w[manufacturer model fault_code].each do |key|
      assert_same ctx[:previous_state].dig("facts", key), result.state.dig("facts", key), key
    end
    assert_same ctx[:previous_state]["identifiers"], result.state["identifiers"]
  end

  def fact_value(result, key)
    result.state.dig("facts", key, "value")
  end

  def fact_status(result, key)
    result.state.dig("facts", key, "status")
  end

  def episode_state(goal: nil, manufacturer: nil, pending: nil, fault_code: nil, identifiers: [], model_status: nil)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:prior", now: NOW)
    episode.assign_goal!(goal, correlation_id: "query:prior") if goal
    if manufacturer
      episode.write_fact!("manufacturer", status: "known", value: manufacturer, source: "user", correlation_id: "query:prior", at: NOW.iso8601)
    end
    if model_status
      episode.write_fact!("model", status: model_status, source: "user", correlation_id: "query:prior", at: NOW.iso8601)
    end
    if fault_code
      episode.write_fact!("fault_code", status: "known", value: fault_code, source: "user", correlation_id: "query:prior", at: NOW.iso8601)
    end
    identifiers.each { |value| episode.append_identifier!(value, correlation_id: "query:prior") }
    episode.pending_fact = { "subject" => pending, "correlation_id" => "query:prior" } if pending
    episode.to_h
  end
end
