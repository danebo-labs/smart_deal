# frozen_string_literal: true

require "test_helper"

class Rag::PendingQuestionTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 9, 25, 15, 0, 0)

  test "fault_code manufacturer and model round-trip and win over prose" do
    state = episode_state
    fault = Rag::ActiveEpisodeTurn.apply_assistant(
      state: state, text: "¿Cuál es la marca?", now: NOW, correlation_id: "query:a",
      pending_question: { "type" => "fault_code" }
    )
    assert_equal "fault_code", fault.state.dig("pending_question", "type")
    assert_equal "fault_code", fault.state.dig("pending_fact", "subject")

    model = Rag::ActiveEpisodeTurn.apply_assistant(
      state: state, text: "¿Cuál es el código?", now: NOW, correlation_id: "query:b",
      pending_question: { "type" => "model" }
    )
    assert_equal "model", model.state.dig("pending_question", "type")
    assert_equal "model", model.state.dig("pending_fact", "subject")

    brand = Rag::ActiveEpisodeTurn.apply_assistant(
      state: state, text: "sin pregunta", now: NOW, correlation_id: "query:c",
      pending_question: { "type" => "manufacturer" }
    )
    assert_equal "manufacturer", brand.state.dig("pending_question", "type")
    assert_equal "manufacturer", brand.state.dig("pending_fact", "subject")
  end

  test "choice options round-trip and al abrir selects opening" do
    question = { "type" => "choice", "options" => %w[opening closing] }
    state = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Al abrir o al cerrar?", now: NOW, correlation_id: "query:choice",
      pending_question: question
    ).state
    assert_equal question, state["pending_question"]
    assert_nil state["pending_fact"]

    answered = Rag::ActiveEpisodeTurn.call(
      state: state, text: "al abrir", now: NOW, enabled: true, shared: false, correlation_id: "query:reply"
    )
    assert_nil answered.state["pending_question"]
    assert_nil answered.state.dig("facts", "fault_code")
    assert_equal({ "type" => "choice", "value" => "opening" }, Rag::PendingQuestion.parse_reply("al abrir", pending_question: question))
  end

  test "ninguno on a fault_code question confirms absence" do
    state = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Qué código muestra?", now: NOW, correlation_id: "query:code",
      pending_question: { "type" => "fault_code" }
    ).state
    answered = Rag::ActiveEpisodeTurn.call(
      state: state, text: "ninguno", now: NOW, enabled: true, shared: false, correlation_id: "query:none"
    )
    assert_equal "absent_confirmed", answered.state.dig("facts", "fault_code", "status")
    assert_nil answered.state["pending_question"]
  end

  test "a conversational target is stored without a fact and is not parsed from prose" do
    question = { "type" => "work_relation", "carry" => [ "Q2" ] }
    state = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Esto sigue siendo el mismo equipo?", now: NOW, correlation_id: "query:rel",
      pending_question: question
    ).state

    assert_equal question, state["pending_question"]
    assert_nil state["pending_fact"]
    assert_nil Rag::PendingQuestion.parse_reply("Es otro ascensor", pending_question: question)
    assert_nil Rag::PendingQuestion.coerce("type" => "work_relation", "options" => [ "same" ])["options"]
  end

  test "from_publication stores the last published question without label and with only the sources it cites" do
    sources = [ { "document" => "Manual VF5", "document_key" => "s3://m", "filename" => "m.pdf", "page" => "7" } ]
    cited = Rag::PendingQuestion.from_publication(
      "La fuente dice «Indicador LED.» [1]\n\n**Próxima comprobación:** ¿Qué LED está encendido?", sources: sources, locale: :es
    )
    assert_equal "¿Qué LED está encendido?", cited["question"]
    assert_equal [], cited["targets"]

    inline = Rag::PendingQuestion.from_publication("Indicador LED [1] ¿Qué LED está encendido?", sources: sources, locale: :es)
    assert_equal "¿Qué LED está encendido?", inline["question"]
    assert_equal [ "Manual VF5" ], inline["targets"].pluck("item")
    assert_equal "7", inline["targets"].first["page"]
  end

  # Live run 20261120T134952Z, T4. The model states what the answer decides in
  # the same line as the question, as the generator prompt asks it to.
  test "with the flag on a question keeps being the last thing asked when its reason shares the line" do
    published = "Pregunta: ¿en qué punto exacto se detiene la hoja? ¿Dentro de la zona con residuos de la guía del piso 3 o antes de llegar a ella? La respuesta cambia si la acumulación está en el recorrido de la hoja."
    stored = "¿en qué punto exacto se detiene la hoja? ¿Dentro de la zona con residuos de la guía del piso 3 o antes de llegar a ella?"

    with_check_outcome_flag("true") do
      assert_equal stored, Rag::PendingQuestion.from_publication(published, locale: :es)["question"]
      assert_equal "¿Qué LED está encendido?",
        Rag::PendingQuestion.from_publication("¿Qué LED está encendido? Esa lectura decide la rama. Sigue [2].", locale: :es)["question"]
      assert_nil Rag::PendingQuestion.from_publication("Revisa el cableado. La respuesta cambia si hay corte.", locale: :es),
        "no question, nothing stored"
    end
    with_check_outcome_flag(nil) do
      assert_nil Rag::PendingQuestion.from_publication(published, locale: :es), "flag off keeps the base reading"
    end
  end

  test "from_publication keeps a compound question whole and returns nil without a question" do
    compound = "¿Con la señal #21 activa, el LED de FOTOCÉLULA se enciende y el relé conmuta?"
    assert_equal compound, Rag::PendingQuestion.from_publication("Revisa el cableado.\n\n#{compound}", locale: :es)["question"]
    assert_nil Rag::PendingQuestion.from_publication("Revisa el cableado y repite la prueba.", locale: :es)
    assert_equal "¿El EA no vuelve a aparecer?", Rag::PendingQuestion.question_in("Resumen. ¿El EA no vuelve a aparecer?", locale: :es)
  end

  test "from_publication takes the question that a citation sentence follows and keeps the lead-in condition" do
    otis = "Pero no confirma la causa. DCL y DFC siguen sin verificar.\n\nPróxima comprobación: con la puerta de piso 3 cerrada, " \
      "¿el LED DFC del panel queda encendido? Según [21], DFC \"Puertas completamente cerradas\"."
    sources = Array.new(21) { |index| { "document" => "Guía #{index + 1}", "document_key" => "k#{index + 1}", "filename" => "g.pdf", "page" => "3" } }
    stored = Rag::PendingQuestion.from_publication(otis, sources: sources, locale: :es)

    assert_equal "con la puerta de piso 3 cerrada, ¿el LED DFC del panel queda encendido?", stored["question"]
    assert_equal [ "Guía 21" ], stored["targets"].pluck("item")
    thyssen = "Comprobación: en operación normal, tras varias maniobras en automático, ¿el EA no vuelve a aparecer?\n\nLa referencia describe el manual."
    assert_equal "en operación normal, tras varias maniobras en automático, ¿el EA no vuelve a aparecer?",
      Rag::PendingQuestion.from_publication(thyssen, locale: :es)["question"]
    assert_nil Rag::PendingQuestion.from_publication("Repite la maniobra y dime si falla. Según [5], el estado no se afirma.", locale: :es)
  end

  test "an untargeted pending survives a stored read but not a read built from a clarification" do
    raw = { "type" => "documented_context", "question" => "¿Qué LED está encendido?", "targets" => [] }

    assert_nil Rag::PendingQuestion.coerce(raw)
    assert_equal raw, Rag::PendingQuestion.coerce_stored(raw)
    state = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Qué LED está encendido?", now: NOW, correlation_id: "query:untargeted", pending_question: raw
    ).state
    assert_equal [], state.dig("pending_question", "targets")
    assert_equal "q1", state.dig("pending_question", "id")
  end

  test "a longer no se answers the documented question and a negated state does not" do
    question = {
      "type" => "documented_context",
      "question" => "¿El LED se enciende por la entrada 21 o por la fotocélula?",
      "targets" => [ { "item" => "Fotocélula.", "document_key" => "s3://x", "filename" => "chunk_p7_3.txt", "page" => "7" } ]
    }
    reply = Rag::PendingQuestion.parse_reply(
      "No sé cómo distinguir si lo activa la entrada 21 o la fotocélula",
      pending_question: question
    )
    assert_equal({ "type" => "documented_context", "r" => "unknown" }, reply)
    assert_nil Rag::PendingQuestion.parse_reply("No se enciende el LED", pending_question: question)
  end

  test "prose fallback still sets the subject when no structured object is passed" do
    result = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Sabes el modelo del equipo?", now: NOW, correlation_id: "query:prose"
    )
    assert_nil result.state["pending_question"]
    assert_equal "model", result.state.dig("pending_fact", "subject")
  end

  test "the assistant answer text is not rewritten when a pending question is stored" do
    prose = "Ajusta el freno según el manual. [1]"
    result = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: prose, now: NOW, correlation_id: "query:cite",
      pending_question: { "type" => "fault_code" }
    )
    assert_equal "fault_code", result.state.dig("pending_question", "type")
    assert_not_includes JSON.generate(result.state), prose
    service = Rails.root.join("app/services/bedrock_rag_service.rb").read
    assert_includes service, "pending_question"
    assert_not_includes service, "PendingQuestion.parse_reply"
  end

  test "a pending question does not evict identifiers inside the 2048-byte budget" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:budget", now: NOW)
    episode.assign_goal!("cómo se ajustan los resortes", correlation_id: "query:budget")
    episode.write_fact!("manufacturer", status: "known", value: "Otis", source: "user", correlation_id: "query:budget", at: NOW.iso8601)
    episode.write_fact!("model", status: "known", value: "MonoSpace", source: "user", correlation_id: "query:budget", at: NOW.iso8601)
    5.times { |index| episode.append_identifier!("ID#{index}TOKEN", correlation_id: "query:budget") }
    before = episode.to_h
    stored = Rag::ActiveEpisodeTurn.apply_assistant(
      state: before, text: "¿Qué código?", now: NOW, correlation_id: "query:budget",
      pending_question: { "type" => "fault_code" }
    ).state
    assert_equal before["identifiers"], stored["identifiers"]
    assert_equal before["facts"], stored["facts"]
    assert_operator JSON.generate(stored).bytesize, :<=, Rag::ActiveEpisode::MAX_BYTES
  end

  test "both the open question and the clarification count when the text has both" do
    text = "#{entry_question}\n#{indicator_question}"
    assert_equal held_question, Rag::PendingQuestion.presented(held_question, text, retained: open_question)
  end

  test "a clarification published alone keeps the open question already stored" do
    kept = Rag::PendingQuestion.presented(held_question, indicator_question, retained: open_question)
    assert_equal held_question, kept
    assert_equal indicator_question, kept.dig("shown", "question")
  end

  test "a clarification absent from the text is not stored as shown" do
    assert_nil Rag::PendingQuestion.presented(held_question, "texto sin preguntas", retained: open_question)
    kept = Rag::PendingQuestion.presented(held_question, entry_question, retained: open_question)
    assert_equal open_question, kept
    assert_nil kept["shown"]
  end

  test "a question that was not stored and did not reach the text is not kept through its clarification" do
    assert_nil Rag::PendingQuestion.presented(held_question, indicator_question, retained: nil)
    other = open_question.merge("question" => "¿Otra pregunta?")
    assert_nil Rag::PendingQuestion.presented(held_question, indicator_question, retained: other)
  end

  test "a clarification already stored stays when the same datum is reworded and published" do
    reworded = held_question.merge("question" => "¿La entrada A está activa?")
    assert_equal reworded, Rag::PendingQuestion.presented(reworded, "¿La entrada A está activa?", retained: held_question)
    assert_nil Rag::PendingQuestion.presented(reworded, indicator_question, retained: held_question)
  end

  test "a bold question label is stored as the wording the answer published" do
    screen = documented_question("**Consulta:** ¿la pantalla sigue marcando EC?")
    published = Object.new.extend(RagQueryConcern).send(
      :sanitize_answer, "La lectura queda pendiente.\n\n**Consulta:** ¿la pantalla sigue marcando EC?"
    )
    kept = Rag::PendingQuestion.presented(screen, published)
    assert_equal "Consulta: ¿la pantalla sigue marcando EC?", kept["question"]
    assert_equal screen["targets"], kept["targets"]

    brake = documented_question("**Pregunta:** ¿el freno queda abierto?")
    assert_equal "Pregunta: ¿el freno queda abierto?", Rag::PendingQuestion.presented(brake, "Pregunta: ¿el freno queda abierto?")["question"]
    assert_nil Rag::PendingQuestion.presented(brake, "El variador no arranca.")
    assert_equal "¿La entrada está activa?", Rag::PendingQuestion.presented(documented_question("¿La entrada está activa?"), "¿La entrada está activa?")["question"]
  end

  test "a clarification withdrawn from the final answer is not stored even though the proposal had it" do
    proposal_text = "Orientación.\n#{entry_question}\n#{indicator_question}"
    final_answer = "Orientación.\n#{entry_question}"
    assert_includes proposal_text, indicator_question
    assert_not_includes final_answer, indicator_question

    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_plan_pending, held_question)
    service.instance_variable_set(:@companion_plan_retained, open_question)
    published_proposal = service.send(:companion_turn_pending, true, proposal_text)
    assert_equal indicator_question, published_proposal.dig("shown", "question")
    withdrawn = service.send(:companion_turn_pending, true, final_answer)
    assert_equal open_question, withdrawn
    assert_nil withdrawn["shown"]
    assert_nil service.send(:companion_turn_pending, true, "Orientación sin preguntas.")
    assert_nil service.send(:companion_turn_pending, false, proposal_text)

    only_clarification = "Orientación.\n#{indicator_question}"
    kept = service.send(:companion_turn_pending, true, only_clarification)
    assert_equal entry_question, kept["question"]
    assert_equal indicator_question, kept.dig("shown", "question")

    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: NOW)
    episode.assign_goal!("el conjunto no responde", correlation_id: "query:open")
    episode.pending_question = open_question
    session = Struct.new(:active_episode).new(episode.to_h)
    host = Object.new.extend(RagQueryConcern)
    final = publication(final_answer, final_answer)
    published = host.send(:companion_published_pending, held_question, final, session)
    assert_equal open_question, published
    assert_nil published["shown"]

    history_drops_it = publication(proposal_text, final_answer)
    from_history = host.send(:companion_published_pending, held_question, history_drops_it, session)
    assert_equal open_question, from_history
    assert_nil from_history["shown"]

    abstained = publication(proposal_text, "", route_outcome: :abstained, companion_reason: "companion_contract_invalid")
    assert_nil host.send(:companion_published_pending, held_question, abstained, session)
  end

  test "a technical question stays the follow-up when the plate notice comes after it" do
    noise = "¿El ruido es muy elevado en su evaluación?"
    kpvs = "¿Qué valor de KP-VS midió Ingeniería?"
    notice = I18n.t("rag.controller_reference_boundary", locale: :es)
    plate = I18n.t("rag.controller_label_question", locale: :es)
    published = "La fuente lo condiciona a «En caso de ruido audible muy elevado» [1].\n\n#{noise}\n\n#{notice}"

    assert_equal noise, Rag::PendingQuestion.followup_line(published, locale: :es)
    assert_equal kpvs, Rag::PendingQuestion.followup_line("#{kpvs}\n\n#{notice}", locale: :es)
    assert_equal noise, Rag::PendingQuestion.followup_line("#{published}\n\n#{plate}", locale: :es)
    assert_nil Rag::PendingQuestion.followup_line("#{notice}\n\n#{plate}", locale: :es)
  end

  # Otis T5, live round 3 (20261119T223408Z): the question cited [9], and the
  # stored target had the manual's title with an empty document_key, filename
  # and page, because the source list the writer reads carried none of them.
  test "FIELD_CHECK_OUTCOME gives the cited source its key, file and page in the stored target" do
    chunk = {
      "content" => "DFC encendido: puertas completamente cerradas.", "identity_applicability" => "compatible",
      "location_uri" => "s3://bucket/bulk_chunks/3/otis/chunk_p121_1.txt",
      "metadata" => { "canonical_name" => "MANUAL DE AYUDA TÉCNICA (p1-123)", "page_number" => "121",
                      "original_source_uri" => "s3://bucket/bulk_uploads/3/otis (p1-123).pdf" }
    }
    published = "Comprobación: con la puerta de piso 3 cerrada, ¿el LED DFC del panel está encendido? Según [1], DFC encendido indica puertas cerradas."
    service = BedrockRagService.allocate

    with_check_outcome_flag("true") do
      stored = Rag::PendingQuestion.from_publication(published, sources: service.send(:companion_publication_sources, [ chunk ]))
      target = stored.fetch("targets").sole
      assert_equal "MANUAL DE AYUDA TÉCNICA (p1-123)", target.fetch("item")
      assert_equal "s3://bucket/bulk_uploads/3/otis (p1-123).pdf", target.fetch("document_key")
      assert_equal "chunk_p121_1.txt", target.fetch("filename")
      assert_equal "121", target.fetch("page")
    end

    with_check_outcome_flag(nil) do
      source = service.send(:companion_publication_sources, [ chunk ]).sole
      assert_equal %w[applicability content document index reference_only], source.keys.sort, "flag off keeps the base shape"
    end
  end

  # Otis T5, live round 3 (correlation query:73c59b4b…). The generator cited [9]
  # and the stored target came back with only the title. Same ten passages in
  # the same order, pages as floats as Retrieve returns them: the target must
  # point at passage 9, page 121 of the (p1-123) manual, and at no neighbour.
  test "FIELD_CHECK_OUTCOME keeps the reference of the passage [9] names among ten" do
    pages = [ [ 23, "p124-245" ], [ 47, "p1-123" ], [ 87, "p124-245" ], [ 22, "p124-245" ], [ 85, "p124-245" ],
              [ 42, "p1-123" ], [ 54, "p124-245" ], [ 55, "p124-245" ], [ 121, "p1-123" ], [ 83, "p124-245" ] ]
    chunks = pages.each_with_index.map { |(page, part), index| otis_chunk(page, part, index) }
    published = "Comprobación: con la puerta de piso 3 cerrada, ¿el LED DFC del panel está encendido? " \
                "Según [9], DFC encendido indica \"Puertas completamente cerradas (Cadena de seguridad cerrada)\"."

    with_check_outcome_flag("true") do
      sources = BedrockRagService.allocate.send(:companion_publication_sources, chunks)
      target = Rag::PendingQuestion.from_publication(published, sources: sources).fetch("targets").sole

      assert_equal "MANUAL DE AYUDA TÉCNICA (p1-123)", target.fetch("item")
      assert_equal "s3://bucket/bulk_uploads/3/MANUAL (p1-123).pdf", target.fetch("document_key")
      assert_equal "chunk_p121_9.txt", target.fetch("filename")
      assert_equal "121", target.fetch("page"), "a float page is stored as the page the technician reads"
    end
  end

  test "FIELD_CHECK_OUTCOME reads a reopened case's cited number, not its position" do
    first = otis_chunk(121, "p1-123", 0).merge("case_number" => 7)
    second = otis_chunk(55, "p124-245", 1).merge("case_number" => 9)
    published = "Comprobación: ¿el LED DFC del panel está encendido? Según [9], DFC encendido indica puertas cerradas."

    with_check_outcome_flag("true") do
      sources = BedrockRagService.allocate.send(:companion_publication_sources, [ first, second ])
      target = Rag::PendingQuestion.from_publication(published, sources: sources).fetch("targets").sole

      assert_equal "chunk_p55_2.txt", target.fetch("filename"), "[9] is the passage numbered 9, which sits second"
      assert_equal "55", target.fetch("page")
    end
  end

  test "FIELD_CHECK_OUTCOME falls back to the chunk's own source uri when the sidecar metadata has no key" do
    chunk = otis_chunk(121, "p1-123", 8)
    chunk["metadata"].delete("original_source_uri")
    chunk["original_source_uri"] = "s3://bucket/bulk_uploads/3/MANUAL (p1-123).pdf"

    with_check_outcome_flag("true") do
      locator = BedrockRagService.allocate.send(:companion_source_locator, chunk["metadata"], chunk)
      assert_equal "s3://bucket/bulk_uploads/3/MANUAL (p1-123).pdf", locator.fetch("document_key")
      assert_equal "chunk_p121_9.txt", locator.fetch("filename")
    end
  end

  test "flag off reads the cited source by position and leaves the source shape alone" do
    chunks = [ otis_chunk(121, "p1-123", 0).merge("case_number" => 9), otis_chunk(55, "p124-245", 1) ]
    sources = with_check_outcome_flag(nil) { BedrockRagService.allocate.send(:companion_publication_sources, chunks) }
    assert_empty sources.flat_map(&:keys) & %w[number document_key filename page]

    target = Rag::PendingQuestion.from_publication("¿El LED DFC está encendido? Según [2], DFC indica puertas cerradas.", sources: sources).fetch("targets").sole
    assert_equal "MANUAL DE AYUDA TÉCNICA (p124-245)", target.fetch("item")
  end

  # Otis T5, live round 4 (correlation query:1bb60e4e…). The manual's line sat
  # in the labelled check paragraph and the question alone under it, so the
  # pending was stored with targets []. The cited passage must reach it.
  ROUND4_T5 = <<~TEXT.strip
    Resultado: Tras retirar los residuos de la guía, la puerta cerró por completo. Esto solo vale para esa maniobra.

    Pendiente: DCL y DFC sin verificar. DCL ya quedó pendiente antes, así que no lo vuelvo a pedir.

    Siguiente comprobación (DFC): Según el panel, el LED DFC indica "Puertas completamente cerradas (Cadena de seguridad cerrada)" [9].

    ¿Con la puerta del piso 3 cerrada, el LED DFC del panel está encendido?
  TEXT

  test "FIELD_CHECK_OUTCOME gives the question the passage cited in its labelled check paragraph" do
    chunks = (1..10).map { |index| otis_chunk(index == 9 ? 121 : 20 + index, index == 9 ? "p1-123" : "p124-245", index - 1) }

    with_check_outcome_flag("true") do
      sources = BedrockRagService.allocate.send(:companion_publication_sources, chunks)
      stored = Rag::PendingQuestion.from_publication(ROUND4_T5, sources: sources)

      assert_equal "¿Con la puerta del piso 3 cerrada, el LED DFC del panel está encendido?", stored.fetch("question")
      target = stored.fetch("targets").sole
      assert_equal "MANUAL DE AYUDA TÉCNICA (p1-123)", target.fetch("item")
      assert_equal "chunk_p121_9.txt", target.fetch("filename")
      assert_equal "121", target.fetch("page")
      assert_equal "s3://bucket/bulk_uploads/3/MANUAL (p1-123).pdf", target.fetch("document_key")
    end
  end

  test "the labelled check paragraph is read only with the flag on, and only that paragraph" do
    sources = (1..10).map { |index| { "document" => "Manual #{index}", "index" => index } }

    with_check_outcome_flag(nil) do
      assert_empty Rag::PendingQuestion.from_publication(ROUND4_T5, sources: sources).fetch("targets"), "flag off keeps targets []"
    end

    with_check_outcome_flag("true") do
      unlabeled = ROUND4_T5.sub("Siguiente comprobación (DFC): Según", "Según")
      assert_empty Rag::PendingQuestion.from_publication(unlabeled, sources: sources).fetch("targets"),
                   "a paragraph without the check label backs nothing"

      far = ROUND4_T5.sub("\n\n¿Con la puerta", "\n\nLectura aparte sin cita.\n\n¿Con la puerta")
      assert_empty Rag::PendingQuestion.from_publication(far, sources: sources).fetch("targets"),
                   "only the paragraph right above the question counts"

      own = ROUND4_T5.sub("encendido?", "encendido? Según [2], DFC indica puertas cerradas.")
      assert_equal [ "Manual 2" ], Rag::PendingQuestion.from_publication(own, sources: sources).fetch("targets").pluck("item"),
                   "a citation in the question's own paragraph wins"
    end
  end

  private

  def otis_chunk(page, part, index)
    {
      "content" => "DFC ● Puertas completamente cerradas (Cadena de seguridad cerrada)", "identity_applicability" => "compatible",
      "location_uri" => "s3://bucket/bulk_chunks/3/#{part}/chunk_p#{page}_#{index + 1}.txt",
      "metadata" => { "canonical_name" => "MANUAL DE AYUDA TÉCNICA (#{part})", "page_number" => page.to_f,
                      "original_source_uri" => "s3://bucket/bulk_uploads/3/MANUAL (#{part}).pdf" }
    }
  end

  def documented_question(text)
    Rag::PendingQuestion.coerce(
      "type" => "documented_context",
      "question" => text,
      "targets" => entry_target
    )
  end

  def entry_question
    "¿Está activada la entrada A?"
  end

  def indicator_question
    "¿Cuál indicador está encendido, X o Y?"
  end

  def entry_target
    [ { "item" => "Conjunto.", "document_key" => "doc", "filename" => "p12.txt", "page" => "12" } ]
  end

  def indicator_targets
    [
      { "item" => "Indicador X.", "document_key" => "doc", "filename" => "p7.txt", "page" => "7" },
      { "item" => "Indicador Y.", "document_key" => "doc", "filename" => "p7.txt", "page" => "7" }
    ]
  end

  def open_question
    Rag::PendingQuestion.coerce(
      "type" => "documented_context", "question" => entry_question, "targets" => entry_target
    )
  end

  def held_question
    open_question.merge("shown" => { "question" => indicator_question, "targets" => indicator_targets })
  end

  def publication(presented, history, route_outcome: :answered, companion_reason: nil)
    RagQueryConcern::CompanionPublication.new(
      presented: presented, history: history, route_outcome: route_outcome, companion_reason: companion_reason
    )
  end

  def with_check_outcome_flag(value)
    previous = ENV["FIELD_CHECK_OUTCOME"]
    value.nil? ? ENV.delete("FIELD_CHECK_OUTCOME") : ENV["FIELD_CHECK_OUTCOME"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("FIELD_CHECK_OUTCOME") : ENV["FIELD_CHECK_OUTCOME"] = previous
  end

  def episode_state
    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: NOW)
    episode.assign_goal!("ruido al abrir", correlation_id: "query:open")
    episode.to_h
  end
end
