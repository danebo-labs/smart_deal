# frozen_string_literal: true

require "test_helper"

class Rag::WorkContextReducerTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.parse("2026-10-06 15:00:00 UTC")
  end

  test "a fault-code correction stores 18 and keeps 8 rejected" do
    episode = open_episode
    episode.write_fact!(
      "fault_code", status: "known", value: "8", source: "user",
      correlation_id: "seed", at: @now.iso8601
    )
    episode.append_observation!("El display muestra código 8", correlation_id: "seed")
    episode.append_observation!("detenida cerca de planta 1", correlation_id: "seed")
    turn = "No, leí mal: era código 18, no 8."

    with_owner { settle(episode, correction_payload, turn) }

    fact = episode.fact("fault_code")
    assert_equal "known", fact["status"]
    assert_equal "18", fact["value"]
    assert_equal "user", fact["source"]
    assert_includes episode.rejected.pluck("value"), "8"
    assert_not_includes episode.rejected.pluck("value"), "18"
    assert episode.observations.any? { |row| row["text"].include?("planta 1") }
    assert episode.observations.none? { |row| row["text"].match?(/(?<![[:alnum:]])8(?![[:alnum:]])/) }
  end

  test "rejecting fault code 8 keeps an independent 8 and the goal" do
    episode = open_episode
    episode.assign_goal!("la puerta 8 no cierra", correlation_id: "seed")
    episode.write_fact!(
      "fault_code", status: "known", value: "8", source: "user",
      correlation_id: "seed", at: @now.iso8601
    )
    [
      "El display muestra código 8",
      "El LED 8 está apagado",
      "la puerta 8 no cierra",
      "detenida en planta 8"
    ].each { |text| episode.append_observation!(text, correlation_id: "seed") }
    turn = "No, leí mal: era código 18, no 8."

    with_owner { settle(episode, correction_payload, turn) }

    texts = episode.observations.pluck("text")
    assert_equal "18", episode.fact("fault_code")["value"]
    assert_equal "la puerta 8 no cierra", episode.goal["text"]
    assert_includes texts, "El LED 8 está apagado"
    assert_includes texts, "la puerta 8 no cierra"
    assert_includes texts, "detenida en planta 8"
    assert texts.none? { |text| text.match?(/\bc[oó]digo\s+8\b/i) }
  end

  test "a continuity echo does not replace the open checks" do
    episode = open_episode
    episode.assign_goal!("la puerta no termina de cerrar", correlation_id: "seed")
    episode.append_observation!("El LED 7 está apagado", correlation_id: "seed")
    turn = "Sigue igual."

    with_owner { settle(episode, report_payload([ "Sigue igual" ]), turn) }

    assert_equal "la puerta no termina de cerrar", episode.goal["text"]
    assert_equal [ "El LED 7 está apagado" ], episode.observations.pluck("text")
  end

  test "a symptom sentence does not take an identifier slot from the equipment" do
    episode = open_episode
    turn = "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza."
    with_owner do
      settle(
        episode,
        report_payload(
          [ "la puerta 1 no termina de cerrar", "el imán no magnetiza" ],
          [
            { "span" => "Elemont MH", "act" => "assert" },
            { "span" => "CEA15", "act" => "assert" },
            { "span" => "la puerta 1 no termina de cerrar", "act" => "assert" },
            { "span" => "el imán no magnetiza", "act" => "assert" }
          ]
        ),
        turn
      )
    end

    values = episode.identifiers.pluck("value")
    assert_includes values, "Elemont MH"
    assert_includes values, "CEA15"
    assert values.none? { |value| value.include?("puerta") || value.include?("imán") }
  end

  test "a no-code report stores fault_code absent_confirmed" do
    episode = open_episode
    turn = "Solo lo he visto en planta 3; en otras plantas no lo observé. No aparece código de falla."

    with_owner do
      settle(episode, report_payload([ "Solo lo he visto en planta 3", "No aparece código de falla" ]), turn)
    end

    fact = episode.fact("fault_code")
    assert_equal "absent_confirmed", fact["status"]
    assert_nil fact["value"]
    assert episode.observations.any? { |row| row["text"] == "No aparece código de falla" }
  end

  test "an unmatched negate does not become an absent fault code" do
    episode = open_episode
    episode.assign_goal!("queda pasado de nivel", correlation_id: "seed")
    turn = "No veo ningún código de falla"

    with_owner { settle(episode, report_payload([], [ { "span" => turn, "act" => "negate" } ]), turn) }

    assert_nil episode.fact("fault_code")
  end

  test "a correction of a different door does not delete the other floor" do
    episode = open_episode
    episode.append_observation!("la puerta de planta 1 está cerrada", correlation_id: "seed")
    turn = "Corrijo la puerta de planta 2: la puerta de planta 2 está abierta."

    with_owner { settle(episode, report_payload([ "la puerta de planta 2 está abierta" ]), turn) }

    texts = episode.observations.pluck("text")
    assert_includes texts, "la puerta de planta 1 está cerrada"
    assert_includes texts, "la puerta de planta 2 está abierta"
  end

  test "a retracted floor inside a longer observation keeps the independent fact" do
    episode = seeded_turn_episode
    turn = "Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1. No lo sé."
    raw = {
      "move" => "correct",
      "assertions" => [ { "span" => "planta 2", "act" => "assert", "slot_hint" => nil } ],
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }

    decision = nil
    with_owner { decision = settle(episode, raw, turn) }
    stored = travel_to(@now) { Rag::ActiveEpisode.parse(episode.to_h, now: @now) }
    texts = stored.observations.pluck("text")
    explained = Rag::QueryComposer.explain(
      state: stored, turn: turn, perception: perception_for(stored, raw, turn), decision: decision
    )

    assert_includes texts, "la cabina está detenida cerca de planta 2"
    assert_includes texts, "no hay personas dentro"
    assert texts.none? { |text| text.match?(/(?<![[:alnum:]])planta 1(?![[:alnum:]])/i) }
    assert_includes texts, "La puerta llega al marco, pero vuelve a abrir"
    assert_includes texts, "no veo una obstrucción"
    assert_includes texts, "El LED 7 está apagado"
    assert_includes texts, "Al pedir cierre se oye un clic, pero no termina de cerrar"
    assert_equal "18", stored.fact("fault_code")["value"]
    assert_includes stored.rejected.pluck("value"), "8"
    assert stored.goal["text"].match?(/(?<![[:alnum:]])planta 2(?![[:alnum:]])/i)
    assert_not stored.goal["text"].match?(/(?<![[:alnum:]])planta 1(?![[:alnum:]])/i)
    assert_includes explained[:query], "planta 2"
    assert_includes explained[:query], "no hay personas dentro"
    assert_not_includes explained[:query], "planta 1 y no hay personas dentro"

    travel_to @now do
      with_owner do
        session = ConversationSession.create!(
          identifier: "web:plant:#{SecureRandom.hex(4)}",
          channel: "web",
          expires_at: 30.days.from_now,
          active_episode: stored.to_h
        )
        block = SessionContextBuilder.field_problem_block(session)
        obs = block.lines.grep(/\AObs:/).join
        assert_match(/Goal:.*planta 2/i, block)
        assert_includes obs, "no hay personas dentro"
        assert_not block.match?(/(?<![[:alnum:]])planta 1(?![[:alnum:]])/i)
        assert_includes block, "Fault code: 18"
        assert_includes block, "El LED 7 está apagado"
      end
    end
  end

  test "a retracted floor drops that observation and keeps the replacement" do
    episode = open_episode
    episode.append_observation!("detenida cerca de planta 1", correlation_id: "seed")
    episode.append_observation!("no hay personas dentro", correlation_id: "seed")
    turn = "Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1."

    with_owner { settle(episode, report_payload([ "detenida cerca de planta 2" ]), turn) }

    texts = episode.observations.pluck("text")
    assert_includes texts, "detenida cerca de planta 2"
    assert_includes texts, "no hay personas dentro"
    assert texts.none? { |text| text.match?(/(?<![[:alnum:]])planta 1(?![[:alnum:]])/i) }
  end

  test "correcting a code does not leave a residual phrase as the goal" do
    episode = open_episode
    episode.assign_goal!("El display muestra código 8", correlation_id: "seed")
    [
      "El display muestra código 8",
      "La cabina está detenida cerca de planta 1 y no hay personas dentro",
      "La puerta llega al marco, pero vuelve a abrir",
      "El LED 7 está apagado"
    ].each { |text| episode.append_observation!(text, correlation_id: "seed") }
    turn = "No, leí mal: era código 18, no 8."

    with_owner { settle(episode, correction_payload, turn) }

    assert_equal "18", episode.fact("fault_code")["value"]
    assert_not_equal "El display muestra", episode.goal["text"]
    assert episode.goal["text"].match?(/puerta|planta/i)
    assert_includes episode.observations.pluck("text"), "El LED 7 está apagado"
    assert_includes episode.observations.pluck("text"), "La puerta llega al marco, pero vuelve a abrir"

    kept = episode.goal["text"]
    with_owner { settle(episode, { "move" => "follow_up", "assertions" => [], "observations" => [], "pending_resolution" => nil, "clarification_target" => nil }, "¿Y ahora?") }
    with_owner { settle(episode, report_payload([ "Sigue igual" ]), "Sigue igual.") }

    assert_equal kept, episode.goal["text"]
  end

  test "a click inside an observation is not equipment identity" do
    episode = open_episode
    episode.assign_goal!("la puerta no termina de cerrar", correlation_id: "seed")
    turn = "Al pedir cierre se oye un clic, pero no termina de cerrar."
    raw = report_payload(
      [ turn.delete_suffix(".") ],
      [
        { "span" => "clic", "act" => "assert" },
        { "span" => "no termina de cerrar", "act" => "assert" }
      ]
    )

    with_owner { settle(episode, raw, turn) }

    assert_includes episode.observations.pluck("text"), "Al pedir cierre se oye un clic, pero no termina de cerrar"
    assert_empty episode.identifiers
    assert_equal "la puerta no termina de cerrar", episode.goal["text"]
  end

  test "a floor and an indicator state stay observations when asserted without a slot" do
    episode = open_episode
    turn = "planta 2. LED 7 apagado."
    raw = report_payload(
      [ "planta 2", "LED 7 apagado" ],
      [
        { "span" => "planta 2", "act" => "assert" },
        { "span" => "LED 7 apagado", "act" => "assert" }
      ]
    )

    with_owner { settle(episode, raw, turn) }

    texts = episode.observations.pluck("text")
    assert_includes texts, "planta 2"
    assert_includes texts, "LED 7 apagado"
    assert_empty episode.identifiers
    assert_nil episode.fact("manufacturer")
    assert_nil episode.fact("model")
    assert_nil episode.fact("controller")
    assert_not Rag::EquipmentIdentity.from_episode(episode)&.known?
  end

  test "a designator inside an observation stays identity and a reread keeps it out of the symptom slots" do
    episode = open_episode
    turn = "El Elemont MH con placa CEA15 y controlador NICE3000 no cierra y se oye un clic. planta 2. LED 7 apagado."
    raw = report_payload(
      [
        "El Elemont MH con placa CEA15 y controlador NICE3000 no cierra y se oye un clic",
        "planta 2",
        "LED 7 apagado"
      ],
      [
        { "span" => "Elemont MH", "act" => "assert" },
        { "span" => "CEA15", "act" => "assert" },
        { "span" => "NICE3000", "act" => "assert" },
        { "span" => "clic", "act" => "assert" },
        { "span" => "planta 2", "act" => "assert" },
        { "span" => "LED 7 apagado", "act" => "assert" }
      ]
    )

    with_owner { settle(episode, raw, turn) }

    assert_equal [ "Elemont MH", "CEA15", "NICE3000" ], episode.identifiers.pluck("value")
    texts = episode.observations.pluck("text")
    assert_includes texts, "El Elemont MH con placa CEA15 y controlador NICE3000 no cierra y se oye un clic"
    assert_includes texts, "planta 2"
    assert_includes texts, "LED 7 apagado"
    assert_nil episode.fact("manufacturer")
    assert_nil episode.fact("model")
    assert_nil episode.fact("controller")
    identity = Rag::EquipmentIdentity.from_episode(episode)
    assert identity
    assert_not identity.known?
    assert_not_includes episode.to_json, "CEA15+"

    travel_to @now do
      stored = Rag::ActiveEpisode.parse(episode.to_h, now: @now)
      assert_equal [ "Elemont MH", "CEA15", "NICE3000" ], stored.identifiers.pluck("value")
      assert_includes stored.observations.pluck("text"), "planta 2"
      assert_includes stored.observations.pluck("text"), "LED 7 apagado"
      with_owner do
        session = ConversationSession.create!(
          identifier: "web:identity:#{SecureRandom.hex(4)}",
          channel: "web",
          expires_at: 30.days.from_now,
          active_episode: stored.to_h
        )
        reread = Rag::ActiveEpisode.parse(session.reload.active_episode, now: @now)
        assert_equal [ "Elemont MH", "CEA15", "NICE3000" ], reread.identifiers.pluck("value")
        assert_includes reread.observations.pluck("text"), "planta 2"
        assert_includes reread.observations.pluck("text"), "LED 7 apagado"
        assert reread.observations.any? { |item| item["text"].include?("clic") }
      end
    end
  end

  test "a valid opening keeps identity and the problem when a code is corrected" do
    episode = open_episode
    opening = "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza."
    with_owner do
      settle(
        episode,
        report_payload(
          [ "la puerta 1 no termina de cerrar", "el imán no magnetiza" ],
          [
            { "span" => "Elemont MH", "act" => "assert" },
            { "span" => "CEA15", "act" => "assert" }
          ]
        ),
        opening
      )
    end
    goal = episode.goal["text"]
    with_owner { settle(episode, correction_payload, "No, leí mal: era código 18, no 8.") }

    assert_equal goal, episode.goal["text"]
    assert_includes episode.identifiers.pluck("value"), "Elemont MH"
    assert_includes episode.identifiers.pluck("value"), "CEA15"
    assert_equal "18", episode.fact("fault_code")["value"]
    assert_nil episode.fact("manufacturer")
    assert_not_equal "El display muestra", episode.goal["text"]
  end

  test "new work on a fresh episode replaces the goal" do
    episode = open_episode
    turn = "otra falla: la puerta no abre"
    with_owner { settle(episode, report_payload([ "la puerta no abre" ]).merge("move" => "new_work"), turn) }

    assert_includes episode.goal["text"], "la puerta no abre"
  end

  test "a level correction replaces por arriba and keeps the no-code observation" do
    episode = open_episode
    episode.append_observation!("No aparece código de falla", correlation_id: "seed")
    episode.append_observation!("2 o 3 cm por arriba del nivel", correlation_id: "seed")
    turn = "Corrijo lo de arriba: queda unos 2 o 3 cm por debajo del nivel."

    with_owner { settle(episode, report_payload([ "2 o 3 cm por debajo del nivel" ]), turn) }

    texts = episode.observations.pluck("text")
    assert_includes texts, "2 o 3 cm por debajo del nivel"
    assert_includes texts, "No aparece código de falla"
    assert texts.none? { |text| text.include?("por arriba") }
  end

  private

  def settle(episode, raw, turn)
    perception = Rag::TurnPerception.build(
      raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil
    )
    decision = Rag::RoutePolicy.call(previous: episode, perception: perception, focus_count: 0, locale: :es)
    Rag::WorkContextReducer.apply!(
      episode: episode, perception: perception, decision: decision,
      turn: turn, correlation_id: "seed", now: @now
    )
    decision
  end

  def open_episode
    Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
  end

  def seeded_turn_episode
    episode = open_episode
    episode.assign_goal!("El display muestra", correlation_id: "seed")
    episode.write_fact!(
      "fault_code", status: "known", value: "18", source: "user",
      correlation_id: "seed", at: @now.iso8601
    )
    episode.append_rejected!("fault_code", "8")
    episode.append_identifier!("clic", correlation_id: "seed", source: "user")
    [
      "La cabina está detenida cerca de planta 1 y no hay personas dentro",
      "La puerta llega al marco, pero vuelve a abrir",
      "no veo una obstrucción",
      "El LED 7 está apagado",
      "Al pedir cierre se oye un clic, pero no termina de cerrar"
    ].each { |text| episode.append_observation!(text, correlation_id: "seed") }
    episode
  end

  def perception_for(episode, raw, turn)
    Rag::TurnPerception.build(raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil)
  end

  def correction_payload
    {
      "move" => "correct",
      "assertions" => [
        { "span" => "8", "act" => "negate" },
        { "span" => "18", "act" => "assert", "slot_hint" => "fault_code" }
      ],
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def report_payload(observations, assertions = [])
    {
      "move" => "report",
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end
end
