# frozen_string_literal: true

require "application_system_test_case"

# F7 reads server bands. The presenter does not classify, and a missing
# contract keeps the answer renderer that already shipped.
class RagProvenancePresentationTest < ApplicationSystemTestCase
  include Warden::Test::Helpers

  setup do
    login_as users(:one), scope: :user
    visit root_path
  end

  teardown do
    Warden.test_reset!
  end

  test "presenter renders server bands in order and falls back without classifying" do
    source = Rails.root.join("app/javascript/rag/answer_presenter.js").read
    module_url = "data:text/javascript;base64,#{Base64.strict_encode64(source)}"
    result = page.driver.browser.execute_async_script(<<~JAVASCRIPT, module_url)
      const [moduleUrl, done] = arguments
      import(moduleUrl).then(({ formatAnswerForWeb }) => {
        const host = (html) => {
          const el = document.createElement("div")
          el.innerHTML = html
          return el
        }
        const labels = (html) => [...host(html).querySelectorAll(".answer-provenance-label")].map((node) => node.textContent)
        const bands = (html) => [...host(html).querySelectorAll(".answer-provenance")].map((node) => node.getAttribute("data-provenance-band"))
        const bodies = (html) => [...host(html).querySelectorAll(".answer-provenance-text")].map((node) => node.textContent)
        const citations = [{ number: 1, title: "Manual — p. 46", tooltip_excerpt: "cota" }]
        const plain = formatAnswerForWeb("Hola **mundo** [24].", citations)
        const mixed = [
          { band: "MANUAL_FACT", text: "Según el manual: el ajuste se realiza en ambos lados." },
          { band: "VISUAL_OBSERVATION", text: "En la foto: se observan resortes en el conjunto." },
          { band: "DANEBO_GUIDANCE", text: "Para revisar: verificá primero que ambos lados tengan una carga similar." }
        ]

        done({
          mixedHtml: formatAnswerForWeb("ANSWER_SHOULD_NOT_WIN", [], mixed),
          groupedHtml: formatAnswerForWeb("x", [], [
            { band: "MANUAL_FACT", text: "A." },
            { band: "MANUAL_FACT", text: "B." },
            { band: "DANEBO_GUIDANCE", text: "C." }
          ]),
          splitHtml: formatAnswerForWeb("x", [], [
            { band: "MANUAL_FACT", text: "Primero." },
            { band: "VISUAL_OBSERVATION", text: "Medio." },
            { band: "MANUAL_FACT", text: "Último." }
          ]),
          manyHtml: formatAnswerForWeb("x", [], [
            { band: "MANUAL_FACT", text: "M1." },
            { band: "MANUAL_FACT", text: "M2." },
            { band: "MANUAL_FACT", text: "M3." },
            { band: "VISUAL_OBSERVATION", text: "V1." },
            { band: "VISUAL_OBSERVATION", text: "V2." },
            { band: "DANEBO_GUIDANCE", text: "G1." },
            { band: "DANEBO_GUIDANCE", text: "G2." }
          ]),
          absent: formatAnswerForWeb("Hola **mundo** [24].", citations, undefined),
          nulled: formatAnswerForWeb("Hola **mundo** [24].", citations, null),
          empty: formatAnswerForWeb("Hola **mundo** [24].", citations, []),
          badItem: formatAnswerForWeb("Hola **mundo** [24].", citations, [{ band: "MANUAL_FACT" }]),
          badShape: formatAnswerForWeb("Hola **mundo** [24].", citations, { band: "MANUAL_FACT", text: "no" }),
          blankTexts: formatAnswerForWeb("Hola **mundo** [24].", citations, [{ band: "MANUAL_FACT", text: "   " }]),
          nullItem: formatAnswerForWeb("Hola **mundo** [24].", citations, [{ band: "MANUAL_FACT", text: "A." }, null]),
          plain,
          unknownHtml: formatAnswerForWeb("ignored", [], [
            { band: "USER_FACT", text: "El técnico dijo que la puerta no cierra." }
          ]),
          unknownPlain: formatAnswerForWeb("El técnico dijo que la puerta no cierra.", []),
          looseHtml: formatAnswerForWeb("ignored", [], [
            { band: "MANUAL_FACT", text: "Dato documental." },
            { band: "USER_FACT", text: "Frase sin banda conocida." },
            { band: "DANEBO_GUIDANCE", text: "Orientación propia." }
          ]),
          xss: formatAnswerForWeb("ignored", [], [
            { band: "MANUAL_FACT", text: '<img src=x onerror="alert(1)">' }
          ]),
          cited: formatAnswerForWeb("ignored", citations, [
            { band: "MANUAL_FACT", text: "El ajuste queda en [1]." }
          ]),
          unresolved: formatAnswerForWeb("ignored", [], [
            { band: "DANEBO_GUIDANCE", text: "El terminal es [24]." }
          ]),
          noMarker: formatAnswerForWeb("ignored", citations, [
            { band: "MANUAL_FACT", text: "El ajuste se realiza en ambos lados." }
          ]),
          mismatched: formatAnswerForWeb("ignored", [], [
            { band: "DANEBO_GUIDANCE", text: "Según el manual: revisá el freno." }
          ]),
          ellipsis: formatAnswerForWeb("ignored", [], [
            { band: "MANUAL_FACT", text: "Según el manual … el ajuste sigue." }
          ]),
          prefixOnly: formatAnswerForWeb("ignored", [], [
            { band: "MANUAL_FACT", text: "Según el manual:" }
          ]),
          singleHtml: formatAnswerForWeb("ignored", [], [
            { band: "VISUAL_OBSERVATION", text: "Se observan resortes." }
          ]),
          markdown: formatAnswerForWeb("ignored", [], [
            { band: "MANUAL_FACT", text: "El **ajuste** se realiza." }
          ])
        })
      }).catch((error) => done({ error: error.message }))
    JAVASCRIPT

    assert_not result["error"], "module import failed: #{result['error']}"

    assert_equal [ "Manual", "Foto", "Guía Danebo" ], labels_in(result["mixedHtml"])
    assert_equal %w[MANUAL_FACT VISUAL_OBSERVATION DANEBO_GUIDANCE], bands_in(result["mixedHtml"])
    bodies = bodies_in(result["mixedHtml"])
    assert_equal "el ajuste se realiza en ambos lados.", bodies[0]
    assert_equal "se observan resortes en el conjunto.", bodies[1]
    assert_equal "verificá primero que ambos lados tengan una carga similar.", bodies[2]
    assert_not_includes result["mixedHtml"], "ANSWER_SHOULD_NOT_WIN"
    assert_not_includes result["mixedHtml"], "Según el manual:"
    assert_not_includes result["mixedHtml"], "En la foto:"
    assert_not_includes result["mixedHtml"], "Para revisar:"
    assert_not_includes result["mixedHtml"], "<table"

    assert_equal [ "Manual", "Guía Danebo" ], labels_in(result["groupedHtml"])
    assert_equal [ "A. B.", "C." ], bodies_in(result["groupedHtml"])

    assert_equal [ "Manual", "Foto", "Manual" ], labels_in(result["splitHtml"])
    assert_equal [ "Primero.", "Medio.", "Último." ], bodies_in(result["splitHtml"])

    assert_equal [ "Manual", "Foto", "Guía Danebo" ], labels_in(result["manyHtml"])
    assert_equal [ "M1. M2. M3.", "V1. V2.", "G1. G2." ], bodies_in(result["manyHtml"])

    [ "absent", "nulled", "empty", "badItem", "badShape", "blankTexts", "nullItem" ].each do |key|
      assert_equal result["plain"], result[key], key
    end
    assert_includes result["plain"], "<strong>mundo</strong>"
    assert_includes result["plain"], "[24]"
    assert_not_includes result["plain"], "answer-provenance"
    assert_not_includes result["plain"], "citation"

    assert_equal result["unknownPlain"], result["unknownHtml"]
    assert_includes result["unknownHtml"], "El técnico dijo que la puerta no cierra."
    assert_not_includes result["unknownHtml"], "answer-provenance"
    assert_not_includes result["unknownHtml"], "Manual"
    assert_not_includes result["unknownHtml"], "Foto"
    assert_not_includes result["unknownHtml"], "Guía Danebo"

    assert_equal [ "Manual", "Guía Danebo" ], labels_in(result["looseHtml"])
    assert_equal [ "Dato documental.", "Orientación propia." ], bodies_in(result["looseHtml"])
    assert_includes result["looseHtml"], "Frase sin banda conocida."
    assert_not_includes bodies_in(result["looseHtml"]).join(" "), "Frase sin banda conocida."

    assert_includes result["xss"], "&lt;img"
    assert_not_includes result["xss"], "<img"
    assert_not_includes result["xss"], "<script"

    assert_includes result["cited"], 'class="citation"'
    assert_includes result["cited"], 'data-citation-number="1"'
    assert_not_includes result["cited"], "chat-sources"
    assert_includes result["unresolved"], "[24]"
    assert_not_includes result["unresolved"], "citation"
    assert_not_includes result["noMarker"], "[1]"
    assert_not_includes result["noMarker"], "citation"

    assert_equal [ "Guía Danebo" ], labels_in(result["mismatched"])
    assert_equal [ "Según el manual: revisá el freno." ], bodies_in(result["mismatched"])
    assert_equal [ "Según el manual … el ajuste sigue." ], bodies_in(result["ellipsis"])
    assert_equal [ "Según el manual:" ], bodies_in(result["prefixOnly"])
    assert_equal [ "Foto" ], labels_in(result["singleHtml"])
    assert_equal 1, result["singleHtml"].scan("answer-provenance-label").size
    assert_includes result["markdown"], "<strong>ajuste</strong>"
    assert labels_in(result["mixedHtml"]).none? { |label| label == "Recomendación oficial" }
  end

  test "assistant answers keep sources, suggestions, and the verification notice" do
    page.current_window.resize_to(390, 844)
    segments = [
      { "band" => "MANUAL_FACT", "text" => "Según el manual: el ajuste se realiza en ambos lados." },
      { "band" => "VISUAL_OBSERVATION", "text" => "En la foto: se observan resortes en el conjunto." },
      { "band" => "DANEBO_GUIDANCE", "text" => "Para revisar: verificá primero la carga." }
    ]
    suggestion = {
      "tie_at_top" => false,
      "cards" => [
        {
          "document_uid" => "uid-otis",
          "kb_document_id" => 41,
          "display_name" => "Manual Otis",
          "label" => "BRAND_ONLY",
          "text" => "manual de la misma marca; compatibilidad con este equipo no confirmada",
          "knowledge_scope" => "tenant_private",
          "provenance" => "Tu biblioteca",
          "focused" => false
        }
      ]
    }
    citations = [ { "number" => 1, "title" => "Manual — p. 46", "filename" => "manual.pdf" } ]

    hidden = render_assistant_answer(
      { answer: "Texto histórico sin bandas.", citations: citations, response_locale: "es" },
      show_sources: false
    )
    assert_includes hidden, "Texto histórico sin bandas."
    assert_not_includes hidden, "answer-provenance"
    assert_not_includes hidden, "chat-sources"
    assert_includes hidden, "answer-verification-notice"

    shown = render_assistant_answer(
      {
        answer: "Texto histórico sin bandas [1].",
        citations: citations,
        response_locale: "es",
        manual_suggestion: suggestion
      },
      show_sources: true
    )
    assert_includes shown, "chat-sources"
    assert_includes shown, "Fuentes (1)"
    assert_includes shown, "manual-suggestion"
    assert_includes shown, "Usar este manual"
    assert_includes shown, "Tu biblioteca"
    assert_not_includes shown, "answer-provenance"

    banded = render_assistant_answer(
      {
        answer: "ANSWER_SHOULD_NOT_WIN",
        citations: citations,
        provenance_segments: segments,
        response_locale: "en",
        manual_suggestion: suggestion
      },
      show_sources: true
    )
    assert_includes banded, "Manual"
    assert_includes banded, "Foto"
    assert_includes banded, "Guía Danebo"
    assert_includes banded, "el ajuste se realiza en ambos lados."
    assert_not_includes banded, "ANSWER_SHOULD_NOT_WIN"
    assert_includes banded, "chat-sources"
    assert_includes banded, "Sources (1)"
    assert_includes banded, "manual-suggestion"
    assert_includes banded, "manual de la misma marca; compatibilidad con este equipo no confirmada"
    assert_includes banded, "verify any action on safety devices"
    assert_not_includes banded, "Recomendación oficial"
    assert_not_includes banded, "<table"

    within(all(".chat-row-assistant", visible: :all).last) do
      assert_selector ".answer-provenance-label", text: "Manual", visible: :all
      assert_selector ".answer-provenance-label", text: "Foto", visible: :all
      assert_selector ".answer-provenance-label", text: "Guía Danebo", visible: :all
      assert_selector ".chat-sources", visible: :all
      assert_no_selector ".answer-provenance .chat-sources", visible: :all
      assert_no_selector ".answer-provenance .manual-suggestion", visible: :all
      assert_no_selector ".answer-provenance .answer-verification-notice", visible: :all
      assert_selector ".answer-verification-notice", visible: :all
    end

    hidden_bands = render_assistant_answer(
      { answer: "ANSWER_SHOULD_NOT_WIN", citations: citations, provenance_segments: segments, response_locale: "es" },
      show_sources: false
    )
    assert_includes hidden_bands, "Guía Danebo"
    assert_not_includes hidden_bands, "chat-sources"
    assert_includes hidden_bands, "verifica cualquier acción sobre seguridades"
  end

  test "photo answers use provenance and analysis events do not" do
    page.current_window.resize_to(390, 844)
    segments = [
      { "band" => "MANUAL_FACT", "text" => "Según el manual: el ajuste se realiza en ambos lados." },
      { "band" => "VISUAL_OBSERVATION", "text" => "En la foto: se observan resortes en el conjunto." },
      { "band" => "DANEBO_GUIDANCE", "text" => "Para revisar: verificá primero la carga." }
    ]

    invoke("addPhotoQuestionAnswer", {
      status: "photo_question_answered",
      answer: "Por la foto, esto parece el conjunto.",
      citations: [],
      field_photo_id: 42,
      response_locale: "es"
    })
    within(all(".chat-row-assistant", visible: :all).last) do
      assert_text "Por la foto, esto parece el conjunto."
      assert_no_selector ".answer-provenance", visible: :all
      assert_button "Preguntar sobre esta foto"
      assert_selector ".answer-verification-notice", visible: :all
    end

    evaluate_script(<<~JAVASCRIPT)
      (function () {
        const element = document.querySelector('[data-controller~="rag-chat"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "rag-chat")
        controller.showSourcesValue = true
      })()
    JAVASCRIPT
    invoke("addPhotoQuestionAnswer", {
      status: "photo_question_answered",
      answer: "ANSWER_SHOULD_NOT_WIN",
      citations: [ { "number" => 1, "title" => "Manual — p. 46" } ],
      provenance_segments: segments,
      visual_summary: "Se ve una placa con un indicador rojo.",
      field_photo_id: 42,
      response_locale: "es"
    })
    within(all(".chat-row-assistant", visible: :all).last) do
      assert_selector "[data-photo-visual-summary]", text: "Se ve una placa con un indicador rojo.", visible: :all
      assert_no_selector "[data-photo-visual-summary] .answer-provenance", visible: :all
      assert_selector ".answer-provenance-label", text: "Manual", visible: :all
      assert_selector ".answer-provenance-label", text: "Foto", visible: :all
      assert_selector ".answer-provenance-label", text: "Guía Danebo", visible: :all
      assert_selector ".chat-sources", visible: :all
      assert_no_selector ".answer-provenance .chat-sources", visible: :all
      assert_no_text "ANSWER_SHOULD_NOT_WIN"
      assert_button "Preguntar sobre esta foto"
    end

    invoke("addImageSummaryMessage", {
      status: "photo_analyzed",
      canonical_name: "UNKNOWN",
      summary: "Veo un amarre de cables con resortes.",
      provenance_segments: [ { "band" => "VISUAL_OBSERVATION", "text" => "Veo un amarre de cables con resortes." } ],
      field_photo_id: 42,
      response_locale: "es"
    })
    within(all(".chat-row-assistant", visible: :all).last) do
      assert_text "Veo un amarre de cables con resortes."
      assert_no_selector ".answer-provenance", visible: :all
      assert_no_text "Foto"
      assert_button "Preguntar sobre esta foto"
    end

    ack = evaluate_script(<<~JAVASCRIPT)
      (function () {
        const element = document.querySelector('[data-controller~="rag-chat"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "rag-chat")
        controller.pendingUploadType = "image"
        controller.indexingLoadingId = controller.addLoadingMessage()
        controller.setIndexingLoadingAcknowledgment("Recibí tu foto y estoy analizando lo que se ve directamente.")
        return document.getElementById(controller.indexingLoadingId).querySelector(".chat-message").innerHTML
      })()
    JAVASCRIPT
    assert_includes ack, "Recibí tu foto y estoy analizando lo que se ve directamente."
    assert_not_includes ack, "answer-provenance"
    assert_not_includes ack, "Guía Danebo"
  end

  private

  def labels_in(html)
    fragment(html).css(".answer-provenance-label").map { |node| node.text.strip }
  end

  def bands_in(html)
    fragment(html).css(".answer-provenance").pluck("data-provenance-band")
  end

  def bodies_in(html)
    fragment(html).css(".answer-provenance-text").map { |node| node.text.strip }
  end

  def fragment(html)
    Nokogiri::HTML.fragment(html)
  end

  def render_assistant_answer(payload, show_sources: nil)
    evaluate_script(<<~JAVASCRIPT, payload.to_json, show_sources)
      (function (payloadJson, showSources) {
        const element = document.querySelector('[data-controller~="rag-chat"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "rag-chat")
        if (showSources !== null && showSources !== undefined) controller.showSourcesValue = showSources
        controller.renderAssistantAnswer(JSON.parse(payloadJson))
        const rows = element.querySelectorAll(".chat-row-assistant")
        return rows[rows.length - 1].querySelector(".chat-message").innerHTML
      })(arguments[0], arguments[1])
    JAVASCRIPT
  end

  def invoke(method, payload)
    result = evaluate_script(<<~JAVASCRIPT, method, payload.to_json)
      (function (methodName, payloadJson) {
        const element = document.querySelector('[data-controller~="rag-chat"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "rag-chat")
        controller[methodName](JSON.parse(payloadJson))
        return true
      })(arguments[0], arguments[1])
    JAVASCRIPT
    assert_equal true, result
  end
end
