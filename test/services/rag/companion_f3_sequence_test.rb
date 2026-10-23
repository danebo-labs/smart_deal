# frozen_string_literal: true

require "test_helper"

# T1 to T4 through the reducer, the plan check, the render, and the history
# the next turn actually reads. No model and no remote storage.
class Rag::CompanionF3SequenceTest < ActiveSupport::TestCase
  TURNS = [
    "Estoy con un operador de puerta Fermator VF5+. La puerta se reabre sola. El LED de fotocélula está apagado. No veo obstrucción. No he comprobado el #54. No hice mediciones.",
    "Corrijo solo el estado del LED: el LED de fotocélula está encendido, no apagado.",
    "Ya revisé la fotocélula y no está activada.",
    "¿qué sigue?"
  ].freeze
  MANUAL = <<~TEXT
    [DOCUMENT: vf5.pdf]
    [PDF_PAGE: 7]
    5.6 Indicador
    LED encendido cuando la fotocélula o la entrada de re-apertura está activada.
    [PDF_PAGE: 12]
    • La puerta se re-abre sola.
    – Comprobar la sensibilidad del #54.
    – Comprobar que la fotocélula no esté activada.
    – Comprobar que no hay una obstrucción mecánica en la puerta.
    [PDF_PAGE: 13]
    – En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta.
    • La puerta se vuelve a abrir cuando el patín está cerrando.
    – Comprobar la regulación del patín.
    [NOTA_EXTRACCION] Note: the meaning of the codes is not on the page.
    [CONFLICTO_DOCUMENTAL C1: el texto rotula «N» y otra página rotula «Nm».]
    Diagrama de la página (etiquetas literales):
    20 receptor
  TEXT

  test "the four turns keep the case, the correction, and the published antecedent" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: Time.current)
    settle(episode, {
      "move" => "report",
      "assertions" => [ { "span" => "Fermator", "act" => "assert" }, { "span" => "VF5+", "act" => "assert" } ],
      "observations" => [ "La puerta se reabre sola", "El LED de fotocélula está apagado", "No veo obstrucción" ],
      "pending_resolution" => nil,
      "clarification_target" => nil,
      "checks" => [ { "subject" => "#54", "status" => "not_done", "result" => nil } ]
    }, TURNS[0], "query:t1")

    assert episode.observations.any? { |row| row["text"].include?("apagado") }
    assert episode.observations.any? { |row| row["text"].include?("No veo obstrucción") }
    assert episode.checks.none? { |row| Array(row["operation"]).include?("measure") }
    assert_equal [ "not_done" ], episode.checks.pluck("status")
    assert_equal [ "check" ], episode.checks.first["operation"]

    settle(episode, {
      "move" => "correct",
      "assertions" => [],
      "observations" => [ "el LED de fotocélula está encendido, no apagado" ],
      "pending_resolution" => nil,
      "clarification_target" => nil,
      "checks" => []
    }, TURNS[1], "query:t2")
    texts = episode.observations.pluck("text")
    assert texts.any? { |text| text.downcase.include?("encendido") }
    assert texts.none? { |text| text.downcase.include?("apagado") }
    assert_equal "not_done", episode.checks.first["status"]

    settle(episode, {
      "move" => "report",
      "assertions" => [],
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil,
      "checks" => [ { "subject" => "fotocélula", "status" => "done", "result" => "no está activada" } ]
    }, TURNS[2], "query:t3")
    photocell = episode.checks.find { |row| row["subject"] == "fotocélula" }
    assert_equal "done", photocell["status"]
    assert_equal "no está activada", photocell["result"]
    assert_equal [ "check" ], photocell["operation"]
    assert_equal "not_done", episode.checks.find { |row| row["subject"].include?("54") }["status"]

    session = session_for(episode)
    chunks = [ chunk ]
    statements = Rag::CompanionStatements.parse(chunks)
    note = statements.statements.find { |item| item.text.include?("NOTA_EXTRACCION") }
    assert_equal "extraction_note", note.kind
    assert_not_includes Rag::CompanionPlan::STATEMENT_KINDS, "extraction_note"
    facts = Rag::CompanionCaseFacts.build(episode, session: session)
    activation = statements.statements.find { |item| item.step? && item.text.include?("no esté activada") }
    compound = statements.statements.find { |item| item.step? && item.text.include?("desconectar") }
    skate = statements.statements.find { |item| item.step? && item.text.include?("patín") }
    question = "¿Se vuelve a abrir cuando el patín está cerrando?"
    checked = Rag::CompanionPlanCheck.call(
      {
        "links" => [ { "fact" => facts.find("C1").id, "statement" => compound.id, "reading" => "" } ],
        "steps" => [ activation.id, compound.id, skate.id ],
        "question" => question
      },
      facts: facts, statements: statements, turns: TURNS
    )
    assert_equal [ "operation_mismatch" ], checked.rejections.select { |item| item["part"] == "link" }.pluck("reason")
    assert_includes checked.steps, activation.id
    assert_not_includes checked.steps, skate.id
    assert_equal "case_unconfirmed", checked.rejections.find { |item| item["part"] == "step" && item["value"] == skate.id }["reason"]
    assert_equal question, checked.question
    text = Rag::CompanionPlanRender.call(checked, facts: facts, statements: statements)
    activation_line = text.lines.find { |line| line.include?("no esté activada") }
    assert_includes activation_line, "ya informaste"
    assert_includes activation_line, "no está activada"
    compound_line = text.lines.find { |line| line.include?("desconectar") }
    assert_not_includes compound_line.to_s, "ya informaste"
    assert_includes text, question
    assert_not_includes text, "NOTA_EXTRACCION"
    assert_includes text, "Ojo, el documento no es coherente (C1)"
    assert_includes text, "rotula 'N'"
    assert_includes text, "rotula 'Nm'"
    published = Rag::CompanionTurnPublication.call(
      text: text,
      sources: [ { "index" => 1, "content" => MANUAL, "applicability" => "compatible", "reference_only" => false } ],
      technician_texts: TURNS + episode.observations.pluck("text") + episode.checks.flat_map { |row| [ row["subject"], row["result"] ] }.compact,
      manufacturer: "Fermator"
    )
    assert published.accepted?, published.reasons.inspect

    session.update!(conversation_history: session.conversation_history + [
      { "role" => "assistant", "content" => text, "prompt_reply" => text, "correlation_id" => "query:t3", "ts" => Time.current.iso8601 }
    ])
    prepared = Rag::CompanionPlan.prepare(
      raw_question: TURNS[3], chunks: chunks, episode: episode, session: session, correlation_id: "query:t4"
    )
    assert_includes prepared.user, "no está activada"
    assert_includes prepared.user, text.lines.first
    assert_not_includes prepared.user, "NOTA_EXTRACCION"
    assert_includes prepared.facts.prompt_block, "encendido"
    assert_not_includes prepared.facts.prompt_block, "apagado"

    clarified = episode.fork
    clarified.append_observation!("Se vuelve a abrir justo cuando el patín está cerrando", correlation_id: "query:t5")
    clarified_facts = Rag::CompanionCaseFacts.build(clarified, session: session)
    reported = clarified_facts.facts.find { |item| item.text.include?("justo cuando el patín") }
    skate_item = statements.statements.find { |item| item.kind == "item" && item.text.include?("patín") }
    follow = Rag::CompanionPlanCheck.call(
      {
        "links" => [ { "fact" => reported.id, "statement" => skate_item.id, "reading" => "" } ],
        "steps" => [ activation.id, skate.id ],
        "question" => question
      },
      facts: clarified_facts, statements: statements, turns: TURNS + [ "Se vuelve a abrir justo cuando el patín está cerrando" ]
    )
    assert_nil follow.question
    assert_includes follow.steps, skate.id
    follow_text = Rag::CompanionPlanRender.call(follow, facts: clarified_facts, statements: statements)
    assert_includes follow_text, "Para lo que informaste, «Se vuelve a abrir justo cuando el patín está cerrando», la documentación indica en «La puerta se vuelve a abrir cuando el patín está cerrando»"
    assert_not_includes follow_text, question
  end

  private

  def settle(episode, raw, turn, correlation_id)
    with_flags do
      perception = Rag::TurnPerception.build(raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil)
      decision = Rag::RoutePolicy.call(previous: episode, perception: perception, focus_count: 0, locale: :es)
      Rag::WorkContextReducer.apply!(
        episode: episode, perception: perception, decision: decision,
        turn: turn, correlation_id: correlation_id, now: Time.current
      )
    end
  end

  def session_for(episode)
    ConversationSession.create!(
      identifier: "web:f3-sequence-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy),
      active_episode: episode.to_h,
      conversation_history: TURNS.first(3).each_with_index.map { |text, index|
        { "role" => "user", "content" => text, "correlation_id" => "query:t#{index + 1}", "ts" => (4 - index).minutes.ago.iso8601 }
      }
    )
  end

  def chunk
    {
      content: MANUAL,
      metadata: { "canonical_name" => "Operador VF5+", "page_number" => "12", "original_source_uri" => "s3://example/vf5.pdf" },
      identity_applicability: "compatible"
    }
  end

  def with_flags
    keys = %w[FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED HAIKU_QUERY_ANALYSIS_MODE]
    previous = keys.index_with { |key| ENV[key] }
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
