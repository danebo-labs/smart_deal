# frozen_string_literal: true

require "test_helper"

# Offline replay of the model drafts captured in live run 20261120T012019Z
# (Otis case 29, T5 and T6) through the real publication path. No model call.
# Fixture: test/fixtures/files/field_companion/otis_case29_live_20261120.json.
class Rag::OtisCase29ReplayTest < ActiveSupport::TestCase
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/otis_case29_live_20261120.json").read).fetch("turns")
  CLOSING_T5 = "Tras retirar los residuos de la guía, la puerta cerró por completo y el 0102 no volvió a aparecer en tu prueba. " \
    "Lo más probable es que el cambio se deba a esa limpieza, porque reportaste que la hoja se trababa antes de completar el cierre.\n\n" \
    "Eso no confirma la causa. El 0102 significa \"La puerta no fue capaz de cerrar\" [2] y se asocia a " \
    "\"al desaparecer alguna de las señales DCL, DFC o DW\" [1].\n\nSigue sin verificarse DCL ni DFC."

  test "T5 keeps the reported action and its result, limited to that test, with the flag on" do
    with_check_outcome_flag("true") do
      result = publish("t5")

      assert_equal :answered, result[:route_outcome]
      assert_includes result[:answer], "Tras retirar los residuos de la guía, la puerta cerró por completo"
      assert_includes result[:answer], "el 0102 no volvió a aparecer en tu prueba"
      assert_includes result[:answer], "Lo más probable es que el cambio se deba a esa limpieza"
      record_evidence("t5-live-draft", result, nil)
    end
  end

  test "T5 with the flag off is the base publication: the reported result is still filtered" do
    with_check_outcome_flag(nil) do
      result = publish("t5")

      assert_not_includes result[:answer], "Tras retirar los residuos de la guía"
      record_evidence("t5-base-flag-off", result, nil)
    end
  end

  test "T5 can close the exchange: a draft that asks nothing publishes no question and stores no pending" do
    with_check_outcome_flag("true") do
      result = publish("t5", draft: CLOSING_T5)

      assert_equal :answered, result[:route_outcome]
      assert_includes result[:answer], "el 0102 no volvió a aparecer en tu prueba"
      assert_includes result[:answer], "Sigue sin verificarse DCL ni DFC"
      assert_not_includes result[:answer], "?"
      assert_nil result[:pending_question]
    end
  end

  test "T6 does not publish or store a question about DCL, which the technician declared unverified" do
    with_check_outcome_flag("true") do
      assert_includes FIXTURE.dig("t6", "raw_draft"), "¿DCL aparece activo en la consola?"
      result = publish("t6")

      assert_equal :answered, result[:route_outcome]
      assert_not_includes result[:answer], "DCL aparece activo"
      assert_not_includes result[:answer], "?"
      assert_nil result[:pending_question]
      assert_includes result[:answer], "DCL sigue sin verificarse"
    end
  end

  test "T6 with the flag off keeps the base behavior: the question is published" do
    with_check_outcome_flag(nil) do
      result = publish("t6")

      assert_includes result[:answer], "¿DCL aparece activo en la consola?"
      record_evidence("t6-base-flag-off", result, nil)
    end
  end

  test "T6 keeps the DFC reading recorded when T5 left no pending question" do
    with_check_outcome_flag("true") do
      episode = episode_of("t6")

      assert_nil episode.pending_question, "T5 left nothing pending"
      assert_includes episode.observations.pluck("text"), "el LED DFC se encendió y se mantuvo encendido al quedar cerrada"
      assert_equal [ "dcl" ], Rag::DeclaredUnverified.open_codes(episode), "DFC was reported in T6; DCL was not"
    end
  end

  T5_CID = "query:5a699288-5fe4-4913-b9e4-eb12e3268019"
  T6_CID = "query:1783e20e-692c-4beb-b6c8-a2637aecfe4d"
  Q4 = "¿La puerta se detiene siempre en el mismo punto antes de cerrar, o el punto cambia de un intento a otro?"

  test "T5 closing: after the reload nothing waits, the stale impediment question included, and the report is kept" do
    with_check_outcome_flag("true") do
      with_owner_mode do
        episode = episode_of("t5")
        Rag::ActiveEpisodeTurn.install_pending!(episode, { "type" => "documented_context", "question" => Q4, "targets" => [] }, "query:before-t5")
        assert_equal Q4, episode.pending_question["question"], "the stale question was open before T5"
        result = publish("t5", draft: CLOSING_T5)

        reloaded = reload(episode, result, T5_CID)

        assert_nil reloaded.pending_question
        assert_includes reloaded.observations.pluck("text"), "Después la puerta cerró por completo"
        assert_equal %w[dcl dfc], Rag::DeclaredUnverified.open_codes(reloaded).sort
        record_evidence("t5-closing", result, reloaded)
      end
    end
  end

  test "T6 after the reload: no pending, the DFC reading kept, DCL still unverified and not asked" do
    with_check_outcome_flag("true") do
      with_owner_mode do
        episode = episode_of("t6")
        result = publish("t6")

        reloaded = reload(episode, result, T6_CID)

        assert_nil reloaded.pending_question
        assert_includes reloaded.observations.pluck("text"), "el LED DFC se encendió y se mantuvo encendido al quedar cerrada"
        assert_equal [ "dcl" ], Rag::DeclaredUnverified.open_codes(reloaded)
        assert_not_includes result[:answer], "?"
        record_evidence("t6", result, reloaded)
      end
    end
  end

  test "T6 with the question kept by a text that is only that question: persistence still refuses the pending" do
    with_check_outcome_flag("true") do
      with_owner_mode do
        episode = episode_of("t6")
        only = "**Pregunta:** ¿DCL aparece activo en la consola?"
        state = Rag::ActiveEpisodeTurn.apply_assistant(
          state: episode, text: only, correlation_id: T6_CID,
          pending_question: Rag::PendingQuestion.from_publication(only, locale: :es)
        ).state

        assert_nil Rag::ActiveEpisode.parse(state).pending_question
      end
    end
  end

  private

  def with_owner_mode
    previous = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    yield
  ensure
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous
  end

  # The state a reload reads after the publication is stored.
  def reload(episode, result, correlation_id)
    stored = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode, text: result[:answer], correlation_id: correlation_id, pending_question: result[:pending_question]
    ).state
    Rag::ActiveEpisode.parse(stored)
  end

  # Set STAGE1_EVIDENCE_DIR to keep the published text and the reloaded state.
  def record_evidence(label, result, reloaded)
    directory = ENV["STAGE1_EVIDENCE_DIR"].to_s
    return if directory.empty?

    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "#{label}.json"), JSON.pretty_generate(
      "label" => label, "flag" => ENV["FIELD_CHECK_OUTCOME"].presence || "off", "published" => result[:answer],
      "pending_from_publication" => result[:pending_question],
      "reloaded" => reloaded && {
        "pending_question" => reloaded.pending_question, "observations" => reloaded.observations,
        "checks" => reloaded.checks, "declared_unverified_codes" => Rag::DeclaredUnverified.open_codes(reloaded)
      }
    ))
  end

  def publish(label, draft: nil)
    turn = FIXTURE.fetch(label)
    episode = episode_of(label)
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_turn, true)
    service.instance_variable_set(:@citation_processor, Bedrock::CitationProcessor.new)
    service.send(
      :finish_companion_turn_generation,
      question: turn.fetch("message"), raw_answer: draft || turn.fetch("raw_draft"),
      chunks: chunks(turn), response_locale: :es, retrieval: {}, stop_reason: "end_turn",
      technician_texts: service.send(:companion_technician_texts, nil, episode, turn.fetch("message")),
      manufacturer: nil, correlation_id: "query:replay-#{label}", reference_mode: true, reference_confirmed: false,
      episode: episode
    )
  end

  def episode_of(label)
    stored = FIXTURE.dig(label, "episode")
    episode = Rag::ActiveEpisode.open(correlation_id: "query:replay-open", now: Time.current)
    episode.checks = stored.fetch("checks")
    episode.observations = stored.fetch("observations")
    episode
  end

  def chunks(turn)
    turn.fetch("sources").map do |source|
      {
        content: source.fetch("text"), location_uri: source.fetch("uri"), case_number: source.fetch("n"),
        metadata: { "canonical_name" => source.fetch("title"), "page_number" => source.fetch("page"),
                    "original_source_uri" => source.fetch("uri") }
      }
    end
  end
end
