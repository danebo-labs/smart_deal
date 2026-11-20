# frozen_string_literal: true

require "test_helper"

class Rag::DeclaredUnverifiedTest < ActiveSupport::TestCase
  DCL_PHOTO = "photo:f886c8ec"
  T5 = "query:t5"
  T6 = "query:t6"
  PUBLISHED = "**Lectura:** La prueba coincide con lo que reportas.\n\n" \
    "**Fuentes:** DCL sigue sin verificarse. Es el \"Límite final de cierre de puertas\" [4].\n\n" \
    "**Pregunta:** Con la puerta del piso 3 cerrada, ¿DCL aparece activo en la consola?"

  test "a code declared unverified is open until the technician reports on it without a negation" do
    episode = episode_with(
      checks: [ check("Todavía no he confirmado el.estado de DCL", DCL_PHOTO), check("No llegamos a verificar DCL ni DFC", T5) ],
      observations: [ obs("Todavía no he confirmado el.estado de DCL", DCL_PHOTO), obs("Encontré residuos en la guía", T5) ]
    )
    assert_equal %w[dcl dfc], Rag::DeclaredUnverified.open_codes(episode).sort

    episode.observations << obs("el LED DFC se encendió y se mantuvo encendido", T6)
    assert_equal [ "dcl" ], Rag::DeclaredUnverified.open_codes(episode)

    episode.observations << obs("Todavía no he visto DCL", "query:t7")
    assert_equal [ "dcl" ], Rag::DeclaredUnverified.open_codes(episode), "a negated mention is not a reading"

    episode.observations << obs("DCL quedó activo con la puerta cerrada", "query:t8")
    assert_empty Rag::DeclaredUnverified.open_codes(episode)
  end

  test "a report that came before the declaration does not count as the reason to ask again" do
    episode = episode_with(
      checks: [ check("No pude verificar DFC", T6) ],
      observations: [ obs("el LED DFC se encendió", T5), obs("la puerta cierra", T6) ]
    )

    assert_equal [ "dfc" ], Rag::DeclaredUnverified.open_codes(episode)
  end

  test "the question is dropped from the text when it repeats a declared datum" do
    episode = episode_with(checks: [ check("No llegamos a verificar DCL ni DFC", T5) ], observations: [ obs("el LED DFC se encendió", T6) ])
    result = Rag::DeclaredUnverified.without_repeated_question(PUBLISHED, episode: episode, locale: :es)

    assert result.dropped
    assert_equal "Con la puerta del piso 3 cerrada, ¿DCL aparece activo en la consola?", result.question
    assert_not_includes result.text, "?"
    assert_includes result.text, "DCL sigue sin verificarse"
    assert_not_includes result.text, "Pregunta"
    assert_nil Rag::PendingQuestion.from_publication(result.text, locale: :es)
  end

  test "a question about a code the technician already reported, or never declared, is kept" do
    episode = episode_with(checks: [ check("No llegamos a verificar DCL ni DFC", T5) ], observations: [ obs("el LED DFC se encendió", T6) ])
    keep = lambda do |question|
      Rag::DeclaredUnverified.without_repeated_question("Lectura: algo.\n\nPregunta: #{question}", episode: episode, locale: :es)
    end

    [ "¿El LED DFC sigue encendido?", "¿DW aparece activo en la consola?", "¿DCL y DW aparecen activos?", "¿La hoja roza la guía?" ].each do |question|
      assert_not keep.call(question).dropped, question
    end
  end

  test "a text that is only the declared question is kept: nothing is never published" do
    episode = episode_with(checks: [ check("No verifiqué DCL", T5) ])
    only = "**Pregunta:** ¿DCL aparece activo en la consola?"
    result = Rag::DeclaredUnverified.without_repeated_question(only, episode: episode, locale: :es)

    assert_not result.dropped
    assert_equal only, result.text
    assert Rag::DeclaredUnverified.repeated_question?("¿DCL aparece activo en la consola?", episode)
  end

  test "persistence refuses a pending that repeats a declared datum and clears the previous one, flag on" do
    episode = episode_with(checks: [ check("No llegamos a verificar DCL ni DFC", T5) ])
    question = { "type" => "documented_context", "question" => "¿DCL aparece activo en la consola?", "targets" => [] }

    with_check_outcome_flag("true") do
      assert_equal "pending_declared_unverified", Rag::ActiveEpisodeTurn.install_pending!(episode, question, T6)
      assert_nil episode.pending_question
    end
  end

  test "persistence without the flag installs the question as the base does" do
    episode = episode_with(checks: [ check("No llegamos a verificar DCL ni DFC", T5) ])
    question = { "type" => "documented_context", "question" => "¿DCL aparece activo en la consola?", "targets" => [] }

    with_check_outcome_flag(nil) do
      assert_nil Rag::ActiveEpisodeTurn.install_pending!(episode, question, T6)
      assert_equal "¿DCL aparece activo en la consola?", episode.pending_question["question"]
    end
  end

  private

  def episode_with(checks: [], observations: [])
    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: Time.current)
    episode.checks = checks
    episode.observations = observations
    episode
  end

  def check(subject, correlation_id)
    { "subject" => subject, "status" => "not_done", "correlation_id" => correlation_id, "operation" => [ "check" ] }
  end

  def obs(text, correlation_id)
    { "text" => text, "correlation_id" => correlation_id }
  end
end
