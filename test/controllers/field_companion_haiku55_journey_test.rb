# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/haiku55_journey_rubric")

# Authenticated HTTP replay of the twelve Opus turns. External calls are the
# captured interpreter tool, the captured Retrieve bodies, and the captured
# generator text. Focus, the Retrieve query, the evidence, and the published
# answer are the product path.
class FieldCompanionHaiku55JourneyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper
  include ActionCable::TestHelper

  FIXTURES = "test/fixtures/files/field_companion/haiku55_journeys"
  SCRIPTS = {
    "guion2" => {
      "capture" => "#{FIXTURES}/guion2",
      "uid" => "126cda62-64ad-4469-8674-a29f12e38d48",
      "name" => "VF5",
      "key" => "bulk_uploads/1/2026-08-31/VF5.pdf"
    },
    "guion1" => {
      "capture" => "#{FIXTURES}/guion1",
      "uid" => "126cda62-64ad-4469-8674-a29f12e38d48",
      "name" => "VF5",
      "key" => "bulk_uploads/1/2026-08-31/VF5.pdf"
    },
    "elemont" => {
      "capture" => "#{FIXTURES}/elemont",
      "uid" => "dcc8e046-037d-48a6-8913-1992aed28507",
      "name" => "Elemont Montacargas Hidraulico Modelo MH",
      "key" => "bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf"
    }
  }.freeze

  DECISIVE = {
    "guion2" => { "turn" => 1, "suffix" => "chunk_p8_1.txt", "page" => 8, "sha256" => "e97501793af4cc7eb41e7417e4e1de415a770c83a11a90bbdf2b9e66d6d858bb" },
    "elemont" => { "turn" => 1, "suffix" => "chunk_p5_1.txt", "page" => 5, "sha256" => "a13141fe7586c9013d698aa29f2b6809f112702e98f4da99d9a47c3ba01d7779" }
  }.freeze

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @user.update!(account: @account)
    sign_in @user
    @env = %w[
      HAIKU_QUERY_ANALYSIS_MODE FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED
      RAG_COMPANION_TURN DOCUMENT_IDENTITY_SCOPE_ENABLED RAG_EPISODE_SCOPE_ENABLED BEDROCK_KNOWLEDGE_BASE_ID
      RAG_COMPANION_GENERATION BEDROCK_INFERENCE RAG_VALIDATION_CAPTURE_RUN
      RAG_VALIDATION_CAPTURE_ACCOUNT_IDS COMPANION_DIRECT_EFFORT COMPANION_DIRECT_THINKING
      COMPANION_DIRECT_MAX_TOKENS COMPANION_DIRECT_MODEL_ID COMPANION_DIRECT_PROVIDER
      ANTHROPIC_API_KEY SHOW_RAG_SOURCES RAG_TRANSIENT_ATTEMPT_LIMIT
    ].index_with { |key| ENV[key] }
    ENV["ANTHROPIC_API_KEY"] = "offline-replay"
    ENV["SHOW_RAG_SOURCES"] = "true"
    ENV.delete("HAIKU_QUERY_ANALYSIS_MODE")
    ENV.delete("FIELD_COMPANION_EPISODE_ENABLED")
    ENV.delete("FIELD_COMPANION_TURN_ENABLED")
    ENV.delete("RAG_COMPANION_TURN")
    ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    ENV.delete("RAG_EPISODE_SCOPE_ENABLED")
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "Y7RZWMFJSR"
    ENV.delete("RAG_COMPANION_GENERATION")
    ENV["BEDROCK_INFERENCE"] = "blocked"
    ENV.delete("COMPANION_DIRECT_EFFORT")
    ENV.delete("COMPANION_DIRECT_MODEL_ID")
    ENV.delete("COMPANION_DIRECT_PROVIDER")
    ENV.delete("COMPANION_DIRECT_MAX_TOKENS")
    ENV.delete("COMPANION_DIRECT_THINKING")
    Thread.current[:haiku55_block_net] = true
  end

  teardown do
    Thread.current[:haiku55_block_net] = nil
    @env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "guion 2 replays three turns through the pinned companion" do
    play("guion2")
  end

  test "guion 1 replays five turns and does not ask again for the contact the technician cannot check" do
    play("guion1")
  end

  test "elemont replays four turns on one episode" do
    play("elemont")
  end

  # A base-journey answer is the wrong answer once the variant changes the history.
  test "the variant rubric rejects the base answers where the history changed" do
    questions = load_turns(SCRIPTS.fetch("guion1")["capture"]).map(&:question)
    discarded = "Lo que ya comprobaste:\n- Fotocélula: no activada.\n- Pendiente: #54."
    still_open = "Con la fotocélula activándose durante el cierre, sigue abierta la causa: «Comprobar que la fotocélula no esté activada» [2]."
    unable = "Entendido: no te pido identificar #21 ni el contacto entre #21 y #23."
    engaged = "La fuente indica que la señal se activa al «conectar la entrada re-apertura (21) con la entrada de +12V (23)» [11]."

    assert_equal [ "variant:photocell_discarded" ], Haiku55JourneyRubric.reasons("guion1_photocell_active", 4, discarded, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1_photocell_active", 4, still_open, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1_photocell_active", 4,
      "**Comprobado:** la fotocélula se activa durante el cierre.\n- Si la fotocélula sigue activa con el haz libre.", questions)
    assert_equal [ "variant:photocell_discarded" ],
      Haiku55JourneyRubric.reasons("guion1_photocell_active", 4, "Con la fotocélula libre, esa entrada es la candidata principal.", questions)
    assert_equal %w[variant:contact_not_engaged variant:treated_as_unable],
      Haiku55JourneyRubric.reasons("guion1_can_measure", 5, unable, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1_can_measure", 5, engaged, questions)
  end

  # live4 turn 2: the interpreter sent the negate span the reference omitted.
  test "elemont keeps the correction when the interpreter negates the earlier component itself" do
    play("elemont", tool_inputs: {
      2 => {
        "move" => "correct",
        "assertions" => [
          { "span" => "Chapa nivel 3", "act" => "assert", "slot_hint" => "designator" },
          { "span" => "Chapa nivel 2", "act" => "negate", "slot_hint" => "designator" }
        ],
        "observations" => [], "pending_resolution" => nil, "clarification_target" => nil
      }
    })
  end

  # Opening sentences of live3, live5 and live4 G1-T5.
  test "guion 1 turn 5 accepts the stated limit and rejects the contact sent back as an inspection" do
    questions = load_turns(SCRIPTS.fetch("guion1")["capture"]).map(&:question)
    method_limit = "No puedo darte un método para comprobar #21 ni el contacto #21–#23, porque la documentación cargada no lo trae."
    technician_limit = "Entendido: no te pido identificar #21 ni el contacto entre #21 y #23."
    inspection = "No necesitas medir #21 ni el contacto #21–#23 para seguir. Puedes mirar si hay algo conectado a esos bornes. " \
      "No puedes identificar si #21 está activada ni verificar el contacto #21–#23."
    silent = "Revisa el potenciómetro #54 y vuelve a probar el cierre."

    assert_empty Haiku55JourneyRubric.reasons("guion1", 5, method_limit, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1", 5, technician_limit, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1", 5,
      "No puedo darte otra forma de verificar #21 con la documentación cargada, así que no te lo pediré de nuevo.", questions)
    assert_equal [ "t5:reasks_contact" ], Haiku55JourneyRubric.reasons("guion1", 5, inspection, questions)
    assert_includes Haiku55JourneyRubric.reasons("guion1", 5, silent, questions), "t5:limit_not_acknowledged"
  end

  REVISION_FIXTURES = "test/fixtures/files/field_companion/companion_revision"
  REVISION_DOCS = {
    cea: [ "9a4fa817-b9e8-4a9e-ae83-526c0731e603", "manual-cea15p.pdf", "manual-cea15p" ],
    fallas: [ "85590ab2-d2b2-49b2-a36d-0c8c50f9bd76", "Monarch nice 3000 fallas-1.pdf", "Monarch nice 3000 fallas-1" ],
    monarch: [ "6e578b57-0f5e-42f0-91d6-4dd908e0eba2", "Manual_monarch_Español_3000+.pdf", "Manual_monarch_Español_3000+" ]
  }.freeze
  test "guion 1 turn 5 credits the limit in the full published answer" do
    questions = load_turns(SCRIPTS.fetch("guion1")["capture"]).map(&:question)
    published = Rails.root.join(REVISION_FIXTURES, "guion1_c8e9cbf_t5_published.txt").read
    clauses = published.split(/(?<=\.)[ \t]+|\n+/)
    dispensations, rest = clauses.partition { |clause| clause.start_with?("No necesitas identificar") }
    reports, omitted = rest.partition { |clause| clause.start_with?("No puede identificar") }

    assert_equal 1, dispensations.size
    assert_equal 1, reports.size
    dispensed = (dispensations + omitted).join("\n")
    recognized = (reports + omitted).join("\n")
    # T5_LIMIT, technician_limitation, and method_limit do not read the
    # dispensation as the technician's limit. The final reasons stay on
    # the terminal clause.

    assert_empty Haiku55JourneyRubric.reasons("guion1", 5, published, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1", 5, recognized, questions)
    assert_equal [ "t5:limit_not_acknowledged" ],
      Haiku55JourneyRubric.reasons("guion1", 5, dispensed, questions)
    assert_equal [ "t5:limit_not_acknowledged" ],
      Haiku55JourneyRubric.reasons("guion1", 5, omitted.join("\n"), questions)
    assert_equal [ "t5:limit_not_acknowledged" ],
      Haiku55JourneyRubric.reasons("guion1", 5, "No puede identificar el LED. #{omitted.join("\n")}", questions)
  end

  CEA_QUESTION = "La puerta de piso no traba. Hay patín retráctil. ¿Qué tiene que cumplirse para que la seguridad automática SA quede en 1?"
  # Manual DD549-R05, PDF p. 24. Production exited before Retrieve, so
  # the SDK row and the generation here are synthetic, not captured traffic.
  CEA_PASSAGE = %q("Seguridad Automática" o SA debe ser "1" sólo si los mandos de patín retráctil ordenados por el controlador - después que las puertas están cerradas - se ejecutaron completamente.)

  test "the replay maps captured paths to the test bucket without merging document identities" do
    focus = "s3://offline-kb/manuals/selected.pdf"
    row = {
      "uri" => "s3://multimodal-source-destination/chunks/other.txt",
      "original_source_uri" => "s3://multimodal-source-destination/manuals/other.pdf",
      "content" => "Captured passage."
    }

    result = Retrieved.new(row, @account.id, focus)

    assert_equal "s3://offline-kb/chunks/other.txt", result.location.s3_location.uri
    assert_equal "s3://offline-kb/manuals/other.pdf", result.metadata.fetch("original_source_uri")
    assert_equal row.fetch("content"), result.content.text

    foreign = "s3://another-bucket/manuals/other.pdf"
    result = Retrieved.new(row.merge("original_source_uri" => foreign), @account.id, focus)
    assert_equal foreign, result.metadata.fetch("original_source_uri")
  end

  test "revision CEA pin retrieves and saves a nameplate question, then uses the reported label" do
    check_cea_followup("Leo CEA15+ en el rótulo de la placa.", "value", "known")
  end

  test "revision CEA with another reported plate names the mismatch and does not teach the pinned manual" do
    document = revision_pin(:cea)
    revision_ask("cea-other", 1, cea_turn(CEA_QUESTION, document), document)
    turn = cea_turn("Leo CEA20 en el rótulo de la placa.", document, move: "answer_pending", resolution: "value")
    turn.tool_input["assertions"] = [ { "span" => "CEA20", "act" => "assert", "slot_hint" => "controller" } ]
    [ turn, cea_turn(CEA_SCRIPT[1], document, move: "follow_up") ].each.with_index(2) do |entry, number|
      body, cassette = revision_ask("cea-other", number, entry, document)
      assert_revision_scope(cassette, document)
      assert_equal 0, cassette.sent.count { |payload| !payload[:tool_choice] }
      assert_equal I18n.t("rag.controller_plate_mismatch", locale: :es, reported: "CEA20", documented: "CEA15+"), body.fetch("answer")
      assert_empty body.fetch("citations")
      assert_equal [ document.id ], reloaded_session.focus_document_ids
    end
    assert_equal({ "value" => "CEA20", "status" => "known", "source" => "user" },
      reloaded_session.active_episode.dig("facts", "controller").slice("value", "status", "source"))
  end

  CEA_VALUES = %q(Una serie de seguridad es "1" si la tensión en el terminal correspondiente es 24 Vcc, o "0" si la tensión en el terminal correspondiente es 0 Vcc.)

  # Shapes of the live Haiku 5.5 answers (0a5033c, cea1) that the full
  # unconfirmed-identity guard withheld as "no evidence".
  test "revision CEA with the plate pending publishes the documented values and drops the uncited configuration sentence" do
    document = revision_pin(:cea)
    revision_ask("cea-values", 1, cea_turn(CEA_QUESTION, document), document)
    raw = %(Según la fuente, 24 Vcc es "1" y 0 Vcc es "0". «#{CEA_VALUES.delete_suffix('.')}» [2].\n\nMi lectura: en esa configuración, la serie SA queda en 0.)
    body, cassette = revision_ask("cea-values", 2, cea_turn(CEA_SCRIPT[2], document, passage: CEA_VALUES, raw: raw, move: "follow_up"), document)
    assert_revision_scope(cassette, document)
    answer = body.fetch("answer")
    assert_match(/24 Vcc.*0 Vcc/m, answer)
    assert_no_match(/Mi lectura|no encontr/i, answer)
    assert_includes answer, I18n.t("rag.controller_reference_boundary", locale: :es)
    assert_equal [ 24 ], body.fetch("citations").pluck("page")
  end

  test "revision CEA with the plate confirmed as the pinned manual keeps the documented configuration" do
    document = revision_pin(:cea)
    revision_ask("cea-confirmed", 1, cea_turn(CEA_QUESTION, document), document)
    raw = "#{cea_reference}\n\nEn esa configuración, SA queda en 1 cuando el patín retráctil terminó su mando."
    turn = cea_turn("Leo CEA15+ en el rótulo de la placa.", document, raw: raw, move: "answer_pending", resolution: "value")
    body, cassette = revision_ask("cea-confirmed", 2, turn, document)
    assert_revision_scope(cassette, document)
    assert_includes body.fetch("answer"), "En esa configuración, SA queda en 1"
    assert_equal [ 24 ], body.fetch("citations").pluck("page")
  end

  test "revision CEA with the plate pending and an identity assertion publishes the withheld reference, not a missing-evidence claim" do
    document = revision_pin(:cea)
    raw = "Tu equipo es un CEA15+. En el manual CEA15+: «#{CEA_PASSAGE.delete_suffix('.')}» [1]."
    body, cassette = revision_ask("cea-withheld", 1, cea_turn(CEA_QUESTION, document, raw: raw), document)
    assert_revision_scope(cassette, document)
    answer = body.fetch("answer")
    assert answer.start_with?(I18n.t("rag.unconfirmed_reference_withheld", locale: :es, references: "|").split("|").first.strip), answer
    assert_no_match(/no encontr|Tu equipo es/i, answer)
    assert_empty body.fetch("citations")
    assert_equal [ document.id ], reloaded_session.focus_document_ids
  end

  test "revision CEA keeps the pin when the technician cannot see the label" do
    check_cea_followup("No puedo ver el rótulo.", "unknown", "unknown_confirmed")
  end

  test "revision CEA records the unseen label when the interpreter adds a note and a null key outside the schema" do
    check_cea_followup("No puedo ver el rótulo.", "unknown", "unknown_confirmed",
      extra: { "pending_resolution_note" => "unknown", "pending" => nil })
  end

  test "revision CEA explicit reference, empty, insufficient, failed and foreign results never open the pin or use the Bedrock generator" do
    ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = "1"
    document = revision_pin(:cea)
    [
      [ "¿Qué dice el manual sobre la Seguridad Automática SA y el patín retráctil?", CEA_PASSAGE, cea_reference ],
      [ CEA_QUESTION, nil, "" ],
      [ CEA_QUESTION, "Fin de Puerta Abierta. El uso de FPA es opcional.", "Esto no está en la documentación cargada en este turno." ],
      [ CEA_QUESTION, CEA_PASSAGE, "" ],
      [ CEA_QUESTION, CEA_PASSAGE, :timeout ],
      [ CEA_QUESTION, :foreign, cea_reference ]
    ].each_with_index do |(question, passage, raw), index|
      turn = if passage == :foreign
        cea_turn(question, document).tap do |entry|
          foreign = "s3://#{KbDocument::KB_BUCKET}/bulk_uploads/1/2026-08-31/VF5.pdf"
          entry.rows.each { |row| row.merge!("uri" => foreign, "original_source_uri" => foreign, "document" => "VF5") }
        end
      else
        cea_turn(question, document, passage: passage, raw: raw)
      end
      body, cassette = revision_ask("cea-evidence", index + 1, turn, document)
      assert_revision_scope(cassette, document)
      assert_equal question, cassette.queries.last if cassette.filters.size == 2
      assert_equal [ document.id ], reloaded_session.focus_document_ids
      assert_no_match(/servicio no está disponible/i, body.fetch("answer"))
      if index.zero?
        assert_equal [ 24 ], body.fetch("citations").pluck("page")
      else
        assert_empty body.fetch("citations"), "case #{index + 1}"
        assert_match(/no (encontr|está)|evidencia/i, body.fetch("answer"), "case #{index + 1}")
      end
    end
  end

  CEA_SCRIPT = [
    CEA_QUESTION,
    "¿Qué son los terminales SM, SPC y SA en la serie de seguridad de puertas?",
    "Si mido un terminal de la serie de seguridad, ¿qué tensión es un 1 y qué tensión es un 0?",
    "No hay contactos que cierren por el patín retráctil. ¿Cómo se conecta SA?",
    "La puerta de cabina es manual y la de piso es manual, con doble contacto y traba por patín. ¿Qué contactos van en SM y cuáles en SA?",
    "La bobina del patín retráctil mete interferencia. ¿Qué hay que instalar en paralelo con esa bobina?",
    "¿El contacto del operador de puerta automática entra en la serie SM?"
  ].freeze
  # Manual DD549-R05, PDF p. 19, chunk_p19_2 (capacitive coupling).
  CEA_ARC_PASSAGE = "Se debe instalar un supresor de arco en cada componente del sistema capaz de producir interferencia capacitiva, " \
    "incluyendo las bobinas de contactores, las bobinas de relés auxiliares, la bobina del patín retráctil electromagnético, la bobina del freno. " \
    "El supresor de arco se debería conectar en paralelo con el elemento que genera la interferencia, esto es, el que almacena la energía."
  CEA_ARC_ANSWER = "El manual indica que «el supresor de arco se debería conectar en paralelo con el elemento que genera la interferencia» [2]."
  CEA_LEVEL_PASSAGE = "Una serie de seguridad es \"1\" si la tensión en el terminal correspondiente es 24 Vcc, " \
    "o \"0\" si la tensión en el terminal correspondiente es 0 Vcc."
  CEA_LEVEL_ANSWER = "Según la fuente, una serie es \"1\" «si la tensión en el terminal correspondiente es 24 Vcc» " \
    "y es \"0\" «si la tensión en el terminal correspondiente es 0 Vcc» [2]."

  # live final5 CEA-T6: the composed query ranked p. 19 13th of 16.
  test "the reference route orders sixteen candidates by the technician turn and keeps three" do
    document = revision_pin(:cea)
    pages = {
      20 => "En paralelo con la bobina del patín retráctil se puede conectar un rectificador rueda libre con resistencia serie para disminuir el retardo en la caída.",
      26 => "Los contactos de precierre de las puertas de piso se incluyen en SM.",
      27 => "Los contactos de traba de las puertas de piso se incluyen en SA.",
      19 => CEA_ARC_PASSAGE
    }
    rows = pages.map do |page, content|
      { "content" => content, "uri" => document.canonical_uri, "original_source_uri" => document.canonical_uri,
        "document" => "CEA15+", "page" => page, "score" => 0.5 }
    end
    order = [ CEA_ARC_PASSAGE, pages[20] ].map { |text| Digest::SHA256.hexdigest(text) }
    turn = TurnCapture.new({
      "question" => CEA_SCRIPT[5], "retrieve_query" => CEA_SCRIPT[5],
      "tool_input" => { "move" => "report", "assertions" => [], "observations" => [], "pending_resolution" => nil, "clarification_target" => nil },
      "generator_text" => CEA_ARC_ANSWER.sub("[2]", "[1]"), "rows" => rows, "rerank_sha256" => order
    })

    body, cassette = revision_ask("cea-rerank", 1, turn, document)
    generator = cassette.sent.reject { |payload| payload[:tool_choice] }.sole
    prompt = Array(generator[:messages]).last[:content].map { |block| block[:text].to_s }.join

    assert_equal [ 16 ], cassette.sizes
    assert_equal [ 19 ], body.fetch("citations").pluck("page")
    assert_includes prompt, CEA_ARC_PASSAGE
    assert_includes prompt, pages[20]
    assert_includes prompt, pages[26]
    assert_not_includes prompt, pages[27]
  end

  # live cand4 CEA-T6: the composed query did not return p. 19 in 16 or 20;
  # the technician's turn alone ranked it 2nd.
  test "the reference route adds the technician turn's candidates when the composed query misses them" do
    document = revision_pin(:cea)
    revision_ask("cea-turn-retrieve", 1, cea_turn(CEA_QUESTION, document), document)
    pages = {
      20 => "En paralelo con la bobina del patín retráctil se puede conectar un rectificador rueda libre con resistencia serie para disminuir el retardo en la caída.",
      26 => "Los contactos de precierre de las puertas de piso se incluyen en SM.",
      27 => "Los contactos de traba de las puertas de piso se incluyen en SA.",
      19 => CEA_ARC_PASSAGE
    }
    rows = pages.map do |page, content|
      row = { "content" => content, "uri" => "s3://#{KbDocument::KB_BUCKET}/bulk_chunks/1/cea/chunk_p#{page}_1.txt",
              "original_source_uri" => document.canonical_uri, "document" => "CEA15+", "page" => page, "score" => 0.5 }
      page == 19 ? row.merge("for_query" => CEA_SCRIPT[5]) : row
    end
    turn = TurnCapture.new({
      "question" => CEA_SCRIPT[5], "retrieve_query" => CEA_SCRIPT[5],
      "tool_input" => { "move" => "follow_up", "assertions" => [], "observations" => [ "La bobina del patín retráctil mete interferencia." ],
                        "pending_resolution" => nil, "clarification_target" => nil },
      "generator_text" => CEA_ARC_ANSWER, "rows" => rows,
      "rerank_sha256" => [ CEA_ARC_PASSAGE, pages[20] ].map { |text| Digest::SHA256.hexdigest(text) }
    })

    body, cassette = revision_ask("cea-turn-retrieve", 2, turn, document)

    assert_equal [ 16, 16 ], cassette.sizes
    assert_not_equal CEA_SCRIPT[5], cassette.queries.first
    assert_equal CEA_SCRIPT[5], cassette.queries.last
    assert_equal [ 3, 4 ], cassette.returned.map(&:size)
    assert_equal [ 19 ], body.fetch("citations").pluck("page")

    failing = TurnCapture.new({
      "question" => CEA_SCRIPT[6], "retrieve_query" => CEA_SCRIPT[6], "retrieve_failure" => CEA_SCRIPT[6],
      "tool_input" => { "move" => "follow_up", "assertions" => [], "observations" => [], "pending_resolution" => nil, "clarification_target" => nil },
      "generator_text" => cea_reference, "rows" => rows.first(1)
    })
    body, cassette = revision_ask("cea-turn-retrieve", 3, failing, document)

    assert_equal [ 16, 16 ], cassette.sizes
    assert_equal 1, cassette.sent.count { |payload| !payload[:tool_choice] }
    assert_no_match(/servicio no está disponible/i, body.fetch("answer"))
  end

  # final5 CEA-T6 and G1-T2, published text.
  test "the rubric judges CEA T6 by the interference purpose and accepts an explicit LED correction" do
    rectifier = "Según la fuente, en paralelo con la bobina del patín retráctil se puede conectar un rectificador «rueda libre» " \
      "con resistencia serie, «para disminuir el retardo en la caída» [4].\n\n" \
      "La fuente presenta ese componente para reducir el retardo en la caída, no como solución de interferencia."
    suppressor = "Para la interferencia, el manual indica un supresor de arco en paralelo con la bobina del patín retráctil [2]. " \
      "El rectificador «rueda libre» de la p. 20 es para disminuir el retardo en la caída."

    assert_equal [ "cea:t6_no_arc_suppressor" ], Haiku55JourneyRubric.reasons("cea", 6, rectifier, CEA_SCRIPT)
    assert_equal %w[cea:t6_no_arc_suppressor cea:t6_rectifier_as_interference_fix],
      Haiku55JourneyRubric.reasons("cea", 6, "Instala un rectificador «rueda libre» en paralelo [4].", CEA_SCRIPT)
    assert_empty Haiku55JourneyRubric.reasons("cea", 6, suppressor, CEA_SCRIPT)
    assert_empty Haiku55JourneyRubric.reasons("cea", 5, rectifier, CEA_SCRIPT)
    assert_equal [ "cea:t3_no_levels" ],
      Haiku55JourneyRubric.reasons("cea", 3, "Cada serie es «la serie lógica (AND) de llaves de seguridad» [6].", CEA_SCRIPT)
    assert_empty Haiku55JourneyRubric.reasons("cea", 3, "Según la fuente, 24 Vcc es un 1 y 0 Vcc es un 0 [1].", CEA_SCRIPT)
    assert_equal [ "cea:t7_operator_in_sm" ],
      Haiku55JourneyRubric.reasons("cea", 7, "Sí, según la fuente el contacto de precierre va en SM.", CEA_SCRIPT)
    assert_empty Haiku55JourneyRubric.reasons("cea", 7, "No. La fuente dice que SM «NO incluye los contactos por acción de operador» [5].", CEA_SCRIPT)

    questions = load_turns(SCRIPTS.fetch("guion1")["capture"]).map(&:question)
    corrected = "Corrijo mi mensaje anterior, que partía de un LED apagado. Con el LED encendido, la entrada está activa."
    assert_empty Haiku55JourneyRubric.reasons("guion1", 2, corrected, questions)
    assert_equal [ "t2:keeps_off" ],
      Haiku55JourneyRubric.reasons("guion1", 2, "Corrijo el paso anterior. Con el LED apagado, revisa la entrada.", questions)
  end

  # Original CEA15+ script. The passage and generations are synthetic; the
  # route, filter, episode, pending question and publication are the product.
  test "revision CEA original script stays on the pin, asks the label once and never enters the Bedrock generator" do
    document = revision_pin(:cea)
    episode = nil
    asked = CEA_SCRIPT.each_with_index.map do |question, index|
      move = index.zero? ? "report" : "follow_up"
      turn = case index
      when 2 then cea_turn(question, document, passage: CEA_LEVEL_PASSAGE, raw: CEA_LEVEL_ANSWER, move: move, page: 22)
      when 5 then cea_turn(question, document, passage: CEA_ARC_PASSAGE, raw: CEA_ARC_ANSWER, move: move, page: 19)
      else cea_turn(question, document, move: move)
      end
      body, cassette = revision_ask("cea-script", index + 1, turn, document)
      assert_revision_scope(cassette, document)
      assert_equal 1, cassette.sent.count { |payload| !payload[:tool_choice] }, "T#{index + 1}"
      assert_equal [ { 2 => 22, 5 => 19 }.fetch(index, 24) ], body.fetch("citations").pluck("page"), "T#{index + 1}"
      assert_equal [ document.id ], reloaded_session.focus_document_ids
      episode ||= reloaded_session.live_episode_id
      assert_equal episode, reloaded_session.live_episode_id
      assert_empty Haiku55JourneyRubric.reasons("cea", index + 1, body.fetch("answer"), CEA_SCRIPT)
      body.fetch("answer").include?(I18n.t("rag.controller_label_question", locale: :es))
    end
    assert_equal [ true, false, false, false, false, false, false ], asked
  end

  test "CEA captured T2 T3 and T5 publish documentary evidence through HTTP" do
    document = revision_pin(:cea)
    fixture = JSON.parse(Rails.root.join(REVISION_FIXTURES, "cea_reference_failures.json").read)
    revision_ask("cea-captured-repair", 1, cea_turn(CEA_QUESTION, document), document)
    episode = reloaded_session.live_episode_id

    [2, 3, 5].each do |number|
      captured = fixture.fetch(number.to_s)
      question = captured.fetch("question")
      rows = captured.fetch("rows").map do |row|
        row.merge("uri" => "s3://#{KbDocument::KB_BUCKET}/bulk_chunks/1/cea/chunk_p#{row.fetch('page')}_1.txt",
          "original_source_uri" => document.canonical_uri, "document" => "CEA15+", "score" => 0.9)
      end
      turn = TurnCapture.new("question" => question, "retrieve_query" => question,
        "tool_input" => cea_turn(question, document, move: "follow_up").tool_input,
        "rows" => rows, "generator_text" => captured.fetch("raw"))
      body, cassette = revision_ask("cea-captured-repair", number, turn, document)
      answer = body.fetch("answer")
      assert_revision_scope(cassette, document)
      assert_equal episode, reloaded_session.live_episode_id
      assert_empty Haiku55JourneyRubric.reasons("cea", number, answer, CEA_SCRIPT)
      assert_empty Haiku55JourneyRubric.cea_completion_reasons(number, answer, body.fetch("citations"))
      assert_includes answer, "terminal SPC" if number == 2
      assert_includes answer, "0 Vcc" if number == 3
      next unless number == 5

      assert_includes body.fetch("citations").pluck("page"), 25
      assert_includes answer, "Los contactos de traba de las puertas de piso se incluyen en SA"
      assert_match(/condicionada a confirmar el contacto de traba/i, answer)
      assert_includes answer, "¿El contacto de traba de la puerta de piso cierra por acción del patín retráctil?"
      refute_includes answer, "SA no iría a SPC"
    end
  end

  %w[elemont_first elemont_second].each do |name|
    test "revision #{name} resolves the same level and shows the two neighboring rows" do
      document = revision_pin(:elemont)
      responses = revision_turns(name).map.with_index { |turn, index| revision_ask(name, index + 1, turn, document) }
      body, cassette = responses.last
      assert_match(/nivel 3.*nivel 4.*nivel 2/m, body.fetch("answer"))
      assert_includes reloaded_session.active_episode.fetch("identifiers").pluck("value"), "Chapa nivel 3"
      assert_match(/nivel 3/i, cassette.queries.sole)
      assert_no_match(/Chapa nivel 2/i, cassette.queries.sole)
      source = body.fetch("citations").sole
      assert_match(/Elemont/i, source.fetch("title"))
      assert_equal 5, source.fetch("page")
      assert_match(/nivel 4.*nivel 3.*nivel 2/m, source.fetch("matched_excerpt"))
      assert_no_match(/FIELD_RECORD|DATA_NOT_AVAILABLE/, source.fetch("matched_excerpt"))
    end
  end

  test "revision Jesús keeps the equipment drawing and offers the named controller as an addition" do
    plan = revision_pin(:elemont)
    manual = revision_document(:cea)
    question = "Hola, tengo una falla eléctrica en un elevador hidráulico Elemont, con imanes y tarjeta Cea15"
    entry = cea_turn(question, plan, passage: "Los componentes se conectan en serie entre los nodos Seg In y Seg Out.",
      raw: "En el plano, «Los componentes se conectan en serie entre los nodos Seg In y Seg Out» [1].")
    entry.tool_input["assertions"] = [
      { "span" => "elevador hidráulico Elemont", "act" => "assert", "slot_hint" => "designator" },
      { "span" => "tarjeta Cea15", "act" => "assert", "slot_hint" => "controller" }
    ]
    entry.tool_input["observations"] = [ "falla eléctrica" ]
    first, first_cassette = revision_ask("jesus", 1, entry, plan)
    assert_revision_scope(first_cassette, plan)
    assert_match(/rótulo/i, first.fetch("answer"))
    assert_nil first["manual_suggestion"]&.fetch("cards", [])&.find { |card| card["kb_document_id"] == manual.id }
    episode = reloaded_session.live_episode_id

    confirmed = cea_turn("Leo CEA15+ en el rótulo de la placa.", plan, passage: "Los componentes se conectan en serie entre los nodos Seg In y Seg Out.",
      raw: "En el plano, «Los componentes se conectan en serie entre los nodos Seg In y Seg Out» [1].", move: "answer_pending", resolution: "value")
    second, second_cassette = revision_ask("jesus", 2, confirmed, plan)
    assert_revision_scope(second_cassette, plan)
    card = revision_card(second, manual)
    assert_equal "add", card.fetch("action")
    assert_match(/controlador/, card.fetch("text"))
    cid = second.fetch("manual_suggestion").fetch("correlation_id")
    assert_equal [ plan.id ], reloaded_session.focus_document_ids
    accept_revision_card(manual, "add", episode, cid)
    assert_equal [ plan.id, manual.id ].sort, reloaded_session.focus_document_ids.sort
    replay, cassette = revision_ask("jesus", 3, confirmed, plan, replay: cid)
    assert_equal true, replay.fetch("replayed")
    assert_revision_scope(cassette, plan, manual)
    assert_equal episode, reloaded_session.live_episode_id
    assert_equal 2, reloaded_session.conversation_history.count { |row| row["role"] == "user" }
  end

  test "revision G2 exposes the passage supporting the answer instead of field records" do
    document = revision_pin(:guion2)
    body, = revision_turns("g2").map.with_index { |turn, i| revision_ask("g2", i + 1, turn, document) }.last
    source = body.fetch("citations").find { |citation| citation["page"] == 8 }
    assert source
    assert_match(/VF5/, source.fetch("title"))
    assert_no_match(/chunk_/, source.fetch("title"))
    assert_match(/necesario realizar otra vez el autoajuste/i, source.fetch("matched_excerpt"))
    assert_no_match(/FIELD_RECORD|DATA_NOT_AVAILABLE/, source.fetch("matched_excerpt"))
  end

  test "revision G1 keeps the LED and persistence unconfirmed and respects the technician limit" do
    document = revision_pin(:guion1)
    replies = revision_turns("g1").map.with_index { |turn, i| revision_ask("g1", i + 1, turn, document).first.fetch("answer") }
    assert_no_match(/es la hipótesis que queda|lo que queda por revisar/i, replies[2])
    assert_no_match(/LED de FOTOCÉLULA \(o re-apertura\) está encendido/i, replies[3])
    assert_no_match(/posición de (?:SW4|DIP 4)|condición (?:aún )?no se cumple/i, replies[3..4].join)
    assert_match(/no (?:necesitas|puede)/i, replies.last)
    assert_match(/#54/, replies.last)
  end

  test "revision Monarch add replays the same message and does not turn sizing into a diagnostic threshold" do
    fallas = revision_pin(:fallas)
    extra = revision_document(:monarch)
    turns = revision_turns("monarch_add")
    initial, = revision_ask("monarch_add", 1, turns.first, fallas)
    episode = reloaded_session.live_episode_id
    cid = reloaded_session.conversation_history.find { |row| row["role"] == "user" }.fetch("correlation_id")
    assert_equal [ fallas.id ], reloaded_session.focus_document_ids
    card = revision_card(initial, extra)
    assert_equal "add", card.fetch("action")
    accept_revision_card(extra, card.fetch("action"), episode, cid)
    assert_equal [ fallas.id, extra.id ].sort, reloaded_session.focus_document_ids.sort
    replay, replay_cassette = revision_ask("monarch_add", 2, turns[1], fallas, replay: cid)
    assert_equal true, replay.fetch("replayed")
    assert_includes replay_cassette.queries.sole, turns.first.question
    assert_equal 1, reloaded_session.conversation_history.count { |row| row["role"] == "user" }
    body, cassette = revision_ask("monarch_add", 3, turns[2], fallas)
    assert_revision_scope(cassette, fallas, extra)
    assert_equal episode, reloaded_session.live_episode_id
    assert_match(/filtro/i, body.fetch("answer"))
    assert_no_match(/temperatura ambiente es menos probable|dentro del rango de operación/i, body.fetch("answer"))
    source = body.fetch("citations").find { |citation| citation["page"] == 2 && citation["title"].include?("fallas") }
    assert source, body.fetch("citations").inspect
    assert_match(/grietas|vibración/i, source.fetch("matched_excerpt"))
    assert_no_match(/vida útil|FIELD_RECORD|DATA_NOT_AVAILABLE/i, source.fetch("matched_excerpt"))
  end

  test "revision Monarch with only the faults manual keeps the blocked filter as evidence" do
    fallas = revision_pin(:fallas)
    episode = nil
    body, cassette = revision_turns("monarch_single").map.with_index do |turn, index|
      response = revision_ask("monarch_single", index + 1, turn, fallas)
      episode ||= reloaded_session.live_episode_id
      assert_equal episode, reloaded_session.live_episode_id
      response
    end.last
    assert_revision_scope(cassette, fallas)
    assert_match(/filtro de aire est[aá] bloqueado/i, body.fetch("answer"))
    assert_no_match(/temperatura ambiente es menos probable|dentro del rango de operación/i, body.fetch("answer"))
    assert body.fetch("citations").any? { |source| source["page"] == 8 && source["matched_excerpt"].match?(/filtro/) }
  end

  test "revision component focus replacement rejects a stale click and excludes the replaced ledger sources" do
    fallas = revision_pin(:fallas)
    extra = revision_document(:monarch)
    turns = revision_turns("monarch_add")
    initial, = revision_ask("monarch_replace", 1, turns.first, fallas)
    episode = reloaded_session.live_episode_id
    cid = reloaded_session.conversation_history.find { |row| row["role"] == "user" }.fetch("correlation_id")
    accept_revision_card(extra, "replace", "stale_episode", cid, status: :unprocessable_entity)
    assert_equal [ fallas.id ], reloaded_session.focus_document_ids
    accept_revision_card(extra, "replace", episode, cid)
    assert_equal [ extra.id ], reloaded_session.focus_document_ids
    _, cassette = revision_ask("monarch_replace", 2, turns[1], extra, replay: cid)
    assert_equal episode, reloaded_session.live_episode_id
    generator = cassette.sent.find { |payload| !payload[:tool_choice] }
    assert generator
    assert_not_includes generator.fetch(:messages).last.to_json, "El filtro de aire está bloqueado"
    assert_revision_scope(cassette, extra)
  end

  %w[control unsafe installation same_sentence negation exact_minimum explicit_target plain_emphasis haiku_exact comparison_first].each do |scenario|
    test "Thyssen KP-VS #{scenario} keeps the cited floor and the engineering review" do
      play_thyssen_kpvs(scenario)
    end
  end

  AUDIT_ROOT = Rails.root.join("test/fixtures/field_companion/audit_20261113")
  AUDIT_JOURNEYS = JSON.parse(AUDIT_ROOT.join("journeys.json").read).freeze
  AUDIT_PRODUCTION = JSON.parse(AUDIT_ROOT.join("production.json").read).freeze
  EA_LINE = "Quando falha de P28 - porta aberta - revisar linha dos trincos"
  P28_LINE = "Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada"
  NOISE_LINE = 'En caso de ruido audible muy elevado: disminuya el valor del parámetro "KP-VS", hasta el mínimo de [3,0]'

  test "audit Thyssen photo carries the accepted reading and current question through the worker and follow-ups" do
    play_audit_photo("photo", AUDIT_JOURNEYS.fetch("photo"))
  end

  test "audit Thyssen photo caps real worker and HTTP provider boundaries offline" do
    with_guarded_thyssen_photo do |haiku_spend, vision_spend|
      play_audit_photo("photo", AUDIT_JOURNEYS.fetch("photo"))
      assert_equal 8, haiku_spend.snapshot.fetch("attempts")
      assert_equal 1, vision_spend.snapshot.fetch("attempts")
      assert_equal "settled", vision_spend.snapshot.fetch("entries").sole.fetch("status")
    end
  end

  test "photo codes from the real uncertain reading reach generation without suggesting a diagnosis" do
    @audit_photo_reading = JSON.parse(AUDIT_ROOT.join("photo_sonnet_live.json").read)
    play_audit_photo("photo-live-reading", AUDIT_JOURNEYS.fetch("photo"))
  end

  test "photo keeps its observed labels and the manually sourced passage on the EA follow-up" do
    document = audit_thyssen_pin
    @audit_photo_reading = JSON.parse(AUDIT_ROOT.join("photo_sonnet_live.json").read)
    opening = "Estoy con un Thyssen FDN Universal con MCINV4. Está detenido y la puerta no cierra. Te adjunto el esquema de la bornera."
    opening_reply = "Si el código es EA, «#{EA_LINE}» [p24]. En el esquema se ven P26, P27 y P28. El manual describe P28 como «sinal do contato de engate do trinco» [p9]. ¿Qué código aparece?"
    turn = audit_thyssen_turn(document, opening, opening_reply, pages: %w[24_1 9_3],
      observations: [ "Está detenido", "la puerta no cierra" ], opening: true)
    opening_body, = audit_photo_post("photo-source-carry", turn, document)
    original_episode = reloaded_session.live_episode_id
    assert_includes opening_body.fetch("answer"), "sinal do contato de engate do trinco"

    question = "El display marca EA."
    followup = audit_thyssen_turn(document, question,
      "EA es falla de señales. «#{EA_LINE}» [p24]. ¿La conexión de P28 en la bornera está firme?",
      pages: %w[24_1], observations: [ question.delete_suffix(".") ], move: "follow_up")
    body, cassette = revision_ask("audit-photo-source-carry", 2, followup, document)
    prompt = audit_generator_prompt(cassette)
    assert_includes prompt, question
    visual = Rag::ActivePhotoContext.generation_evidence(prompt)
    %w[P26 P27 P28].each { |label| assert_match(/\b#{label}\b/, visual) }
    assert_includes prompt, "RA-53 / P28 = +110 Vcc"
    assert_includes prompt, EA_LINE
    assert_equal original_episode, reloaded_session.live_episode_id
    assert_includes body.fetch("answer"), "¿La conexión de P28 en la bornera está firme?"

    correction = "Me corrijo: el rótulo es P29, no P28."
    correction_turn = audit_thyssen_turn(document, correction,
      "Tomo P29 como el rótulo que ves. La correspondencia con el borne del manual queda por confirmar. «#{EA_LINE}» [p24].",
      pages: %w[24_1], observations: [ "el rótulo es P29" ], move: "follow_up")
    corrected, correction_capture = revision_ask("audit-photo-source-carry", 3, correction_turn, document)
    assert_includes audit_generator_prompt(correction_capture), correction
    assert_includes corrected.fetch("answer"), "Tomo P29 como el rótulo que ves."
    assert_equal original_episode, reloaded_session.live_episode_id
  end

  test "EA journey follows the requested observations through the persistent electrical fault" do
    unless defined?(Haiku55Http)
      previous = ENV["HTTP55_REQUIRE"]
      begin
        ENV["HTTP55_REQUIRE"] = "1"
        load Rails.root.join("script/field_companion/run_haiku55_http.rb")
      ensure
        ENV["HTTP55_REQUIRE"] = previous
      end
    end
    document = audit_thyssen_pin
    @audit_photo_reading = JSON.parse(AUDIT_ROOT.join("photo_sonnet_live.json").read)
    questions = AUDIT_JOURNEYS.fetch("photo_ea").dup
    replies = [
      "En el esquema se lee P28. La imagen identifica el rótulo. «#{EA_LINE}» [p24]. ¿Qué código muestra el display?",
      "EA es falla de señales. «#{EA_LINE}» [p24]. La puerta de piso orienta a esa línea. ¿La conexión de P28 en la bornera está firme?",
      "Con la conexión de P28 firme queda por comprobar el enganche. «#{EA_LINE}» [p24]. Cuando intenta cerrar, ¿el trinco llega a enganchar?",
      "Si el trinco no engancha, fíjate si queda desalineado. «#{EA_LINE}» [p24]. ¿El trinco queda desalineado?",
      "Con el trinco desalineado, corrige la alineación según el procedimiento autorizado de tu empresa. Luego comprueba si la puerta cierra, traba y sigue marcando EA. «#{EA_LINE}» [p24].",
      "La puerta ya cierra y traba, pero EA sigue activo. El manual documenta «Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada» [p9]. Con la puerta cerrada y trabada, ¿qué tensión lees en RA-53/P28?",
      "La tabla identifica «RA-53 / P28 = +110 Vcc» para el «sinal do contato de engate do trinco» [p9]. Los 0 Vcc que reportas en RA-53/P28 están por debajo de los +110 Vcc. Revisa el contacto y las conexiones de la línea de trincos; falta localizar la pérdida.",
      "Reportaste 0 Vcc en RA-53/P28. El manual identifica ese punto como confirmación de enganche: «Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada» [p9]. RA-30/A4+ alimenta el circuito: «Ponto para ligar alimentação do circuito de trinco e palhetas das portas de pavimento» [p10]. Para localizar la pérdida hace falta el plano y el procedimiento de la instalación."
    ]
    original_episode = nil
    pending = nil
    questions.each_with_index do |question, index|
      number = index + 1
      rows = number == 8 ? %w[24_1 9_3 10_1] : %w[24_1 9_3]
      observations = number == 1 ? [ "Está detenido", "la puerta de piso no cierra" ] : [ question ]
      turn = audit_thyssen_turn(document, question, replies.fetch(index), pages: rows,
        observations: observations, opening: number == 1, move: number == 1 ? "report" : "follow_up")
      if pending && number < 8
        turn.tool_input = turn.tool_input.merge("part_replies" => [
          { "question_id" => pending.fetch("id"), "part_id" => pending.fetch("parts").sole.fetch("id"),
            "state" => "complete", "quote" => question, "supersedes" => nil }
        ])
      end
      body, cassette = if number == 1
        audit_photo_post("photo-ea", turn, document)
      else
        revision_ask("audit-photo-ea", number, turn, document)
      end
      assert_revision_scope(cassette, document)
      prompt = audit_generator_prompt(cassette)
      assert_includes prompt, question
      assert_match(/\bP28\b/, Rag::ActivePhotoContext.generation_evidence(prompt))
      answer = body.fetch("answer")
      assert_empty Haiku55JourneyRubric.photo_ea_reasons(number, answer), answer
      session = reloaded_session
      pending = session.active_episode["pending_question"]
      row = { "answer" => answer, "pending_question" => pending }
      Haiku55Http.place_photo_reply!(questions, index, row)
      assert_nil row["block_reason"], answer
      original_episode ||= session.live_episode_id
      assert_equal original_episode, session.live_episode_id
    end
    expected = AUDIT_JOURNEYS.fetch("photo_ea").dup
    expected[6] = Haiku55Http::PHOTO_OPEN_READING_REPLY
    assert_equal expected, questions
  end

  test "KONE uses the Engineering reading and advances after the sensor is reconnected" do
    @account = accounts(:pilot)
    host! "piloto.danebo.ai"
    @user.update!(account: @account)
    sign_in @user
    document = KbDocument.create!(account: @account, document_uid: "6b37e94e-1d4c-4d59-a33a-66e894116c9a",
      display_name: "puesta en marcha de ascensores sin sala de maquina",
      s3_key: "bulk_uploads/3/2026-08-24/puesta en marcha de ascensores sin sala de maquina.pdf",
      aliases: %w[KONE MonoSpace KDL16 AM-11.65.031])
    post pinned_documents_path, params: { kb_document_id: document.id }, as: :json
    assert_response :no_content
    questions = AUDIT_JOURNEYS.fetch("kone_lwi")
    replies = [
      "Con la cabina vacía, el paso 2 pide «Ajuste Selección de monitor del display en tiempo real (6_75) a 65 (valor de entrada del pesacargas)» [p38]. ¿Qué valor de entrada ves en el panel LOP-CB?",
      "El 0 que reporta Ingeniería corresponde a la entrada del sensor con cabina vacía. El paso 2 dice «Si el valor es 0 => El sensor no está conectado o hay un espacio demasiado grande» [p38]. ¿El sensor está conectado?",
      "Estaba desconectado y, después de conectarlo, mediste 7 mA con cabina vacía. El paso 2 dice «Compruebe que LOP-CB muestre el valor entre 6-8» [p38]. Los 7 mA quedan dentro de ese rango. Con la cabina aún vacía y si ya completaste el reinicio del paso 1, el paso 3 registra la carga cero: «Seleccione el parámetro de Ajuste del pesacargas (6_74)» [p38]. Los 7 mA son la señal del sensor; el ajuste sigue en curso."
    ]
    episode = nil
    questions.each_with_index do |question, index|
      row = audit_manual_row(document, AUDIT_ROOT.join("kone_lwi_p38.txt").read, 38)
      # The live interpreter emits the drive separately from the brand/platform.
      assertions = if index.zero?
        [
          { "span" => "KONE MonoSpace", "act" => "assert", "slot_hint" => "model" },
          { "span" => "KDL16", "act" => "assert", "slot_hint" => "controller" },
          { "span" => "pesacargas LWI", "act" => "assert", "slot_hint" => nil }
        ]
      else
        []
      end
      observations = index.zero? ? [ "no logro terminar el ajuste del pesacargas" ] : [question]
      turn = audit_turn(question, replies.fetch(index), rows: [row], move: index.zero? ? "report" : "follow_up",
        observations: observations, assertions: assertions)
      body, cassette = revision_ask("audit-kone-lwi", index + 1, turn, document)
      assert_revision_scope(cassette, document)
      prompt = audit_generator_prompt(cassette)
      assert_includes prompt, question
      refute_includes prompt, "Un documento seleccionado no identifica la instalación"
      assert_equal "KDL16", reloaded_session.active_episode.dig("facts", "model", "value")
      answer = body.fetch("answer")
      assert_empty Haiku55JourneyRubric.kone_lwi_reasons(index + 1, answer), answer
      if index == 1
        assert_match(/0 que reporta Ingeniería/, answer)
        assert_match(/Si el valor es 0 => El sensor no está conectado o hay un espacio demasiado grande/, answer)
      elsif index == 2
        payload = cassette.sent.reject { |request| request[:tool_choice] }.sole
        user_messages = payload.fetch(:messages).select { |message| message[:role] == "user" }
        assert_includes user_messages.flat_map { |message| message[:content].pluck(:text) }.join("\n"), "La cabina está vacía"
        assert_match(/desconectado.*conectarlo.*7 mA con cabina vacía/, answer)
        assert_match(/si ya completaste el reinicio del paso 1.*paso 3 registra la carga cero.*6_74/, answer)
      end
      assert_nil Haiku55JourneyRubric.kone_lwi_followup_stop(index + 1, answer), answer
      episode ||= reloaded_session.live_episode_id
      assert_equal episode, reloaded_session.live_episode_id
    end
  end

  test "KONE checks that the field reply answers the question instead of incidental prose" do
    unrelated = "Pendiente: revisar la conexión del sensor y el espacio. ¿Tu sistema tiene placa LCEVTC?"
    assert_equal "field_reply_does_not_answer_kone_t2", Haiku55JourneyRubric.kone_lwi_followup_stop(2, unrelated)
    assert_nil Haiku55JourneyRubric.kone_lwi_followup_stop(2, "El sensor está conectado?")
  end

  test "captured EA answer passes the connection branch and independently fails provenance" do
    answer = <<~TEXT
      EA es falla de señales. [1] indica: «#{EA_LINE}».
      Corrección: lo que dije antes sobre P26, P27 y P28 no está en las fuentes de este turno, así que no lo uses.
      ¿Ya revisaste la conexión de P28 en la bornera y está firme?
    TEXT

    assert_equal ["undue_photo_retraction"], Haiku55JourneyRubric.photo_ea_reasons(2, answer)
    assert_nil Haiku55JourneyRubric.photo_ea_followup_stop(2, answer)
    assert_equal "field_reply_does_not_answer_photo_t2",
      Haiku55JourneyRubric.photo_ea_followup_stop(2, "¿Cuánto mide la tensión en P28?")
  end

  test "real Engineering opening asks the current parameter before continuing" do
    document = audit_thyssen_pin
    question = AUDIT_JOURNEYS.fetch("engineering").first
    turn = audit_thyssen_turn(document, question,
      'Antes de tocar el parámetro, ¿el equipo muestra algún código de falla (E, F o EA/EC)?',
      pages: %w[18_3], observations: [ "se oye fuerte el motor de tracción" ], opening: true)
    turn.rows.first["content"] = AUDIT_ROOT.join("kpvs_live_passage.txt").read

    body, _ = revision_ask("audit-engineering-live-opening", 1, turn, document)
    assert_match(/¿Cuál es la lectura actual de KP-VS en el menú PID\?/i, body.fetch("answer"))
    assert_includes body.fetch("answer"), NOISE_LINE
    assert_equal "parameter_reading", reloaded_session.active_episode.dig("pending_question", "aspect")
  end

  test "audit 18:36 caption and its original follow-ups replay independently of the corrected conversation" do
    turns = AUDIT_PRODUCTION.dig("photo", "history").select { |row| row["role"] == "user" }
    play_audit_photo("photo-original", turns.map { |row| row["full_content"] || row.fetch("content") })
  end

  test "audit photo provider failure reaches Action Cable and survives reload with the paid reading" do
    document = audit_thyssen_pin
    question = AUDIT_JOURNEYS.fetch("photo").first
    turn = audit_thyssen_turn(document, question, :timeout,
      pages: %w[9_3 24_1], observations: [ "Está detenido", "la puerta no cierra" ], opening: true)
    message, = audit_photo_post("photo-failure", turn, document)
    assert_equal I18n.t("rag.photo_question_unavailable", locale: :es), message.fetch("answer")
    assert_match(/bornera/, message.fetch("visual_summary"))
    trace_path = Rails.root.join("tmp/field_companion/haiku55_offline/revision-audit-photo-failure/turn-1/trace.json")
    failure = JSON.parse(trace_path.read).fetch("events").find { |event| event["kind"] == "photo_answer_delivery" }
    assert_equal "Anthropic::Errors::APITimeoutError", failure.fetch("error_class")
    assert_equal "generation_error", failure.fetch("outcome_reason")
    assert_equal "failed", reloaded_session.conversation_history.last["outcome"]
    assert_equal "", reloaded_session.conversation_history.last["prompt_reply"]
    assert_equal [ document.id ], reloaded_session.focus_document_ids
  end

  test "audit Engineering supplies the requested reading and the live episode keeps it" do
    play_audit_engineering("engineering", variant: false)
  end

  test "audit Engineering variant keeps the nameplate and resumes the question after same-equipment confirmation" do
    play_audit_engineering("engineering-variant", variant: true)
  end

  test "audit Elemont starts from calls, uses the visible pilot light and keeps the corrected level" do
    document = revision_pin(:elemont)
    questions = AUDIT_JOURNEYS.fetch("elemont")
    captures = load_turns(SCRIPTS.dig("elemont", "capture"))
    diagram = captures.flat_map(&:rows).find { |row| row["content"].to_s.include?("Chapa nivel 3") && row["content"].include?("puente semicircular") }
    rows = [ audit_manual_row(document, AUDIT_ROOT.join("elemont_h4.txt").read, 5), diagram ]
    replies = [
      "¿Está encendido H4? El plano lo rotula «Luz piloto, falla seguridad» [p5].",
      "Con H4 encendida, revisa qué seguridad quedó indicada. El plano identifica H4 como «Luz piloto, falla seguridad» [p5]. El plano no establece la causa de la falta de respuesta a las llamadas.",
      "En el plano, «cruza PasCom 24V con un puente semicircular sin punto de unión y termina en el terminal rotulado Chapa nivel 2» [p#{diagram.fetch('page').to_i}].",
      "En el plano, «cruza PasCom 24V con un puente semicircular sin punto de unión y termina en el terminal rotulado Chapa nivel 3» [p#{diagram.fetch('page').to_i}]."
    ]
    episode = nil
    questions.each_with_index do |question, index|
      turn = audit_turn(question, replies[index], rows: rows,
        move: index == 3 ? "correct" : (index.zero? ? "report" : "follow_up"),
        observations: index.zero? ? [ "no responde a las llamadas", "No veo un código de falla" ] : [],
        assertions: case index
        when 2 then [ { "span" => "Chapa nivel 2", "act" => "assert", "slot_hint" => "designator" } ]
        when 3 then [ { "span" => "Chapa nivel 3", "act" => "assert", "slot_hint" => "designator" },
                      { "span" => "Chapa nivel 2", "act" => "negate", "slot_hint" => "designator" } ]
        else []
        end)
      body, = revision_ask("audit-elemont", index + 1, turn, document)
      assert_includes body.fetch("answer"), [ "H4", "H4", "nivel 2", "nivel 3" ][index]
      assert_equal 1, body.fetch("answer").count("?") if index.zero?
      session = reloaded_session
      episode ||= session.live_episode_id
      assert_equal episode, session.live_episode_id
      assert_includes session.active_episode.dig("goal", "text"), "no responde a las llamadas"
      assert_equal [ document.id ], session.focus_document_ids
    end
    assert_includes reloaded_session.active_episode.fetch("identifiers").pluck("value"), "Chapa nivel 3"
  end

  test "audit manual doors replay the abstaining CEA branch and keep the patin condition and S1 open" do
    document = revision_pin(:cea)
    questions = AUDIT_JOURNEYS.fetch("cea")
    rows = [ audit_manual_row(document, CEA_PASSAGE, 24) ]
    rows += [ 26, 27 ].map { |page| audit_manual_row(document, AUDIT_ROOT.join("cea_p#{page}.txt").read, page) }
    captured = JSON.parse(AUDIT_ROOT.join("production_legacy.json").read).fetch("cea_t2")
    raw = captured.fetch("events").find { |event| event["kind"] == "companion_direct" }.fetch("text")
    assert_includes raw, "Según la fuente, con puerta de cabina manual"
    refute captured.fetch("events").find { |event| event["kind"] == "companion_publication" }.fetch("accepted")
    # Replay the actual rejected lead against the publication filter, with
    # the new scoped, conditional completion instead of the unsupported body.
    answers = [
      "Para acotar la traba, verifica si hay un contacto que cierre por la acción del patín. La fuente indica «#{CEA_PASSAGE.delete_suffix('.')}» [p24]. ¿Hay un contacto que cierre por acción del patín?",
      raw.lines.first.strip + "\n\n" +
        "Si la traba actúa por el contacto del patín, el ejemplo de ambas puertas manuales dice:\n" +
        "- SM: «El contacto de puerta de cabina cerrada se incluye en SM» [p26].\n" +
        "- SM: «Los contactos de precierre de las puertas de piso se incluyen en SM» [p26].\n" +
        "- SA: «Los contactos de traba de las puertas de piso se incluyen en SA» [p26].",
      "Queda pendiente identificar el contacto del patín para las dos puertas manuales. «Los contactos de traba de las puertas de piso se incluyen en SA» [p26] en el ejemplo condicionado a ese contacto.",
      "La correspondencia de S1 queda pendiente. La fuente identifica SA: «#{CEA_PASSAGE.delete_suffix('.')}» [p24]. Conserva ambas puertas manuales y el contacto del patín pendiente."
    ]
    id = nil
    questions.each_with_index do |question, index|
      observations = case index
      when 0 then [ "La puerta de piso no traba", "hay patín retráctil" ]
      when 1 then [ "La puerta de cabina y la puerta de piso son manuales", "La de piso tiene doble contacto y traba por patín" ]
      when 2 then [ question.delete_suffix(".") ]
      else []
      end
      turn = audit_turn(question, answers[index], rows: rows, move: index.zero? ? "report" : "follow_up", observations: observations)
      body, cassette = revision_ask("audit-cea", index + 1, turn, document)
      assert_revision_scope(cassette, document)
      assert_includes body.fetch("answer"), [ "contacto", "precierre", "pendiente", "S1" ][index]
      assert_equal 1, body.fetch("answer").count("?") if index.zero?
      refute_includes body.fetch("answer"), raw.lines.first.strip if index == 1
      assert_includes audit_generator_prompt(cassette), "son manuales" if index == 1
      session = reloaded_session
      id ||= session.live_episode_id
      assert_equal id, session.live_episode_id
      assert_equal [ document.id ], session.focus_document_ids
      assert_includes session.active_episode.fetch("observations").pluck("text"), "La puerta de cabina y la puerta de piso son manuales" if index >= 1
    end
  end

  test "audit VF5 asks for the reopening check before the technician names its input" do
    document = revision_pin(:guion1)
    questions = AUDIT_JOURNEYS.fetch("reopening")
    captures = load_turns(SCRIPTS.dig("guion1", "capture"))
    capture = captures.first
    reopening = capture.rows.find { |row| row["content"].to_s.include?("Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)") }
    signal = "Indicador LED y relé activado cuando la fotocélula o la entrada de re-apertura está activada"
    input = captures[2].rows.find { |row| row["content"].to_s.include?(signal) }
    rows = [ reopening, input ]
    answers = [
      "Comprueba la sensibilidad de reapertura. Para la puerta que se reabre sola, el manual dice «Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)» [p12].",
      "Para ubicar el siguiente paso, dime cuál LED está encendido. ¿Es el de la fotocélula? El manual indica «Comprobar que la fotocélula no esté activada» [p12].",
      "Con la fotocélula ya observada, queda por distinguir la entrada de reapertura. La fuente indica «#{signal}» [p#{input.fetch('page').to_i}]. ¿Puedes confirmar si la entrada #21 está activa?",
      "Deja #21 y #23 pendientes para quien tenga acceso al operador. Con lo revisado, sigue abierta la causa de la reapertura. La comprobación del manual es «Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)» [p12]."
    ]
    id = nil
    questions.each_with_index do |question, index|
      observations = [
        [ "La puerta se reabre sola durante el cierre", "El LED está apagado", "no veo obstrucción" ],
        [ "el LED está encendido" ], [ "no se activa durante el cierre" ], [ questions.last.delete_suffix(".") ]
      ][index]
      assertions = index.zero? ? capture.tool_input.fetch("assertions") : []
      turn = audit_turn(question, answers[index], rows: rows, move: index == 1 ? "correct" : (index.zero? ? "report" : "follow_up"),
        observations: observations, assertions: assertions)
      body, = revision_ask("audit-vf5", index + 1, turn, document)
      assert_includes body.fetch("answer"), [ "#54", "LED", "#21", "pendientes" ][index]
      session = reloaded_session
      id ||= session.live_episode_id
      assert_equal id, session.live_episode_id
      assert_includes session.active_episode.dig("goal", "text"), "se reabre sola"
      assert_equal [ document.id ], session.focus_document_ids
    end
  end

  test "Thyssen guion 3 replays w2 and keeps the engineering reading in the open job" do
    data, document = pin_thyssen_guion3
    turns = revision_turns("thyssen_guion3", data: data)
    first, cassette = revision_ask("thyssen-guion3-w2", 1, turns[0], document)
    assert_revision_scope(cassette, document)
    assert_equal [16], cassette.sizes
    assert_includes cassette.sent.last.fetch(:messages).last.to_json, "hasta el mínimo de [3,0]"
    episode = reloaded_session.live_episode_id
    assert episode

    second, = revision_ask("thyssen-guion3-w2", 2, turns[1], document)
    assert_equal episode, reloaded_session.live_episode_id
    third, = revision_ask("thyssen-guion3-w2", 3, turns[2], document)
    assert_equal episode, reloaded_session.live_episode_id

    assert_match(/Ingeniería/i, first.fetch("answer"))
    assert_match(/lectura actual de KP-VS.*pendiente/i, first.fetch("answer"))
    assert_match(/2,5.*por debajo.*3,0/i, second.fetch("answer"))
    assert_match(/3,5.*(?:instalación|comisionamiento|puesta en marcha)/i, third.fetch("answer"))
  end

  test "Thyssen guion 3 w1 preserves the complete noise condition when referring the reading" do
    data, document = pin_thyssen_guion3
    data["turns"] = [data.fetch("alternates").fetch("w1_guion3")]
    turn = revision_turns("thyssen_guion3", data: data).sole
    body, = revision_ask("thyssen-guion3-w1", 1, turn, document)

    assert_match(/Ingeniería/i, body.fetch("answer"))
    assert_match(/ruido audible muy elevado.*mínimo de \[3,0\]/i, body.fetch("answer"))
  end

  test "Thyssen isolated w2 keeps the comparison without a decrease order" do
    data, document = pin_thyssen_guion3
    data["turns"] = [data.fetch("alternates").fetch("w2_kpvs")]
    turn = revision_turns("thyssen_guion3", data: data).sole
    body, = revision_ask("thyssen-kpvs-w2", 1, turn, document)

    assert_empty Haiku55JourneyRubric.reasons("kpvs", 1, body.fetch("answer"), [turn.question])
  end

  private

  def with_guarded_thyssen_photo
    skip "Set AUDIT_THYSSEN_PHOTO_PATH to use the technician's JPEG" unless ENV["AUDIT_THYSSEN_PHOTO_PATH"]
    ledger = Rag::LocalPassLedger
    guard = Rag::GuardedPhotoVision
    Dir.mktmpdir do |directory|
      haiku_path = File.join(directory, "haiku.json")
      vision_path = File.join(directory, "vision.json")
      spend = Rag::AssignmentSpend.new(path: haiku_path, call_cap: 150, cost_cap_usd: "0.1")
      spend.admit_execution!(id: "offline-replay", calls: 8, cost_usd: "0.1")
      vision = guard.assignment(vision_path)
      vision.admit_execution!(id: guard::GRANT_ID, calls: 1, cost_usd: guard.ceiling)
      config = {
        ledger::GUARD_ENV => "1", ledger::CALL_CAP_ENV => "8", ledger::COST_CAP_ENV => "0.1",
        ledger::ATTEMPTS_ENV => "1", ledger::ASSIGNMENT_PATH_ENV => haiku_path, guard::PATH_ENV => vision_path,
        ledger::ALLOWED_CALLS_ENV => "converse@claude-haiku-5-5-direct,converse_message@claude-haiku-5-5-direct,photo_vision@claude-sonnet-5-5-direct",
        ledger::EXECUTION_ENV => "offline-replay", ledger::SCOPE_ENV => "offline-replay/photo",
        "RAG_PHOTO_LOCAL_STORE" => directory
      }
      previous = config.keys.to_h { |key| [key, ENV[key]] }
      config.each { |key, value| ENV[key] = value }
      @guarded_photo = true
      ledger.reset!
      ledger.reset_local_process!
      yield spend, vision
    ensure
      previous&.each { |key, value| ENV[key] = value }
      ledger.reset!
      ledger.reset_local_process!
      @guarded_photo = false
    end
  end

  def play_audit_photo(name, questions)
    document = audit_thyssen_pin
    replies = [
      "Lee el código del display para orientar la comprobación. En la sección de señales del operador, P28 es «#{P28_LINE}» [p9]. En el esquema se distingue PV-1. El equipo Thyssen FDN Universal con MCINV4 es el que reportaste. ¿Qué código aparece?",
      "Con EA, sigue por la línea de trincos: «#{EA_LINE}» [p24]. ¿Qué lecturas tienes de P28 y P27 con la orden de cierre?",
      "Prioriza la línea de trincos: «#{EA_LINE}» [p24]. P28 dio 0 Vcc y P27 dio 110 Vcc en terreno. La tabla de señales del operador documenta «RA-53 / P28 = +110 Vcc» [p9]. P26 queda pendiente para quien tenga acceso. ¿El trinco de piso queda enganchado?",
      "La fila de EA no respalda cambiar un parámetro con TLS. Orienta a los trincos: «#{EA_LINE}» [p24]. Con EA persistente, conserva P28 en 0 Vcc y P27 en 110 Vcc como lecturas de terreno. P26 queda pendiente para quien tenga acceso."
    ]
    if name == "photo-original"
      replies[1] = "## Señal P28\nla describe así: «#{P28_LINE}» [p9]. ¿Qué código aparece?"
    end
    questions.each_with_index do |question, index|
      observations = case index
      when 0 then [ "Está detenido", "la puerta no cierra" ]
      when 2 then question.split(/(?<=\.)\s+/).map(&:strip)
      when 3 then question.split(/(?<=\.)\s+/).first(2).map(&:strip)
      else []
      end
      turn = audit_thyssen_turn(document, question, replies[index],
        pages: %w[9_3 24_1], observations: observations, opening: index.zero?)
      body, cassette = if index.zero?
        audit_photo_post(name, turn, document)
      else
        revision_ask("audit-#{name}", index + 1, turn, document)
      end

      assert_revision_scope(cassette, document)
      answer = body.fetch("answer")
      assert_includes answer, index < 2 && (index.zero? || name == "photo-original") ? P28_LINE : EA_LINE
      assert_includes answer, "Señal P28" if name == "photo-original" && index == 1
      assert_includes answer, "P26 queda pendiente" if index >= 2
      assert_includes answer, "cambiar un parámetro con TLS" if index == 3
      assert_nil body["manual_suggestion"]
      prompt = audit_generator_prompt(cassette)
      assert_includes prompt, question
      assert_includes prompt, "PV-1"
      assert_includes prompt, "Photo Evidence"
      if @audit_photo_reading
        evidence = Rag::ActivePhotoContext.generation_evidence(prompt.split("Fuentes de este turno:").first)
        assert_includes evidence, "P26"
        assert_includes evidence, "P27"
        assert_includes evidence, "P28"
      end
      assert_includes cassette.sent.last.fetch(:messages).to_json, "P27 marca 110" if index == 3 && name == "photo"
      episode = reloaded_session.active_episode
      @audit_photo_episode ||= episode.fetch("episode_id")
      assert_equal @audit_photo_episode, episode.fetch("episode_id")
      assert episode.dig("active_photo", "field_photo_id")
      assert_equal [ document.id ], reloaded_session.focus_document_ids
    end
  end

  def play_audit_engineering(name, variant:)
    document = audit_thyssen_pin
    questions = AUDIT_JOURNEYS.fetch("engineering").dup
    questions[2] = AUDIT_JOURNEYS.fetch("engineering_variant").first if variant
    replies = [
      "¿Qué valor indica KP-VS en el menú PID? La lectura permite ubicar el caso frente al límite de la rama «#{NOISE_LINE}» [1]. La causa del ruido sigue abierta.",
      "Deja pendiente la lectura actual de KP-VS en el menú PID y deriva la verificación a Ingeniería. La rama se aplica «#{NOISE_LINE}» [1].",
      "Con KP-VS en 2,5, que leyó Ingeniería, la lectura está por debajo del mínimo documentado. La condición y el límite son «#{NOISE_LINE}» [1]. La evaluación del ruido sigue pendiente.",
      "No le pidas a Ingeniería que cambie KP-VS a 3,5 por el ruido. Esa es una referencia de puesta en marcha: «#{audit_installation_quote}» [2]. Sigue pendiente la evaluación del ruido con la lectura de 2,5."
    ]
    if variant
      replies[2] += ' <respuesta_complementaria>El ejemplo Eberle no completa la placa de obra: «Os valores reais dependem do motor instalado na obra» [2]. La corriente nominal queda pendiente.</respuesta_complementaria>'
    end

    episode_id = nil
    questions.each_with_index do |question, index|
      if variant && index == 3
        previous = reloaded_session
        state = Rag::ActiveEpisode.parse(previous.active_episode)
        state.pending_question = { "type" => "work_relation" }
        previous.update!(active_episode: state.to_h)
        previous.add_to_history("user", question, user_id: @user.id, correlation_id: "query:unanswered")
        previous.add_to_history("assistant", I18n.t("rag.clarify_work_relation", locale: :es), correlation_id: "query:unanswered")
        question = AUDIT_JOURNEYS.fetch("engineering_variant").last
      end
      observations = [
        [ "En viaje se oye fuerte el motor de tracción" ],
        [ questions[1].delete_suffix(".") ],
        variant ? [ "La corriente no se alcanza a leer" ] : [ "Ingeniería leyó KP-VS en 2,5" ],
        variant ? [] : [ "el ruido sigue" ]
      ].fetch(index)
      turn = audit_thyssen_turn(document, question, replies[index],
        pages: %w[18_3 15_3], observations: observations, opening: index.zero?,
        move: index >= 2 ? "new_work" : (index.zero? ? "report" : "follow_up"))
      body, cassette = revision_ask("audit-#{name}", index + 1, turn, document)
      assert_revision_scope(cassette, document)
      answer = body.fetch("answer")
      assert_includes answer, [ "¿Cuál es la lectura actual", "Ingeniería", "por debajo", "puesta en marcha" ].fetch(index)
      assert_includes answer, "Eberle" if variant && index == 2
      assert_includes audit_generator_prompt(cassette), questions[3] if variant && index == 3
      assert_includes cassette.queries.first, questions[3] if variant && index == 3
      session = reloaded_session
      episode_id ||= session.live_episode_id
      assert_equal episode_id, session.live_episode_id
      assert_equal [ document.id ], session.focus_document_ids
      assert_includes session.active_episode.fetch("observations").pluck("text"), "Ingeniería leyó KP-VS en 2,5" if index >= 2
    end

    turn = audit_thyssen_turn(document, AUDIT_JOURNEYS.fetch("other_equipment"), "",
      pages: [], observations: [ "La cabina no nivela" ], move: "new_work",
      assertions: [ { "span" => "KONE", "act" => "assert", "slot_hint" => "manufacturer" } ])
    revision_ask("audit-#{name}", 5, turn, document)
    assert_not_equal episode_id, reloaded_session.live_episode_id
  end

  def audit_installation_quote
    data = JSON.parse(Rails.root.join(REVISION_FIXTURES, "thyssen_kpvs.json").read)
    data.dig("quotes", "installation")
  end

  def audit_thyssen_pin
    @account = accounts(:pilot)
    host! "piloto.danebo.ai"
    @user.update!(account: @account)
    sign_in @user
    data = JSON.parse(Rails.root.join(REVISION_FIXTURES, "thyssen_kpvs.json").read)
    spec = data.fetch("document")
    doc = KbDocument.create!(account: @account, s3_key: spec.fetch("key"),
      document_uid: spec.fetch("uid"), display_name: spec.fetch("name"), aliases: [])
    post pinned_documents_path, params: { kb_document_id: doc.id }, as: :json
    assert_response :no_content
    doc
  end

  def audit_manual_row(document, text, page)
    { "content" => text, "uri" => "s3://#{KbDocument::KB_BUCKET}/audit/#{document.document_uid}/chunk_p#{page}_1.txt",
      "original_source_uri" => document.canonical_uri, "document" => document.display_name, "page" => page, "score" => 0.9 }
  end

  def audit_turn(question, answer, rows:, move:, observations:, assertions: [])
    TurnCapture.new({
      "question" => question, "retrieve_query" => question, "generator_text" => answer, "rows" => rows,
      "tool_input" => { "move" => move, "assertions" => assertions, "observations" => observations,
                        "pending_resolution" => nil, "clarification_target" => nil }
    })
  end

  def audit_thyssen_turn(doc, question, answer, pages:, observations:, move: "report", opening: false, assertions: [])
    assertions = [ { "span" => "Thyssen", "act" => "assert", "slot_hint" => "manufacturer" } ] if opening
    rows = pages.map do |page_key|
      { "content" => AUDIT_ROOT.join("chunk_p#{page_key}.txt").read,
        "uri" => "s3://#{KbDocument::KB_BUCKET}/audit/thyssen/chunk_p#{page_key}.txt",
        "original_source_uri" => doc.canonical_uri, "document" => doc.display_name,
        "page" => page_key.split("_").first.to_i, "score" => 0.9 }
    end
    audit_turn(question, answer, rows: rows, move: move, observations: observations, assertions: assertions)
  end

  def audit_generator_prompt(cassette)
    cassette.sent.reject { |payload| payload[:tool_choice] }.sole.fetch(:messages).last.fetch(:content).pluck(:text).join
  end

  def audit_photo_post(name, turn, document)
    cassette = JourneyCassette.new([ turn ], viewer_id: @account.id, focus_uri: document.canonical_uri)
    original_compression = ImageCompressionService.method(:compress_with_thumbnail)
    original_vision = FieldPhotoAnalysisService.instance_method(:call)
    original_stream = ClaudeChunkingClient.instance_method(:build_client)
    original_s3 = S3DocumentsService.method(:new)
    photo_path = ENV["AUDIT_THYSSEN_PHOTO_PATH"].presence
    binary = photo_path ? File.binread(photo_path) : "fixture transport bytes"
    filename = photo_path ? File.basename(photo_path) : "bornera-fixture.jpg"
    cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    if photo_path.nil?
      ImageCompressionService.define_singleton_method(:compress_with_thumbnail) do |data, media, **|
        { data: data, media_type: media, binary: Base64.decode64(data) }
      end
    end
    observation = @audit_photo_reading || AUDIT_PRODUCTION.dig("photo", "observation").merge("subsystem" => "UNKNOWN")
    if @guarded_photo
      vision_text = JSON.generate(observation.merge("summary" => "Se distingue la bornera PV-1."))
      vision_client = Object.new
      vision_client.define_singleton_method(:messages) { self }
      vision_client.define_singleton_method(:stream) do |**request|
        raise "SDK retries enabled" unless request.dig(:request_options, :max_retries) == 0
        image = request.fetch(:messages).sole.fetch(:content).find { |part| part[:type] == "image" }
        raise "photo bytes differ from upload" unless Base64.strict_decode64(image.dig(:source, :data)) == binary

        usage = Struct.new(:input_tokens, :output_tokens).new(300, 100)
        text = Struct.new(:type, :text).new("text", vision_text)
        response = Struct.new(:model, :usage, :content, :stop_reason).new("claude-sonnet-5-5", usage, [text], "end_turn")
        Struct.new(:accumulated_message).new(response)
      end
      ClaudeChunkingClient.define_method(:build_client) { vision_client }
    else
      FieldPhotoAnalysisService.define_method(:call) do
        component = observation.fetch("canonical_component")
        raise "photo bytes differ from upload" unless @binary == binary

        { parsed: observation, analysis: component, compact_context: "[FOTO] #{component}", usage: {},
          model: "claude-sonnet-5-5", target_visible: true, relevance_to_goal: observation.fetch("relevance_to_goal", "relevant") }
      end
    end
    store = Object.new
    store.define_singleton_method(:upload_binary) { |key, _data, _media| key }
    store.define_singleton_method(:list_keys) { |**| [] }
    S3DocumentsService.define_singleton_method(:new) { |**| store }
    previous = ENV.slice("PHOTO_QUESTION_RAG_ENABLED", "RAG_TRANSIENT_ATTEMPT_LIMIT")
    ENV["PHOTO_QUESTION_RAG_ENABLED"] = "true"
    ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = "1"
    message = nil

    with_doubles(cassette) do
      events = Rag::ValidationCapture.capture do
        assert_enqueued_jobs 1, only: FieldPhotoAnalysisJob do
          post rag_ask_path, params: {
            question: turn.question,
            image: { data: Base64.strict_encode64(binary), filename: filename, media_type: "image/jpeg" }
          }, as: :json
        end
        assert_response :success
        correlation = response.parsed_body.fetch("correlation_id")
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(@account.id)) do
          perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
        end
        message = messages.sole
        assert_equal correlation, message.fetch("correlation_id")
        assert_equal "photo_question_answered", message.fetch("status")
      end
      events << { "kind" => "offline_vision_replay", "filename" => filename, "sha256" => Digest::SHA256.hexdigest(binary),
                  "bytes" => binary.bytesize, "visual_observation" => observation, "vision_source" => "production_capture" }
      write_trace("revision-audit-#{name}", 1, message, events, cassette, index: 0)
    end
    stored = FieldPhoto.find_by!(account: @account, sha256: Digest::SHA256.hexdigest(binary))
    assert stored.thumbnail_data.present? if photo_path
    assert_equal "UNKNOWN", stored.visual_observation["manufacturer"]
    assert_includes stored.visual_observation["visible_text"], "MQ6"
    assert_equal "Thyssen", reloaded_session.active_episode.dig("facts", "manufacturer", "value")
    [ message, cassette ]
  ensure
    ImageCompressionService.define_singleton_method(:compress_with_thumbnail) { |*a, **kw| original_compression.call(*a, **kw) }
    FieldPhotoAnalysisService.define_method(:call, original_vision)
    ClaudeChunkingClient.define_method(:build_client, original_stream)
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| original_s3.call(*a, **kw) }
    Rails.cache = cache
    %w[PHOTO_QUESTION_RAG_ENABLED RAG_TRANSIENT_ATTEMPT_LIMIT].each do |key|
      previous[key] ? ENV[key] = previous[key] : ENV.delete(key)
    end
  end

  def pin_thyssen_guion3
    data = JSON.parse(Rails.root.join(REVISION_FIXTURES, "thyssen_guion3.json").read)
    @account = accounts(:pilot)
    host! "piloto.danebo.ai"
    @user.update!(account: @account)
    spec = data.fetch("document")
    document = KbDocument.create!(account: @account, s3_key: spec.fetch("key"),
      document_uid: spec.fetch("uid"), display_name: spec.fetch("name"), aliases: [])
    post pinned_documents_path, params: { kb_document_id: document.id }, as: :json
    assert_response :no_content
    [data, document]
  end

  def play_thyssen_kpvs(scenario)
    name = "thyssen_kpvs"
    data = JSON.parse(Rails.root.join(REVISION_FIXTURES, "#{name}.json").read)
    @account = accounts(:pilot)
    host! "piloto.danebo.ai"
    @user.update!(account: @account)
    sign_in @user
    spec = data.fetch("document")
    document = KbDocument.create!(account: @account, s3_key: spec.fetch("key"),
      document_uid: spec.fetch("uid"), display_name: spec.fetch("name"), aliases: [])
    post pinned_documents_path, params: { kb_document_id: document.id }, as: :json
    assert_response :no_content

    entry = data.fetch("turns").sole
    contrasts = data.fetch("contrasts")
    if data.fetch("variants").key?(scenario)
      variant = data.dig("variants", scenario)
      entry["generator_text"] = variant.fetch("generator_text")
      %w[question retrieve_query].each { |key| entry[key] = variant[key] if variant[key] }
      entry["tool_input"]["observations"][1] = variant["observation"] if variant["observation"]
    elsif scenario != "control"
      entry["generator_text"] = contrasts.fetch("#{scenario}_generator_text")
    end
    entry["rows"][2] = contrasts.fetch("installation_row") if scenario == "installation"
    turn = revision_turns(name, data: data).sole
    original_review = Rag::CompanionParameterReview.method(:build)
    Rag::CompanionParameterReview.define_singleton_method(:build) { |**| nil }
    body, cassette = revision_ask("thyssen-kpvs-#{scenario}", 1, turn, document)
    assert_revision_scope(cassette, document)
    assert cassette.sizes.all? { |size| size == 16 }
    assert_equal turn.question, cassette.queries.last
    assert_equal [ document.id ], reloaded_session.focus_document_ids

    generator = cassette.sent.reject { |payload| payload[:tool_choice] }.sole
    prompt = generator.fetch(:messages).last.fetch(:content).pluck(:text).join
    noise = data.dig("quotes", "noise")
    assert_includes prompt, "En caso de ruido audible muy elevado"
    assert_includes prompt, "hasta el mínimo de [3,0]"
    assert_includes prompt, noise
    if scenario == "installation"
      assert_includes prompt, "18.5 Verificar"
      assert_includes prompt, "em caso de diferença"
      assert_includes prompt, '"KP-VS" = [3,5]'
    else
      assert_no_match(/18\.5 Verificar|\[3,5\]/, prompt)
    end

    directory = Rails.root.join("tmp/field_companion/haiku55_offline/revision-thyssen-kpvs-#{scenario}/turn-1")
    events = JSON.parse(directory.join("trace.json").read).fetch("events")
    directory.join("layers.json").write(JSON.pretty_generate(
      "production_correlation" => data.dig("production", "correlation_id"),
      "indexed" => data.fetch("indexed"),
      "retrieve_pages" => cassette.returned.last.map(&:page),
      "generator_request" => generator,
      "generator_stub" => turn.raw,
      "noise_quote" => noise,
      "answer" => body.fetch("answer"),
      "events" => events
    ))
    backing = events.find { |event| event["kind"] == "companion_claim_backing" }
    publication = events.find { |event| event["kind"] == "companion_publication" }
    reference_filter = events.find { |event| event["kind"] == "companion_reference_filter" }
    floor = events.find { |event| event["kind"] == "companion_cited_floor" }
    answer = body.fetch("answer")
    assert publication.fetch("accepted"), publication.inspect
    if scenario == "comparison_first"
      # The closing offer is an uncited attribution and leaves; the comparison does not.
      assert_equal [ "Si quieres, puedo revisar qué otros códigos o señales documenta el manual para fallas en el motor de tracción." ],
        Array(backing&.dig("removed")).pluck("sentence")
    else
      assert_not_includes Array(backing&.dig("removed")).pluck("reason"), "uncited_attribution"
    end
    assert_floor_sentence(answer, scenario) unless %w[unsafe haiku_exact comparison_first].include?(scenario)
    assert_includes answer.delete("*"), noise.delete("*") unless scenario == "comparison_first"
    referral = "La revisión del ajuste corresponde a Ingeniería."
    if reference_filter
      assert_not_includes reference_filter.fetch("removed"), referral
    end
    if scenario == "plain_emphasis"
      assert_includes answer, "No lo reduzcas más."
      assert_includes answer, referral
      assert_nil floor
    end
    if scenario == "haiku_exact"
      # Real Haiku output (kp22): the comparison and the quote sit in two sentences.
      assert_includes answer, "Con KP-VS en 3,0 ya está en el mínimo que indica el manual."
      assert_includes answer, "hasta el mínimo de [3,0]» [1]."
      assert_nil floor
    end
    if scenario == "comparison_first"
      # Real Haiku output (v1 kpvs, 79723a5): the comparison comes before the
      # sentence that quotes the limit, and that sentence only survives with the
      # condition quoted in the next paragraph. The comparison keeps the limit.
      assert_includes answer, "Con KP-VS en 2,5, el valor ya está por debajo del mínimo documentado."
      assert_includes answer, "hasta el mínimo de [3,0]\" [1]."
      assert_nil floor
    end
    unless %w[control unsafe installation plain_emphasis haiku_exact comparison_first].include?(scenario)
      assert_includes answer, referral
      assert floor, events.pluck("kind").inspect
      assert_equal [ "below_cited_minimum" ], floor.fetch("removed").pluck("reason")
      assert_equal [ "message" ], floor.fetch("removed").pluck("reported_from")
      assert_no_match(/red[uú]celo|sigue bajando|baja KP|b[aá]jalo/i, answer)
    end

    case scenario
    when "control"
      assert_nil floor
      assert_includes answer, "No lo reduzcas más."
      assert_includes answer, referral
      assert_no_match(/red[uú]celo a[uú]n m[aá]s/i, answer)
    when "unsafe"
      assert floor, events.pluck("kind").inspect
      assert_equal [ "below_cited_minimum" ], floor.fetch("removed").pluck("reason")
      assert_no_match(/red[uú]celo a[uú]n m[aá]s/i, answer)
      assert_no_match(/Ingeniería/, answer)
    when "installation"
      assert_includes answer, referral
      assert_match(/referencia de instalaci[oó]n/i, answer)
      assert_includes answer, "em caso de diferença"
      assert_includes answer, '"KP-VS" = [3,5]'
      assert_includes answer, "[3]"
      assert_not_includes Array(backing.fetch("removed")).pluck("reason"), "unbacked_citation"
    end
  ensure
    Rag::CompanionParameterReview.define_singleton_method(:build, original_review) if original_review
  end

  def assert_floor_sentence(answer, scenario = nil)
    reported = scenario == "exact_minimum" ? "3,0" : "2,5"
    sentence = answer.split(/(?<=[.!?])\s+/).find { |part| part.include?(reported) && part.include?("[3,0]") }
    if scenario == "explicit_target"
      assert_match(/\[3,0\]/, answer)
      assert_no_match(/1,5/, answer)
      return
    end
    assert sentence, answer
    assert_match(scenario == "exact_minimum" ? /ya est[aá] en el m[ií]nimo/ : /por debajo del mínimo de 3,0/, sentence)
    assert_match(/En caso de ruido audible muy elevado/, sentence)
    assert_match(/\[1\]/, sentence)
  end

  def revision_turns(name, data: nil)
    data ||= JSON.parse(Rails.root.join(REVISION_FIXTURES, "#{name}.json").read)
    data.fetch("turns").map { |turn|
      turn["rows"].each { |row| row["content"] = data.fetch("passages").fetch(row.fetch("body_sha256")) }
      TurnCapture.new(turn)
    }
  end

  def revision_document(name)
    uid, file, title = REVISION_DOCS[name]
    if uid
      key = "bulk_uploads/1/2026-08-31/#{file}"
    else
      spec = SCRIPTS.fetch(name.to_s)
      uid, key, title = spec.values_at("uid", "key", "name")
    end
    KbDocument.create!(account: @account, document_uid: uid, s3_key: key, display_name: title, aliases: [])
  end

  def revision_pin(name)
    document = revision_document(name)
    post pinned_documents_path, params: { kb_document_id: document.id }, as: :json
    assert_response :no_content
    document
  end

  def revision_ask(name, number, turn, document, replay: nil)
    cassette = JourneyCassette.new([ turn ], viewer_id: @account.id, focus_uri: document.canonical_uri)
    with_doubles(cassette) do
      forbid_bedrock = TracePoint.new(:call) do |call|
        methods = { BedrockClient => %i[generate_text converse converse_message], AiProvider => %i[query converse] }
        flunk "Unexpected Bedrock generator entry #{call.defined_class}##{call.method_id}\n#{caller.grep(%r{/app/}).first(8).join("\n")}" if methods[call.defined_class]&.include?(call.method_id)
      end
      events = Rag::ValidationCapture.capture do
        params = replay ? { replay_correlation_id: replay } : { question: turn.question }
        forbid_bedrock.enable { post rag_ask_path, params: params, as: :json }
      end
      body = response.parsed_body
      write_trace("revision-#{name}", number, body, events, cassette, index: 0)
      assert_response :success, body.inspect
      assert_equal "success", body.fetch("status")
      [ body, cassette ]
    end
  end

  # The reference route may add one Retrieve with the technician's turn; every
  # Retrieve of the turn keeps the same filter.
  def assert_revision_scope(cassette, *documents)
    assert_includes [ 1, 2 ], cassette.filters.size
    cassette.filters.each do |filter|
      assert_equal documents.map(&:canonical_uri).sort, filter.to_json.scan(/s3:[^"]+/).uniq.sort
    end
  end

  def revision_card(body, document)
    card = body.values.grep(Hash).flat_map { |section| Array(section["cards"]) }
      .find { |row| row["kb_document_id"] == document.id }
    assert card, body.inspect
    card
  end

  def accept_revision_card(document, mode, episode, cid, status: :ok)
    post pinned_documents_path, params: {
      kb_document_id: document.id, document_uid: document.document_uid,
      focus_mode: mode, episode_id: episode, correlation_id: cid
    }, as: :json
    assert_response status
  end

  def cea_reference
    "En el manual CEA15+: «#{CEA_PASSAGE.delete_suffix(".")}» [1]."
  end

  def cea_turn(question, document, passage: CEA_PASSAGE, raw: cea_reference, move: "report", resolution: nil, page: 24)
    assertions = resolution == "value" ? [ { "span" => "CEA15+", "act" => "assert", "slot_hint" => "controller" } ] : []
    TurnCapture.new({
      "question" => question, "retrieve_query" => question,
      "tool_input" => {
        "move" => move, "assertions" => assertions, "observations" => [],
        "pending_resolution" => resolution, "clarification_target" => nil
      },
      "generator_text" => raw,
      "rows" => passage ? [ {
        "content" => passage, "uri" => document.canonical_uri,
        "original_source_uri" => document.canonical_uri, "document" => "CEA15+", "page" => page, "score" => 0.9
      } ] : []
    })
  end

  def check_cea_followup(reply, resolution, status, extra: {})
    document = revision_pin(:cea)
    name = "cea-#{status}"
    body, first = revision_ask(name, 1, cea_turn(CEA_QUESTION, document), document)
    assert_revision_scope(first, document)
    assert_match(/patín retráctil/i, body.fetch("answer"))
    assert_match(/rótulo/i, body.fetch("answer"))
    assert_equal "controller", reloaded_session.active_episode.dig("pending_question", "type")
    episode = reloaded_session.live_episode_id
    turn = cea_turn(reply, document, move: "answer_pending", resolution: resolution)
    turn.tool_input.merge!(extra)
    second, cassette = revision_ask(name, 2, turn, document)
    assert_revision_scope(cassette, document)
    assert_equal episode, reloaded_session.live_episode_id
    assert_equal status, reloaded_session.active_episode.dig("facts", "controller", "status")
    assert_nil reloaded_session.active_episode["pending_question"]
    assert_no_match(/¿[^?]*rótulo/i, second.fetch("answer"))
    generator = cassette.sent.find { |payload| !payload[:tool_choice] }
    assert_match(/#{status == "known" ? "CEA15\\+" : "no (?:puede|puedo|se pudo)"}|#{status}/i, generator.to_json)
  end

  def play(name, tool_inputs: {})
    spec = SCRIPTS.fetch(name)
    turns = load_turns(spec["capture"])
    tool_inputs.each { |number, input| turns[number - 1].tool_input = input }
    document = KbDocument.create!(
      account: @account, s3_key: spec["key"], document_uid: spec["uid"],
      display_name: spec["name"], aliases: []
    )
    focus_uri = document.display_s3_uri(KbDocument::KB_BUCKET)
    ConversationSession.where(identifier: @user.id.to_s, channel: "web").delete_all
    cassette = JourneyCassette.new(turns, viewer_id: @account.id, focus_uri: focus_uri)
    episode_ids = []
    with_doubles(cassette) do
      post pinned_documents_path, params: { kb_document_id: document.id }, as: :json
      assert_includes [ 200, 204 ], response.status, response.body.to_s.truncate(400)
      assert_equal document.id, reloaded_session.document_focus_entries.sole["kb_document_id"]

      turns.each_index do |index|
        turn = turns[index]
        events = Rag::ValidationCapture.capture do
          post rag_ask_path, params: { question: turn.question }, as: :json
        end
        body = response.parsed_body
        write_trace(name, index + 1, body, events, cassette)
        assert_response :success, failure_detail(name, index + 1, body, cassette)
        assert_equal "success", body["status"], failure_detail(name, index + 1, body, cassette)
        answer = body["answer"].to_s
        assert_not_equal I18n.t("rag.service_unavailable", locale: :es), answer, failure_detail(name, index + 1, body, cassette)
        assert_not_equal I18n.t("rag.data_not_available", locale: :es), answer
        episode_ids << reloaded_session.active_episode["episode_id"]
        assert_equal document.id, reloaded_session.document_focus_entries.sole["kb_document_id"]
        query = cassette.queries[index]
        assert query.to_s.strip.present?, "turn #{index + 1} did not reach Retrieve"
        if name == "elemont" && index.positive?
          assert_match(/nivel 3/i, query)
          assert_no_match(/Chapa nivel 2/i, query)
        else
          assert_equal turn.retrieve_query, query, "#{name} turn #{index + 1}: Retrieve query diverged from the capture"
        end
        # After the first turn the pack can now keep canonical names in its
        # ledger and omit retired sources. Check the actual source, filter,
        # publication and state rather than freezing the old header bytes.
        if turn.generator_messages_sha256 && index.zero?
          assert_equal turn.generator_messages_sha256, cassette.generator_messages_sha256(index)
        end
        assert cassette.filters[index].to_json.include?(focus_uri), cassette.filters[index].to_json
        assert_behavior(name, index + 1, answer, turns.map(&:question))
        assert_payloads(cassette, index)
        assert_cited(name, index + 1, answer, body)
      end
    end
    assert_equal 1, episode_ids.compact.uniq.size, episode_ids.inspect
    assert_decisive(name, cassette)
  end

  def assert_behavior(name, number, answer, questions)
    assert_empty Haiku55JourneyRubric.reasons(name, number, answer, questions), answer
  end

  def assert_payloads(cassette, index)
    interpreter = cassette.sent.select { |body| body[:tool_choice] || body["tool_choice"] }[index]
    generator = cassette.sent.reject { |body| body[:tool_choice] || body["tool_choice"] }[index]
    assert interpreter, "missing interpreter payload #{index + 1}"
    assert_equal "claude-haiku-5-5", interpreter[:model]
    assert_equal 512, interpreter[:max_tokens]
    assert_equal({ effort: "high" }, interpreter[:output_config])
    assert_equal "turn_perception", interpreter.dig(:tool_choice, :name)
    assert_nil interpreter[:temperature]
    assert_nil interpreter[:thinking]
    assert generator, "missing generator payload #{index + 1}"
    assert_equal "claude-haiku-5-5", generator[:model]
    assert_equal 4_000, generator[:max_tokens]
    assert_equal({ type: "adaptive", display: "summarized" }, generator[:thinking])
    assert_nil generator[:output_config]
    assert_nil generator[:tools]
    assert_equal Rag::CompanionDirectAnswer::SYSTEM_PROMPT, generator[:system]
  end

  def assert_cited(name, number, answer, body)
    spec = DECISIVE[name]
    return unless spec && number == spec["turn"]

    assert_includes answer, "[1]"
    cited = Array(body["citations"])
    assert cited.any? { |item| item["page"].to_i == spec["page"] }, cited.pluck("page").inspect
  end

  def assert_decisive(name, cassette)
    spec = DECISIVE[name]
    return unless spec

    row = cassette.returned[spec["turn"] - 1].to_a.find { |item|
      item.uri.to_s.end_with?(spec["suffix"]) && item.page.to_i == spec["page"]
    }
    assert row, cassette.returned[spec["turn"] - 1].to_a.map(&:uri).inspect
    assert_equal spec["sha256"], Digest::SHA256.hexdigest(row.text)
  end

  def with_doubles(cassette)
    block_network
    original_anthropic = Anthropic::Client.method(:new)
    original_agent = Aws::BedrockAgentRuntime::Client.method(:new)
    Anthropic::Client.define_singleton_method(:new) { |*, **| cassette }
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*, **| cassette }
    yield
  ensure
    Anthropic::Client.define_singleton_method(:new) { |*args, **kwargs| original_anthropic.call(*args, **kwargs) } if original_anthropic
    if original_agent
      Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args, **kwargs|
        original_agent.call(*args, **kwargs)
      }
    end
  end

  def block_network
    return if Net::HTTP.ancestors.include?(NetworkBlock)

    Net::HTTP.prepend(NetworkBlock)
  end

  def load_turns(relative)
    root = Rails.root.join(relative)
    flunk("falta el fixture #{relative}") unless root.directory?

    root.glob("turn-*.json").sort_by { |path| path.basename.to_s[/\d+/].to_i }.map { |path| TurnCapture.load(path) }
  end

  def reloaded_session
    ConversationSession.find_by!(identifier: @user.id.to_s, channel: "web", account_id: @account.id)
  end

  def failure_detail(name, number, body, cassette)
    {
      "script" => name,
      "turn" => number,
      "answer" => body["answer"].to_s.truncate(500),
      "query" => cassette.queries[number - 1],
      "message" => body["message"]
    }.to_json
  end

  def write_trace(name, number, body, events, cassette, index: number - 1)
    directory = Rails.root.join("tmp/field_companion/haiku55_offline", name, format("turn-%d", number))
    FileUtils.mkdir_p(directory)
    File.write(directory.join("published.txt"), body["answer"].to_s)
    File.write(directory.join("trace.json"), JSON.generate(
      "answer" => body["answer"],
      "query" => cassette.queries[index],
      "filter" => cassette.filters[index],
      "http" => body,
      "technician_message" => reloaded_session.conversation_history.reverse.find { |row| row["role"] == "user" },
      "model_payloads" => cassette.sent,
      "episode" => reloaded_session.active_episode,
      "focus" => reloaded_session.document_focus_entries,
      "events" => events
    ))
  end

  module NetworkBlock
    def connect(*)
      raise "offline network blocked" if Thread.current[:haiku55_block_net]

      super
    end
  end

  # One fixture turn from script/field_companion/haiku55_journey_fixtures.rb.
  # Rows keep the Retrieve order and the page value the knowledge base sent.
  class TurnCapture
    def self.load(path)
      data = JSON.parse(path.read)
      new(data)
    end

    def initialize(data)
      @question = data.fetch("question")
      @tool_input = data.fetch("tool_input")
      @rows = data.fetch("rows").map { |row| row.merge("sha256" => Digest::SHA256.hexdigest(row["content"].to_s)) }
      @raw = data.fetch("generator_text")
      @stop_reason = data["stop_reason"].presence || "end_turn"
      @retrieve_query = data.fetch("retrieve_query")
      @rerank_sha256 = Array(data["rerank_sha256"])
      @generator_messages_sha256 = data["generator_messages_sha256"]
      @retrieve_failure = data["retrieve_failure"]
    end

    attr_reader :question, :rows, :raw, :stop_reason, :retrieve_query, :rerank_sha256,
      :generator_messages_sha256, :retrieve_failure
    attr_accessor :tool_input
  end

  class JourneyCassette
    def initialize(turns, viewer_id:, focus_uri:)
      @turns = turns
      @viewer_id = viewer_id
      @focus_uri = focus_uri
      @index = 0
      @sent = []
      @queries = []
      @filters = []
      @sizes = []
      @returned = []
    end

    attr_reader :sent, :queries, :filters, :sizes, :returned

    def messages
      self
    end

    def create(**payload)
      @sent << payload
      turn = @turns[@index] or raise "model call without a turn"
      if payload[:tool_choice] || payload["tool_choice"]
        reply(turn.tool_input, "tool_use", tool: true)
      else
        raise Anthropic::Errors::APITimeoutError.new(url: URI("https://api.anthropic.com/v1/messages")) if turn.raw == :timeout

        @index += 1

        answer = turn.raw
        if answer.is_a?(String) && answer.match?(/\[p\d+\]/)
          prompt = payload.fetch(:messages).last.fetch(:content).pluck(:text).join
          answer = answer.gsub(/\[p(\d+)\]/) do
            page = Regexp.last_match(1)
            marker = prompt[/^\[(\d+)\] [^\n]+, página #{page}(?:\D|$)/, 1]
            "[#{marker || raise("pinned page #{page} missing from generator")}]"
          end
        end
        reply(answer, turn.stop_reason, tool: false)
      end
    end

    def retrieve(params)
      turn = @turns[@index] or raise "retrieve without a turn"
      config = params[:retrieval_configuration] || params["retrieval_configuration"] || {}
      vector = config[:vector_search_configuration] || config["vector_search_configuration"] || {}
      query = params.dig(:retrieval_query, :text) || params.dig("retrieval_query", "text")
      @queries << query
      @filters << (vector[:filter] || vector["filter"])
      @sizes << (vector[:number_of_results] || vector["number_of_results"])
      raise Aws::BedrockAgentRuntime::Errors::ValidationException.new(nil, "replayed failure") if turn.retrieve_failure == query

      rows = turn.rows.select { |row| row["for_query"].nil? || row["for_query"] == query }
        .map { |row| Retrieved.new(row, @viewer_id, @focus_uri) }
      @returned << rows
      Aws::BedrockAgentRuntime::Types::RetrieveResponse.new(retrieval_results: rows)
    end

    # Scores follow the captured Cohere order, matched by body digest.
    def rerank(payload)
      order = @turns[@index].rerank_sha256
      sources = Array(payload[:sources] || payload["sources"])
      rows = sources.each_with_index.map { |source, index|
        text = source.dig(:inline_document_source, :text_document, :text).to_s
        rank = order.index(Digest::SHA256.hexdigest(text)) || order.size + index
        Struct.new(:index, :relevance_score).new(index, 1.0 / (rank + 1))
      }
      Struct.new(:results, :next_token).new(rows, nil)
    end

    def generator_messages_sha256(index)
      payload = sent.reject { |body| body[:tool_choice] || body["tool_choice"] }[index]
      return nil unless payload

      text = Array(payload[:messages]).map { |message|
        "#{message[:role]}:" + Array(message[:content]).map { |block| block[:text].to_s }.join
      }.join("\n---\n")
      Digest::SHA256.hexdigest(text.sub(PENDING_SCOPE, "").sub("Responde primero a la consulta actual. ", ""))
    end

    # The fixtures predate this sentence of the referral note. Everything
    # else in the generator message must still match them byte for byte.
    PENDING_SCOPE = "Lo que falta no incluye un componente, ajuste o modo cuya condición o ejemplo documentado depende " \
      "de algo que el técnico ya descartó. "

    def retrieve_and_generate(*, **)
      raise "bedrock retrieve_and_generate is blocked"
    end

    private

    # The live client returns SDK models, not hashes: blocks are typed
    # objects and enums are symbols.
    def reply(value, stop_reason, tool:)
      content = if tool
        [ { type: :tool_use, id: "tool-1", name: "turn_perception", input: value } ]
      else
        [ { type: :text, text: value.to_s } ]
      end
      Anthropic::Models::Message.new(
        id: "msg-replay", type: :message, role: :assistant, model: "claude-haiku-5-5",
        stop_reason: stop_reason.to_sym, stop_sequence: nil, content: content,
        usage: { input_tokens: 32, output_tokens: 16 }
      )
    end
  end

  class Retrieved
    CAPTURE_BUCKET_PREFIX = "s3://multimodal-source-destination/"

    def initialize(row, viewer_id, focus_uri)
      @text = row["content"].to_s
      @content = Aws::BedrockAgentRuntime::Types::RetrievalResultContent.new(text: @text)
      @score = row["score"]
      bucket, = KbDocument.canonical_source(focus_uri)
      @uri = replay_uri(row["uri"], bucket)
      source_uri = replay_uri(row["original_source_uri"], bucket) || focus_uri
      @page = row["page"]
      @location = Aws::BedrockAgentRuntime::Types::RetrievalResultLocation.new(
        type: "S3", s3_location: Aws::BedrockAgentRuntime::Types::RetrievalResultS3Location.new(uri: @uri)
      )
      @metadata = {
        "account_id" => viewer_id.to_s,
        "original_source_uri" => source_uri,
        "x-amz-bedrock-kb-source-uri" => @uri,
        "page_number" => @page,
        "canonical_name" => row["document"],
        "original_filename" => File.basename(source_uri)
      }
    end

    attr_reader :content, :score, :location, :metadata, :uri, :page, :text

    private

    # The rows came from production; local fixture documents use the KB bucket
    # configured at boot. Rebase only that captured bucket, keeping the object
    # keys (including other manuals) and the captured passage bytes unchanged.
    def replay_uri(uri, bucket)
      return uri unless uri&.start_with?(CAPTURE_BUCKET_PREFIX)

      "s3://#{bucket}/#{uri.delete_prefix(CAPTURE_BUCKET_PREFIX)}"
    end
  end
end
