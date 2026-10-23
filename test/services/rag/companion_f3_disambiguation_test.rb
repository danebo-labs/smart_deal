# frozen_string_literal: true

require "test_helper"
require_relative "../../support/companion_plan_response"

# F3 asks, keeps a partial answer, and orients only when the case matches.
# Captured plans are replayed locally. No model call.
class Rag::CompanionF3DisambiguationTest < ActiveSupport::TestCase
  SKATE = "La puerta se vuelve a abrir cuando el patín está cerrando"
  LAHIRI = "Cuando la puerta cierra, el patín todavía no ha empezado a cerrar"
  PARTIAL = "Mientras se está cerrando; no distingo qué parte"
  BEFORE = "Se reabre durante el cierre de la puerta, antes de que el patín empiece a cerrar"
  DURING = "Se vuelve a abrir justo cuando el patín está cerrando"
  MANUAL = <<~TEXT
    • La puerta se re-abre sola.
    – Comprobar que la fotocélula no esté activada.
    – Comprobar que no hay una obstrucción mecánica en la puerta.
    – Verificar si los LEDs de obstrucción se encienden.
    • #{SKATE}.
    – Comprobar la regulación del patín, ya que probablemente el patín roza. Verificar si los LEDs de obstrucción se encienden.
  TEXT
  CAPTURE = Rails.root.join("tmp/field_companion/vf5_correction/f2f3_joint/runs/20261023T182442Z-conversation")
  Q1_RUN = Rails.root.join("tmp/field_companion/vf5_correction/f2f3_joint/runs/20261023T204654Z-q1")
  KB = Rails.root.join("tmp/field_companion/vf5_correction/f2f3_joint/f2/candidate_r2/kb")
  DEFINITIONS = {
    "1f1bc47d81282a868b149e555545a73adefdf7cc871c5b831dc74f8f8f5d0a89" => <<~TEXT,
      5.11 Seguridad (54)
      Potenciómetro que permite ajustar la fuerza de cierre de la puerta (sensibilidad a reaperturas).
      Esta valor es regulable de 60 a 150Nm.
    TEXT
    "df2848fc87ec5110133a34dd86730a09d7857bf6a94effd3a6c421e50c672e4d" => <<~TEXT
      5.5 Otras entradas (26, 21, 25, 23)
      21.- Re-apertura
      Esta señal se usa para instalar el interruptor de la puerta de cabina o una barrera externa.
      Para activar esta señal, se debe conectar la entrada re-apertura (21) con la entrada de +12V (23).
      Utilizar contactos libres de tensión.
      La señal de re-apertura tiene prioridad sobre la señal cerrar.
    TEXT
  }.freeze

  test "a negation after the noun and an unknown construction stay unresolved or incompatible" do
    lahiri = relation(LAHIRI, SKATE)
    assert_equal :incompatible, lahiri.relation
    assert_equal "patin:negation", lahiri.reason
    assert_equal :incompatible, relation("no es cuando el patín está cerrando", SKATE).relation
    assert_equal :incompatible, relation(BEFORE, SKATE).relation
    assert_equal "patin:before/during", relation(BEFORE, SKATE).reason
    assert_equal :compatible, relation(DURING, SKATE).relation
    assert_equal :compatible, relation("se reabre mientras cierra el patín", SKATE).relation
    closed = relation("Se reabre al cerrar", SKATE)
    assert_equal :unresolved, closed.relation
    assert_equal "anchor_missing", closed.reason
    partial = relation(PARTIAL, SKATE)
    assert_equal :unresolved, partial.relation
    assert_equal "anchor_missing", partial.reason
    rub = relation("el patín roza", SKATE)
    assert_equal :unresolved, rub.relation
    assert_equal "condition_not_stated", rub.reason
    unknown = relation("salvo cuando el patín está cerrando", SKATE)
    assert_equal :unresolved, unknown.relation
    assert_equal "unrecognized", unknown.reason
    assert_equal :compatible, relation("antes de la marcha", "antes de la marcha", "La bomba pierde presión").relation
    during = relation("durante la marcha", "antes de la marcha", "La bomba pierde presión")
    assert_equal :incompatible, during.relation
    assert_match(/during\/before|before\/during/, during.reason)
    running = relation("aparece ya en marcha", "durante la marcha", "La bomba pierde presión")
    assert_equal :unresolved, running.relation
    assert_equal "condition_not_stated", running.reason
    restricted = relation("cuando el patín está cerrando", "El patín roza la guía")
    assert_equal :unresolved, restricted.relation
    assert_equal "fact_restricted", restricted.reason
    assert_not Rag::CompanionCaseRelation.explicit_correction?("Corrijo solo el estado del LED")
    assert Rag::CompanionCaseRelation.explicit_correction?("me equivoqué: ocurre cuando el patín está cerrando")
  end

  # Local product replay. The sentence below is the question Haiku sent on
  # 20261023T213823Z-q1p. This test does not call the model and does not say
  # what a later generation would write. The published question is derived
  # by Ruby from the report and the documentary step.
  MODEL_QUESTION = "¿Has comprobado manualmente que no hay obstrucción mecánica en la puerta, o solo la observaste visualmente?"
  Q1P_RUN = Rails.root.join("tmp/field_companion/vf5_correction/f2f3_joint/runs/20261023T213823Z-q1p")
  REPORT = "No veo obstrucción"
  PARTIAL_SCOPE = "El marco de la puerta, nada más"

  test "a neutral clarification of the obstruction report is published and a partial answer binds" do
    content = <<~TEXT
      • La puerta se re-abre sola.
      – Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).
      – Comprobar que la fotocélula no esté activada.
      – Comprobar que no hay una obstrucción mecánica en la puerta.
      – En caso que el problema persiste, desconectar la fotocélula y pulsar TEST.
      • El patín no se mueve.
      – Verificar manualmente el movimiento del patín.
    TEXT
    statements = Rag::CompanionStatements.parse([ obstruction_chunk(content) ])
    obstruction = statements.statements.find { |item| item.step? && item.text.include?("obstrucción mecánica") }
    parent = statements.statements.find { |item| item.kind == "item" && item.text.include?("re-abre") }
    episode = episode_for("La puerta se reabre sola", [ "La puerta se reabre sola", REPORT, "el LED de fotocélula está encendido" ])
    episode.write_fact!("manufacturer", status: "known", value: "Fermator", source: "user", correlation_id: "query:f3", at: Time.current.iso8601)
    episode.write_fact!("model", status: "known", value: "VF5+", source: "user", correlation_id: "query:f3", at: Time.current.iso8601)
    episode.upsert_check!({ "subject" => "#54", "status" => "not_done" }, correlation_id: "query:f3")
    episode.upsert_check!({ "subject" => "fotocélula", "status" => "done", "result" => "no está activada" }, correlation_id: "query:f3")
    episode_id = episode.episode_id
    facts = Rag::CompanionCaseFacts.build(episode)
    plan = {
      "steps" => statements.statements.select(&:step?).map(&:id),
      "question" => MODEL_QUESTION,
      "question_about" => [ obstruction.id ]
    }

    checked = check_plan(plan, facts, statements)
    assert_equal "modality:manualmente,visualmente", rejection(checked, "question")
    assert_includes checked.question, "«#{REPORT}»"
    assert_includes checked.question, "obstrucción mecánica"
    assert_not_equal MODEL_QUESTION, checked.question
    assert_not_includes checked.question, "manualmente"
    assert_not_includes checked.question, "visualmente"
    assert_equal [ parent.id ], checked.question_targets
    assert_equal :related, Rag::ReportedOperation.correspondence(
      report_text: REPORT, result: nil, status: "done", statement_text: obstruction.text
    )

    text = render_of(checked, statements, facts)
    assert_includes text, checked.question
    assert_includes text, "no consta como hecha"
    published = publish_case(text, episode, content)
    assert published.accepted?, published.reasons.inspect
    history = Rag::FieldCaseRecord.attach(text, episode: episode, generation_mode: nil, companion_turn: true)
    assert_equal text, history.history
    assert_equal text, history.presented

    prepared = Rag::CompanionPlan::Prepared.new(
      params: {}, system: "", user: "", facts: facts, statements: statements,
      turns: [ "¿Qué sigue?" ], chunks: [ obstruction_chunk(content) ]
    )
    composed = Rag::CompanionPlan.compose(CompanionPlanResponse.build(plan), prepared)
    assert_equal checked.question, composed.pending["question"]
    assert_equal "La puerta se re-abre sola.", composed.pending.dig("targets", 0, "item")
    assert_equal "chunk_p12_5.txt", composed.pending.dig("targets", 0, "filename")
    assert_equal "12", composed.pending.dig("targets", 0, "page")
    dropped = Rag::CompanionPlan.compose(
      CompanionPlanResponse.build({ "question" => "¿Usaste el multímetro en la obstrucción?" }),
      prepared
    )
    assert_nil dropped.pending
    repeated = check_plan({ "question" => "¿Has comprobado manualmente el #54?" }, facts, statements)
    assert_match(/\Arepeats_fact:/, rejection(repeated, "question"))
    assert_nil repeated.question

    with_flags do
      Rag::ActiveEpisodeTurn.apply_assistant(
        state: episode, text: composed.text, pending_question: composed.pending, correlation_id: "query:local"
      )
    end
    assert_equal episode_id, episode.episode_id
    assert_equal "Fermator", episode.fact("manufacturer")["value"]
    assert_equal "VF5+", episode.fact("model")["value"]
    assert_equal checked.question, episode.pending_question["question"]
    assert episode.observations.any? { |row| row["text"] == "el LED de fotocélula está encendido" }
    assert episode.checks.any? { |row| row["subject"] == "fotocélula" && row["result"] == "no está activada" && row["status"] == "done" }
    assert episode.checks.any? { |row| row["subject"] == "#54" && row["status"] == "not_done" }

    settle(episode, follow_up(PARTIAL_SCOPE), PARTIAL_SCOPE, "query:local-partial")
    stored = episode.observations.find { |row| row["text"] == PARTIAL_SCOPE }
    assert_equal checked.question, stored.dig("answers", "q")
    assert_nil stored.dig("answers", "r")
    assert_equal "La puerta se re-abre sola.", stored.dig("answers", "t", 0, "item")
    assert_nil episode.pending_question
    assert_equal episode_id, episode.episode_id
    assert_equal "Fermator", episode.fact("manufacturer")["value"]

    later = Rag::CompanionCaseFacts.build(episode)
    second = check_plan(plan, later, statements)
    assert_nil second.question
    assert_not_includes render_of(second, statements, later), checked.question
    paraphrase = check_plan(
      { "question" => "¿La obstrucción mecánica en la puerta es lo que ves?", "question_about" => [ parent.id ] },
      later, statements
    )
    assert_nil paraphrase.question
    assert_not_includes render_of(paraphrase, statements, later), "es lo que ves"
  end

  test "local replay of the captured obstruction question publishes the clarification" do
    skip "captura q1p ausente" unless Q1P_RUN.exist? && KB.exist?

    call = Q1P_RUN.join("q1p_t1/calls").children.find { |path| path.basename.to_s.start_with?("02-companion") }
    plan = JSON.parse(call.join("raw_response.txt").read)
    stored = JSON.parse(call.join("state_before.json").read)
    episode = Rag::ActiveEpisode.parse(stored, now: Time.iso8601(stored["updated_at"]) + 60)
    chunks = JSON.parse(call.join("sources.json").read).fetch("sources").map { |source| live_chunk(source) }
    statements = Rag::CompanionStatements.parse(chunks)
    facts = Rag::CompanionCaseFacts.build(episode)
    turns = [ Q1P_RUN.join("q1p_t1/question.txt").read.strip ]
    checked = Rag::CompanionPlanCheck.call(plan, facts: facts, statements: statements, turns: turns)

    assert_equal MODEL_QUESTION, plan["question"]
    assert_equal "modality:manualmente,visualmente", rejection(checked, "question")
    assert_includes checked.question, "«#{REPORT}»"
    assert_includes checked.question, "obstrucción mecánica"
    assert_not_equal MODEL_QUESTION, checked.question
    assert_not_includes checked.question, "manualmente"
    assert_not_includes checked.question, "visualmente"

    prepared = Rag::CompanionPlan::Prepared.new(
      params: {}, system: "", user: "", facts: facts, statements: statements, turns: turns, chunks: chunks
    )
    composed = Rag::CompanionPlan.compose(CompanionPlanResponse.build(plan), prepared)
    assert_includes composed.text, checked.question
    assert_not_includes composed.text, "movimiento del patín"
    assert_equal checked.question, composed.pending["question"]
    target = composed.pending["targets"].first
    assert_includes target["item"], "La puerta se re-abre sola"
    assert_equal "chunk_p12_5.txt", target["filename"]
    assert_equal "12", target["page"]
    history = Rag::FieldCaseRecord.attach(composed.text, episode: episode, generation_mode: nil, companion_turn: true)
    assert_equal composed.text, history.history
    sources = chunks.each_with_index.map { |chunk, index|
      { "index" => index + 1, "content" => chunk[:content], "applicability" => "compatible", "reference_only" => false }
    }
    technician = episode.observations.pluck("text") +
                 episode.checks.flat_map { |row| [ row["subject"], row["result"] ] } +
                 episode.identifiers.pluck("value")
    published = Rag::CompanionTurnPublication.call(
      text: composed.text, sources: sources, technician_texts: technician.compact, manufacturer: "Fermator"
    )
    assert published.accepted?, published.reasons.inspect

    episode_id = episode.episode_id
    with_flags do
      Rag::ActiveEpisodeTurn.apply_assistant(
        state: episode, text: composed.text, pending_question: composed.pending, correlation_id: "query:local-replay"
      )
    end
    settle(episode, follow_up(PARTIAL_SCOPE), PARTIAL_SCOPE, "query:local-replay-partial")
    answer = episode.observations.find { |row| row["text"] == PARTIAL_SCOPE }
    assert_equal checked.question, answer.dig("answers", "q")
    assert_nil answer.dig("answers", "r")
    assert_includes answer.dig("answers", "t", 0, "item"), "La puerta se re-abre sola"
    assert_equal episode_id, episode.episode_id
    assert_equal "Fermator", episode.fact("manufacturer")["value"]
    assert episode.observations.any? { |row| row["text"] == "el LED de fotocélula está encendido" }
    assert episode.checks.any? { |row| row["subject"] == "fotocélula" && row["result"] == "no está activada" }
    assert episode.checks.any? { |row| row["subject"] == "#54" && row["status"] == "not_done" }
    assert_nil episode.pending_question

    later = Rag::CompanionCaseFacts.build(episode)
    second = Rag::CompanionPlanCheck.call(plan, facts: later, statements: statements, turns: turns + [ PARTIAL_SCOPE ])
    assert_nil second.question
    assert_not_includes render_of(second, statements, later), checked.question
  end

  test "clarifying a report does not restore the incompatible skate procedure" do
    statements = statements_for
    skate = skate_step(statements)
    item = skate_item(statements)
    obstruction = statements.statements.find { |row| row.step? && row.text.include?("obstrucción mecánica") }
    facts = facts_for("La puerta se reabre sola", [ REPORT, BEFORE ])
    result = check_plan(
      {
        "links" => [ link_of("O2", item) ],
        "steps" => [ skate.id, obstruction.id ],
        "question" => MODEL_QUESTION,
        "question_about" => [ obstruction.id ]
      },
      facts, statements
    )

    assert_not_includes result.steps, skate.id
    assert_not_includes result.question.to_s, "patín"
    assert_not_includes result.question.to_s, "manualmente"
    assert_includes result.question, "«#{REPORT}»"
  end

  test "a question that only restates a fact is a repeat and one that adds another valve is not" do
    manual = "• La válvula V1 está cerrada.\n• La válvula V2 está abierta.\n"
    statements = Rag::CompanionStatements.parse([ chunk(manual) ])
    facts = facts_for("La válvula falla", [ "La válvula V1 está cerrada" ])
    same = check_plan({ "question" => "¿La válvula V1 está cerrada?" }, facts, statements)
    wider = check_plan({ "question" => "¿La válvula V1 está cerrada o la válvula V2 está abierta?" }, facts, statements)

    assert_match(/\Arepeats_fact:/, rejection(same, "question"))
    assert_equal "¿La válvula V1 está cerrada o la válvula V2 está abierta?", wider.question
  end

  test "an incompatibility vetoes the procedure and a later correction reopens only that item" do
    statements = statements_for
    skate = skate_step(statements)
    general = statements.statements.find { |item| item.step? && item.text.include?("fotocélula") }
    item = skate_item(statements)
    blocked_facts = facts_for("La puerta se reabre sola", [ LAHIRI ])
    blocked = check_plan(
      {
        "links" => [ link_of("O1", item) ],
        "steps" => [ general.id, skate.id ],
        "question" => "¿El patín está cerrando?",
        "question_about" => [ item.id ]
      },
      blocked_facts,
      statements
    )
    blocked_text = render_of(blocked, statements, blocked_facts)
    assert_not_includes blocked.steps, skate.id
    assert_equal "case_incompatible", rejection_for(blocked, "step", skate.id)
    assert_includes blocked.steps, general.id
    assert_includes blocked_text, "no coincide con esa condición"
    assert_not_includes blocked_text, "probablemente"

    applicable = facts_for(SKATE, [ LAHIRI ], answer: answer_for(item, "yes"))
    vetoed = check_plan({ "links" => [ link_of("O1", item) ], "steps" => [ skate.id ] }, applicable, statements)
    assert_equal "case_incompatible", rejection_for(vetoed, "step", skate.id)

    reopened = check_plan(
      { "links" => [ link_of("O1", item) ], "steps" => [ skate.id ] },
      facts_for("La puerta se reabre sola", [ LAHIRI, "me equivoqué: ocurre cuando el patín está cerrando" ]),
      statements
    )
    assert_includes reopened.steps, skate.id

    closed_again = check_plan(
      { "links" => [ link_of("O2", item) ], "steps" => [ skate.id ] },
      facts_for("La puerta se reabre sola", [ DURING, "en realidad el patín todavía no ha empezado a cerrar" ]),
      statements
    )
    assert_not_includes closed_again.steps, skate.id
    led = check_plan(
      { "links" => [ link_of("O1", item) ], "steps" => [ skate.id ] },
      facts_for("La puerta se reabre sola", [ LAHIRI, "Corrijo solo el estado del LED: está encendido" ]),
      statements
    )
    assert_not_includes led.steps, skate.id
  end

  test "a partial answer keeps the doubt and the next question is more concrete" do
    statements = statements_for
    item = skate_item(statements)
    skate = skate_step(statements)
    general = statements.statements.find { |item_row| item_row.step? && item_row.text.include?("fotocélula") }
    first = "¿El patín está cerrando?"
    opening_facts = facts_for("La puerta se reabre sola", [ "El LED de fotocélula está encendido" ])
    opening = check_plan(
      { "steps" => [ general.id ], "question" => first, "question_about" => [ item.id ] },
      opening_facts,
      statements
    )
    text = render_of(opening, statements, opening_facts)
    assert opening.usable?
    assert_equal first, opening.question
    assert_includes text, "Para orientar falta un dato"
    assert_includes text, first
    assert_not_includes opening.steps, skate.id
    published = publish(text)
    assert published.accepted?, published.reasons.inspect

    episode = episode_for("La puerta se reabre sola", [ "El LED de fotocélula está encendido" ])
    install_pending(episode, opening, statements)
    assert_equal "documented_context", episode.pending_question["type"]
    assert_equal first, episode.pending_question["question"]

    settle(episode, {
      "move" => "follow_up", "assertions" => [], "observations" => [ PARTIAL ],
      "pending_resolution" => nil, "clarification_target" => nil, "checks" => []
    }, PARTIAL, "query:partial")
    stored = episode.observations.find { |row| row["text"].include?("no distingo") }
    assert_equal first, stored.dig("answers", "q")
    assert_nil stored.dig("answers", "r")
    assert_nil episode.pending_question

    partial_facts = facts_for("La puerta se reabre sola", [ "El LED de fotocélula está encendido", PARTIAL ], answer: stored["answers"])
    second = check_plan(
      { "links" => [ link_of("O2", item) ], "steps" => [ general.id, skate.id ], "question" => "" },
      partial_facts, statements
    )
    assert_includes second.question, "Qué parte se está cerrando"
    assert_includes second.question, "la puerta o el patín"
    assert_not_includes second.question, SKATE
    assert_not_includes second.question, "Lo que ves coincide"
    assert_not_equal first, second.question
    assert_not_includes second.steps, skate.id
    assert_nil second.rejections.find { |row| row["reason"] == "already_answered" }

    repeated = check_plan(
      { "links" => [ link_of("O2", item) ], "steps" => [ general.id, skate.id ], "question" => first, "question_about" => [ item.id ] },
      partial_facts, statements
    )
    assert_equal second.question, repeated.question
    assert_not_includes repeated.question, SKATE

    narrowed = render_of(second, statements, partial_facts)
    assert_includes narrowed, "falta distinguir la parte"
    assert_not_includes narrowed, first
    assert_not_includes narrowed, SKATE
    assert_not_includes narrowed, "probablemente"
    assert publish(narrowed).accepted?, publish(narrowed).reasons.inspect

    later = facts_for("La puerta se reabre sola", [ "El LED de fotocélula está encendido", BEFORE ], answer: stored["answers"])
    branch_a = check_plan(
      {
        "links" => [ link_of("O2", item) ],
        "steps" => [ general.id, skate.id ],
        "question" => second.question,
        "question_about" => [ item.id ]
      },
      later,
      statements
    )
    branch_a_text = render_of(branch_a, statements, later)
    assert_not_includes branch_a.steps, skate.id
    assert_nil branch_a.question
    assert_equal "already_answered", rejection(branch_a, "question")
    assert_includes branch_a.steps, general.id
    assert_includes branch_a_text, "no coincide con esa condición"
    assert_not_includes branch_a_text, "probablemente"
    assert_includes branch_a_text, "fotocélula"

    matched = facts_for("La puerta se reabre sola", [ "El LED de fotocélula está encendido", DURING ])
    branch_b = check_plan(
      {
        "links" => [ link_of("O2", item) ],
        "steps" => [ general.id, skate.id ],
        "question" => second.question,
        "question_about" => [ item.id ]
      },
      matched,
      statements
    )
    branch_b_text = render_of(branch_b, statements, matched)
    assert_includes branch_b.steps, skate.id
    assert_includes branch_b_text, "probablemente"
    assert_includes branch_b_text, DURING
    assert_not_includes branch_b_text, second.question
  end

  test "a check result is not an identifier and a removed question leaves no pending" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:c1", now: Time.current)
    episode.assign_goal!("La puerta se reabre sola", correlation_id: "query:c1")
    raw = {
      "move" => "report",
      "assertions" => [ { "span" => "VF5+", "act" => "assert" }, { "span" => "no está activada", "act" => "assert" } ],
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil,
      "checks" => [ { "subject" => "fotocélula", "status" => "done", "result" => "no está activada" } ]
    }
    seen = perception_for(episode, raw, "Ya revisé la fotocélula y no está activada.")
    assert_includes seen.identifiers.map(&:value), "no está activada"
    settle(episode, raw, "Ya revisé la fotocélula y no está activada.", "query:c1")
    assert_not_includes episode.identifiers.pluck("value"), "no está activada"

    skip "captura F3 ausente" unless CAPTURE.exist?

    stored = JSON.parse(CAPTURE.join("t3/episode_after.json").read)
    parsed = Rag::ActiveEpisode.parse(stored, now: Time.iso8601(stored["updated_at"]) + 60)
    facts = Rag::CompanionCaseFacts.build(parsed)
    assert_includes facts.facts.map(&:text), "Fermator VF5+"
    assert_not_includes facts.facts.select { |fact| fact.kind == "identity" }.map(&:text), "no está activada"
    kept = stored.deep_dup
    kept["identifiers"].last["correlation_id"] = "query:other"
    other = Rag::CompanionCaseFacts.build(Rag::ActiveEpisode.parse(kept, now: Time.iso8601(kept["updated_at"]) + 60))
    assert_includes other.facts.select { |fact| fact.kind == "identity" }.map(&:text), "no está activada"

    statements = statements_for
    item = skate_item(statements)
    composed = Rag::CompanionPlan.compose(
      CompanionPlanResponse.build({ "links" => [], "steps" => [], "question" => "¿El patín está cerrando?", "question_about" => [ item.id ] }),
      prepared_for(statements, facts_for("La puerta se reabre sola", []))
    )
    assert_equal "documented_context", composed.pending["type"]
    assert_includes composed.text, composed.pending["question"]
    empty = Rag::CompanionPlan.compose(
      CompanionPlanResponse.build({ "links" => [], "steps" => [], "question" => "¿Ajustaste el #54 a 100?", "question_about" => [ item.id ] }),
      prepared_for(statements, facts_for("La puerta se reabre sola", []))
    )
    assert_nil empty.pending
    host = Object.new.extend(RagQueryConcern)
    attached = RagQueryConcern::CompanionPublication.new(
      presented: "No puedo orientarte con la documentación cargada.", history: "", route_outcome: :abstained, companion_reason: "companion_contract_invalid"
    )
    assert_nil host.send(:companion_published_pending, composed.pending, attached)
  end

  test "documented answers stay partial until the closed reply and do not change the route" do
    statements = statements_for
    item = skate_item(statements)
    episode = episode_for("La puerta se reabre sola", [])
    question = {
      "type" => "documented_context", "question" => "¿El patín está cerrando?",
      "targets" => [ { "item" => item.text, "document_key" => "s3://fixture/vf5.pdf", "filename" => "vf5.txt", "page" => "13" } ]
    }
    with_flags { Rag::ActiveEpisodeTurn.apply_assistant(state: episode, text: "orientación", pending_question: question, correlation_id: "query:ask") }
    assert_equal question["question"], episode.pending_question["question"]
    without_owner { Rag::ActiveEpisodeTurn.apply_assistant(state: episode, text: "orientación", pending_question: question, correlation_id: "query:ask2") }
    assert_equal "documented_context", episode.pending_question["type"]

    settle(episode, follow_up(PARTIAL), PARTIAL, "query:partial")
    assert_nil episode.observations.find { |row| row["text"].include?("no distingo") }.dig("answers", "r")
    assert_nil episode.pending_question

    episode.pending_question = question
    settle(episode, follow_up("¿qué sigue?", move: "follow_up", observations: []), "¿qué sigue?", "query:next")
    assert episode.observations.none? { |row| row["text"].include?("qué sigue") }

    episode.pending_question = question
    settle(episode, follow_up("Es otra falla", move: "new_work", observations: [ "Es otra falla" ]), "Es otra falla", "query:new")
    assert_nil episode.pending_question
    assert episode.observations.none? { |row| row.dig("answers", "q") == question["question"] && row["text"].include?("otra falla") }

    episode.pending_question = question
    settle(episode, follow_up("No, ese era el otro", move: "unclear").merge("clarification_target" => "work_relation"), "No, ese era el otro", "query:unclear")
    assert_equal question["question"], episode.pending_question["question"]

    %w[sí no no\ sé].each do |reply|
      episode.pending_question = question
      settle(episode, follow_up(reply, move: "answer_pending", observations: []), reply, "query:#{reply}")
    end
    assert_equal %w[yes no unknown], episode.observations.last(3).map { |row| row.dig("answers", "r") }
    assert_nil Rag::PendingQuestion.parse_reply(PARTIAL, pending_question: question)

    plain = episode_for("La puerta se reabre sola", [ "El LED de fotocélula está encendido" ])
    with_pending = plain.fork
    with_pending.pending_question = question
    perception = perception_for(plain, follow_up("Sigue igual", observations: [ "Sigue igual" ]), "Sigue igual")
    assert_equal Rag::RoutePolicy.call(previous: plain, perception: perception, focus_count: 0, locale: :es).decision,
                 Rag::RoutePolicy.call(previous: with_pending, perception: perception, focus_count: 0, locale: :es).decision

    round = episode.to_h
    assert_equal "yes", Rag::ActiveEpisode.parse(round).observations.find { |row| row.dig("answers", "r") == "yes" }.dig("answers", "r")
    interpreter = Rag::TurnInterpreter.allocate
    interpreter.instance_variable_set(:@episode, with_pending)
    payload = interpreter.send(:pending_payload)
    assert_equal "documented_context", payload["clarification_target"]
    assert_equal question["question"], payload["question"]
    assert_nil payload["slot"]
  end

  test "an answer target is loaded from the catalog and a missing one is said plainly" do
    page = {
      "document_key" => "s3://fixture/vf5.pdf", "filename" => "chunk_p13_1.txt", "page" => 13,
      "name" => "VF5", "provenance" => "fixture", "text" => "• #{SKATE}.\n– Comprobar la regulación del patín."
    }
    catalog = Rag::CompanionDefinitionCatalog.from_pages([ page ])
    target = { "item" => SKATE, "document_key" => page["document_key"], "filename" => page["filename"] }
    added = Rag::CompanionDefinitionExpander.expand([], catalog: catalog, targets: [ target ])
    assert_equal 1, added.added.size
    assert_equal "13", added.added.first["page"]
    assert_equal Digest::SHA256.hexdigest(page["text"]), added.added.first["sha256"]
    assert_equal "answer_target", added.chunks.first[:metadata]["companion_context"]

    absent = Rag::CompanionDefinitionExpander.expand([], catalog: nil, targets: [ target ])
    assert_equal [ { "reason" => "target_not_loaded", "item" => SKATE } ], absent.omitted
    huge = page.merge("text" => "x" * 7_000)
    full = Rag::CompanionDefinitionExpander.expand([], catalog: Rag::CompanionDefinitionCatalog.from_pages([ huge ]), targets: [ target ])
    assert_equal "target_not_loaded", full.omitted.first["reason"]
    assert_empty full.chunks

    statements = statements_for
    facts = facts_for("La puerta se reabre sola", [ "sí" ], answer: {
      "q" => "¿El patín está cerrando?",
      "t" => [ { "item" => "Apartado que no vino", "document_key" => "s3://missing", "filename" => "no.txt", "page" => "1" } ],
      "r" => "yes"
    })
    checked = check_plan({ "steps" => [] }, facts, statements)
    sentence = render_of(checked, statements, facts)
    assert_includes sentence, "no está en la documentación cargada en este turno"
    notice = publish(sentence)
    assert notice.accepted?, notice.reasons.inspect
  end

  test "an observation annotates only the step whose first anchor it names" do
    statements = statements_for
    facts = facts_for("La puerta se reabre sola", [ "No veo obstrucción" ])
    general_steps = statements.statements.select { |item| item.step? && item.item.include?("re-abre") }.map(&:id)
    checked = check_plan({ "steps" => general_steps }, facts, statements)
    text = render_of(checked, statements, facts)
    obstruction = text.lines.find { |line| line.include?("obstrucción mecánica") }
    leds = text.lines.find { |line| line.include?("LEDs de obstrucción") }
    assert_includes obstruction, "No veo obstrucción"
    assert_not_includes leds.to_s, "No veo obstrucción"

    skate_facts = facts_for(SKATE, [ "No veo obstrucción" ])
    skate = skate_step(statements)
    skate_checked = check_plan({ "steps" => [ skate.id ] }, skate_facts, statements)
    skate_text = render_of(skate_checked, statements, skate_facts)
    assert_includes skate_checked.steps, skate.id
    assert_not_includes skate_text, "No veo obstrucción"
  end

  test "the captured conversation keeps the question, the case, and branches A and B" do
    skip "captura F3 ausente" unless CAPTURE.exist? && KB.exist?

    t3 = replay("t3")
    assert_equal "¿Está activada la entrada de re-apertura (#21)?", t3.question
    assert_not_includes t3.facts.facts.select { |fact| fact.kind == "identity" }.map(&:text), "no está activada"
    assert t3.facts.facts.any? { |fact| fact.text.include?("LED de fotocélula está encendido") }
    assert t3.facts.facts.any? { |fact| fact.text.include?("reabre") }
    assert t3.facts.facts.any? { |fact| fact.done_check? && fact.result == "no está activada" }
    assert t3.text.lines.none? { |line| line.include?("regulación del patín") && line.start_with?("-") }

    t1 = replay("t1")
    t2 = replay("t2")
    assert_nil t1.question
    assert_nil t2.question
    assert t1.checked.steps.any?
    assert t2.checked.steps.any?

    branch_a = replay("branch_A")
    assert branch_a.text.lines.none? { |line| line.include?("probablemente") && line.start_with?("-") }
    assert_includes branch_a.text, "no coincide con esa condición"
    without_link = branch_a.plan.deep_dup
    without_link["links"].reject! { |row| row["fact"] == "O4" }
    unlinked = replay_plan(branch_a, without_link)
    assert unlinked.checked.steps.none? { |id| branch_a.statements.find(id).text.include?("probablemente") }
    empty_reading = branch_a.plan.deep_dup
    empty_reading["links"].each { |row| row["reading"] = "" if row["fact"] == "O4" }
    assert replay_plan(branch_a, empty_reading).text.lines.none? { |line| line.include?("probablemente") && line.start_with?("-") }

    branch_b = replay("branch_B")
    assert branch_b.checked.steps.any? { |id| branch_b.statements.find(id).text.include?("probablemente") }
    assert_includes branch_b.text, "probablemente"
    number_only = branch_b.plan.deep_dup
    number_only["links"].reject! { |row| row["fact"] == "O4" }
    number_only["question"] = "¿Está activada la entrada de re-apertura (#21)?"
    released = replay_plan(branch_b, number_only)
    assert released.checked.steps.none? { |id| branch_b.statements.find(id).text.include?("probablemente") }
  end

  test "a partial answer does not repeat the heading when the manual names one part" do
    manual = "• El patín roza.\n– Comprobar la regulación.\n"
    statements = Rag::CompanionStatements.parse([ chunk(manual) ])
    item = statements.statements.find { |row| row.kind == "item" }
    partial = "No distingo qué parte"
    facts = facts_for("La puerta se reabre sola", [ partial ], answer: {
      "q" => "¿El patín está cerrando?", "t" => [ { "item" => item.text, "page" => item.page.to_s } ]
    })
    checked = check_plan({ "links" => [ link_of("O1", item) ], "steps" => [], "question" => "" }, facts, statements)
    text = render_of(checked, statements, facts)

    assert_nil checked.question
    assert_equal "partial", checked.limits.first["note"]
    assert_includes text, "no separa un dato más concreto"
    assert_not_includes text, "Lo que ves coincide"
    assert_not_includes text, "¿El patín está cerrando?"
  end

  test "a pending question that does not fit the episode is not installed" do
    episode = episode_for("La puerta se reabre sola", [])
    answers = {
      "q" => "q" * 200,
      "t" => [
        { "item" => "i" * 160, "document_key" => "k" * 200, "filename" => "f.txt", "page" => "13" },
        { "item" => "j" * 160, "document_key" => "k" * 200, "filename" => "g.txt", "page" => "14" }
      ]
    }
    12.times { |index| episode.append_observation!("#{index} #{'o' * 150}", correlation_id: "query:o#{index}", answers: answers) }
    question = {
      "type" => "documented_context", "question" => "¿El patín está cerrando?",
      "targets" => [ { "item" => SKATE, "document_key" => "s3://fixture/vf5.pdf", "filename" => "vf5.txt", "page" => "13" } ]
    }
    result = with_flags do
      Rag::ActiveEpisodeTurn.apply_assistant(state: episode, text: "pregunta", pending_question: question, correlation_id: "query:overflow")
    end
    assert_equal "pending_overflow", result.reason
    assert_nil episode.pending_question
  end

  private

  Replay = Struct.new(:plan, :facts, :statements, :checked, :text, :question, :chunks, :turns, keyword_init: true)

  def relation(fact, item, goal = "La puerta se reabre sola")
    Rag::CompanionCaseRelation.call(fact_text: fact, item_text: item, goal_text: goal)
  end

  def chunk(content, page: "13")
    {
      content: content,
      metadata: {
        "canonical_name" => "VF5", "page_number" => page, "filename" => "vf5.txt",
        "document_key" => "s3://fixture/vf5.pdf", "original_source_uri" => "s3://fixture/vf5.pdf"
      },
      identity_applicability: "compatible"
    }
  end

  # Reduced fixture. The obstruction step follows chunk_p12_5. The manual
  # skate check follows chunk_p12_3 and must not license that modality here.
  def obstruction_chunk(content)
    {
      content: content,
      metadata: {
        "canonical_name" => "VF5", "page_number" => "12", "filename" => "chunk_p12_5.txt",
        "document_key" => "s3://fixture/VF5.pdf", "original_source_uri" => "s3://fixture/VF5.pdf"
      },
      identity_applicability: "compatible"
    }
  end

  def publish_case(text, episode, content)
    texts = [ episode.goal&.[]("text") ]
    texts.concat(episode.observations.pluck("text"))
    texts.concat(episode.checks.flat_map { |row| [ row["subject"], row["result"] ] })
    texts << episode.fact("manufacturer")&.[]("value")
    texts << episode.fact("model")&.[]("value")
    Rag::CompanionTurnPublication.call(
      text: text,
      sources: [ { "index" => 1, "content" => content, "applicability" => "compatible", "reference_only" => false } ],
      technician_texts: texts.compact,
      manufacturer: episode.fact("manufacturer")&.[]("value")
    )
  end

  def statements_for
    Rag::CompanionStatements.parse([ chunk(MANUAL) ])
  end

  def skate_item(statements)
    statements.statements.find { |item| item.kind == "item" && item.text.include?("patín") }
  end

  def skate_step(statements)
    statements.statements.find { |item| item.step? && item.text.include?("probablemente") }
  end

  def episode_for(goal, observations)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:f3", now: Time.current)
    episode.assign_goal!(goal, correlation_id: "query:f3")
    observations.each { |text| episode.append_observation!(text, correlation_id: "query:f3") }
    episode
  end

  def facts_for(goal, observations, answer: nil)
    episode = episode_for(goal, observations)
    if answer && (row = episode.observations.find { |item| item["text"] == observations.last })
      row["answers"] = answer
    end
    Rag::CompanionCaseFacts.build(episode)
  end

  def answer_for(item, code)
    { "q" => "¿El patín está cerrando?", "r" => code, "t" => [ { "item" => item.text, "page" => item.page.to_s } ] }
  end

  def check_plan(plan, facts, statements)
    Rag::CompanionPlanCheck.call(plan, facts: facts, statements: statements, turns: [])
  end

  def render_of(check, statements, facts)
    Rag::CompanionPlanRender.call(check, facts: facts, statements: statements)
  end

  def link_of(fact, statement)
    { "fact" => fact, "statement" => statement.id, "reading" => "" }
  end

  def rejection(check, part)
    check.rejections.find { |row| row["part"] == part }&.dig("reason")
  end

  def rejection_for(check, part, value)
    check.rejections.find { |row| row["part"] == part && row["value"] == value }&.dig("reason")
  end

  def publish(text)
    Rag::CompanionTurnPublication.call(
      text: text,
      sources: [ { "index" => 1, "content" => MANUAL, "applicability" => "compatible", "reference_only" => false } ],
      technician_texts: [ "La puerta se reabre sola", "El LED de fotocélula está encendido", PARTIAL, BEFORE, DURING, LAHIRI ],
      manufacturer: "Fermator"
    )
  end

  def prepared_for(statements, facts)
    Rag::CompanionPlan::Prepared.new(
      params: {}, system: "", user: "", facts: facts, statements: statements, turns: [], chunks: [ chunk(MANUAL) ]
    )
  end

  def install_pending(episode, check, statements)
    composed = Rag::CompanionPlan.compose(
      CompanionPlanResponse.build({
        "links" => [], "steps" => [], "question" => check.question, "question_about" => check.question_targets
      }),
      prepared_for(statements, facts_for("La puerta se reabre sola", []))
    )
    with_flags do
      Rag::ActiveEpisodeTurn.apply_assistant(
        state: episode, text: composed.text, pending_question: composed.pending, correlation_id: "query:ask"
      )
    end
  end

  def settle(episode, raw, turn, correlation_id)
    with_flags do
      perception = perception_for(episode, raw, turn)
      decision = Rag::RoutePolicy.call(previous: episode, perception: perception, focus_count: 0, locale: :es)
      Rag::WorkContextReducer.apply!(
        episode: episode, perception: perception, decision: decision,
        turn: turn, correlation_id: correlation_id, now: Time.current
      )
    end
  end

  def perception_for(episode, raw, turn)
    Rag::TurnPerception.build(raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil)
  end

  def follow_up(text, move: "follow_up", observations: [ text ])
    {
      "move" => move, "assertions" => [], "observations" => observations,
      "pending_resolution" => nil, "clarification_target" => nil, "checks" => []
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

  def without_owner
    previous = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    ENV.delete("HAIKU_QUERY_ANALYSIS_MODE")
    yield
  ensure
    previous.nil? ? ENV.delete("HAIKU_QUERY_ANALYSIS_MODE") : ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous
  end

  test "the captured Q1 check questions are dropped and the LED question keeps its chunk" do
    skip "captura Q1 ausente" unless Q1_RUN.exist? && KB.exist?

    %w[q1_t1 branch_A].each do |name|
      loaded = q1_replay(name)
      assert_nil loaded.question, name
      assert_match(/\Arepeats_fact:/, rejection(loaded.checked, "question"))
      assert_not_includes loaded.text, "¿Ha comprobado"
      composed = Rag::CompanionPlan.compose(CompanionPlanResponse.build(loaded.plan), prepared_replay(loaded))
      assert_nil composed.pending, name
      assert_not_includes composed.text, "¿Ha comprobado"
      assert_not_includes composed.text, "Ajustaste"
    end

    loaded = q1_replay("branch_B", live: true)
    assert_includes loaded.question, "entrada de re-apertura"
    assert_no_match(/\Arepeats_fact:/, rejection(loaded.checked, "question").to_s)
    composed = Rag::CompanionPlan.compose(CompanionPlanResponse.build(loaded.plan), prepared_replay(loaded))
    assert_includes composed.text, loaded.question
    target = composed.pending["targets"].first
    assert_equal "chunk_p7_3.txt", target["filename"]
    assert_equal "7", target["page"]
    assert_includes target["document_key"], "VF5.pdf"
    assert_equal "Fotocélula.", target["item"]

    page_text = KB.join("bulk_chunks/1/be7a39a3490c92c8381cb883402760cb07d1/chunk_p7_3.txt").read
    catalog = Rag::CompanionDefinitionCatalog.from_pages([
      {
        "document_key" => target["document_key"], "filename" => target["filename"], "page" => 7,
        "name" => "VF5", "provenance" => "chunk chunk_p7_3.txt", "text" => page_text
      }
    ])
    other = { content: "página distinta", metadata: { "page_number" => "12", "filename" => "chunk_p12_5.txt" } }
    expanded = Rag::CompanionDefinitionExpander.expand([ other ], catalog: catalog, targets: [ target ])
    assert_includes expanded.chunks.last[:content], "entrada de re-apertura"
    assert_equal "chunk_p7_3.txt", expanded.added.first["filename"]

    missed = Rag::CompanionDefinitionExpander.expand([ other ], catalog: catalog, targets: [ target.merge("filename" => "") ])
    assert_equal "target_not_loaded", missed.omitted.first["reason"]
    assert_equal 1, missed.chunks.size

    step = loaded.statements.statements.find { |item| item.step? && item.text.include?("re-apertura") }
    rebound = q1_check(loaded, loaded.plan.merge("question_about" => [ step.id ]))
    assert_includes rebound.question, "#21"
    assert_equal [ step.item ], rebound.checked.question_targets.map { |id| loaded.statements.find(id).text }
  end

  def replay(name)
    dir = CAPTURE.join(name)
    plan_dir = dir.join("calls").children.find { |path| path.basename.to_s.start_with?("02-companion") }
    plan = JSON.parse(plan_dir.join("raw_response.txt").read)
    sources = JSON.parse(plan_dir.join("sources.json").read).fetch("sources")
    stored = JSON.parse(dir.join("episode_after.json").read)
    episode = Rag::ActiveEpisode.parse(stored, now: Time.iso8601(stored["updated_at"]) + 60)
    chunks = sources.map { |source| captured_chunk(source) }
    statements = Rag::CompanionStatements.parse(chunks)
    facts = Rag::CompanionCaseFacts.build(episode)
    turns = [ dir.join("question.txt").read.strip ]
    checked = Rag::CompanionPlanCheck.call(plan, facts: facts, statements: statements, turns: turns)
    text = checked.usable? ? Rag::CompanionPlanRender.call(checked, facts: facts, statements: statements) : ""
    Replay.new(plan: plan, facts: facts, statements: statements, checked: checked, text: text, question: checked.question, chunks: chunks, turns: turns)
  end

  def q1_replay(name, live: false)
    dir = Q1_RUN.join(name)
    plan_dir = dir.join("calls").children.find { |path| path.basename.to_s.start_with?("02-companion") }
    plan = JSON.parse(plan_dir.join("raw_response.txt").read)
    sources = JSON.parse(plan_dir.join("sources.json").read).fetch("sources")
    stored = JSON.parse(dir.join("episode_after.json").read)
    episode = Rag::ActiveEpisode.parse(stored, now: Time.iso8601(stored["updated_at"]) + 60)
    chunks = sources.map { |source| live ? live_chunk(source) : captured_chunk(source) }
    q1_check_chunks(plan, episode, chunks, [ dir.join("question.txt").read.strip ])
  end

  def q1_check(loaded, plan)
    q1_check_chunks(plan, nil, loaded.chunks, loaded.turns, facts: loaded.facts, statements: loaded.statements)
  end

  def q1_check_chunks(plan, episode, chunks, turns, facts: nil, statements: nil)
    statements ||= Rag::CompanionStatements.parse(chunks)
    facts ||= Rag::CompanionCaseFacts.build(episode)
    checked = Rag::CompanionPlanCheck.call(plan, facts: facts, statements: statements, turns: turns)
    text = checked.usable? ? Rag::CompanionPlanRender.call(checked, facts: facts, statements: statements) : ""
    Replay.new(plan: plan, facts: facts, statements: statements, checked: checked, text: text, question: checked.question, chunks: chunks, turns: turns)
  end

  def prepared_replay(loaded)
    Rag::CompanionPlan::Prepared.new(
      params: {}, system: "", user: "", facts: loaded.facts, statements: loaded.statements,
      turns: loaded.turns, chunks: loaded.chunks
    )
  end

  def live_chunk(source)
    key = source["key"].to_s
    content = if key.present?
      KB.join(key).read
    else
      DEFINITIONS.fetch(source["sha256"], "")
    end
    uri = key.present? ? "s3://multimodal-source-destination/#{key}" : nil
    {
      content: content,
      location_uri: uri,
      metadata: {
        "canonical_name" => "Módulo electrónico VF5+ Fermator",
        "original_filename" => "VF5.pdf",
        "original_source_uri" => "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf",
        "page_number" => source["page"].to_s,
        "x-amz-bedrock-kb-source-uri" => uri
      }.compact,
      identity_applicability: "compatible"
    }
  end

  def replay_plan(loaded, plan)
    checked = Rag::CompanionPlanCheck.call(plan, facts: loaded.facts, statements: loaded.statements, turns: loaded.turns)
    text = checked.usable? ? Rag::CompanionPlanRender.call(checked, facts: loaded.facts, statements: loaded.statements) : ""
    Replay.new(plan: plan, facts: loaded.facts, statements: loaded.statements, checked: checked, text: text, question: checked.question, chunks: loaded.chunks, turns: loaded.turns)
  end

  def captured_chunk(source)
    key = source["key"]
    content = if key.present?
      KB.join(key).read
    else
      DEFINITIONS.fetch(source["sha256"], "")
    end
    {
      content: content,
      metadata: {
        "canonical_name" => "Módulo electrónico VF5+ Fermator",
        "page_number" => source["page"].to_s,
        "filename" => key.present? ? File.basename(key) : "definition.txt",
        "original_source_uri" => "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
      },
      identity_applicability: "compatible"
    }
  end
end
