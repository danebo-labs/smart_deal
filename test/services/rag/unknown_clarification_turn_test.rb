# frozen_string_literal: true

require "test_helper"
require_relative "../../support/companion_plan_response"

class Rag::UnknownClarificationTurnTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  TURN = "No sé cómo identificar si está activada la entrada #21 ni cómo saber si hay un contacto cerrado entre #21 y #23. ¿Qué información necesitas de mí para orientar el caso?"
  QUESTION = "¿Está activada la entrada de re-apertura (#21) o hay un contacto cerrado entre #21 y #23?"
  PHOTOCELL = "query:photocell"
  MANUAL = <<~TEXT
    • La puerta se re-abre sola.
    – Comprobar la sensibilidad del potenciómetro (#54).
    – Comprobar que no hay una obstrucción mecánica en la puerta.
    • Fotocélula.
    Para activar esta señal, se debe conectar la entrada re-apertura (21) con la entrada de +12V (23).
    Indicador LED y relé activado cuando la fotocélula o la entrada de re-apertura está activada.
  TEXT

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "the published question is kept until the unknown names that datum and is not asked again" do
    assert_equal 168, TURN.length
    session = seed_session
    kept = nil

    with_flags do
      kept = publish_question(session)
      assert_equal QUESTION, kept["question"]
      assert_equal [ "Fotocélula.", "Fotocélula." ], kept["targets"].pluck("item")

      session.record_user_turn!(
        "Revisé la fotocélula y no está activada.",
        user_id: @user.id,
        correlation_id: "query:photocell-again",
        interpreter_client: ReportStub.new("Revisé la fotocélula y no está activada.")
      )
      after_photocell = Rag::ActiveEpisode.parse(session.reload.active_episode)
      assert_equal QUESTION, after_photocell.pending_question["question"]
      assert after_photocell.observations.none? { |item| item.dig("answers", "q") == QUESTION }
      assert_equal "not_done", after_photocell.checks.find { |item| item["subject"] == "#54" }["status"]

      session.record_user_turn!(
        "¿Qué sigue?",
        user_id: @user.id,
        correlation_id: "query:next",
        interpreter_client: FollowStub.new
      )
      after_next = Rag::ActiveEpisode.parse(session.reload.active_episode)
      assert_equal kept, after_next.pending_question.slice("question", "targets")

      result = session.record_user_turn!(
        TURN,
        user_id: @user.id,
        correlation_id: "query:unknown-limit",
        interpreter_client: MetaStub.new
      )
      assert_equal "meta_incompatible", result.reason
    end

    episode = Rag::ActiveEpisode.parse(session.reload.active_episode)
    photocell = episode.observations.find { |item| item["text"] == "Revisé la fotocélula y no está activada." }
    check = episode.checks.find { |item| item["subject"] == "la fotocélula" }
    limit = episode.observations.find { |item| item.dig("answers", "r") == "unknown" }

    assert_equal "done", check["status"]
    assert_equal "no está activada", check["result"]
    assert_nil photocell.dig("answers", "q")
    assert_nil photocell.dig("answers", "r")
    assert limit, "the episode did not keep the unknown limit"
    assert_equal TURN, limit["text"]
    assert_equal QUESTION, limit.dig("answers", "q")
    assert_equal kept["targets"], limit.dig("answers", "t")
    assert_nil episode.pending_question
    assert_equal "not_done", episode.checks.find { |item| item["subject"] == "#54" }["status"]

    visible = SessionContextBuilder.companion_observations(episode)
    assert visible.any? { |item| item.dig("answers", "r") == "unknown" && item.dig("answers", "q") == QUESTION }

    composed = publish_plan(session, episode)
    text = composed.text

    assert_match(/\AIndicaste que no puedes distinguirlo/, text)
    assert_includes text, "Comprobar la sensibilidad del potenciómetro (#54)"
    assert_includes text, "dijiste «No he comprobado el #54», así que sigue pendiente"
    assert_includes text, "También informaste: «Ya revisé la fotocélula y no está activada»"
    assert_includes text, "depende de ese dato"
    assert_not_includes text, QUESTION
    assert_not_includes text, "Para orientar falta distinguir"
    assert_not_includes text, "Lo que ves coincide"
    assert_not_includes text, "?"
    assert_nil composed.pending
  end

  private

  def seed_session
    now = Time.current
    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: now)
    episode.assign_goal!("La puerta se reabre sola", correlation_id: "query:open")
    episode.write_fact!(
      "manufacturer", status: "known", value: "Fermator", source: "user",
      correlation_id: "query:open", at: now.iso8601
    )
    episode.append_identifier!("Fermator VF5+", correlation_id: "query:open")
    episode.append_observation!("La puerta se reabre sola", correlation_id: "query:open")
    episode.append_observation!("No veo obstrucción", correlation_id: "query:open")
    episode.append_observation!("el LED de fotocélula está encendido", correlation_id: "query:led")
    episode.upsert_check!(
      { "subject" => "#54", "status" => "not_done", "operation" => [ "check" ] },
      correlation_id: "query:open"
    )
    episode.upsert_check!(
      { "subject" => "la fotocélula", "status" => "done", "result" => "no está activada", "operation" => [ "check" ] },
      correlation_id: PHOTOCELL
    )
    assert_nil episode.pending_question

    session = ConversationSession.create!(
      identifier: "web:unknown-limit:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: @user,
      account: @account,
      active_episode: episode.to_h,
      conversation_history: [
        { "role" => "user", "content" => "No he comprobado el #54.", "correlation_id" => "query:open", "ts" => now.iso8601 },
        { "role" => "user", "content" => "Ya revisé la fotocélula y no está activada.", "correlation_id" => PHOTOCELL, "ts" => now.iso8601 }
      ]
    )
    session
  end

  def publish_question(session)
    episode = Rag::ActiveEpisode.parse(session.active_episode)
    composed = publish_plan(session, episode)
    assert_equal QUESTION, composed.pending["question"]
    session.record_assistant_turn!(
      composed.text,
      user_id: @user.id,
      correlation_id: "query:published-21",
      pending_question: composed.pending,
      expected_episode_id: session.live_episode_id
    )
    stored = Rag::ActiveEpisode.parse(session.reload.active_episode).pending_question
    stored.slice("question", "targets")
  end

  def with_flags
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
        isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
          isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") { yield }
        end
      end
    end
  end

  def publish_plan(session, episode)
    chunks = [ {
      content: MANUAL,
      metadata: {
        "canonical_name" => "VF5",
        "page_number" => "7",
        "original_source_uri" => "s3://fixture/vf5.pdf",
        "filename" => "chunk_p7_3.txt"
      },
      identity_applicability: "compatible"
    } ]
    prepared = Rag::CompanionPlan.prepare(
      raw_question: TURN, chunks: chunks, episode: episode, session: session,
      correlation_id: "query:unknown-limit"
    )
    passages = prepared.statements.statements.select { |item|
      item.kind == "text" && item.item == "Fotocélula."
    }
    steps = prepared.statements.statements.select(&:step?)
    assert_equal 2, passages.size
    assert_equal 2, steps.size

    Rag::CompanionPlan.compose(
      CompanionPlanResponse.build({
        "links" => [],
        "steps" => steps.map(&:id),
        "question" => QUESTION,
        "question_about" => passages.map(&:id)
      }),
      prepared
    )
  end

  module PerceptionReply
    module_function

    def build(move, observations)
      tool = Struct.new(:name, :input).new("turn_perception", {
        "move" => move,
        "assertions" => [],
        "observations" => observations,
        "pending_resolution" => nil,
        "clarification_target" => nil
      })
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage).new(output, usage)
    end
  end

  class ReportStub
    def initialize(text)
      @text = text
    end

    def converse(_params)
      PerceptionReply.build("report", [ @text ])
    end
  end

  class FollowStub
    def converse(_params)
      PerceptionReply.build("follow_up", [])
    end
  end

  class MetaStub
    def converse(_params)
      PerceptionReply.build("meta", [])
    end
  end
end
