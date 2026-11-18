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
end
