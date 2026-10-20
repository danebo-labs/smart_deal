# frozen_string_literal: true

require "test_helper"
require "open3"

class Rag::PageChunkFidelityTest < ActiveSupport::TestCase
  SW4_CHUNK = <<~TEXT
    THIS JOB'S EQUIPMENT: VF5
    [DOCUMENT: VF5.pdf]
    [SOURCE_URI: s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf]
    [SEARCH_ALIASES: SW4]

    S4 — SAFETY SYSTEM

    SW4 — Máster y Esclavo

    OFF: Esclavo.
    No hay movimientos de re-apertura automáticos. Las puertas solo responden a las instrucciones dadas por el módulo de control del ascensor. Ejemplo: con la fotocélula obstruida la unidad enviará una señal a la maniobra mediante la salida FOTOCÉLULA (36, 37, 38). Entonces, la maniobra desactivará la señal de cerrar y activará la señal de abrir.

    NOTA DE SEGURIDAD: En modo Esclavo, la re-apertura de emergencia por fotocélula depende de la respuesta del módulo de maniobra del ascensor.

    # FIELD-SAFETY EVIDENCE RECORDS

    FIELD_RECORD:
    RECORD_ID: FR-EXAMPLE
    SOURCE_SECTION_OR_PAGE: SW4.- Máster y Esclavo
    RECORD_TYPE: COMMISSIONING_STEP
    ACTION: Configurar SW4 en OFF (Esclavo): la unidad envía señal a la maniobra mediante salida FOTOCÉLULA cuando la fotocélula está obstruida; la maniobra desactiva cerrar y activa abrir.
    EXPECTED_RESULT: DATA_NOT_AVAILABLE
    EVIDENCE: la maniobra desactivara la señal de cerrar y activará la señal de abrir
    END_FIELD_RECORD
  TEXT

  SW4_PAGE = <<~TEXT
    4 Programación
    El VF se puede programar utilizando los interruptores DIP.

    SW4.- Máster y Esclavo

    OFF: Esclavo.
    No hay movimientos de re-apertura automáticos. Las puerta solo responden a las instrucciones dadas por el módulo de control del ascensor. Ejemplo: con la fotocélula obstruida la unidad enviará una señal a la maniobra mediante la salida FOTOCÉLULA (36, 37, 38). Entonces, la maniobra desactivara la señal de cerrar y activará la señal de abrir.
  TEXT

  PAGE13_CHUNK = <<~TEXT
    (Continuación de sección 8 — Resolución de problemas, página anterior)

    Problemas adicionales del operador de puerta VF5+:

    • La puerta no alcanza la posición de apertura completa.
    – Verificar los ajustes mecánicos de la puerta.
  TEXT

  PAGE13 = <<~TEXT
    – En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta.

    • La puerta no alcanza la posición de apertura completa.
    – Verificar los ajustes mecánicos de la puerta.
  TEXT

  test "the field report paragraph is part of the attribution contract only" do
    paragraph = BedrockRagService::FIELD_REPORT_PARAGRAPH
    contract = BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT

    assert_includes paragraph, "A visual observation does not by itself"
    assert_includes paragraph, "stays an example"
    assert_includes paragraph, "Earlier assistant lines"
    assert_not_includes paragraph.downcase, "fermator"
    assert_includes contract, paragraph
    assert_equal 1, contract.scan(paragraph).size
    assert contract.end_with?(Rag::LabelComparisonVariant::HISTORICAL_PARAGRAPH)
    assert_nil Rag::LabelComparisonVariant.production_problem(contract)
    template = BedrockRagService.load_generation_prompt_template
    assert_not_includes template, "A visual observation does not by itself"
  end

  test "drops an inserted heading and note and keeps the example verbatim" do
    corrected = Rag::PageChunkFidelity.correct(SW4_CHUNK, SW4_PAGE)

    assert_not_includes corrected, "S4 — SAFETY SYSTEM"
    assert_not_includes corrected, "NOTA DE SEGURIDAD"
    assert_not_includes corrected, "Configurar SW4 en OFF"
    assert_includes corrected, "Ejemplo: con la fotocélula obstruida"
    assert_includes corrected, "Las puerta solo"
    assert_includes corrected, "desactivara la señal de cerrar"
    assert_includes corrected, "THIS JOB'S EQUIPMENT: VF5"
    assert_includes corrected, "[SOURCE_URI: s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf]"
  end

  test "restores the sentence that opens the next page" do
    corrected = Rag::PageChunkFidelity.correct(PAGE13_CHUNK, PAGE13)

    assert_includes corrected, "En caso que el problema persista, desconectar la fotocélula"
    assert_not_includes corrected, "Problemas adicionales"
    assert_not_includes corrected, "Continuación de sección"
    assert corrected.index("En caso que el problema persista") < corrected.index("La puerta no alcanza")
  end

  test "does not prepend a section that the chunk does not open" do
    chunk = "SW2.- Automática / Semiautomática\n\nON: Automática.\nOperadores con patín (Puertas de rellano automáticas)."
    page = "#{SW4_PAGE}\n\n#{'calibracion documentada del patin ' * 30}\n\n#{chunk}"

    corrected = Rag::PageChunkFidelity.correct(chunk, page)

    assert_not_includes corrected, "Ejemplo: con la fotocélula obstruida"
    assert_includes corrected, "SW2.- Automática / Semiautomática"
  end

  test "rewrites only the search result that aligns with a page" do
    prompt = "<search_result>\n<content>\n#{PAGE13_CHUNK.strip}\n</content>\n<source>\n2\n</source>\n</search_result>"
    rewritten = Rag::PageChunkFidelity.rewrite_search_results(prompt, [ SW4_PAGE ])

    assert_equal prompt, rewritten
  end

  test "a local page file corrects generation context only when the flag matches the document" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "document_id.txt"), "be7a39a3490c92c8381cb883402760cb07d1")
      File.write(File.join(dir, "p13.txt"), PAGE13)
      chunk = {
        content: PAGE13_CHUNK,
        metadata: { "page_number" => 13, "document_id" => "be7a39a3490c92c8381cb883402760cb07d1" }
      }
      plain = Rag::DocumentIdentityScope.generation_context([ chunk ])
      assert_includes plain, "Problemas adicionales"

      ENV["RAG_LOCAL_PAGE_FIDELITY"] = "1"
      ENV["RAG_LOCAL_PAGE_TEXT"] = dir
      corrected = Rag::DocumentIdentityScope.generation_context([ chunk ])
      assert_includes corrected, "En caso que el problema persista"
      assert_not_includes corrected, "Problemas adicionales"

      other = chunk.merge(metadata: { "page_number" => 13, "document_id" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" })
      untouched = Rag::DocumentIdentityScope.generation_context([ other ])
      assert_includes untouched, "Problemas adicionales"
    end
  ensure
    ENV.delete("RAG_LOCAL_PAGE_FIDELITY")
    ENV.delete("RAG_LOCAL_PAGE_TEXT")
  end

  test "the captured VF5 prompts regain the page text and do not gain SW4 where it was absent" do
    root = Rails.root.join("tmp/field_companion/validation_captures/vf5-bound-20261020T1728Z")
    skip "captured prompts are local evidence" unless root.join("354da85f-c20c-4d36-bb88-45a0c059bc2e/bodies/b0005.txt").file?

    pages = [ 5, 12, 13 ].map { |number| pdf_page(number) }
    turn1 = root.join("354da85f-c20c-4d36-bb88-45a0c059bc2e/bodies/b0005.txt").read
    turn2 = root.join("8205d72d-d67f-4dcb-b9d6-532fb3373768/bodies/b0005.txt").read
    corrected1 = Rag::PageChunkFidelity.rewrite_search_results(turn1, pages)
    corrected2 = Rag::PageChunkFidelity.rewrite_search_results(turn2, pages)

    assert_not_includes corrected1, "S4 — SAFETY SYSTEM"
    assert_not_includes corrected1, "NOTA DE SEGURIDAD"
    assert_not_includes corrected1, "Configurar SW4 en OFF"
    assert_not_includes corrected1, "Problemas adicionales del operador"
    assert_includes corrected1, "Ejemplo: con la fotocélula obstruida"
    assert_includes corrected1, "Las puerta solo"
    assert_includes corrected1, "En caso que el problema persista, desconectar la fotocélula"
    assert_includes corrected1, "Verificar los ajustes mecánicos de la puerta"
    assert_includes corrected1, "Comprobar que el desbloqueo del patín esté bien fijado"
    assert_includes corrected1, "Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)"
    assert_includes corrected1, "Comprobar que la fotocélula no esté activada"
    assert_includes corrected1, "Comprobar que no hay una obstrucción mecánica en la puerta"
    assert_equal query_line(turn1), query_line(corrected1)
    assert_equal attribution(turn1), attribution(corrected1)

    assert_includes corrected2, "En caso que el problema persista, desconectar la fotocélula"
    assert_includes corrected2, "Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)"
    assert_not_includes corrected2, "Ejemplo: con la fotocélula obstruida"
    assert_not_includes corrected2, "Máster y Esclavo"
    assert_equal query_line(turn2), query_line(corrected2)
    assert_equal attribution(turn2), attribution(corrected2)
  end

  private

  def pdf_page(number)
    pdf = Rails.root.join("docs/field_companion/fuentes/VF5.pdf")
    output, status = Open3.capture2("pdftotext", "-layout", "-f", number.to_s, "-l", number.to_s, pdf.to_s, "-")
    flunk "pdftotext #{status.exitstatus}" unless status.success?

    Rag::PageChunkFidelity.strip_running_matter(output)
  end

  def query_line(prompt)
    prompt[/^Query: .*$/]
  end

  def attribution(prompt)
    prompt[/^# DOCUMENT IDENTITY ATTRIBUTION\n.*\z/m]
  end
end
