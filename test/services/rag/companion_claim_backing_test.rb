# frozen_string_literal: true

require "test_helper"

class Rag::CompanionClaimBackingTest < ActiveSupport::TestCase
  VF5_58 = "Las puertas se abrirán lentamente en la primera operación después de un fallo de alimentación " \
           "para verificar el paso libre. Solo es necesario realizar otra vez el autoajuste para la configuración " \
           "de los parámetros por defecto o cuando se realicen cambios como la conexión o desconexión de la fotocélula Fermator."
  VF5_54 = "54 Ajuste de la fuerza de reapertura. Girar hacia + para aumentar."
  ELEMONT = "Chapa nivel 3 sale de Com 18vdc, pasa por Dp3 y cruza PasCom 24V con un puente semicircular sin punto de unión. LC7 llega a Sp3."

  def sources(*contents)
    contents.each_with_index.map { |content, index| { "index" => index + 1, "content" => content, "applicability" => "compatible" } }
  end

  def call(text, *contents, technician: [])
    Rag::CompanionClaimBacking.call(text: text, sources: sources(*contents), technician_texts: technician)
  end

  test "keeps a cited sentence with a literal quote of that source" do
    text = "Es esperado: «Las puertas se abrirán lentamente en la primera operación» [1]."
    result = call(text, VF5_58)

    assert_equal text, result.text
    assert_empty result.removed
  end

  test "drops a cited paraphrase that adds a condition and keeps the rest" do
    text = "Si sigue abriendo despacio, lo documentado es repetir el autoajuste [1]. Mi lectura: la primera apertura lenta es esperable.\n\n¿Fue solo la primera?"
    result = call(text, VF5_58)

    assert_equal "Mi lectura: la primera apertura lenta es esperable.\n\n¿Fue solo la primera?", result.text
    assert_equal [ "unbacked_citation" ], result.removed.pluck("reason")
  end

  test "a one-character label does not back a direction" do
    result = call("Gira el potenciómetro #54 hacia el lado «+» [1].", VF5_54)

    assert_empty result.text
    assert_includes %w[unverified_quote unbacked_citation], result.removed.first["reason"]
  end

  test "drops a quote that omits its source condition" do
    result = call("«Es necesario realizar otra vez el autoajuste» [1].", VF5_58)

    assert_includes %w[unverified_quote unbacked_citation], result.removed.first["reason"]
  end

  CEA_P22 = "Lógica de nivel de señal (Figura 3):\nUna serie de seguridad es \"1\" si la tensión en el terminal " \
            "correspondiente es 24 Vcc, o \"0\" si la tensión en el terminal correspondiente es 0 Vcc."
  CEA_P75 = "| 77 | CSUI | Mando direccional de SUbir, independiente de SA | Movimiento | Mando de subir, activo aunque SA=0 |"
  CEA_T3 = "Según [2], \"si la tensión en el terminal correspondiente es 0 Vcc\" la serie vale 0, y con 24 Vcc vale 1."

  test "moves the number of a literal quote to the one other source that holds it" do
    result = call(CEA_T3, CEA_P22, CEA_P75)

    assert_equal CEA_T3.sub("[2]", "[1]"), result.text
    assert_empty result.removed
    assert_equal [ [ 2, 1 ] ], result.reattributed.map { |row| [ row["from"], row["to"] ] }
    assert result.to_h["changed"]
  end

  test "keeps the rejection when the quote is in several sources or drops its condition there" do
    several = call(CEA_T3, CEA_P22, CEA_P75, CEA_P22)
    dropped = call(CEA_T3.sub("\"si la", "\"la"), CEA_P22, CEA_P75)

    [ several, dropped ].each do |result|
      assert_empty result.text
      assert_equal [ "unverified_quote" ], result.removed.pluck("reason")
      assert_empty result.reattributed
    end
  end

  test "drops a citation to a missing source" do
    result = call("Mide continuidad entre #21 y #23 [31].", VF5_58)

    assert_equal "missing_source", result.removed.first["reason"]
  end

  test "drops an uncited attribution to the manual" do
    result = call("Según el manual, hay que cambiar la placa.", VF5_58)

    assert_equal "uncited_attribution", result.removed.first["reason"]
  end

  test "keeps a literal bold quote and ignores a bold heading" do
    text = "**Qué revisar:**\n- **cruza PasCom 24V con un puente semicircular** [1]."
    result = call(text, ELEMONT)

    assert_equal text, result.text
  end

  test "drops a heading left without content" do
    result = call("**Pasos a seguir:**\n\n- Ajusta #54 hacia «+» [1].\n\n¿El LED está encendido?", VF5_54)

    assert_equal "¿El LED está encendido?", result.text
  end

  test "technician quotes are kept and do not back a citation" do
    text = "Dijiste que «no sé cuál es la Chapa nivel 3». El plano muestra que «LC7 llega a Sp3» [1]."
    kept = call(text, ELEMONT, technician: [ "No sé cuál es la Chapa nivel 3" ])
    dropped = call("Reemplaza Dp3, porque «no sé cuál es la Chapa nivel 3» [1].",
                   ELEMONT, technician: [ "No sé cuál es la Chapa nivel 3" ])

    assert_equal text, kept.text
    assert_equal "unbacked_citation", dropped.removed.first["reason"]
  end

  test "a correct literal quote does not carry an identifier written beside it" do
    vf5 = "Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)."
    result = call("«Comprobar la sensibilidad del potenciómetro de regulación» [1] y lleva #52 al máximo.", vf5)
    elemont = call("«LC7 llega a Sp3» [1], y también Sp9.", ELEMONT)

    assert_equal "unbacked_residue", result.removed.first["reason"]
    assert_equal "unbacked_residue", elemont.removed.first["reason"]
  end

  # Literal and backed, but not applicable to what the technician ruled out:
  # this check keeps it; applicability is the prompt's and the rubric's job.
  test "a correct literal quote with an inference beside it is kept" do
    sw4 = "ON: Máster. La unidad de control de la puerta ejecutará la instrucción directamente."
    text = "En modo Máster, «La unidad de control de la puerta ejecutará la instrucción directamente» [1], lo que explicaría la reapertura."
    result = call(text, sw4)

    assert_equal text, result.text
  end

  test "a quote that drops its source condition is removed with the reason" do
    source = "– En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST."
    dropped = call("Como el problema persiste, la guía indica «desconectar la fotocélula y volver a pulsar el botón de TEST» [1].", source)
    carried = call("En caso de que persista, la guía indica «desconectar la fotocélula y volver a pulsar el botón de TEST» [1].", source)

    assert_equal "unverified_quote", dropped.removed.first["reason"]
    assert_empty carried.removed
  end

  test "a period inside a quote and a decimal do not split sentences" do
    text = "Ver sección 5.8: «verificar el paso libre. Solo es necesario realizar otra vez el autoajuste» [1]."
    result = call(text, VF5_58)

    assert_equal text, result.text
  end

  test "what the technician cannot check is not handed back as a pending action" do
    turn = "No sé cómo identificar si está activada la entrada #21 ni cómo saber si hay un contacto cerrado entre #21 y #23. ¿Qué información necesitas de mí para orientar el caso?"
    text = <<~TEXT.strip
      **Resumen para derivar**

      - **Contaste:** no sabes identificar ni comprobar #21 ni el contacto entre 21 y 23.
      - **Comprobaste:** la fotocélula no está activada.
      - **Falta:**
        - Estado de #21, que no puedes comprobar con lo que tienes.
        - Ajuste de #54, sin revisar.
        - Confirmar si hay un contacto o puente entre 21 y 23 (observación visual).
    TEXT
    result = call(text, VF5_54, technician: [ turn ])

    assert_not_includes result.text, "Confirmar si hay un contacto"
    assert_includes result.text, "Estado de #21, que no puedes comprobar"
    assert_includes result.text, "**Comprobaste:** la fotocélula no está activada."
    assert_includes result.text, "Ajuste de #54, sin revisar."
    assert_equal [ "returns_unverifiable" ], result.removed.pluck("reason")
  end

  test "a component the technician cannot identify is not asked again in any equipment" do
    turn = "No sé identificar la Chapa nivel 3 en el tablero."
    text = "Identifica la Chapa nivel 3 en el tablero antes de seguir. Revisa si PasCom 24V llega al tablero.\n\n¿Puedes ubicar la Chapa nivel 3?"
    result = call(text, ELEMONT, technician: [ turn ])

    assert_equal "Revisa si PasCom 24V llega al tablero.", result.text
    assert_equal %w[returns_unverifiable returns_unverifiable], result.removed.pluck("reason")
  end

  test "an inline summary label does not hide a returned action" do
    turn = "No sé cómo identificar en el equipo cuál es la Chapa nivel 3. ¿Con lo que tenemos puedes decirme qué reemplazar?"
    text = <<~TEXT.strip
      - **Contó:** Sin mediciones. No puede identificar la Chapa nivel 3 en el equipo.
      - **Comprobado:** nada en terreno todavía.
      - **Falta:** ubicar la Chapa nivel 3 en el equipo, medir en terreno y relacionar esa chapa con la falta de respuesta a las llamadas.
    TEXT
    result = call(text, ELEMONT, technician: [ turn ])

    assert_not_includes result.text, "ubicar la Chapa nivel 3"
    assert_includes result.text, "No puede identificar la Chapa nivel 3 en el equipo."
    assert_includes result.text, "**Comprobado:** nada en terreno todavía."
    assert_equal [ "returns_unverifiable" ], result.removed.pluck("reason")
  end

  test "a later no does not keep an uncited documentation summary" do
    kept = call("El manual no da un valor.", VF5_54)
    quote = "Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)"
    text = <<~TEXT.strip
      Lo siguiente es revisar el potenciómetro #54: «#{quote}» [1].

      **Resumen para derivar:**
      - **Respaldado por la documentación (fuente 3, pág. 12):** revisar #54, fotocélula no activada, obstrucción mecánica.
    TEXT
    result = call(text, quote)
    published = Rag::CompanionTurnPublication.call(text: result.text, sources: sources(quote))

    assert_equal "El manual no da un valor.", kept.text
    assert_includes result.text, "«#{quote}» [1]."
    assert_not_includes result.text, "Respaldado por la documentación"
    assert_not_includes result.text, "Resumen para derivar"
    assert_equal [ "uncited_attribution" ], result.removed.pluck("reason")
    assert published.accepted?, published.reasons.inspect
  end

  test "doubt about a value is still a check the technician can make" do
    result = call("Revisa el ajuste de #54.", VF5_54, technician: [ "No sé si #54 está bien ajustado." ])

    assert_equal "Revisa el ajuste de #54.", result.text
    assert_empty result.removed
  end

  test "a KP-VS comparison stays when the quote is in the same sentence" do
    quote = "En caso de ruido audible muy elevado: disminuya el valor del parámetro **\"KP-VS\"**, hasta el mínimo de [3,0]"
    source = "- #{quote}."
    together = "El KP-VS reportado de 2,5 ya está por debajo del mínimo de 3,0: «#{quote}» [1]."
    kept = call(together, source, technician: [ "KP-VS está en 2,5" ])

    assert_equal together, kept.text
    assert_empty kept.removed

    split = "El KP-VS reportado de 2,5 ya está por debajo del mínimo documentado de 3,0. «#{quote}» [1]."
    bound = call(split, source, technician: [ "KP-VS está en 2,5" ])

    assert_equal split, bound.text
    assert_empty bound.removed

    unbound = "El KP-VS reportado de 2,5 ya está por debajo del mínimo documentado de 3,5. «#{quote}» [1]."
    dropped = call(unbound, source, technician: [ "KP-VS está en 2,5" ])

    assert_equal [ "uncited_attribution" ], dropped.removed.pluck("reason")
    assert_includes dropped.text, "«#{quote}» [1]."
    assert_not_includes dropped.text, "documentado"
  end

  # Real Haiku output (haiku55_http kp3/kp4): the model copies the words of the
  # passage and drops the markdown emphasis the chunk keeps around «"KP-VS"».
  KPVS_CHUNK = "19.13 Ajuste del ruido en el motor de tracción — parámetro \"KP-VS\" en \"MENU PID\"\n\n" \
               "- En caso de ruido audible muy elevado: disminuya el valor del parámetro **\"KP-VS\"**, hasta el mínimo de [3,0]."

  test "a quote that drops the markdown emphasis of the chunk still verifies" do
    text = "Según [1], «En caso de ruido audible muy elevado: disminuya el valor del parámetro \"KP-VS\", hasta el mínimo de [3,0]».\n\n" \
           "La fuente no documenta qué hacer con un valor por debajo de 3,0. Lo que reporta no permite concluir la causa del ruido."
    result = call(text, KPVS_CHUNK, technician: [ "En el menú PID, KP-VS está en 2,5." ])

    assert_equal text, result.text
    assert_empty result.removed
  end

  test "a quote after an earlier clause that states the condition still verifies without the emphasis" do
    text = "Según la fuente, si el ruido audible es muy elevado, debe disminuir KP-VS hasta el mínimo de 3,0: " \
           "«disminuya el valor del parámetro \"KP-VS\", hasta el mínimo de [3,0]» [1]."
    result = call(text, KPVS_CHUNK, technician: [ "En el menú PID, KP-VS está en 2,5." ])

    assert_equal text, result.text
    assert_empty result.removed
  end

  # Real Haiku output (kp2, kp7): the numeric limit is quoted on its own and the
  # passage condition is quoted literally in the neighbouring sentence.
  test "a quote keeps its condition when the answer quotes that condition beside it" do
    after = "El ajuste llega hasta el mínimo documentado: «hasta el mínimo de [3,0]» [1]. " \
            "La fuente lo asocia a «En caso de ruido audible muy elevado» [1]."
    before = "La fuente lo asocia a «En caso de ruido audible muy elevado» [1]. " \
             "En ese caso, la fuente indica bajar el parámetro «hasta el mínimo de [3,0]» [1]."

    [ after, before ].each do |text|
      result = call(text, KPVS_CHUNK, technician: [ "En el menú PID, KP-VS está en 2,5." ])

      assert_equal text, result.text
      assert_empty result.removed
    end
  end

  test "a condition quoted beside the limit must be the condition of that passage" do
    text = "El ajuste llega hasta «hasta el mínimo de [3,0]» [1]. Se aplica «Si la tensión es 24 Vcc» [1]."
    result = call(text, KPVS_CHUNK, technician: [ "En el menú PID, KP-VS está en 2,5." ])

    assert_includes result.removed.pluck("sentence"), "El ajuste llega hasta «hasta el mínimo de [3,0]» [1]."
  end

  test "a condition sentence that is itself removed does not carry the limit" do
    text = "El manual dice «En caso de ruido audible muy elevado». El ajuste llega «hasta el mínimo de [3,0]» [1]."
    result = call(text, KPVS_CHUNK, technician: [ "En el menú PID, KP-VS está en 2,5." ])

    assert_equal [ "uncited_attribution", "unverified_quote" ], result.removed.pluck("reason")
    assert_empty result.text
  end

  # Real Haiku output (kp14, kp15): the reading goes in its own sentence, as the
  # prompt asks, and says «documentado». Its two numbers are the technician's
  # value and the limit that a kept sentence quotes with [1].
  KPVS_QUOTED = "Según [1], con «En caso de ruido audible muy elevado» hay que disminuir KP-VS «hasta el mínimo de [3,0]»."
  KPVS_TECHNICIAN = [ "En el menú PID, KP-VS está en 2,5." ].freeze

  test "a comparison of the reported value with a limit quoted in the answer is not an uncited attribution" do
    [ "Tu valor, 2,5, está por debajo de ese mínimo documentado.",
      "Su KP-VS está en 2,5, por debajo de ese mínimo documentado de 3,0." ].each do |reading|
      text = "#{KPVS_QUOTED}\n\n#{reading} Por eso no puedo darte otro valor."
      result = call(text, KPVS_CHUNK, technician: KPVS_TECHNICIAN)

      assert_equal text, result.text, reading
      assert_empty result.removed, reading
    end
  end

  test "a documented-limit sentence stays removed when its numbers are not bound to the answer" do
    {
      "foreign limit" => "Tu valor, 2,5, está por debajo del mínimo documentado de 3,5.",
      "no reported value" => "El valor queda por debajo del mínimo documentado de 3,0.",
      "an order" => "Tu valor, 2,5, está por debajo del mínimo documentado, bájalo a 3,0."
    }.each do |label, reading|
      result = call("#{KPVS_QUOTED}\n\n#{reading}", KPVS_CHUNK, technician: KPVS_TECHNICIAN)

      assert_equal [ "uncited_attribution" ], result.removed.pluck("reason"), label
    end
  end

  test "the same comparison is removed when no sentence of the answer quotes the limit" do
    result = call("Tu valor, 2,5, está por debajo de ese mínimo documentado.", KPVS_CHUNK, technician: KPVS_TECHNICIAN)

    assert_equal [ "uncited_attribution" ], result.removed.pluck("reason")
  end

  test "a quote that leaves out the condition of the passage is still dropped" do
    text = "Con KP-VS en 3,0 ya estás en el mínimo que indica la fuente: " \
           "«disminuya el valor del parámetro \"KP-VS\", hasta el mínimo de [3,0]» [1]."
    result = call(text, KPVS_CHUNK, technician: [ "En el menú PID, KP-VS está en 3,0." ])

    assert_equal [ "unverified_quote" ], result.removed.pluck("reason")
  end
end
