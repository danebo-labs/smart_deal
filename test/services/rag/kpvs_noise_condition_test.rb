# frozen_string_literal: true

require "test_helper"

class Rag::KpvsNoiseConditionTest < ActiveSupport::TestCase
  PASSAGE = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/companion_revision/thyssen_kpvs.json").read)
    .dig("passages", "9a2cad2e366f0641cc5150205c697d3d63484892b2c4cb9871c674bfd77a31f1")
  CONDITION = "En caso de ruido audible muy elevado: disminuya el valor del parámetro \"KP-VS\", hasta el mínimo de [3,0]"
  LOUD = "Tenemos un Thyssen con controlador MCINV4. Se escucha fuerte el motor de tracción durante el viaje"
  READING = "El parámetro KP-VS es de 2,5"
  APPLIED = <<~TEXT.strip
    Lo que describes coincide con la condición de la fuente [1]: «#{CONDITION}».

    Según eso, el ajuste aplicable es bajar KP-VS en MENU PID, sin pasar de 3,0.

    La fuente no indica la causa del ruido, así que el ajuste no confirma que el motor esté bien. Después de ajustarlo, revisa de nuevo el ruido durante el viaje.

    No reportaste código de falla, así que no aplico la tabla de códigos.
  TEXT
  SHORT = <<~TEXT.strip
    Con KP-VS en 2,5 ya estás por debajo del mínimo documentado, que es 3,0. La fuente indica «disminuya el valor del parámetro "KP-VS", hasta el mínimo de [3,0]» [1], así que no conviene bajarlo más.

    Corrijo mi respuesta anterior: no sabía el valor con que llegabas y di el ajuste como si aún hubiera que bajarlo.

    La fuente no establece la causa del ruido, así que esto no confirma que el equipo esté bien. Revisa si el ruido sigue durante el viaje.
  TEXT

  test "a loud-motor report keeps the manual condition pending" do
    held = Rag::UnconfirmedProcedure.hold(text: APPLIED, sources: [ source(PASSAGE) ], technician_texts: [ LOUD ])

    assert held
    assert_includes held, "«#{CONDITION}» [1]"
    assert_includes held, "¿El ruido audible es muy elevado?"
    assert_not_includes held, "coincide con la condición"
    assert_not_includes held, "ajuste aplicable"
    assert_not_includes held, "Después de ajustarlo"
    guarded = guard(held, [ LOUD ])
    assert_includes guarded, CONDITION
    assert_includes guarded, "¿El ruido audible es muy elevado?"
    published = Rag::CompanionTurnPublication.call(
      text: guarded, sources: [ source(PASSAGE) ], technician_texts: [ LOUD ], guarded_text: guarded
    )
    assert published.accepted?, published.reasons.inspect
  end

  test "a stated very-high noise is not rewritten" do
    stated = "#{LOUD} El ruido audible es muy elevado."
    assert_nil Rag::UnconfirmedProcedure.hold(text: APPLIED, sources: [ source(PASSAGE) ], technician_texts: [ stated ])
  end

  test "a reported KP-VS reading keeps its value beside the complete condition" do
    completed = Rag::ConditionalQuote.complete(text: SHORT, sources: [ source(PASSAGE) ])
    assert_nil Rag::UnconfirmedProcedure.hold(text: completed, sources: [ source(PASSAGE) ], technician_texts: [ READING ])
    assert_includes completed, "«#{CONDITION}» [1]"
    assert_not_includes completed, "«disminuya el valor del parámetro \"KP-VS\", hasta el mínimo de [3,0]»"
    guarded = guard(completed, [ READING ])
    assert_includes guarded, "2,5"
    assert_includes guarded, CONDITION
    assert_includes guarded, "[1]"
    published = Rag::CompanionTurnPublication.call(
      text: guarded, sources: [ source(PASSAGE) ], technician_texts: [ READING ], guarded_text: guarded
    )
    assert published.accepted?, published.reasons.inspect
  end

  private

  def source(content)
    { "content" => content, "applicability" => "compatible" }
  end

  def guard(text, technician)
    Rag::CompanionClaimBacking.call(text: text, sources: [ source(PASSAGE) ], technician_texts: technician).text
  end
end
