# frozen_string_literal: true

require "test_helper"

class Rag::CompanionPlanEvidenceTest < ActiveSupport::TestCase
  ELEMONT = "DIAGRAMAS CIRCUITO #3\nBotonera Pasillo Nivel 1, Elemont MH.\n" \
            "Chapa nivel 2 sale de Com 18vdc, pasa por Dp2 y cruza PasCom 24V con un puente semicircular sin punto de unión."
  VF5 = "3 Conexionado\nPRIORITY INPUTS 21 RE-OPEN 23 +12V COM\n54 SAFETY"
  ELEMONT_T1 = "Estoy con un montacargas Elemont MH que no responde a las llamadas. En el plano, " \
               "¿el trazo de Chapa nivel 2 se une a PasCom 24V donde lo cruza?"

  def sufficient?(question, *contents)
    Rag::CompanionPlanEvidence.sufficient?(question: question, chunks: contents.map { |content| { content: content } })
  end

  test "a plan question whose labels are printed in a retrieved source keeps the companion" do
    assert sufficient?(ELEMONT_T1, ELEMONT)
    assert sufficient?("En el esquema de conexionado, ¿en qué bornes está RE-OPEN?", VF5)
  end

  test "a label the sources do not print sends the question to the plan route" do
    assert_not sufficient?("En el esquema, ¿dónde está el relé K9?", VF5)
    assert_not sufficient?(ELEMONT_T1, VF5)
  end

  test "a question that depends on an absent image does not stay on the companion" do
    assert_not sufficient?("En la foto del plano que te mandé, ¿qué borne es RE-OPEN?", VF5)
  end

  test "a plan question without a printed label does not stay on the companion" do
    assert_not sufficient?("¿Qué muestra el plano?", ELEMONT)
  end

  test "reference-only sources do not count as evidence" do
    chunk = { content: VF5, metadata: { "reference_only" => true }, identity_applicability: "reference_only" }

    assert_not Rag::CompanionPlanEvidence.sufficient?(question: "En el esquema, ¿dónde está RE-OPEN?", chunks: [ chunk ])
  end
end

class Rag::CompanionPlanSkipReasonTest < ActiveSupport::TestCase
  Applied = Struct.new(:status)

  def reason(question, episode, content)
    service = BedrockRagService.allocate
    service.define_singleton_method(:document_identity_system_role?) { false }
    service.send(:companion_turn_skip_reason, applied: Applied.new(:scoped), chunks: [ { content: content } ],
                                               episode: episode, raw_question: question)
  end

  def active_episode
    Rag::ActiveEpisode.new.tap do |episode|
      episode.episode_id = "ep_test"
      episode.status = "active"
    end
  end

  test "a plan question inside an active episode with printed labels stays on the companion" do
    assert_nil reason("En el esquema de conexionado, ¿en qué bornes está RE-OPEN?", active_episode, Rag::CompanionPlanEvidenceTest::VF5)
    assert_nil reason(Rag::CompanionPlanEvidenceTest::ELEMONT_T1, active_episode, Rag::CompanionPlanEvidenceTest::ELEMONT)
  end

  test "a standalone plan question keeps the plan route" do
    assert_equal :plan, reason("En el esquema, ¿en qué bornes está RE-OPEN?", nil, Rag::CompanionPlanEvidenceTest::VF5)
  end

  test "an active episode without the label in evidence keeps the plan route" do
    assert_equal :plan, reason("En el esquema, ¿dónde está el relé K9?", active_episode, Rag::CompanionPlanEvidenceTest::VF5)
  end
end
