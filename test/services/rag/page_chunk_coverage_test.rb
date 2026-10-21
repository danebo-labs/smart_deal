# frozen_string_literal: true

require "test_helper"

class Rag::PageChunkCoverageTest < ActiveSupport::TestCase
  HEADER = "ACME FIELD SERVICE BULLETIN REV A"
  OPENING = "Check the seal before starting the motor and record the reading today."
  FOLLOWING = "Leave the coupling guarded while the shaft is turning and the guard stays closed."

  test "a repeated header is furniture and a blank page stays unverifiable" do
    pages = {
      1 => "#{HEADER}\nPág. 1 / 9\n\n#{OPENING}\n\n#{FOLLOWING}\nSet the coil to 230 V.\n",
      2 => "#{HEADER}\nPág. 2 / 9\n\n#{FOLLOWING}\n",
      3 => "#{HEADER}\nPág. 3 / 9\n\nLap the seat until the ring is even and the valve closes without a leak across the face.\nThe relief setting on this sheet is 0,12 and the spare is marked #7.\n",
      4 => ""
    }
    faithful = "#{OPENING}\n#{FOLLOWING}\nSet the coil to 230 V."
    invented = "NOTE: this sheet was not transmitted and the previous chapter continues from an unseen page."
    report = Rag::PageChunkFidelity.assess_coverage(
      page_texts: pages,
      chunks: [
        { page: 1, text: faithful },
        { page: 3, text: invented },
        { page: 4, text: "The figure shows a pump housing and a shaft." }
      ]
    )

    assert_includes report[:running_lines], HEADER
    assert_not_includes report[:running_lines], "Lap the seat until the ring is even and the valve closes without a leak across the face."

    first = report[:pages][1]
    assert first[:accounted]
    assert first[:verifiable]
    assert first[:opening_present]
    assert_not first[:precision_low]
    assert_empty first[:added_lines]
    assert_not_includes first[:missing_numbers], "230 V"
    assert_not first[:layout_order_verified]

    assert_not report[:pages][2][:accounted]
    assert_not report[:pages][2][:discarded]

    third = report[:pages][3]
    assert third[:precision_low]
    assert third[:added_lines].any? { |line| line.include?("not transmitted") }
    assert_includes third[:missing_numbers], "0,12"
    assert_includes third[:missing_numbers], "#7"
    assert_not third[:layout_order_verified]

    fourth = report[:pages][4]
    assert fourth[:accounted]
    assert_not fourth[:verifiable]
    assert_not fourth[:precision_low]
    assert_nil fourth[:opening_present]
    assert_nil fourth[:missing_numbers]
  end

  test "a discard accounts for a page and does not call the content surplus" do
    text = "#{FOLLOWING}\n#{OPENING}\n"
    bare = Rag::PageChunkFidelity.assess_coverage(page_texts: { 2 => text }, chunks: [])
    kept = Rag::PageChunkFidelity.assess_coverage(
      page_texts: { 2 => text },
      chunks: [],
      discards: { 2 => "index" }
    )

    assert_not bare[:pages][2][:accounted]
    assert kept[:pages][2][:accounted]
    assert kept[:pages][2][:discarded]
    assert_not kept[:pages][2].key?(:surplus)
  end

  test "an opening counts only when its words stay in order" do
    pages = { 1 => "#{OPENING}\n\n#{FOLLOWING}\n" }
    scrambled = "The motor and the seal record a reading before starting today after the check of the coupling."
    absent = Rag::PageChunkFidelity.assess_coverage(
      page_texts: pages,
      chunks: [ { page: 1, text: scrambled } ]
    )
    present = Rag::PageChunkFidelity.assess_coverage(
      page_texts: pages,
      chunks: [ { page: 1, text: OPENING } ]
    )

    assert_not absent[:pages][1][:opening_present]
    assert present[:pages][1][:opening_present]
  end

  test "moved text keeps the opening of its source page" do
    pages = { 1 => "#{OPENING}\n\n#{FOLLOWING}\n" }
    pre_merge = [ { page: 1, text: FOLLOWING } ]
    before = Rag::PageChunkFidelity.assess_coverage(page_texts: pages, chunks: pre_merge)
    by_field = Rag::PageChunkFidelity.assess_coverage(
      page_texts: pages,
      chunks: pre_merge,
      recall_chunks: pre_merge + [ { page: 2, source_pdf_page: 1, text: OPENING } ]
    )
    by_mark = Rag::PageChunkFidelity.assess_coverage(
      page_texts: pages,
      chunks: pre_merge,
      recall_chunks: pre_merge + [ { page: 2, text: "[PDF_PAGE: 1]\n#{OPENING}\n" } ]
    )

    assert_not before[:pages][1][:opening_present]
    assert_not before[:pages][1][:precision_low]
    assert by_field[:pages][1][:opening_present]
    assert by_mark[:pages][1][:opening_present]
  end

  test "a longer digit run does not satisfy a shorter literal" do
    pages = {
      1 => "#{OPENING}\n#{FOLLOWING}\nThe factor printed here is 0,12.\n"
    }
    report = Rag::PageChunkFidelity.assess_coverage(
      page_texts: pages,
      chunks: [ { page: 1, text: "#{OPENING}\n#{FOLLOWING}\nUse the row 10,12 when the panel changes." } ]
    )

    assert_includes report[:pages][1][:missing_numbers], "0,12"
  end

  test "an example action that drops the example mark is promoted" do
    narrative = <<~TEXT
      Ejemplo: con la fotocélula obstruida la unidad enviará una señal a la maniobra mediante la salida FOTOCÉLULA (36, 37, 38). Entonces, la maniobra desactivará la señal de cerrar y activará la señal de abrir.
    TEXT
    example = {
      "a" => "Configurar SW4 en OFF (Esclavo): la unidad envía señal a la maniobra mediante salida FOTOCÉLULA (terminales 36, 37, 38) cuando la fotocélula está obstruida; la maniobra desactiva cerrar y activa abrir.",
      "ev" => "la maniobra desactivara la señal de cerrar y activará la señal de abrir"
    }
    step = {
      "a" => "Comprobar que no hay una obstrucción mecánica en la puerta del rellano",
      "ev" => "Comprobar que no hay una obstrucción mecánica en la puerta"
    }

    assert Rag::PageChunkFidelity.promoted_example?(example, narrative)
    assert_not Rag::PageChunkFidelity.promoted_example?(step, narrative)
  end

  test "historical bodies show the known coverage defects" do
    pdf = Rails.root.join("docs/field_companion/fuentes/VF5.pdf")
    directory = Rails.root.join("tmp/review_vf5")
    skip "historical VF5 bodies are local evidence" unless pdf.file? && directory.join("chunk_p12_1.txt").file?

    pages = page_texts(pdf)
    paths = Dir[directory.join("chunk_p*.txt").to_s]
    chunks = paths.map { |path|
      match = File.basename(path).match(/chunk_p(\d+)_/)
      { page: match[1].to_i, text: File.read(path) }
    }
    report = Rag::PageChunkFidelity.assess_coverage(page_texts: pages, chunks: chunks, page_count: pages.size)
    promoted = promoted_actions(chunks)

    assert_equal 22, pages.size
    assert_equal 30, chunks.size
    assert_equal 112, promoted[:total]
    assert_equal 3, promoted[:actions].size
    assert promoted[:actions].any? { |action| action.include?("FOTOCÉLULA") && action.include?("Esclavo") }
    assert_not promoted[:actions].any? { |action| action.include?("obstrucción mecánica") }

    assert_not report[:pages][3][:accounted]
    assert_not report[:pages][4][:verifiable]
    assert_not report[:pages][4][:precision_low]
    assert_not report[:pages][1][:precision_low]

    added = report[:pages][5][:added_lines]
    assert added.any? { |line| line.include?("S4") && line.match?(/SAFETY/i) }, added.inspect
    assert added.any? { |line| line.match?(/NOTA DE SEGURIDAD/i) }, added.inspect
    assert_not added.any? { |line| line.match?(/fotocélula obstruida/i) }, added.inspect
    assert_not report[:pages][5][:precision_low]
    assert report[:pages][5][:opening_present], "p5 opening"

    assert_not report[:pages][12][:opening_present], "p12 opening"
    assert_includes report[:pages][12][:missing_numbers], "#21"
    assert_not report[:pages][12][:precision_low]
    assert_not report[:pages][13][:opening_present], "p13 opening"
    assert_not report[:pages][13][:precision_low]

    assert report[:pages][14][:precision_low], report[:pages][14][:precision]
    assert report[:pages][19][:missing_numbers].size >= 10
    assert_includes report[:pages][19][:missing_numbers], "0,12"

    assert report[:pages][11][:opening_present], "p11 opening"
    assert_not report[:pages][11][:added_lines].any? { |line| line.match?(/anti-banging/i) }

    report[:pages].each_value { |page| assert_not page[:layout_order_verified] }
  end

  private

  def page_texts(pdf)
    texts = {}
    PdfPageSplitterService.new(pdf.binread).each_split_page do |page|
      text = page.text.to_s
      text = PageRelevanceFilter.extract_page_text(page.binary) if text.blank?
      texts[page.number] = text
      page.cleanup
    end
    texts
  end

  test "running matter is whichever line repeats, and a single title stays" do
    once = "Módulo electrónico VF5+\nCheck the seal before starting the motor.\nPág. 4 / 9\n"
    kept = Rag::PageChunkFidelity.strip_running_matter(once)
    assert_includes kept, "Módulo electrónico VF5+"
    assert_not_includes kept, "Pág."

    stripped = Rag::PageChunkFidelity.strip_running_matter(once, running_lines: [ "Módulo electrónico VF5+" ])
    assert_not_includes stripped, "Módulo electrónico"
    assert_includes stripped, "Check the seal"
  end

  test "a thin text layer is not low precision and an invented body is" do
    page = "Check the door seal before starting the motor and confirm the photocell input is clear during the full travel of the cabin door."
    invented = {
      "document_name" => "Unit",
      "aliases" => [],
      "chunks" => [ { "text" => "Replace the hydraulic pump and refill the oil reservoir before the next inspection.", "page" => 4, "field_records" => [] } ]
    }.to_json
    faithful = {
      "document_name" => "Unit",
      "aliases" => [],
      "chunks" => [ { "text" => page, "page" => 4, "field_records" => [] } ]
    }.to_json

    assert Rag::PageChunkFidelity.low_precision_body?(invented, page_text: page, page_number: 4, anchor_page: 1)
    assert_not Rag::PageChunkFidelity.low_precision_body?(faithful, page_text: page, page_number: 4, anchor_page: 1)
    assert_not Rag::PageChunkFidelity.low_precision_body?(invented, page_text: "3 Conexionado", page_number: 4, anchor_page: 1)
    assert_not Rag::PageChunkFidelity.low_precision_body?(invented, page_text: "", page_number: 4, anchor_page: 1)
  end

  def promoted_actions(chunks)
    actions = []
    total = 0
    chunks.each do |chunk|
      narrative = chunk[:text].partition("# FIELD-SAFETY EVIDENCE RECORDS").first
      chunk[:text].split(/(?=^FIELD_RECORD:)/).each do |part|
        next unless part.include?("END_FIELD_RECORD")

        total += 1
        record = {
          "a" => part[/^ACTION:\s*(.+)$/, 1],
          "ev" => part[/^EVIDENCE:\s*(.+)$/, 1]
        }
        actions << record["a"].to_s if Rag::PageChunkFidelity.promoted_example?(record, narrative)
      end
    end
    { total: total, actions: actions }
  end
end
