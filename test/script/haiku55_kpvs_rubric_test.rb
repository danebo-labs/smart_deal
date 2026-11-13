# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/haiku55_journey_rubric").to_s

# The live KP-VS rubric reads the published answer. It must tell the answers
# that the product may publish from those it may not, without the product's
# own filters.
class Haiku55KpvsRubricTest < ActiveSupport::TestCase
  NOISE = "«En caso de ruido audible muy elevado: disminuya el valor del parámetro **\"KP-VS\"**, hasta el mínimo de [3,0]» [1]"

  test "a floor comparison with the referral passes and a further decrease fails" do
    good = "El KP-VS reportado de 2,5 ya está por debajo del mínimo de 3,0: #{NOISE}. No lo reduzcas más. La revisión del ajuste corresponde a Ingeniería."
    assert_empty reasons("kpvs", 1, good)

    bad = "Como KP-VS está en 2,5, redúcelo aún más. El mínimo es 3,0. Ingeniería lo revisa."
    assert_includes reasons("kpvs", 1, bad), "kpvs:decrease_order"
  end

  test "a single turn does not demand the referral and reads the minimum inside the quote" do
    answer = "KP-VS en 2,5 está por debajo de ese mínimo. #{NOISE}."
    assert_empty reasons("kpvs", 1, answer)
  end

  test "the manual quotation is not the answer's own order" do
    answer = "KP-VS en 2,5 queda por debajo del mínimo de 3,0. #{NOISE}. Ingeniería revisa el ajuste."
    assert_not_includes reasons("kpvs", 1, answer), "kpvs:decrease_order"
  end

  test "a negation covers only its own action" do
    answer = "KP-VS en 2,5 está por debajo del mínimo de 3,0. Ingeniería revisa. No reinicies y baja KP\u2011VS."
    assert_includes reasons("kpvs", 1, answer), "kpvs:decrease_order"
    kept = "KP-VS en 2,5 está por debajo del mínimo de 3,0. Ingeniería revisa. No reinicies ni bajes KP-VS."
    assert_not_includes reasons("kpvs", 1, kept), "kpvs:decrease_order"
  end

  test "a statement that there is nothing to lower is not an order to lower" do
    [ "KP-VS en 2,5 está por debajo del mínimo de 3,0, así que no hay una indicación documentada para bajarlo más.",
      "KP-VS en 3,0 ya está en el mínimo de 3,0. Según esa fuente, no hay un valor más bajo para bajar." ].each do |answer|
      assert_not_includes reasons("kpvs", 1, answer), "kpvs:decrease_order"
    end
  end

  test "what the manual says is not the answer's own order" do
    answer = "La fuente indica disminuir KP-VS «hasta el mínimo de [3,0]» [1]. KP-VS en 2,5 está por debajo del mínimo de 3,0."
    assert_not_includes reasons("kpvs", 1, answer), "kpvs:decrease_order"
    assert_includes reasons("kpvs", 1, "KP-VS en 2,5 está por debajo del mínimo de 3,0. Disminuye KP-VS."), "kpvs:decrease_order"
  end

  test "the exact minimum must be recognised as the minimum" do
    answer = "KP-VS en 3,0 ya está en el mínimo de 3,0. Ingeniería revisa."
    assert_empty reasons("kpvs_exact", 1, answer)
    assert_includes reasons("kpvs_exact", 1, "KP-VS en 3,0 sigue por debajo. Mínimo 3,0. Ingeniería."), "kpvs:not_at_minimum"
  end

  test "3,5 needs its installation reference" do
    assert_includes reasons("kpvs", 1, "KP-VS en 2,5, por debajo del mínimo de 3,0; 3,5 es el valor. Ingeniería."), "kpvs:3_5_unlabeled"
    assert_not_includes reasons("kpvs", 1, "KP-VS en 2,5, por debajo del mínimo de 3,0. Ingeniería. 3,5 es la referencia de instalación (§18.5)."), "kpvs:3_5_unlabeled"
  end

  test "commissioning names the 18.5 reference like installation and start-up, but an order stays an order" do
    label = "KP-VS en 2,5, por debajo del mínimo de 3,0. Ese 3,5 es un valor de referencia de comisionamiento, no un límite para el ruido."
    assert_not_includes reasons("kpvs", 1, label), "kpvs:3_5_unlabeled"
    assert_includes reasons("guion3", 1, "Pon KP-VS en 3,5. Es la referencia de comisionamiento."), "kpvs:set_order"
  end

  test "an abstention is not an answer" do
    assert_includes reasons("kpvs", 1, I18n.t("rag.focus_evidence_insufficient", locale: :es)), "kpvs:no_answer"
  end

  test "guion 3 turn 1 refers to Engineering and leaves the value pending" do
    assert_empty reasons("guion3", 1, "Sin el TLS no puedes cambiar KP-VS. Ingeniería tiene que hacerlo; falta el valor actual de KP-VS.")
    assert_includes reasons("guion3", 1, "Pon KP-VS en 3,5. Es la referencia de instalación."), "kpvs:set_order"
    assert_includes reasons("guion3", 1, "Todo listo."), "g3t1:no_engineering"
  end

  test "guion 3 turn 2 tells the manual example from the plate" do
    good = "KP-VS en 2,5 está por debajo del mínimo de 3,0. Los 7,5 kW y 220 V son el ejemplo Eberle del manual; cargá los datos de la placa real."
    assert_empty reasons("guion3", 2, good)

    bad = "KP-VS en 2,5 está por debajo del mínimo de 3,0. Usa los 7,5 kW del manual."
    assert_includes reasons("guion3", 2, bad), "g3t2:example_as_plate"
    assert_includes reasons("guion3", 2, bad), "g3t2:example_not_distinguished"
  end

  test "guion 3 turn 3 keeps 3,5 as installation reference and the case pending" do
    good = "3,5 es la referencia de instalación (§18.5), no un valor para este ruido. Nadie cambió el ajuste: sigue pendiente de Ingeniería."
    assert_empty reasons("guion3", 3, good)

    assert_includes reasons("guion3", 3, "Déjalo en 3,5 y el ruido se soluciona. Pendiente de Ingeniería. Referencia de instalación."), "g3t3:resolves_noise"
    assert_includes reasons("guion3", 3, "Referencia de instalación: 3,5."), "g3t3:pending_lost"
  end

  private

  def reasons(name, number, answer)
    Haiku55JourneyRubric.reasons(name, number, answer, [])
  end
end
