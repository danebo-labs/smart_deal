# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/haiku55_journey_rubric")

# Authenticated HTTP replay of the twelve Opus turns. External calls are the
# captured interpreter tool, the captured Retrieve bodies, and the captured
# generator text. Focus, the Retrieve query, the evidence, and the published
# answer are the product path.
class FieldCompanionHaiku55JourneyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

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
      assert_equal 1, cassette.filters.size
      assert_revision_scope(cassette, document)
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

  # Original CEA15+ script. The passage and generations are synthetic; the
  # route, filter, episode, pending question and publication are the product.
  test "revision CEA original script stays on the pin, asks the label once and never enters the Bedrock generator" do
    document = revision_pin(:cea)
    episode = nil
    asked = CEA_SCRIPT.each_with_index.map do |question, index|
      body, cassette = revision_ask("cea-script", index + 1, cea_turn(question, document, move: index.zero? ? "report" : "follow_up"), document)
      assert_revision_scope(cassette, document)
      assert_equal 1, cassette.sent.count { |payload| !payload[:tool_choice] }, "T#{index + 1}"
      assert_equal [ 24 ], body.fetch("citations").pluck("page"), "T#{index + 1}"
      assert_equal [ document.id ], reloaded_session.focus_document_ids
      episode ||= reloaded_session.live_episode_id
      assert_equal episode, reloaded_session.live_episode_id
      assert_empty Haiku55JourneyRubric.reasons("cea", index + 1, body.fetch("answer"), CEA_SCRIPT)
      body.fetch("answer").include?(I18n.t("rag.controller_label_question", locale: :es))
    end
    assert_equal [ true, false, false, false, false, false, false ], asked
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

  private

  def revision_turns(name)
    data = JSON.parse(Rails.root.join(REVISION_FIXTURES, "#{name}.json").read)
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

  def assert_revision_scope(cassette, *documents)
    uris = cassette.filters.sole.to_json.scan(/s3:[^"]+/).uniq
    assert_equal documents.map(&:canonical_uri).sort, uris.sort
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

  def cea_turn(question, document, passage: CEA_PASSAGE, raw: cea_reference, move: "report", resolution: nil)
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
        "original_source_uri" => document.canonical_uri, "document" => "CEA15+", "page" => 24, "score" => 0.9
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
    assert_equal "99862136fb664f55b182ff77b900e5268d304d3df982b582d17f992830cda4ae",
      Digest::SHA256.hexdigest(generator[:system].to_s)
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
    end

    attr_reader :question, :rows, :raw, :stop_reason, :retrieve_query, :rerank_sha256,
      :generator_messages_sha256
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
      @returned = []
    end

    attr_reader :sent, :queries, :filters, :returned

    def messages
      self
    end

    def create(**payload)
      @sent << payload
      turn = @turns[@index] or raise "model call without a turn"
      if payload[:tool_choice] || payload["tool_choice"]
        reply(turn.tool_input, "tool_use", tool: true)
      else
        @index += 1
        raise Anthropic::Errors::APITimeoutError.new(url: URI("https://api.anthropic.com/v1/messages")) if turn.raw == :timeout

        reply(turn.raw, turn.stop_reason, tool: false)
      end
    end

    def retrieve(params)
      turn = @turns[@index] or raise "retrieve without a turn"
      config = params[:retrieval_configuration] || params["retrieval_configuration"] || {}
      vector = config[:vector_search_configuration] || config["vector_search_configuration"] || {}
      query = params.dig(:retrieval_query, :text) || params.dig("retrieval_query", "text")
      @queries << query
      @filters << (vector[:filter] || vector["filter"])
      rows = turn.rows.map { |row| Retrieved.new(row, @viewer_id, @focus_uri) }
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
      Digest::SHA256.hexdigest(text.sub(PENDING_SCOPE, ""))
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
