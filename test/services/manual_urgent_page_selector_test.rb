# frozen_string_literal: true

require "test_helper"

class ManualUrgentPageSelectorTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @orig_classify = FileMultimodalRouter.method(:classify)
  end

  teardown do
    FileMultimodalRouter.define_singleton_method(:classify, @orig_classify)
  end

  test "selects pages matching the technician query without manual page input" do
    stub_pages(
      [ 1, "Indice general y copyright", BatchChunkingPrompt::MODEL_TEXT ],
      [ 2, "Procedimiento de rescate de emergencia con freno y puerta", BatchChunkingPrompt::MODEL_TEXT ],
      [ 3, "Ajuste de encoder y parametrizacion del controlador", BatchChunkingPrompt::MODEL_TEXT ]
    )

    pages = ManualUrgentPageSelector.new.select(
      binary: "%PDF",
      filename: "manual.pdf",
      query: "rescate emergencia freno",
      max_pages: 1
    )

    assert_equal [ 2 ], pages.map(&:number)
    assert_match "query_match", pages.first.reason
  end

  test "falls back to first technical pages when query has no direct lexical match" do
    stub_pages(
      [ 1, "Indice general", BatchChunkingPrompt::MODEL_TEXT ],
      [ 2, "Wiring diagram controller safety circuit", BatchChunkingPrompt::MODEL_TEXT ],
      [ 3, "Maintenance procedure for door lock", BatchChunkingPrompt::MODEL_TEXT ]
    )

    pages = ManualUrgentPageSelector.new.select(
      binary: "%PDF",
      filename: "manual.pdf",
      query: "codigo desconocido",
      max_pages: 2
    )

    assert_equal [ 2, 3 ], pages.map(&:number)
    assert pages.all? { |page| page.reason == "technical_fallback" }
  end

  test "blank query selects no pages" do
    stub_pages([ 1, "Safety procedure", BatchChunkingPrompt::MODEL_TEXT ])

    pages = ManualUrgentPageSelector.new.select(
      binary: "%PDF",
      filename: "manual.pdf",
      query: " ",
      max_pages: 3
    )

    assert_empty pages
  end

  private

  def stub_pages(*raw_pages)
    pages = raw_pages.map do |number, text, model|
      FileMultimodalRouter::PageInfo.new(
        number: number,
        binary: text,
        model: model
      )
    end

    result = FileMultimodalRouter::Result.new(
      model: BatchChunkingPrompt::MODEL_TEXT,
      mode: :pdf_mixed,
      pages: pages
    )

    FileMultimodalRouter.define_singleton_method(:classify) { |**| result }
  end
end
