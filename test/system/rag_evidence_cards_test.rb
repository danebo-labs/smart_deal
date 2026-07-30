# frozen_string_literal: true

require "application_system_test_case"

class RagEvidenceCardsTest < ApplicationSystemTestCase
  include Warden::Test::Helpers

  setup do
    login_as users(:one), scope: :user
    visit root_path
  end

  teardown do
    Warden.test_reset!
  end

  test "ambiguous cards are responsive, accessible, and reveal candidates without dropping payload" do
    inject_resolution(mode: "ambiguous", cards: evidence_cards(5))

    [ 320, 375, 430 ].each do |width|
      page.driver.browser.execute_cdp(
        "Emulation.setDeviceMetricsOverride",
        width: width,
        height: 800,
        deviceScaleFactor: 1,
        mobile: true
      )

      assert_selector ".rag-evidence-resolution[aria-label='Contextos documentados']"
      assert_selector ".rag-evidence-card", count: 3, visible: :visible
      assert_selector ".rag-evidence-card", count: 5, visible: :all
      assert_equal width, evaluate_script("window.innerWidth")
      assert_operator evaluate_script("document.querySelector('.rag-evidence-card').getBoundingClientRect().right"), :<=, width
      assert_operator evaluate_script("document.querySelector('.rag-evidence-primary-action').getBoundingClientRect().height"), :>=, 44
    end

    assert_selector "nav[aria-label='Contexto de la evidencia']"
    assert_selector "button.rag-evidence-primary-action", text: "Usar esta placa", count: 3, visible: :visible
    assert_selector "a.rag-evidence-secondary-action[rel~='noopener']", text: "Ver en el documento"
    assert_operator primary_action_contrast_ratio, :>=, 4.5

    find(".rag-evidence-more summary").click
    assert_selector ".rag-evidence-card", count: 5, visible: :visible
    assert_selector "button.rag-evidence-primary-action", count: 5, visible: :visible

    first(".rag-evidence-primary-action").send_keys(:tab)
    assert evaluate_script("document.activeElement.matches('.rag-evidence-secondary-action, .rag-evidence-primary-action')")
  end

  test "direct, insufficient, and not applicable modes use their contract branches" do
    inject_resolution(mode: "direct", cards: evidence_cards(1), target_id: "direct-resolution")
    inject_resolution(
      mode: "insufficient",
      cards: [],
      target_id: "insufficient-resolution",
      insufficient_reason: "relation_not_documented",
      abstained_relations: [ "state" ]
    )
    inject_resolution(mode: "not_applicable", cards: [], target_id: "na-resolution")

    assert_selector "#direct-resolution details.rag-direct-evidence"
    assert_selector "#direct-resolution .rag-evidence-card", visible: :hidden
    assert_selector "#insufficient-resolution [role='status']", text: /relación pedida/
    assert_no_selector "#na-resolution .rag-evidence-resolution, #na-resolution .rag-resolution-status"
  end

  private

  def evidence_cards(count)
    Array.new(count) do |index|
      {
        id: "c#{index + 1}",
        label: "Placa #{index + 1}",
        breadcrumb: [ "Placa #{index + 1}", "Sección #{index + 1}", "Manual" ],
        excerpt: "LED X#{index + 1} | SERIE DE SEGURIDAD",
        select_query: "Usar placa #{index + 1}",
        page: index + 1,
        evidence_url: "https://example.test/manual.pdf#page=#{index + 1}"
      }
    end
  end

  def inject_resolution(mode:, cards:, target_id: "evidence-test-target", insufficient_reason: nil,
                        abstained_relations: [])
    resolution = {
      contract_version: "resolution_v1",
      mode: mode,
      needs_selection: mode == "ambiguous",
      answered_relations: [],
      abstained_relations: abstained_relations,
      insufficient_reason: insufficient_reason,
      facts: [],
      evidence_cards: cards
    }
    copy = {
      ambiguous: "Encontré varios contextos documentados.",
      insufficient: "La evidencia no permite resolver la consulta.",
      evidence_label: "Ver evidencia",
      cards_label: "Contextos documentados",
      breadcrumb_label: "Contexto de la evidencia",
      use_board: "Usar esta placa",
      view_document: "Ver en el documento",
      page: "p.",
      show_more_contexts: "Ver %{count} contextos más",
      insufficient_reason: {
        relation_not_documented: "El manual no documenta la relación pedida."
      },
      abstained_relations: {
        state: "El manual no especifica el estado consultado."
      }
    }

    source = Rails.root.join("app/javascript/rag/evidence_cards_renderer.js").read
    module_url = "data:text/javascript;base64,#{Base64.strict_encode64(source)}"
    rendered = page.driver.browser.execute_async_script(
      <<~JAVASCRIPT,
        const [moduleUrl, targetId, resolutionJson, copyJson, done] = arguments
        const target = document.createElement("div")
        target.id = targetId
        document.querySelector("[data-rag-chat-target='messages']").appendChild(target)

        import(moduleUrl).then(({ renderEvidenceResolution }) => {
          target.innerHTML = renderEvidenceResolution(JSON.parse(resolutionJson), JSON.parse(copyJson))
          target.dataset.rendered = "true"
          done(true)
        }).catch((error) => done(error.message))
      JAVASCRIPT
      module_url,
      target_id,
      resolution.to_json,
      copy.to_json
    )
    assert_equal true, rendered
    assert_selector "##{target_id}[data-rendered='true']", visible: :all
  end

  def primary_action_contrast_ratio
    evaluate_script <<~JAVASCRIPT
      (() => {
        const style = getComputedStyle(document.querySelector(".rag-evidence-primary-action"))
        const rgb = (value) => value.match(/\\d+/g).slice(0, 3).map(Number)
        const luminance = (value) => {
          const channels = rgb(value).map((channel) => {
            const normalized = channel / 255
            return normalized <= 0.03928 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4
          })
          return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        const foreground = luminance(style.color)
        const background = luminance(style.backgroundColor)
        return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05)
      })()
    JAVASCRIPT
  end
end
