# frozen_string_literal: true

require "test_helper"
require "open3"

class SectionPageContinuityTest < ActiveSupport::TestCase
  PARENT_PAGE = <<~TEXT
    2.1 Marcha
    • La unidad se detiene.
    – Revisar el tope.
    – Revisar el sensor.

    Pág. 4 / 9
  TEXT

  NEXT_PAGE = <<~TEXT
    – Si el aviso sigue, separar el sensor y pulsar la prueba. Si el recorrido queda corto, el manual indica un bloqueo.
    • La unidad no arranca.
    – Revisar la alimentacion.

    Pág. 5 / 9
  TEXT

  HEADED_PAGE = <<~TEXT
    3.1 Otro tema
    • La unidad no arranca.
    – Revisar la alimentacion.

    Pág. 6 / 9
  TEXT

  CONTINUATION = "– Si el aviso sigue, separar el sensor y pulsar la prueba. Si el recorrido queda corto, el manual indica un bloqueo."
  CONTINUATION_RECORD = {
    "k" => "TROUBLESHOOTING_STEP",
    "h" => "(continuación de página anterior)",
    "a" => "Si el aviso sigue, separar el sensor y pulsar la prueba",
    "r" => "Si el recorrido queda corto, el manual indica un bloqueo.",
    "ev" => "separar el sensor y pulsar la prueba"
  }.freeze

  test "joins a mid item opening and does not copy the next aliases" do
    repaired = SectionPageContinuity.repair_prompt(
      sample_prompt,
      pages: { 2 => PARENT_PAGE, 3 => NEXT_PAGE },
      extra_records: [ CONTINUATION_RECORD ]
    )

    assert_nil repaired["blocked"]
    prompt = repaired["prompt"]
    parent, child, other = contents(prompt)

    assert_includes parent, "2.1 Marcha"
    assert_includes parent, "• La unidad se detiene."
    assert_includes parent, "– Revisar el tope."
    assert_includes parent, "– Revisar el sensor."
    assert_includes parent, CONTINUATION
    assert_includes parent, "[PDF_PAGE: 2]"
    assert_includes parent, "[PRINTED_PAGE: 4/9]"
    assert_includes parent, "[PDF_PAGE: 3]"
    assert_includes parent, "[PRINTED_PAGE: 5/9]"
    assert_includes parent, "[SEARCH_ALIASES: tope, sensor]"
    assert_not_includes parent, "alimentacion"
    assert_not_includes parent, "La unidad no arranca"

    assert_not_includes child, "Si el aviso sigue"
    assert_includes child, "• La unidad no arranca."
    assert_includes child, "[SEARCH_ALIASES: arranque, alimentacion]"
    assert_includes child, "RECORD_ID: FR-KEEP"

    assert_includes parent, "SOURCE_SECTION_OR_PAGE: 2.1 Marcha — La unidad se detiene."
    assert_includes parent, "ACTION: Si el aviso sigue, separar el sensor y pulsar la prueba"
    assert_includes parent, "EXPECTED_RESULT: Si el recorrido queda corto, el manual indica un bloqueo."
    assert_includes parent, "RECORD_TYPE: TROUBLESHOOTING_STEP"
    assert_equal 1, prompt.scan(CONTINUATION).size
    assert_includes prompt, other
    assert_equal contents(sample_prompt).last, other
  end

  test "joins when the page text arrives as binary" do
    pages = {
      2 => PARENT_PAGE.dup.force_encoding(Encoding::ASCII_8BIT),
      3 => NEXT_PAGE.dup.force_encoding(Encoding::ASCII_8BIT)
    }
    repaired = SectionPageContinuity.repair_prompt(
      sample_prompt.dup.force_encoding(Encoding::ASCII_8BIT),
      pages: pages,
      extra_records: [ CONTINUATION_RECORD ]
    )

    assert_nil repaired["blocked"]
    assert_includes repaired["prompt"], "2.1 Marcha — La unidad se detiene."
    assert_includes repaired["prompt"], "[PRINTED_PAGE: 5/9]"
  end

  test "does not invent a record when the parse did not emit one" do
    repaired = SectionPageContinuity.repair_prompt(
      sample_prompt,
      pages: { 2 => PARENT_PAGE, 3 => NEXT_PAGE },
      extra_records: []
    )

    parent, = contents(repaired["prompt"])
    assert_includes parent, CONTINUATION
    assert_not_includes parent, "EVIDENCE: separar el sensor y pulsar la prueba"
    assert_not_includes parent, "ACTION: Si el aviso sigue, separar el sensor y pulsar la prueba"
  end

  test "rejects a continuation record that dropped the condition" do
    lossy = CONTINUATION_RECORD.merge("a" => "Separar el sensor y pulsar la prueba")
    repaired = SectionPageContinuity.repair_prompt(
      sample_prompt,
      pages: { 2 => PARENT_PAGE, 3 => NEXT_PAGE },
      extra_records: [ lossy ]
    )

    parent, = contents(repaired["prompt"])
    assert_includes parent, CONTINUATION
    assert_not_includes parent, "ACTION: Separar el sensor y pulsar la prueba"
    assert_includes repaired["joined"]["rejected_records"], "unfaithful or untyped record"
  end

  test "a page that opens on its own heading stays apart" do
    prompt = sample_prompt.sub(NEXT_PAGE_CHUNK, headed_chunk)
    repaired = SectionPageContinuity.repair_prompt(
      prompt,
      pages: { 2 => PARENT_PAGE, 3 => HEADED_PAGE },
      extra_records: [ CONTINUATION_RECORD ]
    )

    assert_equal prompt, repaired["prompt"]
    assert repaired["blocked"].present?
  end

  test "non consecutive pages are not stitched" do
    prompt = sample_prompt.gsub("[PDF_STUB]", "x")
    pages = { 2 => PARENT_PAGE, 4 => NEXT_PAGE }
    # The second result is aligned to page 4 by its text, and 2 then 4 is a gap.
    repaired = SectionPageContinuity.repair_prompt(prompt, pages: pages, extra_records: [ CONTINUATION_RECORD ])

    assert_equal prompt, repaired["prompt"]
  end

  test "the merger keeps an ordinary pair and stitches only a real opening" do
    ordinary = ChunkMergerService.merge(ordinary_pages)
    parsed = JSON.parse(ordinary)
    assert_equal "Content page 2.", parsed["chunks"][0]["text"]
    assert_equal [ "alpha" ], parsed["chunks"][0]["aliases"]
    assert_equal [ "beta" ], parsed["chunks"][1]["aliases"]
    assert_nil parsed["chunks"][0]["field_records"]

    stitched = JSON.parse(ChunkMergerService.merge_with_report(opening_pages, page_texts: {
      2 => PARENT_PAGE,
      3 => NEXT_PAGE
    })[:json])
    parent = stitched["chunks"][0]
    child = stitched["chunks"][1]

    assert_includes parent["text"], "2.1 Marcha"
    assert_includes parent["text"], CONTINUATION
    assert_not_includes child["text"], "Si el aviso sigue"
    assert_equal [ "tope" ], parent["aliases"]
    assert_equal [ "arranque" ], child["aliases"]
    assert_equal "2.1 Marcha — La unidad se detiene.", parent["field_records"].last["h"]
    assert_equal CONTINUATION_RECORD["a"], parent["field_records"].last["a"]
    assert_equal CONTINUATION_RECORD["r"], parent["field_records"].last["r"]
    record = parent["field_records"].last
    assert_not record.key?("_page")
    assert_equal 3, record["source_pdf_page"]
    assert_equal 2, parent["page"]

    parser = BatchResultsParserService.new(s3_service: Object.new)
    asset = Struct.new(:filename).new("unit.pdf")
    assert_nothing_raised do
      parser.send(:validate_field_record!, record, asset: asset, chunk_index: 0, record_index: 0)
    end
    rendered = parser.send(:render_field_record, record, page: parent["page"])
    assert_includes rendered, "SOURCE_PDF_PAGE: 3"
    assert_not_includes rendered, "SOURCE_PDF_PAGE: 2"
  end

  test "a repeated header is running matter and does not hide an opening" do
    header = "ACME FIELD BULLETIN"
    pages = {
      2 => "#{header}\n#{PARENT_PAGE}",
      3 => "#{header}\n#{NEXT_PAGE}",
      4 => "#{header}\n3.1 Otro tema\n• La unidad espera.\n"
    }
    repaired = SectionPageContinuity.repair_prompt(
      sample_prompt, pages: pages, extra_records: [ CONTINUATION_RECORD ]
    )

    assert_nil repaired["blocked"], repaired["notes"].inspect
    parent, = contents(repaired["prompt"])
    assert_includes parent, CONTINUATION
    assert_not_includes parent, header
  end

  test "a page without a printed folio does not invent one" do
    parent_text = PARENT_PAGE.lines.reject { |line| line.match?(/Pág\./) }.join
    child_text = NEXT_PAGE.lines.reject { |line| line.match?(/Pág\./) }.join
    repaired = SectionPageContinuity.repair_prompt(
      sample_prompt, pages: { 2 => parent_text, 3 => child_text }, extra_records: []
    )

    assert_nil repaired["blocked"], repaired["notes"].inspect
    assert_includes repaired["prompt"], "[PDF_PAGE: 2]"
    assert_includes repaired["prompt"], "[PDF_PAGE: 3]"
    assert_not_includes repaired["prompt"], "PRINTED_PAGE"
  end

  test "the merger leaves a hyphen prefix unchanged when page texts are absent" do
    parent_text = "• La unidad se detiene.\n– Revisar el tope.\n– Revisar el sensor."
    child_text = "#{CONTINUATION}\n• La unidad no arranca.\n– Revisar la alimentacion."

    [ nil, {} ].each do |page_texts|
      parsed = JSON.parse(ChunkMergerService.merge_with_report(opening_pages, page_texts: page_texts)[:json])
      parent = parsed["chunks"][0]
      child = parsed["chunks"][1]

      assert_equal parent_text, parent["text"]
      assert_equal child_text, child["text"]
      assert_equal [], parent["field_records"]
      assert_equal CONTINUATION_RECORD, child["field_records"].first
      assert_equal [ "tope" ], parent["aliases"]
      assert_equal [ "arranque" ], child["aliases"]
      assert_equal 2, parent["page"]
      assert_equal 3, child["page"]
    end
  end

  test "the continuity class does not name this manual" do
    source = Rails.root.join("app/services/section_page_continuity.rb").read.downcase

    assert_not_includes source, "fermator"
    assert_not_includes source, "vf5"
    assert_not_includes source, "re-abre"
    assert_not_includes source, "fotocelula"
    assert_not_includes source, "fotocélula"
  end

  test "the captured door item keeps its section, pages, and conditional record" do
    pdf = Rails.root.join("docs/field_companion/fuentes/VF5.pdf")
    control = Rails.root.join("tmp/field_companion/vf5_fidelity_replay/vf5-fidelity-D-historico-20261020T202806Z/t1/attempt-1/bodies/b0001.txt")
    raw = Rails.root.join("tmp/field_companion/local_ingestion/raw-p13.txt")
    skip "local VF5 evidence is absent" unless pdf.file? && control.file? && raw.file?

    extracted = [ 11, 12, 13 ].index_with { |number| pdf_page(pdf, number) }
    running = Rag::PageChunkFidelity.running_matter_lines(extracted)
    pages = extracted.slice(12, 13)
    pages[1] = running.join("\n") if running.any?
    records = JSON.parse(raw.read).fetch("chunks").flat_map { |chunk| Array(chunk["field_records"]) }
    repaired = SectionPageContinuity.repair_prompt(control.read, pages: pages, extra_records: records)

    assert_nil repaired["blocked"], repaired["notes"].inspect
    prompt = repaired["prompt"]
    parent, child, programming = contents(prompt)
    original_parent, original_child, original_programming = contents(control.read)

    assert_includes parent, "8.2 Funcionamiento normal"
    assert_includes parent, "• La puerta se re-abre sola."
    assert_includes parent, "– Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)."
    assert_includes parent, "– Comprobar que la fotocélula no esté activada."
    assert_includes parent, "– Comprobar que no hay una obstrucción mecánica en la puerta."
    assert_includes parent, "En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST."
    assert_includes parent, "Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta."
    assert_includes parent, "[PDF_PAGE: 12]"
    assert_includes parent, "[PRINTED_PAGE: 11/21]"
    assert_includes parent, "[PDF_PAGE: 13]"
    assert_includes parent, "[PRINTED_PAGE: 12/21]"
    assert_includes parent, "SOURCE_SECTION_OR_PAGE: 8.2 Funcionamiento normal — La puerta se re-abre sola."
    assert_includes parent, "ACTION: En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST"
    assert_includes parent, "EXPECTED_RESULT: Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta."
    assert_includes parent, "RECORD_TYPE: TROUBLESHOOTING_STEP"
    assert_not_includes parent, "LED STATUS"
    assert_not_includes parent, "fusibles"
    narrative = parent.sub(/\n# FIELD-SAFETY EVIDENCE RECORDS.*\z/m, "")
    assert_equal 1, narrative.scan("En caso que el problema persista").size

    assert_not_includes child, "En caso que el problema persista"
    continuation = original_child.lines.find { |item| item.include?("En caso que el problema persista") }
    assert_equal original_child.sub("#{continuation}\n", ""), child
    assert_includes child, "[SEARCH_ALIASES: puerta no abre, puerta golpea, LED STATUS apagado, correa dentada, fusibles Fermator, encoder polea, motor intermitente, fuera de servicio]"
    assert_includes child, "RECORD_ID: FR-8677B81AC4AF53FD"
    assert_equal original_programming, programming
    assert_equal control.read[/^Query: .*$/], prompt[/^Query: .*$/]
    assert_equal control.read[/^Goal: .*$/], prompt[/^Goal: .*$/]
    assert_equal control.read[/^# DOCUMENT IDENTITY ATTRIBUTION\n.*\z/m], prompt[/^# DOCUMENT IDENTITY ATTRIBUTION\n.*\z/m]
    assert_not_includes prompt, "Reportado por el técnico:"
    assert_not_includes parent, original_parent[/SOURCE_SECTION_OR_PAGE: .*$/]
    assert_includes original_child, "En caso que el problema persista"
  end

  private

  def sample_prompt
    [
      wrap(parent_chunk, 1),
      wrap(NEXT_PAGE_CHUNK, 2),
      wrap("SW4 queda fuera de este apartado.\n\n[SEARCH_ALIASES: programacion]\n\nTexto de programacion.", 3)
    ].join("\n")
  end

  def parent_chunk
    <<~TEXT.strip
      THIS JOB'S EQUIPMENT: UNIT
      [DOCUMENT: unit.pdf]
      [SOURCE_URI: s3://local/unit.pdf]
      [SEARCH_ALIASES: tope, sensor]

      • La unidad se detiene.
      – Revisar el tope.
      – Revisar el sensor.

      # FIELD-SAFETY EVIDENCE RECORDS

      FIELD_RECORD:
      RECORD_ID: FR-OLD
      SOURCE_SECTION_OR_PAGE: (continuación de página anterior)
      RECORD_TYPE: TROUBLESHOOTING_STEP
      ACTION: Si la unidad se detiene: revisar el tope
      EXPECTED_RESULT: DATA_NOT_AVAILABLE
      EVIDENCE: Revisar el tope
      END_FIELD_RECORD
    TEXT
  end

  NEXT_PAGE_CHUNK = <<~TEXT.strip
    THIS JOB'S EQUIPMENT: UNIT
    [DOCUMENT: unit.pdf]
    [SOURCE_URI: s3://local/unit.pdf]
    [SEARCH_ALIASES: arranque, alimentacion]

    #{CONTINUATION}

    • La unidad no arranca.
    – Revisar la alimentacion.

    # FIELD-SAFETY EVIDENCE RECORDS

    FIELD_RECORD:
    RECORD_ID: FR-KEEP
    SOURCE_SECTION_OR_PAGE: (continuación de página anterior)
    RECORD_TYPE: TROUBLESHOOTING_STEP
    ACTION: Revisar la alimentacion
    EXPECTED_RESULT: DATA_NOT_AVAILABLE
    EVIDENCE: Revisar la alimentacion
    END_FIELD_RECORD
  TEXT

  def headed_chunk
    NEXT_PAGE_CHUNK.sub(CONTINUATION, "3.1 Otro tema\n• La unidad no arranca.")
  end

  def wrap(body, source)
    "<search_result>\n<content>\n#{body}\n</content>\n<source>\n#{source}\n</source>"
  end

  def contents(prompt)
    prompt.scan(%r{<content>\n(.*?)\n</content>}m).flatten
  end

  def ordinary_pages
    [
      page_result(2, "Content page 2.", [ "alpha" ]),
      page_result(3, "Content page 3.", [ "beta" ])
    ]
  end

  def opening_pages
    [
      page_result(2, "• La unidad se detiene.\n– Revisar el tope.\n– Revisar el sensor.", [ "tope" ], []),
      page_result(3, "#{CONTINUATION}\n• La unidad no arranca.\n– Revisar la alimentacion.", [ "arranque" ], [ CONTINUATION_RECORD ])
    ]
  end

  def page_result(number, text, aliases, records = nil)
    chunk = { "text" => text, "page" => number, "aliases" => aliases }
    chunk["field_records"] = records if records
    {
      page_number: number,
      text: { "document_name" => "Unit", "aliases" => aliases, "summary" => "Unit.", "chunks" => [ chunk ] }.to_json,
      usage: nil,
      model: "test"
    }
  end

  def pdf_page(pdf, number)
    output, status = Open3.capture2("pdftotext", "-layout", "-f", number.to_s, "-l", number.to_s, pdf.to_s, "-")
    flunk "pdftotext #{status.exitstatus}" unless status.success?

    output
  end
end
