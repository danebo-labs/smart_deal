# frozen_string_literal: true

require "test_helper"

module Stage1Live
  NO_RUN = true unless const_defined?(:NO_RUN)
end
load Rails.root.join("script/field_companion/run_stage1_live.rb") unless Stage1Live.respond_to?(:judge, true)
require Rails.root.join("test/support/otis_case29_replay")

# Live run 20261120T141251Z (replay 3 of Otis case 29, flag on), T1. The
# generator did what the context asked: it asked for the event on the console.
# The only line it cited, "Si me lo indicas, lo comparo con la tabla [3]", is a
# promise, not a claim, and the claim guard removed it. With no cited claim left
# the reference answer fell back to "No encontré evidencia suficiente…" and the
# plate question, and the event was never requested. The same sources, message
# and state gave an accepted T1 in replay 2, so the draft decided.
class Rag::OtisCase29Replay3Test < ActiveSupport::TestCase
  DRAFT = <<~TEXT.strip
    La foto muestra el teclado de una herramienta de servicio, pero no se lee ningún código de evento en la pantalla.

    Antes de seguir, necesito el dato del equipo: **¿qué código o mensaje aparece en la consola cuando la puerta vuelve a abrir en el piso 3?**

    Si me lo indicas, lo comparo con la tabla de mensajes de diagnóstico [3]. Ten en cuenta que esa tabla corresponde a GeN2 Comfort, así que primero hay que confirmar que aplica a tu equipo.
  TEXT
  FIXTURE = {
    "t1" => JSON.parse(Rails.root.join("test/fixtures/files/field_companion/otis_case29_live_20261120T134952Z.json").read)
                .fetch("turns").fetch("t1").merge("raw_draft" => DRAFT)
  }.freeze

  include Otis29Replay

  test "flag on: the event request is published, stops at the question and is stored as the pending one" do
    with_check_outcome_flag("true") do
      result, episode, turn = abstained_turn

      assert_equal :abstained, result[:route_outcome], "the base path still abstains: no cited claim survived"
      requested = event_request(result, episode, turn)

      assert_equal :answered, requested[:route_outcome]
      assert_includes requested[:answer], "no se lee ningún código de evento"
      assert_includes requested[:answer], "¿qué código o mensaje aparece en la consola cuando la puerta vuelve a abrir en el piso 3?"
      assert_not_includes requested[:answer], "GeN2"
      assert_not_includes requested[:answer], "No encontré evidencia"
      assert_equal "documented_context", requested[:pending_question]["type"]
      assert_match(/código o mensaje/, requested[:pending_question]["question"])
    end
  end

  test "flag on: an event question inside the paragraph is kept and the rest is dropped" do
    with_check_outcome_flag("true") do
      _result, episode, turn = abstained_turn
      draft = "Antes de revisar señales, necesito el evento. ¿La consola o el historial muestra algún código " \
        "o mensaje cuando la puerta de piso 3 intenta cerrar y vuelve a abrir? Si aparece, pásame el texto tal como se ve.\n\n" \
        "En la foto no hay un código."
      requested = event_request({ answer: draft, route_outcome: :abstained }, episode, turn)

      assert_equal :answered, requested[:route_outcome]
      assert_includes requested[:answer], "¿La consola o el historial muestra algún código"
      assert_not_includes requested[:answer], "Si aparece"
      assert_not_includes requested[:answer], "En la foto"
      assert_match(/consola o el historial/, requested[:pending_question]["question"])
    end
  end

  # Live 20261120T230532Z. Claim backing had already removed the cited lines.
  # The leftover photo sentence contained "fallo", publication rejected the
  # whole answer as an uncited technical claim, and the plate question was
  # published instead of the event request.
  FALLO_DRAFT = <<~TEXT.strip
    Antes de cualquier comprobación, necesito el registro del equipo. En la foto solo se ve el teclado y la pantalla de la herramienta de servicio; las etiquetas visibles (MODULE, FUNCTION, DISP STATE, TEST) son rótulos, no un evento ni una lectura del fallo.

    **Pregunta:** ¿La herramienta muestra algún código o evento (historial de sucesos) cuando la puerta del piso 3 intenta cerrar y vuelve a abrir? Si lo tienes, pásamelo tal como aparece.
  TEXT

  test "flag on: an uncited photo sentence does not replace the event question" do
    with_check_outcome_flag("true") do
      turn = FIXTURE.fetch("t1").merge("raw_draft" => FALLO_DRAFT)
      result = nil
      episode = nil
      with_owner_mode do
        now = Time.iso8601(turn.fetch("at"))
        travel_to(now) do
          episode = Rag::ActiveEpisode.parse(turn.fetch("episode_before"), now: now)
          reduce(turn, episode, now)
          result, = publish(turn, episode)
        end
      end

      assert_equal true, result[:companion_contract_invalid]
      assert_equal [ { "rule" => "R5", "detail" => "technical_without_citation" } ], result.dig(:companion_publication, "reasons")
      requested = event_request(result, episode, turn)

      assert_equal :answered, requested[:route_outcome]
      assert_equal false, requested[:companion_contract_invalid]
      assert_includes requested[:answer], "¿La herramienta muestra algún código o evento"
      assert_not_includes requested[:answer], "fallo"
      assert_not_includes requested[:answer], "Si lo tienes"
      assert_not_includes requested[:answer], "No encontré evidencia"
      assert_match(/código o evento/, requested[:pending_question]["question"])
    end
  end

  test "flag off: the base fallback is kept" do
    with_check_outcome_flag(nil) do
      result, episode, turn = abstained_turn

      assert_nil event_request(result, episode, turn)
    end
  end

  test "it does not apply when the case already has an event or the draft asked nothing" do
    with_check_outcome_flag("true") do
      result, episode, turn = abstained_turn

      assert_nil event_request(result.merge(answer: "La foto muestra un teclado."), episode, turn)
      assert_nil event_request(result.merge(applicability_violation: true), episode, turn)
      assert_nil event_request(result.merge(route_outcome: :answered), episode, turn)
      assert_nil event_request(result, episode, turn.merge("message" => "Veo el código 0102 en la consola"))
    end
  end

  private

  def abstained_turn
    turn = fixture.fetch("t1")
    now = Time.iso8601(turn.fetch("at"))
    result = nil
    episode = nil
    with_owner_mode do
      travel_to(now) do
        episode = Rag::ActiveEpisode.parse(turn.fetch("episode_before"), now: now)
        reduce(turn, episode, now)
        result, = publish(turn, episode)
      end
    end
    [ result, episode, turn ]
  end

  def event_request(result, episode, turn)
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_sources, [])
    service.send(:event_request_result, result, episode, turn.fetch("message"), turn.fetch("correlation_id"), :es)
  end
end
