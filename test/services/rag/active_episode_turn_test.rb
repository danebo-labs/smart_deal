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

  test "explicit MonoSpace persists and drops inherited Fuji Yida" do
    prior = episode_state(goal: SPRINGS, manufacturer: "Fuji Yida")
    result = classify("el modelo es MonoSpace, como se ajustan los resortes?", prior: prior)

    assert_equal prior["episode_id"], result.state["episode_id"]
    assert_equal "known", fact_status(result, "model")
    assert_equal "MonoSpace", fact_value(result, "model")
    assert_equal "user", result.state.dig("facts", "model", "source")
    assert_nil result.state.dig("facts", "manufacturer")
    assert_equal [ "MonoSpace" ], Rag::DocumentIdentityScope.needles(fresh_episode(result.state))
  end

  test "an inherited identifier does not stay a needle after an explicit model" do
    prior = episode_state(goal: SPRINGS, manufacturer: "Fuji Yida", identifiers: %w[CEA15])
    result = classify("el modelo es MonoSpace, como se ajustan los resortes?", prior: prior)

    assert_equal "MonoSpace", fact_value(result, "model")
    assert_nil result.state.dig("facts", "manufacturer")
    assert_equal [ "CEA15" ], result.state["identifiers"].pluck("value")
    assert_equal "query:prior", result.state["identifiers"].first["correlation_id"]
    assert_equal [ "MonoSpace" ], Rag::DocumentIdentityScope.needles(fresh_episode(result.state))
  end

  test "an identifier restated in the model turn stays a needle" do
    prior = episode_state(goal: SPRINGS, manufacturer: "Fuji Yida", identifiers: %w[CEA15])
    result = classify("el modelo es MonoSpace, placa CEA15, como se ajustan los resortes?", prior: prior)

    assert_equal "query:turn", result.state["identifiers"].first["correlation_id"]
    needles = Rag::DocumentIdentityScope.needles(fresh_episode(result.state))
    assert_includes needles, "MonoSpace"
    assert_includes needles, "CEA15"
    assert_not_includes needles, "Fuji Yida"
  end

  test "explicit mixed-case model names are accepted and are not hardcoded" do
    %w[MiniSpace Synergy].each do |model|
      result = classify(
        "el modelo es #{model}",
        prior: episode_state(goal: SPRINGS, manufacturer: "Fuji Yida")
      )

      assert_equal model, fact_value(result, "model"), model
      assert_equal "user", result.state.dig("facts", "model", "source")
      assert_nil result.state.dig("facts", "manufacturer")
    end
  end

  test "a digit designator still persists inside an explicit model declaration" do
    result = classify("el modelo es BL6", prior: episode_state(goal: SPRINGS, manufacturer: "Fuji Yida"))

    assert_equal "BL6", fact_value(result, "model")
  end

  test "loose or invalid captures do not become the model" do
    springs = classify(
      "como se ajustan los resortes del amarre",
      prior: episode_state(goal: SPRINGS, manufacturer: "Fuji Yida")
    )
    assert_nil springs.state.dig("facts", "model")
    assert_equal "Fuji Yida", fact_value(springs, "manufacturer")

    lowercase = classify("el modelo es resorte", prior: episode_state(goal: SPRINGS, manufacturer: "Fuji Yida"))
    assert_nil lowercase.state.dig("facts", "model")
    assert_equal "Fuji Yida", fact_value(lowercase, "manufacturer")

    stopword = classify("el modelo es como", prior: episode_state(goal: SPRINGS, manufacturer: "Fuji Yida"))
    assert_nil stopword.state.dig("facts", "model")

    pending = classify("MonoSpace", prior: episode_state(goal: SPRINGS, manufacturer: "Fuji Yida", pending: "model"))
    assert_nil pending.state.dig("facts", "model")
    assert_equal "Fuji Yida", fact_value(pending, "manufacturer")
  end

  test "a manufacturer named in the same turn stays beside the new model" do
    prior = episode_state(goal: SPRINGS, manufacturer: "Fuji Yida")
    result = classify("Fuji Yida, el modelo es MonoSpace, como se ajustan los resortes?", prior: prior)

    assert_equal "MonoSpace", fact_value(result, "model")
    assert_equal "Fuji Yida", fact_value(result, "manufacturer")
    needles = Rag::DocumentIdentityScope.needles(fresh_episode(result.state))
    assert_includes needles, "Fuji Yida"
    assert_includes needles, "MonoSpace"
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

  test "flow A correction and follow-up retrieve KONE without Fuji Yida" do
    springs = "¿Cómo se ajustan los resortes de la fijación de cables?"
    opened = classify(springs)
    named = classify("es Fuji Yida", prior: opened.state)
    corrected = classify("No, no es Fuji Yida. Es KONE", prior: named.state)
    follow = classify("¿Qué reviso primero?", prior: corrected.state)

    assert_equal springs, corrected.state.dig("goal", "text")
    assert_equal "KONE", fact_value(corrected, "manufacturer")
    assert_includes corrected.composed, "resortes"
    assert_includes corrected.composed, "fijación de cables"
    assert_includes corrected.composed, "KONE"
    assert_not_includes corrected.composed, "Fuji"
    assert_not_includes corrected.composed, "No, no es"

    assert_equal springs, follow.state.dig("goal", "text")
    assert_equal "KONE", fact_value(follow, "manufacturer")
    assert_includes follow.composed, "resortes"
    assert_includes follow.composed, "fijación de cables"
    assert_includes follow.composed, "KONE"
    assert_includes follow.composed, "¿Qué reviso primero?"
    assert_not_includes follow.composed, "Fuji"
  end

  test "flow B correction keeps the symptom and CEA15 text without Elemont" do
    goal = "Elemont MH con placa CEA15, la puerta 1 no magnetiza. ¿Qué reviso?"
    opened = classify(goal)
    absent = classify("no muestra ningún código", prior: opened.state)
    corrected = classify("No, no es Elemont. Es KONE", prior: absent.state)
    follow = classify("¿Qué reviso primero?", prior: corrected.state)

    assert_equal goal, corrected.state.dig("goal", "text")
    assert_equal "KONE", fact_value(corrected, "manufacturer")
    assert_equal [], Array(corrected.state["identifiers"])
    assert_equal "absent_confirmed", fact_status(corrected, "fault_code")
    assert_includes corrected.composed, "puerta 1"
    assert_includes corrected.composed, "no magnetiza"
    assert_includes corrected.composed, "CEA15"
    assert_includes corrected.composed, "MH"
    assert_includes corrected.composed, "KONE"
    assert_not_includes corrected.composed, "Elemont"
    assert_not_includes corrected.composed, "No, no es"

    assert_equal goal, follow.state.dig("goal", "text")
    assert_equal "KONE", fact_value(follow, "manufacturer")
    assert_equal [], Array(follow.state["identifiers"])
    assert_includes follow.composed, "puerta 1"
    assert_includes follow.composed, "no magnetiza"
    assert_includes follow.composed, "CEA15"
    assert_includes follow.composed, "KONE"
    assert_includes follow.composed, "¿Qué reviso primero?"
    assert_not_includes follow.composed, "Elemont"
  end

  test "flow B correction that also names code 8 keeps the new code without Elemont" do
    goal = "Elemont MH con placa CEA15, la puerta 1 no magnetiza"
    opened = classify(goal)
    corrected = classify("No, no es Elemont. Es KONE y muestra código 8", prior: opened.state)

    assert_equal :corrected, corrected.decision
    assert_equal goal, corrected.state.dig("goal", "text")
    assert_equal "KONE", fact_value(corrected, "manufacturer")
    assert_includes corrected.composed, "KONE"
    assert_includes corrected.composed, "código 8"
    assert_not_includes corrected.composed, "Elemont"
    assert_not_includes corrected.composed, "No, no es"
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

  def classify(text, prior: {}, selection_turn: false, shared: false, prior_turns: [])
    Rag::ActiveEpisodeTurn.call(
      state: prior,
      text: text,
      now: NOW,
      enabled: true,
      selection_turn: selection_turn,
      shared: shared,
      correlation_id: "query:turn",
      prior_user_turns: prior_turns
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

  def fresh_episode(state)
    state.merge("updated_at" => Time.current.iso8601)
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

  GOAL = "Cómo se ajustan los resortes de la fijación de cables?"

  test "hybrid model turn expands only the cable-fixing referent" do
    result = resolve(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      chain
    )

    assert_equal :continued_self_contained, result.decision
    assert_equal "MonoSpace", fact_value(result, "model")
    assert_nil fact_value(result, "manufacturer")
    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación"
  end

  test "an explicit model does not import the prior cable-fixing complement" do
    result = resolve(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación"
  end

  test "demonstrative plural expands the same referent" do
    result = resolve("esos resortes, ¿cómo se ajustan?", [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_equal "esos resortes de la fijación de cables, ¿cómo se ajustan?", result.composed
  end

  test "omitted object expands only when the verb agrees with the unique referent" do
    result = resolve(
      "el modelo es MonoSpace, ¿cómo se ajustan?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación de cables"
  end

  test "a singular verb does not copy a plural object" do
    result = resolve(
      "el modelo es MonoSpace, ¿cómo se ajusta?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación de cables"
  end

  test "internal y follow-up expands the unique referent" do
    result = resolve(
      "el modelo es MonoSpace, ¿y cómo se ajustan?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación de cables"
  end

  test "a rejected ajust ellipsis does not fall through to whole-goal compose" do
    result = resolve("¿y cómo se ajusta?", [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "¿y cómo se ajusta?"
  end

  test "a new explicit component does not inherit the cable-fixing referent" do
    result = resolve(
      "el modelo es MonoSpace, ¿cómo se ajusta el resorte del paracaídas?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_equal :continued_self_contained, result.decision
    assert_nil result.composed
    assert_includes result.state.dig("goal", "text"), "paracaídas"
    assert_not_includes result.state.dig("goal", "text"), "fijación de cables"
  end

  test "a new session does not invent a component" do
    result = classify("¿cómo se ajustan los resortes?", prior: episode_state(goal: nil))

    assert_not_includes result.composed.to_s, "fijación"
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación"
  end

  test "a short new component is not composed onto the spring goal" do
    result = resolve("el sensor de puerta no activa", [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_equal :continued_self_contained, result.decision
    assert_nil result.composed
    assert_equal "el sensor de puerta no activa", result.state.dig("goal", "text")
  end

  test "a new procedural task does not inherit the cable-fixing referent" do
    result = resolve(
      "la puerta no cierra, ¿cómo la reviso?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_equal :continued_self_contained, result.decision
    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text"), "fijación"
  end

  test "an expired antecedent is not composed" do
    result = resolve(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      [ turn(GOAL, "query:prior", NOW - 5.hours) ]
    )

    assert_nil result.composed
  end

  test "an antecedent outside the last three user turns is not composed" do
    turns = [
      turn(GOAL, "query:prior", NOW - 40.minutes),
      turn("KONE", "query:a", NOW - 30.minutes),
      turn("sin código", "query:b", NOW - 20.minutes),
      turn("lo medí", "query:c", NOW - 10.minutes)
    ]
    result = resolve("el modelo es MonoSpace, como se ajustan los resortes?", turns)

    assert_nil result.composed
  end

  test "a missing duplicate or nil goal correlation does not compose" do
    text = "el modelo es MonoSpace, como se ajustan los resortes?"
    fresh = turn(GOAL, "query:prior", NOW - 5.minutes)

    assert_nil resolve(text, [ fresh ], goal_correlation: nil).composed
    assert_nil resolve(text, [ turn(GOAL, "query:other", NOW - 5.minutes) ]).composed
    assert_nil resolve(text, [ fresh, fresh.merge("ts" => (NOW - 4.minutes).iso8601) ]).composed
  end

  test "a truncated goal does not compose" do
    state = episode_state(goal: GOAL)
    state["goal"]["truncated"] = true
    result = classify(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      prior: state,
      prior_turns: [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
  end

  test "an intermediate technical task blocks the older referent" do
    result = resolve(
      "el modelo es MonoSpace, ¿cómo se ajustan los resortes?",
      [
        turn(GOAL, "query:prior", NOW - 20.minutes),
        turn("la puerta no cierra", "query:door", NOW - 10.minutes)
      ]
    )

    assert_nil result.composed
  end

  test "the Fuji correction keeps precedence over referent expansion" do
    state = episode_state(manufacturer: "Fuji Yida")
    result = classify(
      "No, no es Fuji Yida. Es KONE",
      prior: state,
      prior_turns: [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_equal :corrected, result.decision
    assert_equal "KONE", fact_value(result, "manufacturer")
    assert_not_includes result.composed.to_s, "Fuji"
  end

  test "the Elemont correction keeps KONE and code 8" do
    state = episode_state(manufacturer: "Elemont")
    result = classify(
      "No, no es Elemont. Es KONE y muestra código 8",
      prior: state,
      prior_turns: [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_equal :corrected, result.decision
    assert_equal "KONE", fact_value(result, "manufacturer")
    assert_equal "8", fact_value(result, "fault_code")
    assert_not_includes result.composed.to_s, "Elemont"
  end

  test "a stale identifier is absent from the expanded turn" do
    state = episode_state(goal: GOAL, identifiers: [ "CEA15" ])
    result = classify(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      prior: state,
      prior_turns: chain
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "CEA15"
  end

  test "an explicit model does not paste the prior complement onto a restated identifier" do
    result = resolve(
      "el modelo es MonoSpace, placa CEA15, como se ajustan los resortes?",
      chain
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación de cables"
  end

  test "a 442 character expansion is kept" do
    current, = length_case(442)
    result = resolve(current, [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_equal 442, result.composed.length
    assert_includes result.composed, "fijación de cables"
    assert_equal GOAL, result.state.dig("goal", "text")
  end

  test "a 443 character expansion fails closed without truncating the turn" do
    current, = length_case(443)
    result = resolve(current, [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_nil result.composed
    assert_operator current.length, :>, result.state.dig("goal", "text").to_s.length
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación de cables"
  end

  def length_case(limit)
    suffix = " como se ajustan los resortes?"
    extra = " de la fijación de cables"
    pad = limit - suffix.length - extra.length
    current = "#{'m' * pad}#{suffix}"
    [ current, "#{current.sub(suffix, '')} como se ajustan los resortes#{extra}?" ]
  end

  test "a mixed-case model in the antecedent is not copied onto a new model" do
    goal = "Cómo se ajustan los resortes de la fijación de cables en MiniSpace?"
    result = resolve(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      [ turn(goal, "query:prior", NOW - 5.minutes) ],
      goal: goal
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "MiniSpace"
  end

  test "an explicit component before the verb is not overwritten" do
    result = resolve(
      "el resorte del paracaídas, ¿cómo se ajusta?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
    assert_includes result.state.dig("goal", "text"), "paracaídas"
    assert_not_includes result.state.dig("goal", "text"), "fijación de cables"
  end

  test "an explicit component after the verb is not overwritten" do
    result = resolve(
      "el modelo es MonoSpace, ¿cómo se ajusta el resorte del paracaídas?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text"), "fijación de cables"
  end

  test "two objects in the antecedent do not expand an omitted verb" do
    goal = "Cómo se ajustan los resortes y las poleas?"
    result = resolve(
      "el modelo es MonoSpace, ¿cómo se ajustan?",
      [ turn(goal, "query:prior", NOW - 5.minutes) ],
      goal: goal
    )

    assert_nil result.composed
  end

  test "a matching correlation with different text is not the antecedent" do
    result = resolve(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      [ turn("KONE no nivela", "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
  end

  test "KONE no nivela blocks the older spring goal" do
    result = blocking_bridge("KONE no nivela")

    assert_nil result.composed
  end

  test "código 8 y no nivela blocks the older spring goal" do
    result = blocking_bridge("código 8 y no nivela")

    assert_nil result.composed
  end

  test "lo medí y no nivela blocks the older spring goal" do
    result = blocking_bridge("lo medí y no nivela")

    assert_nil result.composed
  end

  test "placa CEA15 stays an identity follow-up" do
    result = resolve("placa CEA15", [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_equal :continued_elliptical, result.decision
    assert_equal GOAL, result.state.dig("goal", "text")
    assert_includes result.composed.to_s, "CEA15"
  end

  test "el relé no activa is a new task" do
    result = resolve("el relé no activa", [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_equal :continued_self_contained, result.decision
    assert_nil result.composed
    assert_equal "el relé no activa", result.state.dig("goal", "text")
  end

  test "la cerradura no enclava is a new task" do
    result = resolve("la cerradura no enclava", [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_equal :continued_self_contained, result.decision
    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text"), "fijación"
  end

  test "esas bobinas expands from the brake coil referent" do
    goal = "Cómo se ajustan esas bobinas del freno?"
    result = resolve(
      "esas bobinas, ¿cómo se ajustan?",
      [ turn(goal, "query:prior", NOW - 5.minutes) ],
      goal: goal
    )

    assert_equal "esas bobinas del freno, ¿cómo se ajustan?", result.composed
  end

  test "los contactos expands from the relay contact referent" do
    goal = "Cómo se ajustan los contactos del relé?"
    result = resolve(
      "el modelo es MonoSpace, como se ajustan los contactos?",
      [ turn(goal, "query:prior", NOW - 5.minutes) ],
      goal: goal
    )

    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "relé"
  end

  test "a lowercase equipment qualifier in the antecedent is not copied" do
    [ "minispace", "MINISPACE", "MiniSpace" ].each do |model|
      goal = "Cómo se ajustan los resortes de la fijación de cables en #{model}?"
      result = resolve(
        "el modelo es MonoSpace, como se ajustan los resortes?",
        [ turn(goal, "query:prior", NOW - 5.minutes) ],
        goal: goal
      )

      assert_nil result.composed, model
      assert_not_includes result.state.dig("goal", "text").to_s, model
    end
  end

  test "coordination without a second article is not one referent" do
    [ "resortes y poleas", "resorte y polea", "resortes tensores y poleas", "bobinas y contactos" ].each do |objects|
      goal = "Cómo se ajustan #{objects}?"
      result = resolve(
        "el modelo es MonoSpace, ¿cómo se ajusta?",
        [ turn(goal, "query:prior", NOW - 5.minutes) ],
        goal: goal
      )

      assert_nil result.composed, objects
    end
  end

  test "an adjectival noun phrase is not completed from the antecedent" do
    result = resolve("el resorte tensor, ¿cómo se ajusta?", [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_nil result.composed
    assert_includes result.state.dig("goal", "text"), "tensor"
    assert_not_includes result.state.dig("goal", "text"), "fijación de cables"
  end

  test "a shared prefix is not the same goal" do
    result = resolve(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      [ turn("#{GOAL} la puerta no cierra", "query:prior", NOW - 5.minutes) ]
    )

    assert_nil result.composed
  end

  test "a designator followed by a fault is not an identity bridge" do
    [ "CEA15 no activa", "K1 no responde", "borne 12 sin tensión", "CEA15 activa" ].each do |text|
      result = blocking_bridge(text)

      assert_nil result.composed, text
    end
  end

  test "resolved uses only the localized expansion" do
    result = resolve(
      "el modelo es MonoSpace, ¿cómo se ajustan los resortes?",
      [ turn(GOAL, "query:prior", NOW - 5.minutes) ]
    )

    assert_equal :continued_self_contained, result.decision
    assert_nil result.composed
    assert_not_includes result.state.dig("goal", "text").to_s, "fijación de cables"
  end

  test "rejected coordination does not paste the whole goal" do
    goal = "Cómo se ajustan los resortes y poleas?"
    [ "¿cómo se ajustan?", "el modelo es MonoSpace, ¿cómo se ajustan?" ].each do |current|
      result = resolve(current, [ turn(goal, "query:prior", NOW - 5.minutes) ], goal: goal)

      assert_no_inherited_referent(result, "resortes y poleas")
    end
  end

  test "rejected coordination with an article does not paste the whole goal" do
    goal = "Cómo se ajustan los resortes y las poleas de tracción?"
    result = resolve("¿cómo se ajustan?", [ turn(goal, "query:prior", NOW - 5.minutes) ], goal: goal)

    assert_no_inherited_referent(result, "poleas de tracción")
  end

  test "a bare de complement is not copied onto a new model" do
    goal = "Cómo se ajustan los resortes de minispace?"
    result = resolve(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      [ turn(goal, "query:prior", NOW - 5.minutes) ],
      goal: goal
    )

    assert_no_inherited_referent(result, "minispace")
  end

  test "a bare de complement is not copied without a new model either" do
    goal = "Cómo se ajustan los resortes de minispace?"
    result = resolve("¿cómo se ajustan los resortes?", [ turn(goal, "query:prior", NOW - 5.minutes) ], goal: goal)

    assert_no_inherited_referent(result, "minispace")
  end

  test "determined complements still expand" do
    brake = "Cómo se ajustan las bobinas del freno?"
    contacts = "Cómo se ajustan los contactos del relé?"

    brake_result = resolve("¿cómo se ajustan las bobinas?", [ turn(brake, "query:prior", NOW - 5.minutes) ], goal: brake)
    contact_result = resolve(
      "el modelo es MonoSpace, como se ajustan los contactos?",
      [ turn(contacts, "query:prior", NOW - 5.minutes) ],
      goal: contacts
    )
    spring_result = resolve("¿cómo se ajustan los resortes?", [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_equal "¿cómo se ajustan las bobinas del freno?", brake_result.composed
    assert_nil contact_result.composed
    assert_not_includes contact_result.state.dig("goal", "text").to_s, "relé"
    assert_equal "¿cómo se ajustan los resortes de la fijación de cables?", spring_result.composed
  end

  test "a repeated complement stays in the current turn after an explicit model" do
    result = resolve(
      "el modelo es MonoSpace, ¿cómo se ajustan los resortes del freno?",
      [ turn("Cómo se ajustan los resortes del freno?", "query:prior", NOW - 5.minutes) ],
      goal: "Cómo se ajustan los resortes del freno?"
    )

    assert_includes result.state.dig("goal", "text").to_s, "freno"
  end

  test "an ambiguous single word does not bridge back to the spring goal" do
    [ "paracaídas", "puerta", "freno", "polea", "nivela", "activa", "MiniSpace?" ].each do |bridge|
      result = blocking_bridge(bridge)

      assert_no_inherited_referent(result, "fijación de cables", bridge)
    end
  end

  test "structured identity facts still bridge an ajust ellipsis" do
    [ "Fuji Yida", "placa CEA15", "código 8", "sin código", "lo medí y da 18", "el modelo es MiniSpace" ].each do |bridge|
      result = blocking_bridge(bridge)

      assert_nil result.composed
      assert_not_includes result.state.dig("goal", "text").to_s, "fijación de cables"
    end
  end

  test "not applicable follow-ups still use the legacy compose" do
    result = classify("¿Qué reviso primero?", prior: episode_state(goal: GOAL))

    assert_equal :continued_elliptical, result.decision
    assert_includes result.composed, "fijación de cables"
  end

  test "an explicit noun with este or un does not inherit the old complement" do
    goal = "Cómo se ajusta el resorte de la fijación de cables?"
    [
      "este resorte tensor, ¿cómo se ajusta?",
      "esta polea tractora, ¿cómo se ajusta?",
      "un resorte del paracaídas, ¿cómo se ajusta?",
      "una polea de tracción, ¿cómo se ajusta?",
      "el resorte tensor, ¿cómo se ajusta?"
    ].each do |current|
      result = resolve(current, [ turn(goal, "query:prior", NOW - 5.minutes) ], goal: goal)

      assert_no_inherited_referent(result, "fijación de cables", current)
    end
  end

  test "a semantic break keeps the old goal out of a later follow-up" do
    singular = "¿Cómo se ajusta el resorte de la fijación de cables?"
    second = "este resorte tensor, ¿cómo se ajusta?"
    first = episode_state(goal: singular)
    broken = classify(second, prior: first, prior_turns: [ turn(singular, "query:prior", NOW - 10.minutes) ])
    later = classify(
      "¿Qué reviso primero?",
      prior: broken.state,
      prior_turns: [
        turn(singular, "query:prior", NOW - 10.minutes),
        turn(second, "query:mid", NOW - 5.minutes)
      ]
    )

    assert_no_inherited_referent(broken, "fijación de cables")
    assert_no_inherited_referent(later, "fijación de cables")
  end

  test "a rejected coordination cannot be revived by the next follow-up" do
    goal = "¿Cómo se ajustan los resortes y poleas?"
    second = "¿cómo se ajustan?"
    opened = episode_state(goal: goal)
    broken = classify(second, prior: opened, prior_turns: [ turn(goal, "query:prior", NOW - 10.minutes) ])
    later = classify("¿Qué reviso primero?", prior: broken.state, prior_turns: [
      turn(goal, "query:prior", NOW - 10.minutes),
      turn(second, "query:mid", NOW - 5.minutes)
    ])

    assert_no_inherited_referent(broken, "poleas")
    assert_no_inherited_referent(later, "poleas")
  end

  test "a new explicit component stays closed for the following follow-up" do
    goal = "¿Cómo se ajustan los resortes de la fijación de cables?"
    second = "el resorte del paracaídas, ¿cómo se ajusta?"
    broken = classify(second, prior: episode_state(goal: goal), prior_turns: [ turn(goal, "query:prior", NOW - 10.minutes) ])
    later = classify("¿y ahora qué reviso?", prior: broken.state, prior_turns: [
      turn(goal, "query:prior", NOW - 10.minutes),
      turn(second, "query:mid", NOW - 5.minutes)
    ])

    assert_no_inherited_referent(broken, "fijación de cables")
    assert_no_inherited_referent(later, "fijación de cables")
  end

  test "an identity bridge keeps the antecedent available" do
    goal = "¿Cómo se ajustan los resortes de la fijación de cables?"
    bridged = classify("el modelo es MonoSpace", prior: episode_state(goal: goal), prior_turns: [ turn(goal, "query:prior", NOW - 10.minutes) ])
    resolved = classify("¿cómo se ajustan los resortes?", prior: bridged.state, prior_turns: [
      turn(goal, "query:prior", NOW - 10.minutes),
      turn("el modelo es MonoSpace", "query:mid", NOW - 5.minutes)
    ])

    assert_equal goal, bridged.state.dig("goal", "text")
    assert_includes resolved.composed, "fijación de cables"
    assert_includes resolved.composed, "resortes"
  end

  test "a missing antecedent does not break a later follow-up" do
    goal = "¿Cómo se ajustan los resortes de la fijación de cables?"
    missed = classify(
      "¿cómo se ajustan los resortes?",
      prior: episode_state(goal: goal),
      prior_turns: [ turn("otra tarea distinta", "query:prior", NOW - 5.minutes) ]
    )
    later = classify("¿Qué reviso primero?", prior: missed.state, prior_turns: [
      turn(goal, "query:other", NOW - 10.minutes)
    ])

    assert_nil missed.composed
    assert_equal goal, missed.state.dig("goal", "text")
    assert_includes later.composed, "fijación de cables"
  end

  test "determined equipment names are not copied onto a new model" do
    current = "el modelo es MonoSpace, ¿cómo se ajustan los resortes?"
    [ "de minispace", "del minispace", "de la minispace" ].each do |tail|
      [ "minispace", "MiniSpace", "MINISPACE" ].each do |token|
        goal = "¿Cómo se ajustan los resortes #{tail.sub("minispace", token)}?"
        result = resolve(current, [ turn(goal, "query:prior", NOW - 5.minutes) ], goal: goal)

        assert_no_inherited_referent(result, token)
      end
    end
  end

  test "a short unknown equipment name is not copied onto a new model" do
    current = "el modelo es MonoSpace, ¿cómo se ajustan los resortes?"
    {
      "del maxpro" => "maxpro",
      "de maxpro" => "maxpro",
      "de la maxpro" => "maxpro",
      "del evo" => "evo",
      "de x1" => "x1"
    }.each do |tail, token|
      goal = "¿Cómo se ajustan los resortes #{tail}?"
      result = resolve(current, [ turn(goal, "query:prior", NOW - 5.minutes) ], goal: goal)

      assert_no_inherited_referent(result, token, tail)
    end
  end

  test "unknown equipment names stay closed in every casing" do
    current = "el modelo es MonoSpace, ¿cómo se ajustan los resortes?"
    [ "maxpro", "MaxPro", "MAXPRO" ].each do |token|
      goal = "¿Cómo se ajustan los resortes del #{token}?"
      result = resolve(current, [ turn(goal, "query:prior", NOW - 5.minutes) ], goal: goal)

      assert_no_inherited_referent(result, token)
    end
  end

  test "a proven part complement still expands beside a new model" do
    current_for = ->(noun) { "el modelo es MonoSpace, ¿cómo se ajustan #{noun}?" }
    brake = resolve(
      current_for.call("las bobinas"),
      [ turn("¿Cómo se ajustan las bobinas del freno?", "query:prior", NOW - 5.minutes) ],
      goal: "¿Cómo se ajustan las bobinas del freno?"
    )
    contacts = resolve(
      current_for.call("los contactos"),
      [ turn("¿Cómo se ajustan los contactos del relé?", "query:prior", NOW - 5.minutes) ],
      goal: "¿Cómo se ajustan los contactos del relé?"
    )
    springs = resolve(current_for.call("los resortes"), [ turn(GOAL, "query:prior", NOW - 5.minutes) ])

    assert_nil brake.composed
    assert_nil contacts.composed
    assert_nil springs.composed
    assert_not_includes brake.state.dig("goal", "text").to_s, "freno"
    assert_not_includes contacts.state.dig("goal", "text").to_s, "relé"
    assert_not_includes springs.state.dig("goal", "text").to_s, "fijación"
  end

  test "an explicit component breaks continuity even without a valid antecedent" do
    singular = "¿Cómo se ajusta el resorte de la fijación de cables?"
    second = "este resorte tensor, ¿cómo se ajusta?"
    broken = classify(second, prior: episode_state(goal: singular), prior_turns: [])
    later = classify("¿Qué reviso primero?", prior: broken.state, prior_turns: [
      turn(second, "query:mid", NOW - 5.minutes)
    ])

    assert_no_inherited_referent(broken, "fijación de cables")
    assert_no_inherited_referent(later, "fijación de cables")
    assert_not_equal singular, broken.state.dig("goal", "text")
  end

  test "a parachute component breaks continuity even without a valid antecedent" do
    goal = "¿Cómo se ajustan los resortes de la fijación de cables?"
    second = "el resorte del paracaídas, ¿cómo se ajusta?"
    broken = classify(second, prior: episode_state(goal: goal), prior_turns: [ turn("otra tarea", "query:other", NOW - 5.minutes) ])
    later = classify("¿y ahora qué reviso?", prior: broken.state, prior_turns: [
      turn(second, "query:mid", NOW - 5.minutes)
    ])

    assert_no_inherited_referent(broken, "fijación de cables")
    assert_no_inherited_referent(later, "fijación de cables")
  end

  test "a missing antecedent without a new component keeps the goal" do
    goal = "¿Cómo se ajusta el resorte de la fijación de cables?"
    missed = classify("¿cómo se ajustan los resortes?", prior: episode_state(goal: goal), prior_turns: [])

    assert_nil missed.composed
    assert_equal goal, missed.state.dig("goal", "text")
  end

  def assert_no_inherited_referent(result, fragment, label = nil)
    assert_not_includes result.composed.to_s.downcase, fragment.downcase, label
  end

  def blocking_bridge(text)
    resolve(
      "el modelo es MonoSpace, como se ajustan los resortes?",
      [
        turn(GOAL, "query:prior", NOW - 20.minutes),
        turn(text, "query:mid", NOW - 10.minutes)
      ]
    )
  end

  def resolve(text, turns, goal: GOAL, goal_correlation: "query:prior", **state_args)
    state = episode_state(goal: goal, **state_args)
    state["goal"]["correlation_id"] = goal_correlation if state["goal"]
    classify(text, prior: state, prior_turns: turns)
  end

  def chain
    [
      turn(GOAL, "query:prior", NOW - 30.minutes),
      turn("Fuji Yida", "query:fuji", NOW - 10.minutes)
    ]
  end

  def turn(content, correlation_id, ts)
    { "content" => content, "correlation_id" => correlation_id, "ts" => ts.iso8601 }
  end
end
