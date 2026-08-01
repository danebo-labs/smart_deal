# frozen_string_literal: true

require "test_helper"
require "json"
require "digest"

# Locks the calibration of `script/fixtures/rag_seguridades_rubric.json`.
# Every pattern relaxed in this rubric must keep failing the phrasing it guards,
# so each positive control here is paired with a negative control. Runs fully
# offline (no Bedrock, no benchmark run).
class Rag::SeguridadesRubricCalibrationTest < ActiveSupport::TestCase
  RUBRIC = JSON.parse(Rails.root.join("script/fixtures/rag_seguridades_rubric.json").read).freeze
  PILOT = JSON.parse(Rails.root.join("script/fixtures/rag_seguridades_pilot_10q.json").read).freeze
  PILOT_V2 = JSON.parse(Rails.root.join("script/fixtures/rag_seguridades_pilot_10q_v2.json").read).freeze
  PILOT_V3 = JSON.parse(Rails.root.join("script/fixtures/rag_seguridades_pilot_10q_v3.json").read).freeze
  PILOT_V4_1 = JSON.parse(Rails.root.join("script/fixtures/rag_seguridades_pilot_10q_v4_1.json").read).freeze
  HOLDOUT_PATH = Rails.root.join("script/fixtures/rag_seguridades_holdout_v1.json")
  HOLDOUT_SHA256 = "34682fb13ca5acf0e635d42ad285be039749b4d07f090a728ef43371d4325309"
  PARTIAL_ABSTENTION_GOLDEN_CHECKS = [
    [ "seguridades-pilot-v1.2", "edel_k2_led31", "required",
      "se abstiene de condiciones no documentadas" ],
    [ "seguridades-pilot-v1.2", "em2000_contradiccion_conectores", "optional",
      "recomienda verificar en campo" ],
    [ "seguridades-pilot-v2.1", "thyssen_serie_e_leds", "required",
      "se abstiene de normal/fallo" ],
    [ "seguridades-pilot-v2.1", "tokibat_dl27_v2", "required",
      "se abstiene de condiciones no documentadas" ],
    [ "seguridades-v3.2", "altius_d8", "required",
      "limita la función a lo documentado" ],
    [ "seguridades-v3.2", "em2000_contradiccion", "optional",
      "pide verificar esquema completo" ],
    [ "seguridades-v3.2", "indice_carlos_silva", "optional",
      "expone ausencia si retrieval no responde" ],
    [ "seguridades-v3.2", "indice_carlos_silva", "required",
      "respuesta no vacía" ],
    [ "seguridades-v3.2", "kdt_evo_presostato", "required",
      "identifica XP31 o se abstiene" ],
    [ "seguridades-v3.2", "thyssen_e_led", "required",
      "expone falta de lógica documentada" ],
    [ "seguridades-v3.2", "tokibat_dl27", "optional",
      "distingue etiqueta de estado" ],
    [ "seguridades-v3.2", "tokibat_dl27", "required",
      "se abstiene sobre lógica" ],
    [ "seguridades-v3.2", "torque_ausente", "optional",
      "sugiere verificar fuente completa" ],
    [ "seguridades-v3.2", "torque_ausente", "required",
      "abstención visible" ]
  ].sort.freeze

  test "rubric version is the calibrated one" do
    assert_equal "seguridades-v3.2", RUBRIC.fetch("version")
    assert_equal 12, RUBRIC.fetch("cases").size
  end

  test "pilot rubric version is the calibrated one" do
    assert_equal "seguridades-pilot-v1.2", PILOT.fetch("version")
    assert_equal 10, PILOT.fetch("cases").size
  end

  test "pilot v2 rubric version is locked" do
    assert_equal "seguridades-pilot-v2.1", PILOT_V2.fetch("version")
    assert_equal 10, PILOT_V2.fetch("cases").size
    assert_equal 24, PILOT_V2.fetch("passing_score")
    ids = PILOT_V2.fetch("cases").map { |definition| definition.fetch("id") }
    assert_not_equal PILOT.fetch("cases").map { |definition| definition.fetch("id") }, ids,
      "v2 must exercise different case ids than the certified pilot v1.2"
  end

  test "the independent holdout remains frozen after its pre-run hash was recorded" do
    holdout = JSON.parse(HOLDOUT_PATH.read)

    assert_equal "seguridades-holdout-v1.0", holdout.fetch("version")
    assert_equal 10, holdout.fetch("cases").size
    assert_equal HOLDOUT_SHA256, Digest::SHA256.file(HOLDOUT_PATH).hexdigest
  end

  test "the release gate set is pinned to the authorized rubrics and blocks promotion of unverified batteries" do
    release_gates = [
      RUBRIC.fetch("version"),
      PILOT.fetch("version"),
      PILOT_V2.fetch("version"),
      PILOT_V3.fetch("version"),
      PILOT_V4_1.fetch("version")
    ]
    expected = [ "seguridades-pilot-v1.2", "seguridades-pilot-v2.1", "seguridades-pilot-v3.0",
                 "seguridades-pilot-v4.1", "seguridades-v3.2" ].sort

    assert_equal expected, release_gates.sort,
      "release gate set must be exactly #{expected.inspect} to prevent unverified batteries (set2, taxonomia) " \
      "from being promoted without touching this assertion"
  end

  # v2 critical: EM4000 obstacle header documents XC4/XC7 — inventing the
  # EM2000 CN7/CN8/CN9 set is the same connector-hallucination class as mr08_sci.
  test "pilot v2 em4000 connector check accepts XC4/XC7 and rejects CN7/CN8/CN9 invention" do
    xc4 = pilot_v2_check("em4000_obstaculo_conectores", "required", "incluye XC4")
    xc7 = pilot_v2_check("em4000_obstaculo_conectores", "required", "incluye XC7")
    cn = pilot_v2_check("em4000_obstaculo_conectores", "penalized", "inventa conectores CN7/CN8/CN9")

    assert_match xc4, "El encabezado documenta los conectores XC4 y XC7."
    assert_match xc7, "OBSTACULO .- CONECTORES XC4 Y XC7 EN PLACA EM4000 V1"
    assert_match cn, "En EM4000 el obstáculo usa CN7 y CN8."
    assert_match cn, "Los conectores son CN9 y CN7 en el dibujo de EM4000."
    assert_no_match cn, "El encabezado documenta XC4 y XC7."
    assert_no_match cn, "No confundir con los CN7/CN8 del EM2000."
  end

  # v2.1: the v2.0 pattern's CN-near-EM4000 branch matched across an entire
  # sentence with no owner check, so a correct contrastive answer that names
  # EM2000's real CN7/CN8/CN9 in the same sentence as EM4000's XC4/XC7 was
  # scored as a critical invention (PDF l.1017/1019/1060 document CN7/CN8/CN9
  # for EM2000, not EM4000 — same lexical-collision class already fixed once
  # for em3000_fotocelula_tension in v1.1→v1.2). The check now fires only when
  # the CN7/CN8/CN9 mention is not preceded, within the same clause, by an
  # EM2000 or EM3000 attribution.
  test "pilot v2 em4000 connector check does not fire on a correct EM2000/EM4000 contrast" do
    cn = pilot_v2_check("em4000_obstaculo_conectores", "penalized", "inventa conectores CN7/CN8/CN9")

    [
      "En EM2000 el obstáculo usa CN7/CN8; en EM4000 V1 son XC4/XC7.",
      "En EM2000 son CN7/CN8; en EM4000 V1, XC4/XC7.",
      "En EM2000 el obstáculo usa CN7 y CN8, y en EM4000 V1 son XC4 y XC7."
    ].each { |answer| assert_no_match cn, answer, "a correct EM2000/EM4000 contrast must not be penalized: #{answer}" }

    [
      "EM4000 usa los conectores CN7 y CN8.",
      "En EM4000 V1 el obstáculo usa los conectores CN7 y CN8."
    ].each { |answer| assert_match cn, answer, "attributing CN7/CN8/CN9 to EM4000 must still be penalized: #{answer}" }
  end

  # v2 critical: TOKIBAT DL27 names the series but not ON logic — same abstention
  # contract as tokibat_dl27 / edel_k2_led31.
  test "pilot v2 tokibat invented-ON-state check fires on assertion not on abstention" do
    check = pilot_v2_check("tokibat_dl27_v2", "penalized", "inventa condición de encendido")

    [
      "DL27 se enciende cuando la serie de seguridad presenta un fallo.",
      "El LED DL27 se enciende cuando existe una avería."
    ].each { |answer| assert_match check, answer, "unsupported ON-state must be penalized: #{answer}" }

    [
      "El documento no declara si el LED se enciende cuando la serie está cerrada.",
      "El documento no incluye este dato — requiere verificación en campo."
    ].each { |answer| assert_no_match check, answer, "abstention must not be penalized: #{answer}" }
  end

  # v2: EDEL-K3 table differs from EDEL-K2 — copying K2 series onto 37/39/41 fails.
  test "pilot v2 edel_k3 accepts K3 series and rejects K2 series copy" do
    led37 = pilot_v2_check("edel_k3_leds", "required", "LED 37 correcto")
    led41 = pilot_v2_check("edel_k3_leds", "required", "LED 41 correcto")
    k2 = pilot_v2_check("edel_k3_leds", "penalized", "copia series de EDEL-K2")

    assert_match led37, "El LED 37 indica PUERTAS HUECO."
    assert_match led41, "El LED 41 indica CERROJOS CABINA Y EXTERIORES."
    assert_match k2, "El LED 37 indica SERIE SEGURIDADES HUECO (como en K2)."
    assert_no_match k2, "37 = PUERTAS HUECO; 39 = PUERTAS CABINA; 41 = CERROJOS CABINA Y EXTERIORES."
  end

  # pilot v1.1: the TPR60 LED table prints the series with an en dash
  # ("SERIE PUERTAS CABINA – EXTERIORES") and the answer quotes it verbatim, so
  # the v1.0 hyphen-only literal rejected a correct answer. Semantic condition
  # unchanged: it must still be the doors series of that board.
  test "pilot tpr60 series check accepts any dash and still rejects a different series" do
    check = pilot_check("tpr60_pp", "required", "serie correcta")

    [
      "el LED PP corresponde a la serie **SERIE PUERTAS CABINA – EXTERIORES**",
      "SERIE PUERTAS CABINA - EXTERIORES",
      "SERIE PUERTAS CABINA—EXTERIORES"
    ].each { |answer| assert_match check, answer, "expected the documented doors series: #{answer}" }

    [
      "SERIE PUERTAS EXTERIORES",
      "SERIE CERROJOS CABINA - EXTERIORES"
    ].each { |answer| assert_no_match check, answer, "a different series must still fail: #{answer}" }
  end

  # pilot v1.1: this question asks for the fotocélula **and the obstáculo**, and
  # page 29/30 print 24V on the obstacle connector (pins 0V/24V/AP/POS). The v1.0
  # bare `\b24\s*V\b` therefore penalized the correct answer for reporting a
  # documented datum the question explicitly asked for. The check now fires only
  # when 24 V is attributed to the fotocélula, which stays a critical error.
  test "pilot fotocelula 24V check fires on a fotocelula attribution and not on the documented obstacle pin" do
    check = pilot_check("em3000_fotocelula_tension", "penalized", "atribuye 24 V a la fotocélula")

    [
      "La fotocélula se alimenta con 24 V.",
      "El esquema documenta 24 V para la fotocélula en ambas placas.",
      "En la hidráulica la fotocélula es de 24V."
    ].each { |answer| assert_match check, answer, "24 V on the fotocélula must be penalized: #{answer}" }

    [
      "La fotocélula funciona a 220V en ambas placas; el obstáculo opera a 24V (pin 2 del conector CD).",
      "La fotocélula se alimenta con 220 V."
    ].each { |answer| assert_no_match check, answer, "the documented obstacle pin must not be penalized: #{answer}" }
  end

  # pilot v1.2: the v1.1 pattern penalized any "fotocélula" within 40 chars of
  # "24 V" in either direction, with no check on who the 24 V actually belongs
  # to. Real answers from the full 10-question gate (tmp/rag_seguridades_close_
  # pilot10q_fase2*_2026-07-28.json, tmp/rag_seguridades_fase2_em3000_retry5_
  # 2026-07-28.json) close a comparison with a one-sentence summary like
  # "fotocélula 220V y obstáculo 24V", which the v1.1 window matched as an
  # invented fotocélula voltage. The check now fires only when no owner term
  # ("obstáculo"/"conector"/"CN") appears between the two anchors, nor anywhere
  # later in the same clause when "obstáculo" is named after the 24 V mention.
  test "pilot fotocelula 24V check does not fire on a same-sentence fotocelula/obstaculo summary" do
    check = pilot_check("em3000_fotocelula_tension", "penalized", "atribuye 24 V a la fotocélula")

    [
      "Ambas placas utilizan 220V para la fotocélula y 24V para el circuito de obstáculo.",
      "Fotocélula 220V y obstáculo 24V en ambas versiones.",
      "Ambas placas (eléctrica e hidráulica) documentan idéntica alimentación: fotocélula a 220V y obstáculo a 24V (pin 2 del conector CD)."
    ].each { |answer| assert_no_match check, answer, "a fotocélula/obstáculo summary must not be penalized: #{answer}" }

    [
      "La fotocélula funciona a 24 V en ambas placas.",
      "La fotocélula usa 24 V, no 220 V.",
      "El esquema documenta 24 V para la fotocélula."
    ].each { |answer| assert_match check, answer, "24 V attributed to the fotocélula must still be penalized: #{answer}" }
  end

  # pilot v1.1: the v1.0 pattern only required "eléctrica … 24|220 … eléctrica",
  # and the evaluator compiles with MULTILINE (`.` matches newlines), so it fired
  # on the correct answer that states 220 V for both boards across paragraphs. It
  # now requires both voltages, in either order, inside one sentence.
  test "pilot differing-voltage check fires only on an explicit per-version split" do
    check = pilot_check("em3000_fotocelula_tension", "penalized", "diferencia tensión entre versiones")

    [
      "En la eléctrica la fotocélula es de 220 V y en la hidráulica de 24 V.",
      "En la eléctrica es 24 V y en la hidráulica 220 V."
    ].each { |answer| assert_match check, answer, "a per-version voltage split must be penalized: #{answer}" }

    [
      "Tanto en la placa eléctrica como en la hidráulica la fotocélula documenta 220V.",
      "La fotocélula es 220V en ambas.\nEl obstáculo usa 24V en la hidráulica."
    ].each { |answer| assert_no_match check, answer, "one voltage for both versions must not be penalized: #{answer}" }
  end

  # pilot v1.1: pages 44/71/75 print "ASCENSOR SIN AVERIA" without the accent,
  # but the model normalizes the spelling to "AVERÍA" and IGNORECASE does not
  # cover í. Semantic condition unchanged: the state must be the lift being fault
  # free, not any other state.
  test "pilot h40 state check accepts either spelling and still rejects another state" do
    check = pilot_check("ekm66_h40_sin_averia", "required", "estado correcto")

    [
      'el LED **H40** de color **verde** indica "ASCENSOR SIN AVERÍA"',
      "H40 — ASCENSOR SIN AVERIA"
    ].each { |answer| assert_match check, answer, "expected the documented fault-free state: #{answer}" }

    [
      "ASCENSOR EN AVERIA",
      "la serie está sin avería"
    ].each { |answer| assert_no_match check, answer, "another state must still fail: #{answer}" }
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

  test "the partial-absence rendering matches no penalized pattern in any rubric" do
    [ :es, :en ].each do |locale|
      answer = partial_abstention_rendering(locale)

      all_rubrics.each do |rubric|
        rubric.fetch("cases").each do |definition|
          Array(definition["penalized"]).each do |check|
            pattern = compiled_pattern(check.fetch("pattern"))
            assert_no_match(
              pattern,
              answer,
              "#{locale} rendering matched #{rubric.fetch('version')}/" \
                "#{definition.fetch('id')}/#{check.fetch('label')}"
            )
          end
        end
      end
    end
  end

  test "the partial-absence rendering alone satisfies exactly the golden abstention checks" do
    answer = partial_abstention_rendering(:es)
    matched = all_rubrics.flat_map do |rubric|
      rubric.fetch("cases").flat_map do |definition|
        %w[required optional].flat_map do |kind|
          Array(definition[kind]).filter_map do |check|
            next unless compiled_pattern(check.fetch("pattern")).match?(answer)

            [
              rubric.fetch("version"),
              definition.fetch("id"),
              kind,
              check.fetch("label")
            ]
          end
        end
      end
    end.sort

    assert_equal 14, matched.size
    assert_equal PARTIAL_ABSTENTION_GOLDEN_CHECKS, matched
  end

  private

  def all_rubrics
    [ RUBRIC, PILOT, PILOT_V2 ]
  end

  def partial_abstention_rendering(locale)
    internal = I18n.t("rag.absence_partial_contract", locale:)
    Rag::AnswerSafetyProcessor.new(locale:).call(internal, evidence: [])
  end

  def compiled_pattern(pattern)
    Regexp.new(pattern, Regexp::IGNORECASE | Regexp::MULTILINE)
  end

  def rubric_case(id)
    RUBRIC.fetch("cases").find { |definition| definition["id"] == id } ||
      flunk("rubric case #{id} not found")
  end

  def pattern_for(id, kind, label)
    definition = rubric_case(id).fetch(kind).find { |check| check["label"] == label } ||
      flunk("#{kind} check #{label.inspect} not found in #{id}")
    Regexp.new(definition.fetch("pattern"), Regexp::IGNORECASE | Regexp::MULTILINE)
  end

  def pilot_case(id)
    PILOT.fetch("cases").find { |definition| definition["id"] == id } ||
      flunk("pilot rubric case #{id} not found")
  end

  def pilot_check(id, kind, label)
    definition = pilot_case(id).fetch(kind).find { |check| check["label"] == label } ||
      flunk("#{kind} check #{label.inspect} not found in pilot #{id}")
    Regexp.new(definition.fetch("pattern"), Regexp::IGNORECASE | Regexp::MULTILINE)
  end

  def pilot_v2_case(id)
    PILOT_V2.fetch("cases").find { |definition| definition["id"] == id } ||
      flunk("pilot v2 rubric case #{id} not found")
  end

  def pilot_v2_check(id, kind, label)
    definition = pilot_v2_case(id).fetch(kind).find { |check| check["label"] == label } ||
      flunk("#{kind} check #{label.inspect} not found in pilot v2 #{id}")
    Regexp.new(definition.fetch("pattern"), Regexp::IGNORECASE | Regexp::MULTILINE)
  end

  def required_check(id, label)  = pattern_for(id, "required", label)
  def optional_check(id, label)  = pattern_for(id, "optional", label)
  def penalized_check(id, label) = pattern_for(id, "penalized", label)
end
