# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/field_companion/otis_rubric")

module Stage1Live
  NO_RUN = true unless const_defined?(:NO_RUN)
end
load Rails.root.join("script/field_companion/run_stage1_live.rb") unless Stage1Live.private_method_defined?(:generator_sources)

# The rubric of case 29 T5/T6 (docs/field_companion/DANEBO_GUIONES_REGRESION_2026-11-19.md).
# The fixtures are the published texts and reloaded states of live rounds 3
# and 4 (Otis, 19-20 Nov 2026), condensed. Pure: no database, no network.
class OtisCase29RubricTest < ActiveSupport::TestCase
  RUBRIC = Stage1Live::OtisRubric
  P1 = "MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p1-123)"
  P2 = "MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p124-245)"
  ALLOWED = [ P1, P2 ].freeze
  DFC_QUOTE = "Puertas completamente cerradas (Cadena de seguridad cerrada)"
  # The notice every reference-mode publication appends (rag.controller_reference_boundary).
  NOTICE = "La referencia describe el manual; por sí sola no confirma la placa ni la configuración instalada."
  T5_CID = "query:1bb60e4e-ae3d-4194-99a5-9946fe1ed3ba"
  T6_CID = "query:97efda3a-4a65-445d-b6c2-c2f98b8c7dc3"

  # Round 4 T5, as published: the residue is only "una hipótesis".
  ROUND4_T5 = <<~TEXT.strip
    Resultado: Tras retirar los residuos de la guía, la puerta cerró por completo y el 0102 no reapareció en esa prueba. Esto solo vale para esa maniobra. La relación entre los residuos y la falla sigue siendo una hipótesis.

    Pendiente: DCL y DFC sin verificar. DCL ya quedó pendiente antes, así que no lo vuelvo a pedir.

    Siguiente comprobación (DFC): Según el panel, el LED DFC indica "#{DFC_QUOTE}" [9].

    ¿Con la puerta del piso 3 cerrada, el LED DFC del panel está encendido?

    #{NOTICE}
  TEXT

  # The wording this rubric accepts: likeliest explanation, limited to the
  # test, DCL and DFC unverified, and the DFC watch offered, not demanded.
  LIKELY_T5 = <<~TEXT.strip
    Resultado: la hoja se trababa, retiraste residuos de la guía y después cerró por completo; el 0102 no volvió en esa prueba. Eso solo vale para esa maniobra y no certifica la puesta en servicio.

    Lo más probable es que los residuos explicaran que la hoja se trabara, pero la prueba no lo confirma como causa del 0102.

    DCL y DFC siguen sin verificar. Si haces otra maniobra, observa DFC: el manual lo describe como "#{DFC_QUOTE}" [21].

    #{NOTICE}
  TEXT

  # Live 20261120T141251Z T2: the answer paraphrased the 0102 row and cited
  # [1][2]. Pages 22 and 85 hold the row, but the citation has no tooltip
  # excerpt because nothing was quoted. The generator's own source backs it.
  ROW_0102 = "| 0102 OpMode DTC | W | La puerta no cierra en el tiempo programado al desaparecer alguna de las señales DCL, DFC o DW |"
  T2_PUBLISHED = "0102 OpMode DTC: la puerta no cierra en el tiempo programado porque desaparece alguna de las señales DCL, DFC o DW [1][2]."

  test "T2 accepts a cited paraphrase when the source the generator received holds the 0102 row" do
    summary = { "published" => T2_PUBLISHED, "all_observations" => [ "El historial muestra 0102" ],
                "citations" => [ citation(1, P2, 22), citation(2, P2, 85) ],
                "generator_sources" => { "1" => "Tabla\n#{ROW_0102}", "2" => "Otra página sin el código" } }

    assert RUBRIC.t2(summary, allowed_documents: ALLOWED)["checks"]["event_backed_by_a_passage"]
  end

  test "T2 does not accept a citation whose source does not hold the row, nor one with no source recorded" do
    summary = { "published" => T2_PUBLISHED, "all_observations" => [ "El historial muestra 0102" ],
                "citations" => [ citation(1, P2, 22), citation(2, P2, 85) ],
                "generator_sources" => { "1" => "Tabla de otras señales", "2" => "Parámetros DCL (694)" } }

    assert_not RUBRIC.t2(summary, allowed_documents: ALLOWED)["checks"]["event_backed_by_a_passage"]
    assert_not RUBRIC.t2(summary.except("generator_sources"), allowed_documents: ALLOWED)["checks"]["event_backed_by_a_passage"]
  end

  test "the runner records the numbered sources of the last generator_evidence event" do
    events = [ { "kind" => "generator_evidence", "rows" => [ { "n" => 1, "text" => "viejo" } ] },
               { "kind" => "retrieve" },
               { "kind" => "generator_evidence", "rows" => [ { "n" => 1, "text" => "a" }, { "n" => 2, "text" => "b" } ] } ]

    assert_equal({ "1" => "a", "2" => "b" }, Stage1Live.send(:generator_sources, events))
    assert_equal({}, Stage1Live.send(:generator_sources, []))
  end

  test "round 4 T5 fails on the residue wording and on the source of its pending, and on nothing else" do
    verdict = RUBRIC.t5(t5(published: ROUND4_T5, pending: pending(targets: []), citations: [ citation(9, P1, 121) ]), allowed_documents: ALLOWED)

    assert_equal %w[residue_named_as_likely_explanation pending_keeps_its_source], verdict["failed"]
  end

  test "round 3 T5 fails when the pending target lost its document key" do
    blank = [ { "item" => P1, "document_key" => "", "filename" => "", "page" => "" } ]
    verdict = RUBRIC.t5(t5(published: ROUND4_T5, pending: pending(targets: blank), citations: [ citation(9, P1, 121) ]), allowed_documents: ALLOWED)

    assert_includes verdict["failed"], "pending_keeps_its_source"
  end

  test "T5 passes with no pending and targets [] when the DFC watch is only a suggestion" do
    verdict = RUBRIC.t5(t5(published: LIKELY_T5, pending: nil, citations: [ citation(21, P1, 121) ]), allowed_documents: ALLOWED)
    assert verdict["ok"], verdict["failed"].inspect
  end

  test "T5 passes with no suggestion, no citation and no pending" do
    text = LIKELY_T5.sub(/\n\nDCL y DFC.*\z/m, "\n\nDCL y DFC siguen sin verificar.\n\n#{NOTICE}")
    verdict = RUBRIC.t5(t5(published: text, pending: nil, citations: []), allowed_documents: ALLOWED)
    assert verdict["ok"], verdict["failed"].inspect
  end

  test "T5 accepts another citation number, another manual volume and equivalent wording" do
    text = LIKELY_T5.sub("[21]", "[3]").sub("Lo más probable es que los residuos explicaran", "Los residuos son la explicación más probable de")
    verdict = RUBRIC.t5(t5(published: text, pending: nil, citations: [ citation(3, P2, 55) ].map { |c| c.merge("tooltip_excerpt" => DFC_QUOTE) }), allowed_documents: ALLOWED)
    assert verdict["ok"], verdict["failed"].inspect
  end

  test "T5 with a pending keeps the cited document, file and page, whichever number cites it" do
    cited = citation(21, P1, 121)
    target = { "item" => P1, "document_key" => "s3://bucket/bulk_uploads/3/#{P1}.pdf", "filename" => "chunk_p121_2.txt", "page" => "121" }
    verdict = RUBRIC.t5(t5(published: LIKELY_T5.sub("DCL y DFC siguen", "¿DFC queda encendido con la puerta cerrada? DCL y DFC siguen"), pending: pending(targets: [ target ], question: "¿DFC queda encendido con la puerta cerrada?"), citations: [ cited ]), allowed_documents: ALLOWED)
    assert verdict["ok"], verdict["failed"].inspect

    wrong = target.merge("page" => "55")
    asked = LIKELY_T5.sub("DCL y DFC siguen", "¿DFC queda encendido con la puerta cerrada? DCL y DFC siguen")
    assert_not RUBRIC.t5(t5(published: asked, pending: pending(targets: [ wrong ], question: "¿DFC queda encendido con la puerta cerrada?"), citations: [ cited ]), allowed_documents: ALLOWED)["ok"],
           "a target that points at another page is not the cited passage"
  end

  test "T5 fails when DCL is asked, the citation is foreign, or the result is declared fixed" do
    asks = RUBRIC.t5(t5(published: LIKELY_T5, pending: nil, citations: [ citation(21, P1, 121) ], asked_again: "¿DCL está activo?"), allowed_documents: ALLOWED)
    assert_includes asks["failed"], "dcl_not_asked"

    foreign = RUBRIC.t5(t5(published: LIKELY_T5, pending: nil, citations: [ citation(21, "Elemont MH", 5) ]), allowed_documents: ALLOWED)
    assert_includes foreign["failed"], "citations_from_the_loaded_manuals"

    missing = RUBRIC.t5(t5(published: LIKELY_T5, pending: nil, citations: []), allowed_documents: ALLOWED)
    assert_includes missing["failed"], "citations_from_the_loaded_manuals", "a cited number the publication did not deliver"

    fixed = RUBRIC.t5(t5(published: LIKELY_T5.sub("no certifica la puesta en servicio", "el caso queda resuelto"), pending: nil, citations: [ citation(21, P1, 121) ]), allowed_documents: ALLOWED)
    assert_includes fixed["failed"], "result_limited_to_the_test"

    unverified = RUBRIC.t5(t5(published: LIKELY_T5, pending: nil, citations: [ citation(21, P1, 121) ], checks: []), allowed_documents: ALLOWED)
    assert_includes unverified["failed"], "dcl_and_dfc_kept_unverified"
  end

  test "T5 does not accept the confirmed cause in place of the likeliest explanation" do
    text = LIKELY_T5.sub("Lo más probable es que los residuos explicaran que la hoja se trabara, pero la prueba no lo confirma como causa del 0102.",
                         "Los residuos son la causa confirmada de la falla.")
    assert_not RUBRIC.t5(t5(published: text, pending: nil, citations: [ citation(21, P1, 121) ]), allowed_documents: ALLOWED)["ok"]
  end

  # --- Live run 20261120T012019Z, T5 ---------------------------------------

  LIVE_T5 = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/otis_case29_live_20261120.json").read).dig("turns", "t5")
  LIVE_Q4 = { "id" => "q4", "parts" => [ { "id" => "p4", "role" => "main", "text" => "¿La puerta se detiene siempre en el mismo punto antes de cerrar?" } ] }.freeze
  LIVE_Q5 = "¿Cuántos cierres seguidos hiciste en la prueba y en todos la puerta cerró completa?"
  # What the publication delivers once the filter keeps the reported result.
  KEPT_T5 = <<~TEXT.strip
    Tras retirar los residuos de la guía, la puerta cerró por completo y el 0102 no volvió a aparecer en tu prueba. Lo más probable es que el cambio se deba a esa limpieza, porque reportaste que la hoja se trababa antes de completar el cierre.

    Eso no confirma la causa. El 0102 significa "La puerta no fue capaz de cerrar" [2] y se asocia a "al desaparecer alguna de las señales DCL, DFC o DW" [1].

    Sigue sin verificarse DCL ni DFC.

    #{NOTICE}
  TEXT

  test "the live T5 text, without the reported result, fails on what the answer asserts about the test" do
    published = LIVE_T5.fetch("published_live").sub(/\n\nLa referencia describe.*\z/m, "")
    verdict = RUBRIC.t5(t5(published: published, pending: { "id" => "q5", "question" => LIVE_Q5, "targets" => [], "parts" => [ { "id" => "p5", "role" => "main" } ] },
                           citations: [ citation(1, P2, 22), citation(2, P2, 85) ].map { |row| row.merge("tooltip_excerpt" => "La puerta no fue capaz de cerrar") }, pending_before: LIVE_Q4), allowed_documents: ALLOWED)

    assert_includes verdict["failed"], "result_limited_to_the_test", "the question mentions «la prueba»; the answer asserts nothing about it"
    assert_not_includes verdict["failed"], "residue_named_as_likely_explanation", "«limpieza» keeps the meaning"
    assert_not_includes verdict["failed"], "previous_check_addressed"
    assert_not_includes verdict["failed"], "pending_keeps_its_source", "the citations back the 0102 reading, not the question: targets []"
  end

  test "T5 passes when the publication keeps the result limited to the test and closes without a pending" do
    verdict = RUBRIC.t5(t5(published: KEPT_T5, pending: nil, pending_before: LIVE_Q4,
                           citations: [ citation(1, P2, 22), citation(2, P2, 85) ].map { |row| row.merge("tooltip_excerpt" => "La puerta no fue capaz de cerrar") }), allowed_documents: ALLOWED)

    assert verdict["ok"], verdict["failed"].inspect
  end

  test "T5 judges the scope of what the answer asserts, not a mention of the test elsewhere" do
    generalized = KEPT_T5.sub("no volvió a aparecer en tu prueba", "no volvió a aparecer")
    asked = "#{generalized}\n\nPregunta: ¿Cuántos cierres seguidos hiciste en la prueba?"
    verdict = RUBRIC.t5(t5(published: asked, pending: nil, citations: [ citation(1, P2, 22), citation(2, P2, 85) ]), allowed_documents: ALLOWED)

    assert_includes verdict["failed"], "result_limited_to_the_test"

    scoped = generalized.sub("Lo más probable", "Esto solo vale para esa prueba. Lo más probable")
    assert RUBRIC.t5(t5(published: scoped, pending: nil, citations: [ citation(1, P2, 22), citation(2, P2, 85) ]), allowed_documents: ALLOWED)["ok"],
           "a declarative sentence of the same paragraph limits it"
  end

  test "T5 takes the check that was open from the case state, whichever part it was" do
    open = ->(overrides) { RUBRIC.t5(t5(**{ published: KEPT_T5, pending: nil, citations: [ citation(1, P2, 22), citation(2, P2, 85) ], pending_before: LIVE_Q4 }.merge(overrides)), allowed_documents: ALLOWED) }

    assert open.call({})["ok"]
    assert open.call(part_states: { "p4" => "partial" })["ok"]
    assert open.call(pending_before: nil)["ok"], "nothing was open"
    waiting = open.call(pending: { "id" => "q4", "question" => LIVE_Q4.dig("parts", 0, "text"), "targets" => [], "parts" => LIVE_Q4["parts"] })
    assert_includes waiting["failed"], "previous_check_addressed", "the same unanswered question still waits"
    silent = open.call(observations: [])
    assert_includes silent["failed"], "previous_check_addressed", "nothing was recorded this turn"
  end

  test "T5 asks a DFC suggestion for backing only when it makes one" do
    suggests = "#{KEPT_T5}\n\nSi haces otra maniobra, observa DFC: el manual lo describe como \"#{DFC_QUOTE}\" [3]."
    cited = [ citation(1, P2, 22), citation(2, P2, 85) ].map { |row| row.merge("tooltip_excerpt" => "La puerta no fue capaz de cerrar") }

    backed = RUBRIC.t5(t5(published: suggests, pending: nil, citations: cited + [ citation(3, P1, 121) ]), allowed_documents: ALLOWED)
    assert backed["ok"], backed["failed"].inspect

    unbacked = RUBRIC.t5(t5(published: suggests.sub(" [3]", ""), pending: nil, citations: cited), allowed_documents: ALLOWED)
    assert_includes unbacked["failed"], "dfc_suggestion_backed_when_made"

    wrong_passage = RUBRIC.t5(t5(published: suggests, pending: nil, citations: cited + [ citation(3, P1, 121).merge("tooltip_excerpt" => "Otro texto") ]), allowed_documents: ALLOWED)
    assert_includes wrong_passage["failed"], "dfc_suggestion_backed_when_made"

    reported = "#{KEPT_T5}\n\nDCL y DFC, que según tu reporte no llegaron a verificarse."
    kept = RUBRIC.t5(t5(published: reported, pending: nil, citations: cited), allowed_documents: ALLOWED)
    assert_not_includes kept["failed"], "dfc_suggestion_backed_when_made"
  end

  test "T5 pending takes its source from the paragraph that asks it or the check paragraph before it" do
    target = { "item" => P2, "document_key" => "s3://bucket/bulk_uploads/3/#{P2}.pdf", "filename" => "chunk_p22_2.txt", "page" => "22" }
    cited = [ citation(1, P2, 22), citation(2, P2, 85) ]
    text = "#{KEPT_T5}\n\nSiguiente comprobación (DFC): según [1], DCL, DFC o DW.\n\n#{LIVE_Q5}"

    with_source = RUBRIC.t5(t5(published: text, pending: pending(targets: [ target ], question: LIVE_Q5), citations: cited), allowed_documents: ALLOWED)
    assert with_source["ok"], with_source["failed"].inspect

    without = RUBRIC.t5(t5(published: text, pending: pending(targets: [], question: LIVE_Q5), citations: cited), allowed_documents: ALLOWED)
    assert_includes without["failed"], "pending_keeps_its_source", "the cited passage backs the question: its document is kept"
  end

  # --- T6 ---------------------------------------------------------------

  test "round 4 T6 passes: DFC recorded and linked, DCL unverified and not asked, state kept" do
    verdict = RUBRIC.t6(t6, allowed_documents: ALLOWED)
    assert verdict["ok"], verdict["failed"].inspect
  end

  # Live 20261120T201453Z T6. The pending keeps the clause before «¿» and the
  # publication shows the question. They are the same question.
  test "T6 accepts a pending that keeps the clause in front of the question mark" do
    question = "con la puerta del piso 3 cerrada, ¿el LED DW de la placa está encendido?"
    summary = t6("published" => "Sin verificar: DCL.\n\nPregunta: #{question}", "pending" => { "question" => question, "targets" => [] }, "asked_again" => question)

    assert RUBRIC.t6(summary, allowed_documents: ALLOWED)["checks"]["published_question_is_the_pending"]
  end

  test "T6 passes with no pending opened in T5, linked through the DFC the technician declared unverified" do
    summary = t6(opened_pending: nil)
    verdict = RUBRIC.t6(summary, allowed_documents: ALLOWED)
    assert verdict["ok"], verdict["failed"].inspect

    summary = t6(opened_pending: nil, earlier_checks: [ { "subject" => "No llegamos a verificar DCL", "status" => "not_done", "correlation_id" => T5_CID } ])
    assert_includes RUBRIC.t6(summary, allowed_documents: ALLOWED)["failed"], "dfc_thread_kept"
  end

  test "T6 fails when the DFC question stays open, DCL is asked again, marked done, or earlier state is lost" do
    open = RUBRIC.t6(t6(part_states: { "p3" => "partial" }, pending: { "question" => "¿DFC?", "targets" => [] }), allowed_documents: ALLOWED)
    assert_includes open["failed"], "dfc_thread_kept"
    assert_includes open["failed"], "published_question_is_the_pending"

    again = RUBRIC.t6(t6(published: "DFC quedó encendido [9]. ¿Pudiste ver el estado de DCL con la puerta cerrada?", asked_again: "¿Pudiste ver el estado de DCL con la puerta cerrada?"), allowed_documents: ALLOWED)
    assert_includes again["failed"], "dcl_not_asked_again"

    done = RUBRIC.t6(t6(checks: [ { "subject" => "DCL", "status" => "done", "correlation_id" => T6_CID } ]), allowed_documents: ALLOWED)
    assert_includes done["failed"], "dcl_never_marked_done"
    assert_includes done["failed"], "dcl_kept_unverified"

    lost = RUBRIC.t6(t6(all_observations: [ "el LED DFC se encendido y quedó encendido, puerta cerrada" ]), allowed_documents: ALLOWED)
    assert_includes lost["failed"], "state_survives_reload"

    unrecorded = RUBRIC.t6(t6(observations: [ "la puerta completó el cierre" ]), allowed_documents: ALLOWED)
    assert_includes unrecorded["failed"], "maneuver_result_recorded"
  end

  # --- T1 to T4 ---------------------------------------------------------

  test "T1 to T4 pass on the state the document describes and fail on what it rules out" do
    t1 = { "identifiers" => [ { "value" => "GECGB", "source" => "user" } ], "photo" => "loaded", "visible_text" => [ "Ad*** COR CR ][][", "U00D00 D 1C" ],
           "all_observations" => [ "En el.piso 3 la puerta intenta cerrar y vuelve abrir" ], "citations" => [], "published" => "¿Qué evento aparece en el historial?",
           "asked_again" => "¿Qué evento aparece en el historial?" }
    assert RUBRIC.t1(t1, allowed_documents: ALLOWED)["ok"]
    assert_includes RUBRIC.t1(t1.merge("identifiers" => [ { "value" => "GECB" } ]), allowed_documents: ALLOWED)["failed"], "identifier_kept_as_typed"
    assert_includes RUBRIC.t1(t1.merge("visible_text" => [ "MODULE" ]), allowed_documents: ALLOWED)["failed"], "console_labels_kept_from_photo"
    assert_includes RUBRIC.t1(t1.merge("all_observations" => t1["all_observations"] + [ "0102 DTC" ]), allowed_documents: ALLOWED)["failed"], "no_0102_yet"

    t2 = { "all_observations" => [ "En el historial de eventos aparece 0102 0pMode DTC." ], "published" => "¿Se pudo verificar DCL con la puerta cerrada? [1]",
           "asked_again" => "¿Se pudo verificar DCL con la puerta cerrada?", "citations" => [ citation(1, P2, 85).merge("tooltip_excerpt" => "La puerta no fue capaz de cerrar (perdido DCL,DFC ó DW)") ] }
    assert RUBRIC.t2(t2, allowed_documents: ALLOWED)["ok"]
    assert_includes RUBRIC.t2(t2.merge("citations" => [ citation(1, P2, 85) ]), allowed_documents: ALLOWED)["failed"], "event_backed_by_a_passage"

    t3 = { "all_observations" => [ "Todavía no he confirmado el.estado de DCL" ], "photo_turns" => [ { "sequence" => 1 }, { "sequence" => 3 } ], "photo" => "loaded",
           "asked_again" => "¿La hoja llega al cierre completo o se detiene antes?", "citations" => [], "published" => "DCL sigue sin verificar." }
    assert RUBRIC.t3(t3, allowed_documents: ALLOWED)["ok"]
    assert_includes RUBRIC.t3(t3.merge("photo_turns" => [ { "sequence" => 3 }, { "sequence" => 1 } ]), allowed_documents: ALLOWED)["failed"], "two_photos_in_order"

    t4 = { "observations" => [ "Se detiene antes" ], "earlier_observations" => [ "el historial muestra 0102", "no he confirmado DCL" ],
           "asked_again" => "¿Ves algún punto donde se trabe o roce la hoja en el umbral?", "citations" => [], "published" => "..." }
    assert RUBRIC.t4(t4, allowed_documents: ALLOWED)["ok"]
    assert_includes RUBRIC.t4(t4.merge("earlier_observations" => [ "el historial muestra 0102" ]), allowed_documents: ALLOWED)["failed"], "event_and_dcl_kept"
  end

  # --- Run 20261120T121417Z: what each turn may demand ------------------

  test "T1 demands the history event or something else the equipment shows, not a question about a variant of the manual" do
    t1 = { "identifiers" => [ { "value" => "GECGB" } ], "photo" => "loaded", "visible_text" => [ "COR CR" ],
           "all_observations" => [ "En el.piso 3 la puerta intenta cerrar y vuelve abrir" ], "citations" => [] }
    front_or_rear = "¿La puerta del piso 3 es frontal o trasera?"
    asked = ->(question) { RUBRIC.t1(t1.merge("asked_again" => question, "published" => question), allowed_documents: ALLOWED) }

    assert_includes asked.call(front_or_rear)["failed"], "history_event_or_equivalent_requested"
    assert asked.call("¿Qué evento aparece en el historial de la placa?")["ok"]
    assert asked.call("¿Qué código o mensaje muestra la consola cuando falla?")["ok"], "an equivalent request for a reading the equipment shows"
    short = "Antes de revisar señales, necesito el código o evento que muestra la consola cuando la puerta vuelve a abrir. ¿Qué texto o número aparece?"
    assert RUBRIC.t1(t1.merge("asked_again" => "¿Qué texto o número aparece?", "published" => short), allowed_documents: ALLOWED)["ok"]
    assert_includes RUBRIC.t1(t1.merge("published" => "Sin pregunta."), allowed_documents: ALLOWED)["failed"], "history_event_or_equivalent_requested"
  end

  test "T2 accepts a faithful cited explanation of 0102 without imposing DCL as the first check" do
    base = { "all_observations" => [ "En el historial de eventos aparece 0102 0pMode DTC." ], "asked_again" => nil,
             "citations" => [ citation(1, P2, 22).merge("tooltip_excerpt" => "La puerta no cierra en el tiempo programado al desaparecer alguna de las señales DCL, DFC o DW") ] }
    faithful = "El 0102 indica que la puerta no cierra en el tiempo programado cuando desaparece alguna de las señales DCL, DFC o DW [1]."

    assert RUBRIC.t2(base.merge("published" => faithful), allowed_documents: ALLOWED)["ok"], "no DCL question is asked and none is required"
    assert RUBRIC.t2(base.merge("published" => "#{faithful} Es una hipótesis mientras no se sepa qué señal falta."), allowed_documents: ALLOWED)["ok"]
  end

  test "T2 fails when one of the three signals is named as the lost one or the explanation has no passage behind it" do
    base = { "all_observations" => [ "En el historial de eventos aparece 0102 0pMode DTC." ], "asked_again" => nil,
             "citations" => [ citation(1, P2, 22).merge("tooltip_excerpt" => "La puerta no cierra en el tiempo programado al desaparecer alguna de las señales DCL, DFC o DW") ] }

    assumed = RUBRIC.t2(base.merge("published" => "El 0102 ocurre porque se perdió DCL [1]."), allowed_documents: ALLOWED)
    assert_equal [ "no_single_signal_named_as_lost" ], assumed["failed"]

    unbacked = RUBRIC.t2(base.merge("published" => "El 0102 indica que la puerta no cierra a tiempo.", "citations" => []), allowed_documents: ALLOWED)
    assert_includes unbacked["failed"], "event_backed_by_a_passage"
    assert_not_includes unbacked["failed"], "no_single_signal_named_as_lost"
  end

  test "T3 demands a step from the photo and the story and fails when the open question is asked again" do
    t3 = { "all_observations" => [], "checks" => [ { "subject" => "Todavía no he confirmado el.estado de DCL", "status" => "not_done" } ],
           "photo_turns" => [ { "sequence" => 1 }, { "sequence" => 3 } ], "photo" => "loaded", "citations" => [], "published" => "..." }
    front_or_rear = "¿La puerta del piso 3 es frontal o trasera?"
    open_question = { "id" => "q2", "question" => front_or_rear }

    repeated = RUBRIC.t3(t3.merge("asked_again" => front_or_rear, "pending_before" => open_question), allowed_documents: ALLOWED)
    assert_equal [ "advances_from_photo_and_report" ], repeated["failed"]

    assert RUBRIC.t3(t3.merge("asked_again" => "¿La hoja roza o se traba en la guía inferior al cerrar?", "pending_before" => open_question), allowed_documents: ALLOWED)["ok"]
    assert RUBRIC.t3(t3.merge("asked_again" => "¿Cerró por completo o se detiene antes de llegar?", "pending_before" => nil), allowed_documents: ALLOWED)["ok"]
    assert_includes RUBRIC.t3(t3.merge("asked_again" => "¿Qué modelo es la placa?", "pending_before" => open_question), allowed_documents: ALLOWED)["failed"], "advances_from_photo_and_report",
                    "a question that does not use the photo or the story is not an advance"
  end

  test "T4 reads the DCL the technician declared from the persisted check, not only from observations" do
    t4 = { "observations" => [ "Se detiene antes" ], "earlier_observations" => [ "el historial muestra 0102" ],
           "earlier_checks" => [ { "subject" => "Todavía no he confirmado el.estado de DCL", "status" => "not_done" } ],
           "asked_again" => "¿Ves algún punto donde se trabe o roce la hoja en el umbral?", "citations" => [], "published" => "..." }

    assert RUBRIC.t4(t4, allowed_documents: ALLOWED)["ok"]
    assert_includes RUBRIC.t4(t4.merge("earlier_checks" => []), allowed_documents: ALLOWED)["failed"], "event_and_dcl_kept"
  end

  test "T5 accepts the scope in a paragraph of its own and still rejects a result with no scope anywhere" do
    separate = <<~TEXT.strip
      La explicación más probable es el retiro de los residuos: la hoja dejó de trabarse y la puerta completó el cierre. Es una hipótesis, no una causa confirmada.

      **Alcance:** el resultado vale para una prueba de cierre sin reaparición del 0102. No certifica la puesta en servicio.

      **Sin verificar:** estado de DCL y DFC.
    TEXT
    cited = [ citation(2, P2, 85).merge("tooltip_excerpt" => "La puerta no fue capaz de cerrar") ]

    assert RUBRIC.t5(t5(published: separate, pending: nil, citations: cited), allowed_documents: ALLOWED)["ok"]

    unscoped = separate.sub(/\*\*Alcance:\*\*[^\n]*/, "No certifica la puesta en servicio.")
    assert_includes RUBRIC.t5(t5(published: unscoped, pending: nil, citations: cited), allowed_documents: ALLOWED)["failed"], "result_limited_to_the_test"
  end

  test "a stated limit to the reported test scopes the result; a pending condition is not an asserted result" do
    published = <<~TEXT
      Retiraste residuos de la guía, la puerta cerró por completo y el 0102 no volvió a aparecer en esa prueba. La explicación más probable es la obstrucción, aunque no está confirmada.

      Sigue sin verificarse:

      - Si el cierre completo se repite en varios ciclos.

      Esta lectura se limita a la prueba que reportaste.
    TEXT
    cited = [ citation(2, P2, 85).merge("tooltip_excerpt" => "La puerta no fue capaz de cerrar") ]

    assert_not_includes RUBRIC.t5(t5(published: published, pending: nil, citations: cited), allowed_documents: ALLOWED)["failed"], "result_limited_to_the_test"

    unscoped = published.sub("en esa prueba", "").sub(/Esta lectura se limita[^\n]*/, "No certifica la puesta en servicio.")
    assert_includes RUBRIC.t5(t5(published: unscoped, pending: nil, citations: cited), allowed_documents: ALLOWED)["failed"], "result_limited_to_the_test"
  end

  test "a cited DFC table keeps the limit of what the case has not confirmed, in T5 and in T6" do
    cited = [ citation(9, P1, 121) ]
    without = ROUND4_T5.sub(NOTICE, "")
    assert_includes RUBRIC.t5(t5(published: without, pending: pending(targets: []), citations: cited), allowed_documents: ALLOWED)["failed"], "dfc_table_limited_to_the_case_controller"

    bare = t6("published" => "DFC indica \"#{DFC_QUOTE}\" [9]. DCL y DW no están verificados.")
    assert_equal [ "dfc_table_limited_to_the_case_controller" ], RUBRIC.t6(bare, allowed_documents: ALLOWED)["failed"]

    no_table = t6("published" => "El LED DFC se encendió. DCL y DW no están verificados.", "citations" => [])
    assert RUBRIC.t6(no_table, allowed_documents: ALLOWED)["ok"], "nothing cited, nothing to limit"
  end

  test "T6 accepts a published question only when it waits as the pending after the reload, and no pending nobody saw" do
    plate = "¿Qué modelo exacto dice el rótulo de la placa del controlador?"
    published = "#{t6['published']}\n\n#{plate}"
    stored = { "type" => "controller", "question" => plate, "targets" => [] }

    assert RUBRIC.t6(t6("published" => published, "pending" => stored), allowed_documents: ALLOWED)["ok"]
    lost = RUBRIC.t6(t6("published" => published, "pending" => nil), allowed_documents: ALLOWED)
    assert_equal [ "published_question_is_the_pending" ], lost["failed"], "shown and lost"
    unseen = RUBRIC.t6(t6("pending" => stored), allowed_documents: ALLOWED)
    assert_equal [ "published_question_is_the_pending" ], unseen["failed"], "waiting, but nobody was asked"
  end

  private

  def citation(number, document, page)
    { "number" => number, "title" => "#{document} — p. #{page}", "filename" => document, "page" => page, "tooltip_excerpt" => DFC_QUOTE,
      "location" => { "key" => "bulk_chunks/3/abc/chunk_p#{page}_2.txt" } }
  end

  def pending(targets:, question: "¿Con la puerta del piso 3 cerrada, el LED DFC del panel está encendido?")
    { "type" => "documented_context", "question" => question,
      "targets" => targets, "id" => "q3", "parts" => [ { "id" => "p3", "role" => "main", "text" => "¿DFC?" } ] }
  end

  def t5(published:, pending:, citations:, asked_again: nil, checks: nil, pending_before: nil, part_states: nil, observations: nil)
    {
      "label" => "Otis T5", "correlation_id" => T5_CID, "published" => published, "pending" => pending, "citations" => citations,
      "pending_before" => pending_before, "observations" => observations || [ "Encontré residuos en la guía y los retiré" ],
      "asked_again" => asked_again, "part_states" => part_states || { "p1" => "unknown", "p2" => "partial" },
      "checks" => checks || [ { "subject" => "No llegamos a verificar DCL ni DFC", "status" => "not_done", "correlation_id" => T5_CID } ]
    }
  end

  EARLIER_OBSERVATIONS = [ "Encontré residuos en la guía y los retire", "Después la puerta cerró por completo" ].freeze
  T6_OBSERVATIONS = [ "la puerta completo el cierre", "el LED DFC se encendió y se mantuvo encendido al quedar cerrada" ].freeze
  EARLIER_CHECK = { "subject" => "No llegamos a verificar DCL ni DFC", "status" => "not_done", "correlation_id" => T5_CID }.freeze

  def t6(overrides = {})
    {
      "label" => "Otis T6", "correlation_id" => T6_CID, "published" => "Cierre de comprobación: piso 3. DFC indica \"#{DFC_QUOTE}\" [9]. DCL y DW no están verificados.\n\n#{NOTICE}",
      "pending" => nil, "asked_again" => nil, "citations" => [ citation(9, P1, 121) ],
      "opened_pending" => { "id" => "q3", "parts" => [ { "id" => "p3", "role" => "main", "text" => "¿Con la puerta cerrada, el LED DFC está encendido?" } ] },
      "part_states" => { "p2" => "partial", "p3" => "complete" },
      "checks" => [ EARLIER_CHECK, { "subject" => "No verifique DCL", "status" => "not_done", "correlation_id" => T6_CID } ],
      "observations" => T6_OBSERVATIONS, "earlier_observations" => EARLIER_OBSERVATIONS,
      "all_observations" => EARLIER_OBSERVATIONS + T6_OBSERVATIONS, "earlier_checks" => [ EARLIER_CHECK ]
    }.merge(overrides.stringify_keys)
  end
end
