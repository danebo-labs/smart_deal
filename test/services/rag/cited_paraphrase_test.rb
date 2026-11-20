# frozen_string_literal: true

require "test_helper"

# A cited sentence may translate the manual. A span in quotation marks has to
# be the source's own words. The words around it stay when they keep the same
# entities, the same scope, and the same conditions. The two sentences below
# are the unbacked_citation removals of photo:b44674aa-7205-4bdb-904b-ae33c4f268f4.
class Rag::CitedParaphraseTest < ActiveSupport::TestCase
  ROW = <<~TEXT.freeze
    | Código | Falha | Onde | Solução |
    | EA | Falha de sinais | Fiação das linhas START, RED, MAN, DIRU, 1VEL, 2VEL, 3VL, T100, P28, P26, S0S E BKF | 1. Revisar conexão destas linhas; 2. Quando falha de P28 - porta aberta - revisar linha dos trincos; 3. Quando falha de BKF - revisar circuito do freio; 4. Revisar circuito S0S |
  TEXT
  OTHER = <<~TEXT.freeze
    | FA | Falha de alimentação | Fiação das linhas L1 e L2 | 1. Revisar conexão destas linhas; 2. Quando falha de K4 - porta aberta - revisar linha do trinco; 3. Quando falha de BK - revisar circuito do freio |
  TEXT
  WIRING = "Según [1], «Falha de sinais» abarca el cableado de START, RED, MAN, DIRU, 1VEL, 2VEL, 3VL, T100, P28, P26, S0S y BKF."
  BRANCHES = "Dentro de esas, [1] destaca dos casos: P28 (puerta abierta) y BKF (freno)."
  TRANSLATION = "EA es una falla de señales [1]."
  CONFIRMED = "P28 es la causa confirmada de cualquier EA [1]."

  def sources(content)
    [ { "index" => 1, "content" => content, "applicability" => "compatible" } ]
  end

  def backing(text, content)
    Rag::CompanionClaimBacking.call(text: text, sources: sources(content))
  end

  def published(text, content)
    result = backing(text, content)
    guarded = Rag::AnswerSafetyProcessor.new(locale: :es).call(
      result.text, evidence: [ { "content" => content } ], require_cited_evidence: true
    )
    publication = Rag::CompanionTurnPublication.call(
      text: result.text, guarded_text: guarded, sources: sources(content), locale: :es
    )
    [ result, guarded, publication ]
  end

  test "the two removed sentences translate the row and keep the conditional branches" do
    text = "#{TRANSLATION} #{WIRING} #{BRANCHES}"
    result, guarded, publication = published(text, ROW)

    assert_empty result.removed
    assert_includes guarded, "falla de señales"
    assert_includes guarded, "cableado de START"
    assert_includes guarded, "P28 (puerta abierta)"
    assert_includes guarded, "BKF (freno)"
    assert publication.accepted?, publication.reasons.inspect
  end

  test "a confirmed cause drops the condition of another manual" do
    faithful = "Según [1], «Falha de alimentação» abarca el cableado de L1 y L2."
    lost = "Revisa la línea del trinco [1]."
    text = "#{faithful} #{lost} #{CONFIRMED.sub("P28", "K4").sub("EA", "FA")}"
    result, guarded, publication = published(text, OTHER)

    assert_includes guarded, "cableado de L1 y L2"
    assert_not_includes guarded, "trinco"
    assert_not_includes guarded, "causa confirmada"
    assert_equal [ "unbacked_citation", "unbacked_citation" ], result.removed.pluck("reason")
    assert publication.accepted?, publication.reasons.inspect
  end

  test "naming one conditional branch as the cause of every code is removed" do
    result, guarded, = published("#{TRANSLATION} #{CONFIRMED}", ROW)

    assert_includes guarded, "falla de señales"
    assert_not_includes guarded, "causa confirmada"
    assert_equal [ "unbacked_citation" ], result.removed.pluck("reason")
  end

  # Otis case 29, run 20261120T121417Z. The two rows are the passages the
  # generator received in T2 (GeN2 Comfort table, p. 22 of the second volume)
  # and T3 (GeN2 Premier TCBC, p. 85 of the second volume).
  DIAGNOSTIC_TABLE = <<~TEXT.freeze
    | Mensaje | Clase | Descripción | Parámetros relacionados |
    |-|-|-|-|
    | 0102 OpMode DTC | W | La puerta no cierra en el tiempo programado al desaparecer alguna de las señales DCL, DFC o DW | DCL (694), RDCL (695), DOOR, REAR DTC-T |
    | 0103 OpMode DTO | F | La puerta no abre en el tiempo programado al desaparecer DOL | DOL (000), RDOL (544), DOOR, REAR DTO-T |
  TEXT
  EVENT_TABLE = <<~TEXT.freeze
    | SUCESO | CAUSA | PROGRAMACION RELACIONADA |
    |-|-|-|
    | 0102 OpMode DTC | La puerta no fue capaz de cerrar (perdido DCL,DFC ó DW) dentro del tiempo permitido. | DCL (694) / RDCL (695) / DOOR,REAR / DTC-T |
  TEXT

  test "a paraphrase of the three signals of the 0102 row is kept with other words for the loss" do
    result, guarded, publication = published("Según la tabla, ocurre al faltar DCL, DFC o DW [1].", DIAGNOSTIC_TABLE)

    assert_empty result.removed
    assert_includes guarded, "faltar DCL, DFC o DW"
    assert publication.accepted?, publication.reasons.inspect
  end

  test "a faithful reading of the event row, with a verb and a connector the source does not use, is kept" do
    text = "El 0102 indica que la puerta no cerró porque se perdió \"DCL,DFC ó DW\" [1]."
    result, guarded, publication = published(text, EVENT_TABLE)

    assert_empty result.removed
    assert_includes guarded, "DCL,DFC ó DW"
    assert publication.accepted?, publication.reasons.inspect
  end

  test "assigning DCL to the front door and RDCL to the rear door is removed: no row says it" do
    text = "Los parámetros dependen de la puerta: DCL (694) para la delantera o RDCL (695) para la trasera, con su tiempo de cierre DTC-T [1]."
    result, guarded, = published(text, DIAGNOSTIC_TABLE)

    assert_not_includes guarded, "delantera"
    assert_equal [ "unbacked_citation" ], result.removed.pluck("reason")
  end

  test "naming one of the three signals as the lost one is removed: the row lists alternatives" do
    one = "El 0102 ocurre porque se perdió DCL [1]."
    other = "Según la tabla, ocurre al faltar DOS, DFC o DW [1]."
    result, guarded, = published("#{one} #{other}", DIAGNOSTIC_TABLE)

    assert_not_includes guarded, "se perdió DCL"
    assert_not_includes guarded, "DOS"
    assert_equal [ "unbacked_citation", "unbacked_citation" ], result.removed.pluck("reason")
  end

  test "saying that any of the three may be the missing one keeps the alternatives" do
    result, guarded, = published("El 0102 aparece cuando falta cualquiera de DCL, DFC o DW [1].", DIAGNOSTIC_TABLE)

    assert_empty result.removed
    assert_includes guarded, "DCL, DFC o DW"
  end

  PAX_GUIDE = <<~TEXT.freeze
    GUÍA DE SOLUCIÓN DE AVERÍAS EN PUERTA PAX

    2) PROBLEMAS EN LA APERTURA, CIERRE, REAPERTURAS.

    - Comprobar señales del PAX (M-3-1-2 y M-3-1-3 en PAX).
    - Comprobar señales de reapertura en LCB_II (M-1-1-3: DOB, LRD, etc).
    - Comprobar ajustes mecánicos de la puerta.
  TEXT
  FRONT_DOOR = <<~TEXT.freeze
    Grupo Puertas frontales (Front Door):
    | Señal | Descripción | Se muestra cuando (I/O) |
    | DOS | Señal de reapertura de puertas (SGS) | I/O - 605 |
  TEXT

  # Photo turn 6552143e of run 20261120T133511Z: the generator asked for the
  # event and framed two cited lines. The guard removed both for words that
  # only frame the sentence or name «comprobar» as «revisar». No cited claim
  # was left and the publication replaced the request with a refusal.
  test "a conditional frame and revisar for the manual's comprobar keep the cited guide line" do
    text = "Como referencia condicional, la guía para problemas de apertura, cierre y reaperturas indica revisar las señales del PAX y las de reapertura en LCB_II [1]."
    result, guarded, = published(text, PAX_GUIDE)

    assert_empty result.removed
    assert_includes guarded, "revisar las señales del PAX"
  end

  test "figura en el manual keeps the cited row" do
    result, guarded, = published("La señal de reapertura de puertas (DOS) figura en el manual [1].", FRONT_DOOR)

    assert_empty result.removed
    assert_includes guarded, "DOS"
  end

  test "the frame and the check verb do not cover an entity, a part or a different action the line lacks" do
    other = "Como referencia condicional, la guía indica revisar la remota y la señal DCL [1]."
    replace = "La guía indica cambiar las señales del PAX [1]."
    result, = published("#{other} #{replace}", PAX_GUIDE)

    assert_equal [ "unbacked_citation", "unbacked_citation" ], result.removed.pluck("reason")
  end

  GEN2_ROW = "| 0102 OpMode DTC | W | La puerta no cierra en el tiempo programado al desaparecer alguna de las señales DCL, DFC o DW | DCL (694), RDCL (695), DOOR, REAR DTC-T |"
  PREMIER_ROW = "| 0102 OpMode DTC | La puerta no fue capaz de cerrar (perdido DCL,DFC ó DW) dentro del tiempo permitido. | DCL (694) / RDCL (695) / DOOR,REAR / DTC-T |"
  OTIS2000_ROW = "| 0102 OpMode DTC | La puerta no cierra en el tiempo programado (no aparecen las señales DCL, DFC ó DW) | DCL (694), RDCL (695), DOOR, REAR, DTC-T |"

  # Replay 1 of run 20261120T133511Z, turns 2 and 4. The generator joined the
  # wording of two rows of the same event and cited a third of them. The words
  # that differ are the manual's own synonyms: «permitido» for «programado»,
  # «alguna de» for the «ó» of a list, «significa» for «indica».
  test "alguna de, permitido and código keep the 0102 reading cited to the rows that say it" do
    text = "El código 0102 OpMode DTC indica que la puerta no cerró en el tiempo permitido porque faltó alguna de las señales DCL, DFC o DW [1][2]."
    result = Rag::CompanionClaimBacking.call(text: text, sources: [
      { "index" => 1, "content" => PREMIER_ROW, "applicability" => "compatible" },
      { "index" => 2, "content" => OTIS2000_ROW, "applicability" => "compatible" }
    ])

    assert_empty result.removed
    assert_includes result.text, "alguna de las señales DCL, DFC o DW"
  end

  # Live 20261120T200327Z T2. The draft cited only the Premier row, which lists
  # «perdido DCL,DFC ó DW» and does not say the word «señales». That word names
  # the items the row lists.
  # Live 20261120T201126Z T2. «no aparecieron» is the row's «desaparecer» and
  # «perdido». Without the negation the sentence says the opposite.
  test "no aparecieron keeps the 0102 reading and a positive appearance does not" do
    text = "El código indica que la puerta no cerró en el tiempo programado, porque no aparecieron las señales DCL, DFC o DW [1]."
    kept = Rag::CompanionClaimBacking.call(text: text, sources: [
      { "index" => 1, "content" => GEN2_ROW, "applicability" => "compatible" }
    ])
    premier = Rag::CompanionClaimBacking.call(text: text.sub("[1]", "[1]"), sources: [
      { "index" => 1, "content" => PREMIER_ROW, "applicability" => "compatible" }
    ])
    opposite = Rag::CompanionClaimBacking.call(
      text: "Aparecieron las señales DCL, DFC o DW [1].",
      sources: [ { "index" => 1, "content" => GEN2_ROW, "applicability" => "compatible" } ]
    )

    assert_empty kept.removed
    assert_empty premier.removed
    assert_equal [ "unbacked_citation" ], opposite.removed.pluck("reason")
  end

  test "the premier row backs the 0102 reading that calls the listed items señales" do
    text = "La puerta no cerró dentro del tiempo permitido porque faltó alguna de las señales DCL, DFC o DW [1]."
    result = Rag::CompanionClaimBacking.call(text: text, sources: [
      { "index" => 1, "content" => PREMIER_ROW, "applicability" => "compatible" }
    ])

    assert_empty result.removed
  end

  test "significa and no logra cerrar keep the 0102 reading cited to the row of the same event" do
    text = "Según [1], el 0102 significa que la puerta no logra cerrar dentro del tiempo permitido cuando desaparece DCL, DFC o DW."
    result, = published(text, GEN2_ROW)

    assert_empty result.removed
  end

  test "alguna de does not cover a row that lists no alternatives, and a warning class the row does not state stays removed" do
    single = "| 0102 OpMode DTC | La puerta no cierra en el tiempo programado al desaparecer DCL |"
    text = "El 0102 ocurre al faltar alguna de las señales DCL, DFC o DW [1]. En la tabla aparece como clase W, es decir, advertencia [1]."
    result, = published(text, single)

    assert_equal [ "unbacked_citation", "unbacked_citation" ], result.removed.pluck("reason")
    result, guarded, = published("En la tabla aparece como clase W, es decir, advertencia [1].", GEN2_ROW)

    assert_equal [ "unbacked_citation" ], result.removed.pluck("reason"), guarded
  end
end
