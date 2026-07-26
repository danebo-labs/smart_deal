# frozen_string_literal: true

require "test_helper"
require "json"

# Locks the calibration of `script/fixtures/rag_seguridades_rubric.json`.
# Every pattern relaxed in this rubric must keep failing the phrasing it guards,
# so each positive control here is paired with a negative control. Runs fully
# offline (no Bedrock, no benchmark run).
class Rag::SeguridadesRubricCalibrationTest < ActiveSupport::TestCase
  RUBRIC = JSON.parse(Rails.root.join("script/fixtures/rag_seguridades_rubric.json").read).freeze

  test "rubric version is the calibrated one" do
    assert_equal "seguridades-v3.2", RUBRIC.fetch("version")
    assert_equal 12, RUBRIC.fetch("cases").size
  end

  # v3.2: the answer states the datum applies to "ambos diagramas"; v3.1 only
  # accepted the feminine "ambas". Semantic condition unchanged: the answer must
  # cover both diagrams.
  test "em3000 both-diagrams check accepts either gender and still rejects single-diagram coverage" do
    check = required_check("em3000_fotocelula_220v", "aplica a ambas")

    [
      "En ambos diagramas (eléctrico e hidráulico) la fotocélula aparece con 220V.",
      "En ambas páginas la fotocélula documenta 220 V.",
      "Las dos fotocélulas documentan 220 V.",
      "Los dos diagramas documentan 220 V.",
      "Cada una documenta 220 V.",
      "Cada uno de los diagramas documenta 220 V."
    ].each { |answer| assert_match check, answer, "expected coverage of both diagrams: #{answer}" }

    [
      "En el diagrama EM3000 - ELECTRICO (página 29) la fotocélula se etiqueta FOTOCELULA — 220V.",
      "La fotocélula del EM3000 documenta 220 V."
    ].each { |answer| assert_no_match check, answer, "single-diagram coverage must still fail: #{answer}" }
  end

  # v3.2: page 93 now retrieves (THYSSEN alias patch), so the answer names the
  # documented identifiers as "L9 / L8 / L7". v3.1 only accepted "LED9"/"DL27".
  test "thyssen LED identifier check accepts bare L-designators and still rejects an answer that names none" do
    check = optional_check("thyssen_e_led", "identifica LEDs documentados sin asignar estado")

    [
      "**LED L9** — Supervisa la serie de seguridades principales",
      "Los LEDs documentados son L9, L8 y L7.",
      "El DL27 aparece en la placa.",
      "LED 9 aparece en el diagrama."
    ].each { |answer| assert_match check, answer, "expected a documented LED identifier: #{answer}" }

    [
      "La documentación recuperada no contiene información específica sobre un sistema denominado \"Thyssen-E\".",
      "Los documentos describen placas ALJO Level Control 1B, NE 300 LB II, EDEL-K3 y EKM 1000 de FAIN Ascensores.",
      "El documento no incluye este dato; requiere verificación en campo."
    ].each { |answer| assert_no_match check, answer, "an answer naming no LED must not score: #{answer}" }
  end

  # Unchanged in v3.2 — asserted here because the broadened optional check above
  # shares its identifier lexicon: naming a LED must never be enough to claim a
  # normal/fault state.
  test "thyssen penalized check still fires on an unsupported normal-or-fault attribution" do
    check = penalized_check("thyssen_e_led", "asigna normal/fallo sin respaldo")

    [
      "L9 se enciende cuando la condición es normal.",
      "El LED L7 indica un fallo en la serie de cerrojos.",
      "DL27 señala una avería del circuito."
    ].each { |answer| assert_match check, answer, "unsupported state attribution must be penalized: #{answer}" }

    [
      "**LED L9** — Supervisa la serie de seguridades principales. La documentación no define la lógica de encendido/apagado.",
      "El documento identifica qué serie supervisa cada LED (L9, L8, L7) pero no cuál estado es normal."
    ].each { |answer| assert_no_match check, answer, "a correct abstention must not be penalized: #{answer}" }
  end

  # v3.2: the v3.1 guard was the fixed-width lookbehind `(?<!si )`, which only
  # covered "si se enciende cuando…". Real answers hedge as "el documento no
  # declara si el LED se enciende cuando…", so a correct abstention was scored as
  # an invention. The check now fires only on an assertive sentence — one with no
  # negation or hypothesis marker.
  test "tokibat invented-ON-state check fires on an assertion and not on a negated or hypothetical clause" do
    check = penalized_check("tokibat_dl27", "inventa estado de encendido")

    [
      "DL27 se enciende cuando la serie de seguridad presenta un fallo.",
      "El LED DL27 se enciende cuando existe una avería en el circuito.",
      "DL27 se enciende cuando el estado es normal."
    ].each { |answer| assert_match check, answer, "an unsupported ON-state assertion must be penalized: #{answer}" }

    [
      "El documento no declara si el LED se enciende cuando la serie está cerrada, abierta, o en caso de fallo.",
      "La documentación no especifica si se enciende cuando hay un fallo.",
      "No se documenta si DL27 se enciende cuando la condición es normal.",
      "El documento no incluye este dato — requiere verificación en campo."
    ].each { |answer| assert_no_match check, answer, "a negated or hypothetical clause must not be penalized: #{answer}" }
  end

  test "em3000 critical penalized checks remain unchanged" do
    absence = penalized_check("em3000_fotocelula_220v", "afirma ausencia de voltaje")
    twenty_four = penalized_check("em3000_fotocelula_220v", "introduce 24 V")

    assert_match absence, "La fotocélula aparece sin tensión documentada."
    assert_match twenty_four, "La fotocélula se alimenta con 24 V."
    assert_no_match twenty_four, "La fotocélula se alimenta con 220 V."
  end

  private

  def rubric_case(id)
    RUBRIC.fetch("cases").find { |definition| definition["id"] == id } ||
      flunk("rubric case #{id} not found")
  end

  def pattern_for(id, kind, label)
    definition = rubric_case(id).fetch(kind).find { |check| check["label"] == label } ||
      flunk("#{kind} check #{label.inspect} not found in #{id}")
    Regexp.new(definition.fetch("pattern"), Regexp::IGNORECASE | Regexp::MULTILINE)
  end

  def required_check(id, label)  = pattern_for(id, "required", label)
  def optional_check(id, label)  = pattern_for(id, "optional", label)
  def penalized_check(id, label) = pattern_for(id, "penalized", label)
end
