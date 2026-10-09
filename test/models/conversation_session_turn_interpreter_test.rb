# frozen_string_literal: true

require "test_helper"

class ConversationSessionTurnInterpreterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @now = Time.current
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "a report does not become best effort because the model filled pending_resolution" do
    session = web_session
    result = with_owner do
      ask(session, "la puerta no cierra del todo", client(perception(
        "report",
        observations: [ "la puerta no cierra" ],
        pending_resolution: "unknown"
      )))
    end

    assert_equal "ready", result.understanding.decision
    assert_not result.understanding.best_effort?
    assert_includes result.composed, "la puerta no cierra"
  end

  test "an unclear mention of Q2 still stores the carry" do
    session = web_session
    result = with_owner do
      ask(session, "¿Que es Q2?", client(perception(
        "unclear",
        assertions: [ assertion("Q2", "mention") ],
        clarification_target: "referent"
      )))
    end

    assert result.understanding.clarify_first?
    assert_equal [ "Q2" ], session.reload.active_episode.dig("pending_question", "carry")
  end

  test "Q2 with no focus asks for the equipment and does not retrieve or store a fault" do
    session = web_session
    result = with_owner do
      ask(session, "¿Que es Q2?", client(mention("Q2")))
    end

    assert result.understanding.clarify_first?
    assert_nil result.composed
    assert_equal [ "Q2" ], session.reload.active_episode.dig("pending_question", "carry")
    assert_nil session.active_episode.dig("facts", "fault_code")
    assert_nil session.active_episode["goal"]
  end

  test "Q2 carry survives the identity answer and the query keeps both" do
    session = web_session
    doc = manual("nice.pdf")
    with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(monarch_catalog(doc)) do
        ask(session, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2")
        result = ask(
          session, "Monarch NICE3000",
          client(
            perception(
              "answer_pending",
              assertions: [ assertion("Monarch", "assert"), assertion("NICE3000", "assert") ],
              pending_resolution: "value"
            )
          ),
          correlation: "query:nice"
        )
        assert_equal "ready", result.understanding.decision
        assert_includes result.composed, "Q2"
        assert_includes result.composed, "NICE3000"
        assert_match(/monarch/i, result.composed)
      end
    end

    facts = session.reload.active_episode["facts"]
    assert_equal "NICE3000", facts.dig("controller", "value")
    assert_equal "user", facts.dig("controller", "source")
    assert_equal "MONARCH", facts.dig("manufacturer", "value")
    assert_equal "user", facts.dig("manufacturer", "source")
    assert_nil session.active_episode["pending_question"]
  end

  test "the session 196 Elemont MH reading stores the catalog brand and not CEA15+" do
    session = web_session
    elemont = manual("elemont.pdf")
    turn = "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?"
    result = with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(elemont_catalog(elemont)) do
        ask(session, turn, client(door_reading))
      end
    end

    facts = session.reload.active_episode["facts"]
    identifiers = session.active_episode["identifiers"].pluck("value")
    identity = Rag::EquipmentIdentity.from_episode(session.active_episode)

    assert_equal "ready", result.understanding.decision
    assert_not result.understanding.clarify_first?
    assert_nil session.active_episode["pending_question"]
    assert_equal "Elemont", facts.dig("manufacturer", "value")
    assert_equal "user", facts.dig("manufacturer", "source")
    assert_includes identifiers, "Elemont MH"
    assert_includes identifiers, "CEA15"
    assert_not_includes identifiers, "CEA15+"
    assert_not_includes result.composed.to_s, "Elemont Montacargas Hidraulico Modelo MH"
    assert_not_includes result.composed.to_s, "CEA15+"
    assert identity.known?
  end

  test "captured Journey A interpreter outputs preserve one episode through turn 14" do
    turns = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/journey_a_interpreter_raw_20261008.json").read)
    session = web_session
    elemont = manual("journey-a-elemont.pdf")
    first_episode_id = nil
    last_result = nil

    with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(elemont_catalog(elemont)) do
        turns.each_with_index do |row, index|
          last_result = ask(session, row.fetch("turn"), client(row.fetch("tool_input")), correlation: "replay:a:t#{index + 1}")
          stored = session.reload.active_episode
          first_episode_id ||= stored.fetch("episode_id")
          assert_equal first_episode_id, stored.fetch("episode_id"), "turn #{index + 1}"
          next unless index == 4 || index >= 12

          assert_equal "18", stored.dig("facts", "fault_code", "value")
          assert_includes stored.fetch("rejected").pluck("value"), "8"
        end
      end
    end

    stored = session.reload.active_episode
    observations = stored.fetch("observations").pluck("text")
    identifiers = stored.fetch("identifiers").pluck("value")
    assert_includes stored.dig("goal", "text"), "la puerta 1 no termina de cerrar"
    assert_includes identifiers, "Elemont MH"
    assert_includes identifiers, "CEA15"
    assert identifiers.none? { |value| value.match?(/planta|LED|clic/i) }
    assert_includes observations, "la cabina está detenida cerca de planta 2"
    assert_includes observations, "no hay personas dentro"
    assert observations.none? { |text| text.include?("planta 1 y no hay personas") }
    assert_includes observations, "El LED 7 está apagado"
    assert_includes observations, "Al pedir cierre se oye un clic, pero no termina de cerrar"
    assert_includes last_result.composed, "planta 2"
    assert_not_includes last_result.composed, "planta 1 y no hay personas"
    block = with_owner { SessionContextBuilder.field_problem_block(session) }
    identity = Rag::EquipmentIdentity.from_episode(stored)
    assert_includes block, "planta 2"
    assert_includes block, "Fault code: 18"
    assert_equal "user", stored.dig("facts", "manufacturer", "source")
    assert_includes block, "Manufacturer: Elemont (technician)"
    assert identity.known?
    assert_nil Rag::DocumentIdentityScope.applicability_mode(identity)
  end

  test "both visible door manuals keep Elemont and leave CEA15 unresolved" do
    session = web_session
    elemont = manual("elemont.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    controller = manual("cea15.pdf", "Manual CEA15+")
    turn = "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?"
    result = with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(door_catalog(elemont, controller)) do
        ask(session, turn, client(door_reading))
      end
    end

    facts = session.reload.active_episode["facts"]
    identifiers = session.active_episode["identifiers"].pluck("value")
    identity = Rag::EquipmentIdentity.from_episode(session.active_episode)

    assert_equal "ready", result.understanding.decision
    assert_not result.understanding.clarify_first?
    assert_empty session.document_focus_entries
    assert_equal "Elemont", facts.dig("manufacturer", "value")
    assert_equal "user", facts.dig("manufacturer", "source")
    assert_nil facts["controller"]
    assert_includes identifiers, "Elemont MH"
    assert_includes identifiers, "CEA15"
    assert_not_includes identifiers, "CEA15+"
    assert_not_includes result.composed.to_s, "Elemont Montacargas Hidraulico Modelo MH"
    assert_not_includes result.composed.to_s, "Manual CEA15+"
    assert_not_includes result.composed.to_s, "CEA15+"
    assert_not_includes result.composed.to_s, "Controles S.A."
    assert identity.known?
    assert_nil Rag::DocumentIdentityScope.applicability_mode(identity)
  end

  test "an explicit CEA15+ stores the controller and keeps the equipment manufacturer" do
    session = web_session
    elemont = manual("elemont.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    controller = manual("cea15.pdf", "Manual CEA15+")
    seed_episode(session, facts: { "manufacturer" => known("Elemont", source: "catalog") })
    episode = session.active_episode
    episode["identifiers"] = [ { "value" => "Elemont MH", "source" => "user", "correlation_id" => "seed" } ]
    session.update!(active_episode: episode)
    turn = "La placa es CEA15+"
    result = with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(door_catalog(elemont, controller)) do
        ask(session, turn, client(perception("report", assertions: [ assertion("CEA15+", "assert", "controller") ])))
      end
    end

    facts = session.reload.active_episode["facts"]

    assert_equal "ready", result.understanding.decision
    assert_empty session.document_focus_entries
    assert_equal "CEA15+", facts.dig("controller", "value")
    assert_equal "user", facts.dig("controller", "source")
    assert_equal "Elemont", facts.dig("manufacturer", "value")
    assert_equal "catalog", facts.dig("manufacturer", "source")
    assert_not_includes result.composed.to_s, "Controles S.A."
    assert_not_includes result.composed.to_s, "Elemont Montacargas Hidraulico Modelo MH"
    assert_not Rag::EquipmentIdentity.from_episode(session.active_episode).known?
  end

  test "Q2 seek keeps the token and does not ask again" do
    session = web_session
    result = with_owner do
      ask(session, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2")
      ask(
        session, "No sé, busca con eso",
        client(perception("answer_pending", pending_resolution: "seek")),
        correlation: "query:seek"
      )
    end

    assert result.understanding.best_effort?
    assert_includes result.composed, "Q2"
    assert_nil result.understanding.clarification
    assert_nil session.reload.active_episode["pending_question"]
  end

  test "a new job drops the Q2 carry" do
    session = web_session
    with_owner do
      ask(session, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2")
      result = ask(
        session, "otra falla: puertas no cierran",
        client(perception("new_work", observations: [ "puertas no cierran" ])),
        correlation: "query:doors"
      )
      assert_equal "ready", result.understanding.decision
      assert_not_includes result.composed.to_s, "Q2"
      assert_includes result.composed, "puertas"
    end

    assert_nil session.reload.active_episode.dig("pending_question", "carry")
    identifiers = Array(session.active_episode["identifiers"]).pluck("value")
    assert_not_includes identifiers, "Q2"
  end

  test "VF5 with a door symptom searches the code and does not require a controller" do
    session = web_session
    text = "Es VF5, intenta cerrar, vuelve a abrir y marca E03."
    result = with_owner do
      ask(session, text, client(perception(
        "report",
        assertions: [ assertion("VF5", "assert"), assertion("E03", "assert", "fault_code") ],
        observations: [ "intenta cerrar, vuelve a abrir" ]
      )))
    end

    assert_equal "ready", result.understanding.decision
    assert_nil result.understanding.pending_question
    assert_includes result.composed, "VF5"
    assert_includes result.composed, "E03"
    assert_equal "E03", session.reload.active_episode.dig("facts", "fault_code", "value")
    assert_nil session.active_episode.dig("facts", "controller")
  end

  test "a follow-up keeps the open job" do
    session = web_session
    seed_episode(session, facts: { "controller" => known("NICE3000"), "fault_code" => known("E51") }, goal: "Nice300 e51")
    opened = session.live_episode_id
    result = with_owner do
      ask(session, "¿Qué reviso?", client(perception("follow_up")))
    end

    assert_equal "ready", result.understanding.decision
    assert_equal opened, session.reload.live_episode_id
    assert_equal "Nice300 e51", session.active_episode.dig("goal", "text")
    assert_includes result.composed, "NICE3000"
    assert_includes result.composed, "E51"
  end

  test "an unknown pending answer is confirmed and the reply is not the query" do
    session = web_session
    seed_episode(
      session,
      goal: "la puerta no abre",
      pending_question: { "type" => "controller" },
      pending_fact: { "subject" => "controller", "correlation_id" => "seed" }
    )
    result = with_owner do
      ask(session, "Volviendo a eso, no lo sé", client(perception("answer_pending", pending_resolution: "unknown")))
    end

    assert result.understanding.best_effort?
    assert_equal "unknown_confirmed", session.reload.active_episode.dig("facts", "controller", "status")
    assert_not_includes result.composed.to_s, "no lo sé"
    assert_includes result.composed, "la puerta no abre"
  end

  test "an uncatalogued pending answer takes the slot Danebo asked" do
    session = web_session
    seed_episode(
      session,
      pending_question: { "type" => "controller" },
      pending_fact: { "subject" => "controller", "correlation_id" => "seed" }
    )
    with_owner do
      ask(session, "ABC900", client(perception("answer_pending", assertions: [ assertion("ABC900", "assert", "model") ], pending_resolution: "value")))
    end

    fact = session.reload.active_episode.dig("facts", "controller")
    assert_equal "ABC900", fact["value"]
    assert_equal "user", fact["source"]
    assert_nil session.active_episode.dig("facts", "model")
  end

  test "an asserted literal is context and does not ask for a controller" do
    session = web_session
    result = with_owner do
      ask(session, "El controlador es ABC900", client(perception("report", assertions: [ assertion("ABC900", "assert", "controller") ])))
    end

    assert_equal "ready", result.understanding.decision
    assert_not result.understanding.clarify_first?
    identifiers = Array(session.reload.active_episode["identifiers"]).pluck("value")
    assert_includes identifiers, "ABC900"
  end

  test "a meta question does not become an observation or a query" do
    session = web_session
    result = with_owner do
      ask(session, "¿Necesitas controlador?", client(perception("meta")))
    end

    assert result.understanding.meta?
    assert_nil result.composed
    assert_nil session.reload.active_episode["goal"]
    assert_nil session.active_episode["observations"]
  end

  test "a correction replaces the active controller and rejects the old value" do
    session = web_session
    seed_episode(session, facts: { "controller" => known("NICE3000", source: "catalog") })
    text = "No, no es NICE3000. Es NICE1000."
    with_owner do
      ask(session, text, client(perception("correct", assertions: [
        assertion("NICE3000", "negate"),
        assertion("NICE1000", "assert")
      ])))
    end

    episode = session.reload.active_episode
    assert_equal "NICE1000", episode.dig("facts", "controller", "value")
    assert_equal "user", episode.dig("facts", "controller", "source")
    assert_includes episode["rejected"].pluck("value"), "NICE3000"
  end

  test "an uncatalogued replacement takes the corrected slot" do
    session = web_session
    seed_episode(session, facts: { "controller" => known("NICE3000") })
    text = "No, no es NICE3000. Es ABC900."
    with_owner do
      ask(session, text, client(perception("correct", assertions: [
        assertion("NICE3000", "negate"),
        assertion("ABC900", "assert")
      ])))
    end

    episode = session.reload.active_episode
    assert_equal "ABC900", episode.dig("facts", "controller", "value")
    assert_equal "user", episode.dig("facts", "controller", "source")
    assert_includes episode["rejected"].pluck("value"), "NICE3000"
  end

  test "new work opens another episode and clears the procedure" do
    session = web_session
    seed_episode(
      session,
      goal: "ajuste de frenos",
      observations: [ { "text" => "ruido en la máquina", "correlation_id" => "seed" } ],
      procedure: { "step" => 1 }
    )
    previous = session.live_episode_id
    logs = capture_logs do
      with_owner do
        ask(session, "otra falla: puertas no cierran", client(perception("new_work", observations: [ "puertas no cierran" ])))
      end
    end

    session.reload
    assert_not_equal previous, session.live_episode_id
    assert_equal({}, session.current_procedure)
    assert_not_includes session.active_episode.dig("goal", "text").to_s, "ajuste de frenos"
    texts = Array(session.active_episode["observations"]).pluck("text")
    assert_not_includes texts, "ruido en la máquina"
    assert_match(/"case_boundary_reason":"new_episode"/, logs)
  end

  test "a focus change after Haiku uses the fresh focus and does not fall back" do
    session = web_session
    uri = "s3://test-bucket/manuals/focus.pdf"
    doc = manual("focus.pdf")
    interpreter = FocusMutatingClient.new(session, mention("Q2"), uri, doc.id)
    result = with_owner { ask(session, "¿Que es Q2?", interpreter) }

    assert_equal "search_and_clarify", result.understanding.decision
    assert_not result.understanding.fallback
    assert_includes result.understanding.focus_uris, uri
    assert_includes result.composed, "Q2"
    assert_nil session.reload.active_episode.dig("facts", "fault_code")
  end

  test "a private catalog identity stays an unresolved identifier for the other tenant" do
    owner = accounts(:legacy)
    outsider = web_session(account: accounts(:climb))
    uid = SecureRandom.uuid
    key = "manuals/#{uid}.pdf"
    KbDocument.create!(account: owner, s3_key: key, display_name: "Private", document_uid: uid, aliases: [])
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [ catalog_entry(owner, uid, key, "SecretCo", "PRIVATE900", "controller") ]
    })

    with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(catalog) do
        ask(outsider, "PRIVATE900", client(perception("report", assertions: [ assertion("PRIVATE900", "assert", "controller") ])))
      end
    end

    episode = outsider.reload.active_episode
    assert_nil episode.dig("facts", "controller")
    assert_nil episode.dig("facts", "manufacturer")
    assert_not_includes episode.to_json, "SecretCo"
    assert_includes Array(episode["identifiers"]).pluck("value"), "PRIVATE900"
  end

  test "the caption is interpreted and a photo request does not reuse that query" do
    session = web_session
    doc = manual("nice.pdf")
    with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(monarch_catalog(doc)) do
        ask(session, "el controlador es NICE3000", client(perception("report", assertions: [ assertion("NICE3000", "assert") ])))
      end
    end
    assert_equal "NICE3000", session.reload.active_episode.dig("facts", "controller", "value")

    concern = Class.new { include RagQueryConcern }.new
    episode_turn = Struct.new(:understanding).new(Object.new)
    assert_nil concern.send(:turn_understanding_for, "el controlador es NICE3000", session, episode_turn, nil, [ {} ], [], false)
  end

  test "the same correlation does not call Haiku twice or append a second bubble" do
    session = web_session
    interpreter = client(perception("report", assertions: [ assertion("ABC900", "assert") ]))
    with_owner do
      ask(session, "El controlador es ABC900", interpreter, correlation: "query:same")
      second = ask(session, "El controlador es ABC900", interpreter, correlation: "query:same")
      assert_equal "duplicate_correlation", second.reason
    end

    assert_equal 1, interpreter.payloads.size
    assert_equal 1, session.reload.conversation_history.count { |row| row["role"] == "user" }
  end

  test "an interpreter transport failure keeps the literal report without confirming identity" do
    session = web_session
    turn = "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?"
    error = StandardError.new("timeout talking Authorization: Bearer secret AKIAIOSFODNN7EXAMPLE")
    events = []
    logs = []
    with_owner do
      events = Rag::ValidationCapture.capture do
        logs = pilot_events_from do
          ask(session, turn, RaisingInterpreterClient.new(error), correlation: "stage2:a:t01")
        end
      end
    end

    episode = session.reload.active_episode
    assert_equal turn, episode.dig("goal", "text")
    assert_includes episode["observations"].pluck("text"), turn
    assert_nil episode.dig("facts", "manufacturer")
    assert_nil episode.dig("facts", "model")
    assert_empty Array(episode["identifiers"])
    failure = events.find { |row| row["kind"] == "interpreter_failure" }
    assert_equal "StandardError", failure["error_class"]
    assert_equal "converse", failure["stage"]
    assert_equal "stage2:a:t01", failure["correlation_id"]
    assert_equal 1, failure["attempt"]
    assert_not_includes failure["reason"], "AKIA"
    assert_not_includes failure["reason"], "Bearer"
    traced = logs.find { |row| row["event"] == "turn_interpreter" }
    assert_equal "StandardError", traced["error_class"]
    assert_equal "converse", traced["stage"]
    assert_equal "transport_error", traced["turn_interpreter_status"]
    assert_equal 0, traced["input_tokens"]
    assert_equal 0, traced["output_tokens"]
    assert_not_includes traced["interpreter_error_reason"].to_s, "AKIA"
    assert_no_enqueued_jobs only: TrackBedrockQueryJob

    with_owner do
      ask(
        session,
        "El display muestra código 8.",
        client(perception("report", observations: [ "El display muestra código 8" ], assertions: [ assertion("código 8", "assert", "fault_code") ])),
        correlation: "stage2:a:t02"
      )
    end

    followed = session.reload.active_episode
    assert_equal episode["episode_id"], followed["episode_id"]
    assert_equal turn, followed.dig("goal", "text")
    assert_nil followed.dig("facts", "manufacturer")
  end

  test "a converse timeout is transport and does not record usage" do
    session = web_session
    turn = "la puerta no termina de cerrar y el imán no magnetiza"
    error = Timeout::Error.new("timeout talking Authorization: Bearer secret AKIAIOSFODNN7EXAMPLE")
    events = []
    logs = []
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      with_owner do
        events = Rag::ValidationCapture.capture do
          logs = pilot_events_from do
            ask(session, turn, RaisingInterpreterClient.new(error), correlation: "stage:timeout")
          end
        end
      end
    end

    failure = events.find { |row| row["kind"] == "interpreter_failure" }
    assert_equal "converse", failure["stage"]
    assert_equal "Timeout::Error", failure["error_class"]
    assert_equal 1, failure["attempt"]
    assert_not_includes failure["reason"], "AKIA"
    assert_not_includes failure["reason"], "Bearer"
    traced = logs.find { |row| row["event"] == "turn_interpreter" }
    assert_equal "converse", traced["stage"]
    assert_equal "timeout", traced["turn_interpreter_status"]
    assert_equal 0, traced["input_tokens"]
    assert_equal 0, traced["output_tokens"]
    assert_not_includes traced.to_json, "AKIA"
    assert_equal 0, BedrockQuery.where(correlation_id: "stage:timeout").count
    assert_equal turn, session.reload.active_episode.dig("goal", "text")
    assert_empty Array(session.active_episode["identifiers"])
  end

  test "a local failure after a paid response records that stage and the usage once" do
    session = web_session
    turn = "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?"
    error = RuntimeError.new("perception build Authorization: Bearer secret AKIAIOSFODNN7EXAMPLE")
    original = Rag::TurnPerception.method(:build)
    events = []
    logs = []
    Rag::TurnPerception.define_singleton_method(:build) { |*, **| raise error }
    perform_enqueued_jobs only: TrackBedrockQueryJob do
      with_owner do
        events = Rag::ValidationCapture.capture do
          logs = pilot_events_from do
            ask(session, turn, client(perception("report", observations: [ "la puerta no cierra" ])), correlation: "stage:local")
          end
        end
      end
    end

    failure = events.find { |row| row["kind"] == "interpreter_failure" }
    assert_equal "perception", failure["stage"]
    assert_equal "RuntimeError", failure["error_class"]
    assert_equal "stage:local", failure["correlation_id"]
    assert_equal 1, failure["attempt"]
    assert_not_includes failure["reason"], "AKIA"
    assert_not_includes failure["reason"], "Bearer"
    assert_not_includes failure.to_json, "secret"
    traced = logs.find { |row| row["event"] == "turn_interpreter" }
    assert_equal "perception", traced["stage"]
    assert_equal "local_error", traced["turn_interpreter_status"]
    assert_not_equal "converse", traced["stage"]
    assert_not_equal "transport_error", traced["turn_interpreter_status"]
    assert_equal 4, traced["input_tokens"]
    assert_equal 2, traced["output_tokens"]
    assert_not_includes traced.to_json, "AKIA"
    rows = BedrockQuery.where(correlation_id: "stage:local")
    assert_equal 1, rows.count
    assert_equal 4, rows.sole.input_tokens
    assert_equal 2, rows.sole.output_tokens
    assert_equal rows.sole.cost, BedrockQuery.new(model_id: rows.sole.model_id, input_tokens: 4, output_tokens: 2).cost
    episode = session.reload.active_episode
    assert_equal turn, episode.dig("goal", "text")
    assert_empty Array(episode["identifiers"])
    assert_nil episode.dig("facts", "manufacturer")
  ensure
    Rag::TurnPerception.define_singleton_method(:build) { |*args, **kwargs| original.call(*args, **kwargs) } if original
  end

  test "an invalid tool payload stays a contract failure and not an interpreter exception" do
    session = web_session
    turn = "la puerta no cierra del todo"
    bad = perception("report", observations: [ "la puerta no cierra" ]).merge("route" => "ready")
    events = []
    logs = []
    perform_enqueued_jobs only: TrackBedrockQueryJob do
      with_owner do
        events = Rag::ValidationCapture.capture do
          logs = pilot_events_from do
            ask(session, turn, client(bad), correlation: "stage:invalid")
          end
        end
      end
    end

    assert events.none? { |row| row["kind"] == "interpreter_failure" }
    traced = logs.find { |row| row["event"] == "turn_interpreter" }
    assert_nil traced["stage"]
    assert_nil traced["error_class"]
    assert_equal "invalid_schema", traced["turn_interpreter_status"]
    assert_not_equal "transport_error", traced["turn_interpreter_status"]
    assert_equal 1, BedrockQuery.where(correlation_id: "stage:invalid").count
    assert_equal turn, session.reload.active_episode.dig("goal", "text")
    assert_empty Array(session.active_episode["identifiers"])
  end

  test "an episode that changes before the lock is not rewritten from the model" do
    session = web_session
    interpreter = SnapshotMutatingClient.new(session, perception("report", assertions: [ assertion("ABC900", "assert") ]))
    result = with_owner { ask(session, "El controlador es ABC900", interpreter) }

    assert result.understanding.fallback
    assert_equal "otro trabajo", session.reload.active_episode.dig("goal", "text")
    assert_not_includes Array(session.active_episode["identifiers"]).pluck("value"), "ABC900"
  end

  test "Haiku sees the same truncated turn that is stored and validated" do
    session = web_session
    text = (("palabra " * 40) + "COLADETRAS")
    interpreter = client(perception("report", assertions: [ assertion("COLADETRAS", "assert") ]))
    with_owner { ask(session, text, interpreter) }

    stored = session.reload.conversation_history.last["content"]
    sent = JSON.parse(interpreter.payloads.first[:messages].first[:content].first[:text])
    assert_equal Rag::TurnText.truncate(text), stored
    assert_equal stored, sent["turn"]
    assert_not_includes stored, "COLADETRAS"
    assert_not_includes Array(session.active_episode["identifiers"]).pluck("value"), "COLADETRAS"
  end

  test "an expired episode is sent to Haiku without the old job" do
    session = web_session
    seed_episode(session, goal: "objetivo viejo", at: @now - 5.hours, procedure: { "step" => 3 })
    interpreter = client(perception("report", observations: [ "la puerta no cierra bien" ]))
    logs = capture_logs do
      with_owner { ask(session, "la puerta no cierra bien ahora", interpreter, now: @now) }
    end

    sent = JSON.parse(interpreter.payloads.first[:messages].first[:content].first[:text])
    assert_equal({}, sent["work_context"])
    session.reload
    assert_not_includes session.active_episode.dig("goal", "text").to_s, "objetivo viejo"
    assert_equal({}, session.current_procedure)
    assert_match(/"case_boundary_reason":"episode_expired"/, logs)
  end

  test "owner mode leaves a menu selection on the legacy recorder" do
    session = web_session
    interpreter = client(perception("report"))
    def interpreter.converse(*)
      raise "owner interpreter must not run for a selection"
    end

    assert_nothing_raised do
      with_owner do
        session.record_user_turn!(
          "Manual A", user_id: @user.id, correlation_id: "query:menu", selection_turn: true, interpreter_client: interpreter
        )
      end
    end
    assert_equal 1, session.reload.conversation_history.count { |row| row["role"] == "user" }
  end

  test "a relevant photo follows the open job without another vision or model call" do
    session = web_session
    photo = observed_photo
    seed_episode(session, active_photo: photo_ref(photo))
    interpreter = client(perception("follow_up"))
    vision = vision_calls do
      with_owner { ask(session, "¿Qué reviso ahora?", interpreter) }
    end

    assert_equal 1, interpreter.payloads.size
    assert_equal 0, vision
    sent = JSON.parse(interpreter.payloads.first[:messages].first[:content].first[:text])
    assert_equal "relevant", sent.dig("work_context", "active_photo_context", "relevance_to_goal")
    assert_includes session.turn_active_photo_context.generation_block, "Photo Evidence for the active episode"
    context = SessionContextBuilder.build(session)
    assert_includes context, "NICE3000"
    assert_includes context, "Not stated by the technician."
    result = session.reload
    assert_includes result.active_episode.fetch("goal", {}) .fetch("text"), "reviso"
  end

  test "one visual referent is a follow up and two referents stay unclear without retrieval" do
    session = web_session
    photo = observed_photo(visible_text: [ "E51" ])
    seed_episode(session, active_photo: photo_ref(photo), goal: "revisar el controlador")
    followed = with_owner { ask(session, "¿Y eso qué significa?", client(perception("follow_up"))) }
    assert_equal "ready", followed.understanding.decision
    assert_includes followed.composed, "E51"

    contrast = web_session
    seed_episode(contrast, active_photo: photo_ref(photo), goal: "revisar el controlador")
    unclear = with_owner do
      ask(contrast, "¿Y eso qué significa?", client(perception("unclear", clarification_target: "referent")))
    end
    assert unclear.understanding.clarify_first?
    assert_nil unclear.composed
    assert_equal "referent", contrast.reload.active_episode.dig("pending_question", "type")
  end

  test "new work drops the previous photo from the query and the generation block" do
    session = web_session
    photo = observed_photo
    seed_episode(
      session,
      goal: "Nice300 e51",
      facts: { "controller" => known("NICE3000"), "fault_code" => known("E51") },
      active_photo: photo_ref(photo)
    )
    result = with_owner do
      ask(session, "Otra falla: Elemont MH no arranca", client(perception(
        "new_work",
        assertions: [ assertion("Elemont", "assert") ],
        observations: [ "Elemont MH no arranca" ]
      )))
    end

    assert_equal "ready", result.understanding.decision
    assert_nil session.reload.active_episode["active_photo"]
    assert_not_includes result.composed.to_s, "NICE3000"
    assert_nil session.turn_active_photo_context
  end

  test "an unrelated photo is visible to the interpreter and absent from query and generation" do
    session = web_session
    photo = observed_photo(relevance_to_goal: "unrelated", manufacturer: "OTIS", model: "OTIS2000", visible_text: [ "ZZ9" ], canonical_component: "puerta")
    seed_episode(
      session,
      goal: "Nice300 e51",
      facts: { "controller" => known("NICE3000"), "fault_code" => known("E51") },
      active_photo: photo_ref(photo)
    )
    interpreter = client(perception("follow_up"))
    result = with_owner { ask(session, "¿Qué reviso ahora?", interpreter) }
    sent = JSON.parse(interpreter.payloads.first[:messages].first[:content].first[:text])

    assert_equal "unrelated", sent.dig("work_context", "active_photo_context", "relevance_to_goal")
    assert_includes result.composed, "NICE3000"
    assert_not_includes result.composed, "OTIS2000"
    assert_not_includes result.composed, "ZZ9"
    assert_nil session.turn_active_photo_context&.generation_block
    assert_not_includes SessionContextBuilder.build(session), "OTIS2000"
  end

  test "a material work-relation ambiguity does not retrieve or mutate the job" do
    session = web_session
    seed_episode(session, goal: "la puerta no cierra", facts: { "controller" => known("NICE3000") })
    opened = session.live_episode_id
    result = with_owner do
      ask(session, "No, ese era el otro", client(perception("unclear", clarification_target: "work_relation")))
    end

    episode = session.reload.active_episode
    assert result.understanding.clarify_first?
    assert_nil result.composed
    assert_equal false, result.understanding.outside_discovery
    assert_equal opened, session.live_episode_id
    assert_equal "la puerta no cierra", episode.dig("goal", "text")
    assert_equal "NICE3000", episode.dig("facts", "controller", "value")
    assert_equal "work_relation", episode.dig("pending_question", "type")
    assert_nil episode["pending_fact"]
    assert_equal "¿Esto sigue siendo el mismo equipo o estás hablando de otro?", result.understanding.clarification
  end

  test "a thin new work opens an empty episode and does not retrieve even with focus" do
    [ 0, 1 ].each do |focus|
      session = web_session
      photo = observed_photo
      doc = manual("focus-#{focus}.pdf")
      session.update!(document_focus: [ focus_entry(doc) ]) if focus.positive?
      seed_episode(
        session,
        goal: "la puerta no cierra",
        facts: { "controller" => known("NICE3000") },
        observations: [ { "text" => "la puerta no cierra bien", "correlation_id" => "seed" } ],
        pending_question: { "type" => "work_relation", "carry" => [ "Q2" ] },
        active_photo: photo_ref(photo),
        rejected: [ { "slot" => "controller", "value" => "OLD900" } ],
        procedure: { "step" => 4 }
      )
      previous = session.live_episode_id
      result = with_owner do
        ask(session, "Es otro ascensor", client(perception("new_work")))
      end

      episode = session.reload.active_episode
      assert_equal "clarify_first", result.understanding.decision
      assert_nil result.composed
      assert_equal false, result.understanding.outside_discovery
      assert_not_equal previous, session.live_episode_id
      assert_nil episode["goal"]
      assert_nil episode["active_photo"]
      assert_empty episode["facts"]
      assert_nil episode["observations"]
      assert_nil episode["rejected"]
      assert_not_includes Array(episode["identifiers"]).pluck("value"), "Q2"
      assert_equal({}, session.current_procedure)
      assert_equal "¿Qué equipo o qué falla estás revisando?", result.understanding.clarification
      if focus.positive?
        assert_equal [ doc.id ], session.focus_document_ids
      end
    end
  end

  test "a new work that names the equipment retrieves that job" do
    session = web_session
    seed_episode(session, goal: "la puerta no cierra", facts: { "controller" => known("NICE3000") })
    result = with_owner do
      ask(session, "Ahora tengo otro KONE que no nivela", client(perception(
        "new_work",
        assertions: [ assertion("KONE", "assert") ],
        observations: [ "otro KONE que no nivela" ]
      )))
    end

    assert_equal "ready", result.understanding.decision
    assert_includes result.composed, "KONE"
    assert_includes result.composed, "nivela"
    assert_not_includes result.composed, "NICE3000"
    assert_nil session.reload.active_episode["active_photo"]
  end

  test "a photo reference keeps the active photo when one referent is dominant" do
    session = web_session
    photo = observed_photo
    seed_episode(session, goal: "la puerta no cierra", active_photo: photo_ref(photo))
    result = with_owner { ask(session, "Me refería al de la foto", client(perception("follow_up"))) }

    assert_equal "ready", result.understanding.decision
    assert_equal photo.id, session.reload.active_episode.dig("active_photo", "field_photo_id")
    assert_includes result.composed, "NICE3000"
  end

  test "conversational carry is promoted once on the same episode and dropped for new work" do
    session = web_session
    with_owner do
      ask(session, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2")
      ask(session, "No, ese era el otro", client(perception("unclear", clarification_target: "work_relation")), correlation: "query:other")
    end
    episode = session.reload.active_episode
    assert_equal "work_relation", episode.dig("pending_question", "type")
    assert_equal [ "Q2" ], episode.dig("pending_question", "carry")
    assert_nil episode["pending_fact"]

    continued = with_owner do
      ask(session, "Sí, este mismo", client(perception("follow_up")), correlation: "query:same-job")
    end
    kept = session.reload.active_episode
    assert_includes Array(kept["identifiers"]).pluck("value"), "Q2"
    assert_not_equal "work_relation", kept.dig("pending_question", "type")
    assert_includes continued.composed.to_s, "Q2" if continued.understanding.performs_retrieval?

    other = web_session
    with_owner do
      ask(other, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2b")
      ask(other, "No, ese era el otro", client(perception("unclear", clarification_target: "work_relation")), correlation: "query:otherb")
      opened = ask(other, "Es otro ascensor", client(perception("new_work")), correlation: "query:new")
      assert_nil opened.composed
    end
    assert_not_includes Array(other.reload.active_episode["identifiers"]).pluck("value"), "Q2"
  end

  test "a typed turn without a photo does not ask for one or change the route" do
    session = web_session
    seed_episode(session, goal: "Nice300 e51", facts: { "controller" => known("NICE3000"), "fault_code" => known("E51") })
    interpreter = client(perception("follow_up"))
    result = with_owner { ask(session, "¿Qué reviso?", interpreter) }
    sent = JSON.parse(interpreter.payloads.first[:messages].first[:content].first[:text])

    assert_equal "ready", result.understanding.decision
    assert_nil sent.dig("work_context", "active_photo_context")
    assert_not_includes result.understanding.clarification.to_s, "foto"
    assert_includes result.composed, "NICE3000"
  end

  test "a changed episode discards the photo context with the perception" do
    session = web_session
    photo = observed_photo(model: "NICE3000")
    seed_episode(session, active_photo: photo_ref(photo), goal: "el controlador")
    interpreter = SnapshotMutatingClient.new(session, perception("follow_up"))
    result = with_owner { ask(session, "¿Qué reviso ahora?", interpreter) }

    assert result.understanding.fallback
    assert_nil session.turn_active_photo_context
    assert_not_includes result.composed.to_s, "NICE3000"
    assert_not_includes SessionContextBuilder.build(session), "Photo Evidence for the active episode"
  end

  test "owner photo writes close only the manufacturer slot they just stored" do
    session = web_session
    with_owner do
      seed_episode(
        session,
        pending_question: { "type" => "manufacturer" },
        pending_fact: { "subject" => "manufacturer", "correlation_id" => "seed" }
      )
      session.record_photo_observation!(
        photo_value: { manufacturer: "NICE", model_visible: "UNKNOWN", relevance_to_goal: "relevant", target_visible: true },
        field_photo_id: 11, sha256: "mfr", correlation_id: "photo:mfr", expected_episode_id: session.live_episode_id
      )
    end
    closed = session.reload.active_episode
    assert_equal "NICE", closed.dig("facts", "manufacturer", "value")
    assert_equal "photo", closed.dig("facts", "manufacturer", "source")
    assert_nil closed["pending_question"]

    unrelated = web_session
    with_owner do
      seed_episode(
        unrelated,
        pending_question: { "type" => "manufacturer" },
        pending_fact: { "subject" => "manufacturer", "correlation_id" => "seed" }
      )
      unrelated.record_photo_observation!(
        photo_value: { manufacturer: "OTIS", model_visible: "OTIS2000", relevance_to_goal: "unrelated" },
        field_photo_id: 12, sha256: "unrelated", correlation_id: "photo:unrelated", expected_episode_id: unrelated.live_episode_id
      )
    end
    kept = unrelated.reload.active_episode
    assert_nil kept.dig("facts", "manufacturer")
    assert_equal "manufacturer", kept.dig("pending_question", "type")
  end

  test "a photo model does not clear a controller carry or a work relation question" do
    session = web_session
    with_owner do
      seed_episode(
        session,
        pending_question: { "type" => "controller", "carry" => [ "Q2" ] },
        pending_fact: { "subject" => "controller", "correlation_id" => "seed" }
      )
      session.record_photo_observation!(
        photo_value: { manufacturer: "UNKNOWN", model_visible: "NICE3000", relevance_to_goal: "relevant", target_visible: true },
        field_photo_id: 13, sha256: "model", correlation_id: "photo:model", expected_episode_id: session.live_episode_id
      )
      session.record_assistant_turn!(
        "¿Qué controlador es? El modelo parece NICE3000.",
        user_id: @user.id, correlation_id: "photo:model", expected_episode_id: session.live_episode_id, writer: "photo_assistant"
      )
    end
    episode = session.reload.active_episode
    assert_equal "NICE3000", episode.dig("facts", "model", "value")
    assert_equal "photo", episode.dig("facts", "model", "source")
    assert_equal "controller", episode.dig("pending_question", "type")
    assert_equal [ "Q2" ], episode.dig("pending_question", "carry")
    assert_equal "controller", episode.dig("pending_fact", "subject")

    relation = web_session
    with_owner do
      seed_episode(relation, pending_question: { "type" => "work_relation", "carry" => [ "Q2" ] })
      relation.record_photo_observation!(
        photo_value: { manufacturer: "NICE", model_visible: "NICE3000", relevance_to_goal: "relevant", target_visible: true },
        field_photo_id: 14, sha256: "relation", correlation_id: "photo:relation", expected_episode_id: relation.live_episode_id
      )
      relation.record_assistant_turn!(
        "Veo un NICE3000.",
        user_id: @user.id, correlation_id: "photo:relation", expected_episode_id: relation.live_episode_id, writer: "photo_assistant"
      )
    end
    kept = relation.reload.active_episode
    assert_equal "work_relation", kept.dig("pending_question", "type")
    assert_equal [ "Q2" ], kept.dig("pending_question", "carry")
    assert_nil kept["pending_fact"]
  end

  test "a clarify-first text turn keeps its pending after the photo assistant delivers" do
    session = web_session
    with_owner do
      ask(session, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2")
      session.record_photo_observation!(
        photo_value: { manufacturer: "UNKNOWN", model_visible: "P1", relevance_to_goal: "relevant", target_visible: true },
        field_photo_id: 15, sha256: "after-text", correlation_id: "photo:after", expected_episode_id: session.live_episode_id
      )
      session.record_assistant_turn!(
        "¿Qué controlador estás revisando?",
        user_id: @user.id, correlation_id: "photo:after", expected_episode_id: session.live_episode_id, writer: "photo_assistant"
      )
    end

    episode = session.reload.active_episode
    assert_equal "controller", episode.dig("pending_question", "type")
    assert_equal [ "Q2" ], episode.dig("pending_question", "carry")
  end

  test "the default mode does not call the owner interpreter" do
    session = web_session
    interpreter = client(perception("report"))
    def interpreter.converse(*)
      raise "owner interpreter must stay off"
    end

    assert_nothing_raised do
      isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
        isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
          isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") do
            session.record_user_turn!(
              "la puerta no cierra", user_id: @user.id, correlation_id: "query:off", interpreter_client: interpreter
            )
          end
        end
      end
    end
  end

  test "an unmatched negate is traced as ignored and the composed query drops the turn" do
    session = web_session
    sentence = "No veo ningún código de falla"
    seed_episode(
      session,
      goal: "queda pasado de nivel",
      observations: [ { "text" => "pasa solo en planta 3", "correlation_id" => "seed" } ]
    )
    events = []
    result = nil
    with_owner do
      events = pilot_events_from do
        result = ask(session, sentence, client(perception("report", assertions: [ assertion(sentence, "negate") ])), now: @now + 2.minutes)
      end
    end

    interpreter = events.find { |event| event["event"] == "turn_interpreter" }
    turn = events.find { |event| event["event"] == "field_companion_turn" }
    entry = interpreter["interpreter_assertions"].sole
    assert_equal "report", interpreter["interpreter_move"]
    assert_includes entry, "negate:negate::ignored(no_slot):"
    assert_includes entry, sentence
    assert_not_includes entry, "absent"
    assert_equal Digest::SHA256.hexdigest(sentence), turn["original_sha256"]
    assert_equal Digest::SHA256.hexdigest(result.composed.to_s), turn["effective_sha256"]
    assert_not_equal turn["original_sha256"], turn["effective_sha256"]
    assert_includes turn["query_components"], "current_turn:dropped"
    assert_not_includes Array(turn["episode_fields_changed"]), "fault_code"
    assert turn["state_before_sha256"].present?
    assert turn["state_after_sha256"].present?
    assert_not_equal turn["state_before_sha256"], turn["state_after_sha256"]
    assert_nil session.reload.active_episode.dig("facts", "fault_code")
    assert_not_includes result.composed.to_s, "código"
    assert_not turn.key?("meta_kind")
    assert_not interpreter.key?("meta_kind")
  end

  test "a photo offer stays meta and the trace does not invent meta_kind" do
    session = web_session
    text = "Tengo una foto, ¿te sirve?"
    seed_episode(session, goal: "ajustar frenos")
    events = []
    result = nil
    with_owner do
      events = pilot_events_from do
        result = ask(session, text, client(perception("meta")))
      end
    end

    interpreter = events.find { |event| event["event"] == "turn_interpreter" }
    turn = events.find { |event| event["event"] == "field_companion_turn" }
    assert_equal "meta", result.understanding.decision
    assert_nil result.composed
    assert_equal "meta", interpreter["interpreter_move"]
    assert_equal [], turn["episode_fields_changed"]
    assert_equal turn["state_before_sha256"], turn["state_after_sha256"]
    assert_includes turn["query_components"], "current_turn:dropped"
    assert_equal "ep_seed", session.reload.active_episode["episode_id"]
    assert_equal "ajustar frenos", session.active_episode.dig("goal", "text")
    assert_not turn.key?("meta_kind")
    assert_not interpreter.key?("meta_kind")
    assert_not events.any? { |event| event["event"] == "kb_retrieve" }
  end

  test "an assistant turn does not store the reply under the query digests" do
    session = web_session
    events = []
    with_owner do
      seed_episode(session, goal: "ajustar frenos")
      events = pilot_events_from do
        session.record_assistant_turn!(
          "Revisé el freno.",
          user_id: @user.id,
          correlation_id: "asst-1",
          expected_episode_id: session.live_episode_id
        )
      end
    end

    turn = events.find { |event| event["event"] == "field_companion_turn" }
    assert_equal "assistant", turn["result"]
    assert_not turn.key?("original_sha256")
    assert_not turn.key?("effective_sha256")
    assert_not turn.key?("query_components")
    assert turn.key?("state_before_sha256")
    assert turn.key?("state_after_sha256")
  end

  test "a trace failure does not roll back the technician turn" do
    session = web_session
    sentence = "la puerta no cierra"
    original = Rag::CausalTrace.method(:assertion_tokens)
    Rag::CausalTrace.define_singleton_method(:assertion_tokens) { |*| raise "trace down" }
    with_owner do
      ask(session, sentence, client(perception("report", observations: [ sentence ])))
    end
    assert_equal sentence, session.reload.conversation_history.last["content"]
    assert_equal sentence, session.active_episode.dig("goal", "text")
  ensure
    Rag::CausalTrace.define_singleton_method(:assertion_tokens) { |*args, **kwargs| original.call(*args, **kwargs) } if original
  end

  private

  def pilot_events_from
    log = capture_logs { yield }
    log.lines.filter_map { |line|
      next unless line.include?("[PILOT_USAGE]")

      JSON.parse(line.split("[PILOT_USAGE] ", 2).last)
    }
  end

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end

  def ask(session, text, interpreter, correlation: nil, now: Time.current)
    session.record_user_turn!(
      text,
      user_id: @user.id,
      correlation_id: correlation || "query:#{SecureRandom.hex(4)}",
      interpreter_client: interpreter,
      now: now
    )
  end

  def web_session(account: @account)
    ConversationSession.create!(
      identifier: "web:owner:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: @user,
      account: account
    )
  end

  def manual(key, display_name = key)
    KbDocument.create!(
      s3_key: "uploads/2026/owner/#{key}",
      display_name: display_name,
      document_uid: SecureRandom.uuid,
      aliases: [],
      account: @account
    )
  end

  def door_catalog(elemont, controller)
    Rag::DocumentIdentityCatalog.new({
      "documents" => [
        {
          "account_id" => @account.id.to_s,
          "document_id" => elemont.document_uid,
          "s3_key" => elemont.s3_key,
          "display_name" => elemont.display_name,
          "brands" => [ "Elemont" ],
          "designators" => [ "MH" ],
          "generic" => false,
          "confirmed" => true
        },
        {
          "account_id" => @account.id.to_s,
          "document_id" => controller.document_uid,
          "s3_key" => controller.s3_key,
          "display_name" => controller.display_name,
          "brands" => [ "Controles S.A." ],
          "designators" => [ { "value" => "CEA15+", "type" => "controller" } ],
          "generic" => false,
          "confirmed" => true
        }
      ]
    })
  end

  def elemont_catalog(elemont)
    Rag::DocumentIdentityCatalog.new({
      "documents" => [
        {
          "account_id" => @account.id.to_s,
          "document_id" => elemont.document_uid,
          "s3_key" => elemont.s3_key,
          "display_name" => "Elemont Montacargas Hidraulico Modelo MH",
          "brands" => [ "Elemont" ],
          "designators" => [ "MH" ],
          "generic" => false,
          "confirmed" => true
        }
      ]
    })
  end

  def door_reading
    {
      "move" => "report",
      "assertions" => [
        { "span" => "Elemont MH", "act" => "assert", "slot_hint" => "manufacturer" },
        { "span" => "CEA15", "act" => "assert", "slot_hint" => "controller" },
        { "span" => "la puerta 1 no termina de cerrar", "act" => "assert", "slot_hint" => nil },
        { "span" => "el imán no magnetiza", "act" => "assert", "slot_hint" => nil }
      ],
      "observations" => [ "la puerta 1 no termina de cerrar", "el imán no magnetiza" ],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def monarch_catalog(doc)
    Rag::DocumentIdentityCatalog.new({
      "documents" => [ catalog_entry(@account, doc.document_uid, doc.s3_key, "MONARCH", "NICE3000", "controller") ]
    })
  end

  def catalog_entry(account, uid, key, brand, designator, type)
    {
      "account_id" => account.id.to_s,
      "document_id" => uid,
      "s3_key" => key,
      "display_name" => designator,
      "brands" => [ brand ],
      "designators" => [ { "value" => designator, "type" => type } ],
      "generic" => false,
      "confirmed" => true
    }
  end

  def seed_episode(session, facts: {}, goal: nil, observations: [], pending_question: nil, pending_fact: nil, procedure: {}, at: @now, active_photo: nil, rejected: [])
    payload = {
      "v" => 1,
      "episode_id" => "ep_seed",
      "status" => "active",
      "opened_at" => at.iso8601,
      "updated_at" => at.iso8601,
      "facts" => facts,
      "identifiers" => [],
      "observations" => observations,
      "conflicts" => []
    }
    payload["goal"] = { "text" => goal, "correlation_id" => "seed", "truncated" => false } if goal
    payload["pending_question"] = pending_question if pending_question
    payload["pending_fact"] = pending_fact if pending_fact
    payload["active_photo"] = active_photo if active_photo
    payload["rejected"] = rejected if rejected.any?
    session.update!(active_episode: payload, current_procedure: procedure)
  end

  def observed_photo(account: @account, **overrides)
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: account, sha256: sha, s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 8
    )
    raw = {
      "schema_version" => 1,
      "prompt_fingerprint" => "cd" * 32,
      "model_id" => "claude-sonnet-5-5",
      "canonical_component" => "controlador de ascensor",
      "manufacturer" => "NICE",
      "model" => "NICE3000",
      "subsystem" => "CONTROLLER_LOGIC",
      "condition" => "DEGRADED",
      "visible_text" => [ "E51" ],
      "target_visible" => true,
      "relevance_to_goal" => "relevant"
    }.merge(overrides.stringify_keys)
    stored = FieldPhotoObservation.persist!(photo, raw)
    raise "observation rejected" if stored.nil?

    photo
  end

  def photo_ref(photo)
    { "field_photo_id" => photo.id, "sha256" => photo.sha256, "correlation_id" => "photo:seed" }
  end

  def focus_entry(doc)
    {
      "kb_document_id" => doc.id,
      "source_uri" => "s3://test-bucket/manuals/#{doc.id}.pdf",
      "display_name" => doc.display_name,
      "added_at" => @now.iso8601
    }
  end

  def vision_calls
    count = 0
    original = FieldPhotoAnalysisService.method(:new)
    FieldPhotoAnalysisService.define_singleton_method(:new) do |**kwargs|
      count += 1
      original.call(**kwargs)
    end
    yield
    count
  ensure
    FieldPhotoAnalysisService.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) } if original
  end

  def known(value, source: "user")
    { "status" => "known", "value" => value, "source" => source, "correlation_id" => "seed", "at" => @now.iso8601 }
  end

  def mention(span)
    perception("report", assertions: [ assertion(span, "mention") ])
  end

  def perception(move, assertions: [], observations: [], pending_resolution: nil, clarification_target: nil)
    {
      "move" => move,
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => pending_resolution,
      "clarification_target" => clarification_target
    }
  end

  def assertion(span, act, hint = nil)
    item = { "span" => span, "act" => act }
    item["slot_hint"] = hint if hint
    item
  end

  def client(response)
    ScriptedInterpreterClient.new([ response ])
  end

  def capture_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  class RaisingInterpreterClient
    def initialize(error)
      @error = error
    end

    def converse(*)
      raise @error
    end
  end

  class ScriptedInterpreterClient
    attr_reader :payloads

    def initialize(responses)
      @responses = responses.dup
      @payloads = []
    end

    def converse(params)
      @payloads << params
      tool = Struct.new(:name, :input).new("turn_perception", @responses.shift)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(4, 2)
      Struct.new(:output, :usage).new(output, usage)
    end
  end

  class FocusMutatingClient < ScriptedInterpreterClient
    def initialize(session, response, uri, document_id)
      super([ response ])
      @session = session
      @uri = uri
      @document_id = document_id
    end

    def converse(params)
      @session.update!(document_focus: [ {
        "kb_document_id" => @document_id,
        "source_uri" => @uri,
        "display_name" => "Focus manual",
        "added_at" => Time.current.iso8601
      } ])
      super
    end
  end

  class SnapshotMutatingClient < ScriptedInterpreterClient
    def initialize(session, response)
      super([ response ])
      @session = session
    end

    def converse(params)
      @session.update!(active_episode: {
        "v" => 1,
        "episode_id" => "ep_other",
        "status" => "active",
        "opened_at" => Time.current.iso8601,
        "updated_at" => Time.current.iso8601,
        "goal" => { "text" => "otro trabajo", "correlation_id" => "x", "truncated" => false }
      })
      super
    end
  end
end
