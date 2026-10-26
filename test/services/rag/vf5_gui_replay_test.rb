# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../support/companion_plan_response"

# The five captured GUI turns, replayed through perception, the reducer,
# the plan check, the render, and publication. The model replies and the
# chunk bodies are the capture. Nothing here calls Bedrock.
class Rag::Vf5GuiReplayTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FOCUS_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
  ABSTAIN = "No pude preparar una orientación fiable"

  setup do
    @account = accounts(:legacy)
    @user = users(:one)
  end

  test "the captured sequence orients the later turns, separates the LEDs, and keeps the unknown of #21" do
    walked = nil
    document = nil
    previous_mode = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    previous_episode = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    walked, document = walk_sequence
    t1 = walked.fetch("t1")
    t2 = walked.fetch("t2")
    t3 = walked.fetch("t3")
    t4 = walked.fetch("t4")
    t5 = walked.fetch("t5")
    published_question = t1[:episode].pending_question["question"]

    assert_equal "Fermator", t1[:episode].fact("manufacturer")["value"]
    assert_includes t1[:episode].identifiers.pluck("value"), "Fermator VF5+"
    assert_includes t1[:episode].goal["text"], "durante el cierre"
    assert_includes t1[:text], "no se aplica"
    assert_includes t1[:text], published_question
    assert t1[:published].accepted?, t1[:published].reasons.inspect

    assert_equal "el LED está encendido", t2[:episode].observations.pluck("text").find { |text| text.match?(/\bled\b/i) }
    assert t2[:episode].observations.none? { |item| item["text"].match?(/apagado/i) }
    assert_includes t2[:raw].dig("tool_input", "links").pluck("reading").join(" "), "parpadeante"
    assert_not_includes t2[:text], "parpadeante"
    assert_not_includes t2[:text], "apagado"
    assert_match(/LED está encendido/i, t2[:text])
    assert_includes t2[:text], "Fotocélula"
    assert_includes t2[:text], "Estado"
    assert_equal published_question, t2[:episode].pending_question["question"]
    assert_nil t2[:composed].pending
    assert t2[:published].accepted?, t2[:published].reasons.inspect

    [ t3, t4 ].each do |turn|
      assert_includes turn[:raw]["captured_answer"], ABSTAIN
      assert_not_includes turn[:text], ABSTAIN
      assert_includes turn[:text], "potenciómetro"
      assert_includes turn[:text], "sigue pendiente"
      assert_includes turn[:text], "fotocélula"
      assert turn[:published].accepted?, turn[:published].reasons.inspect
      assert_equal published_question, turn[:episode].pending_question["question"]
    end
    assert_includes t3[:text], "no consta como hecha"
    assert_includes t3[:text], "Revisé la fotocélula y no está activada"
    assert_nil t3[:composed].check.question
    assert_nil t4[:composed].check.question
    assert_equal "done", t3[:episode].checks.find { |item| item["subject"] == "fotocélula" }["status"]
    assert_equal "not_done", t3[:episode].checks.find { |item| item["subject"] == "ajuste de #54" }["status"]
    assert_equal "not_done", t3[:episode].checks.find { |item| item["subject"] == "mediciones" }["status"]
    assert t3[:episode].checks.none? { |item| item["subject"].to_s.match?(/obstruc/) && item["status"] == "done" }

    limit = t5[:episode].observations.find { |item| item.dig("answers", "r") == "unknown" }
    proposed = t5[:raw].dig("tool_input", "question")
    # The captured tool says answer_pending. The GUI log for this turn is
    # turn_interpreter_status ok and interpreter_move report: the pending
    # answer is incomplete, so the validator keeps the turn as a report.
    # meta_incompatible applies only when that tool move is meta.
    assert_equal "answer_pending", t5[:raw].dig("interpreter", "move")
    assert_equal "report", t5[:interpreter_reason]
    assert_includes proposed, "contacto cerrado"
    assert_includes limit["text"], "identificar"
    assert_includes limit["text"], "#21"
    assert_includes limit["text"], "#23"
    assert_includes limit["text"], "contacto cerrado"
    assert_equal published_question, limit.dig("answers", "q")
    assert_nil t5[:episode].pending_question
    assert_match(/\AIndicaste que no puedes distinguirlo/, t5[:text])
    assert_not_includes t5[:text], proposed
    assert_not_includes t5[:text], "?"
    assert_includes t5[:text], "potenciómetro"
    assert_includes t5[:text], "ya informaste"
    assert_includes t5[:text], "no consta como hecha"
    assert_equal "not_done", t5[:episode].checks.find { |item| item["subject"] == "ajuste de #54" }["status"]
    assert t5[:published].accepted?, t5[:published].reasons.inspect
    assert_equal "declared_unknown", t5[:composed].check.rejections.find { |row| row["part"] == "question" }["reason"]

    previous_orientation = recompose(t3, applicable: :previous)
    assert_predicate previous_orientation.text, :blank?
    assert previous_orientation.check.rejections.any? { |row| row["reason"] == "case_unresolved" }

    previous_led = recompose(t2, led_context: false)
    assert_includes previous_led.text, "parpadeante"

    previous_unknown = recompose(t5, unknown_match: :exact)
    assert_includes previous_unknown.text, proposed
  ensure
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous_mode
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous_episode
    walked&.each_value&.first&.dig(:session)&.destroy
    document&.destroy
  end

  private

  def walk_sequence
    catalog, document = fermator_catalog
    episode = Rag::ActiveEpisode.new
    session = nil
    walked = {}
    turns.each do |raw|
      now = Time.current
      interpreter_result = nil
      if raw["turn"] == "t5"
        interpreter_result = record_captured_turn(session, raw, now)
        episode = Rag::ActiveEpisode.parse(session.reload.active_episode, now: now)
        history = session.conversation_history
      else
        perception = Rag::TurnPerception.build(
          raw["interpreter"], turn: raw["user"], episode: episode, catalog: catalog, viewer_account: @account
        )
        decision = Rag::RoutePolicy.call(
          previous: episode, perception: perception, focus_count: 1,
          focus_document_ids: [ document.id ], focus_uris: [ FOCUS_URI ], locale: :es, turn: raw["user"]
        )
        episode = Rag::ActiveEpisode.open(correlation_id: raw["correlation_id"], now: now) if episode.blank?
        Rag::WorkContextReducer.apply!(
          episode: episode, perception: perception, decision: decision,
          turn: raw["user"], correlation_id: raw["correlation_id"], now: now
        )
        session ||= ConversationSession.create!(
          identifier: "web:vf5-replay-#{SecureRandom.hex(3)}",
          channel: "web",
          expires_at: 1.hour.from_now,
          user: @user,
          account: @account,
          active_episode: episode.to_h,
          conversation_history: [],
          document_focus: [ {
            "kb_document_id" => document.id,
            "source_uri" => FOCUS_URI,
            "display_name" => "VF5",
            "added_at" => now.iso8601
          } ]
        )
        history = session.conversation_history + [ {
          "role" => "user", "content" => raw["user"],
          "correlation_id" => raw["correlation_id"], "ts" => now.iso8601
        } ]
        session.update!(active_episode: episode.to_h, conversation_history: history)
      end
      composed = compose(raw, episode, session)
      published = publish(composed, raw, episode, session)
      assistant = Rag::ActiveEpisodeTurn.apply_assistant(
        state: episode, text: composed.text, correlation_id: raw["correlation_id"],
        pending_question: composed.pending, now: now
      )
      episode = Rag::ActiveEpisode.parse(assistant.state, now: now)
      session.update!(
        active_episode: episode.to_h,
        conversation_history: history + [ {
          "role" => "assistant", "content" => composed.text,
          "correlation_id" => raw["correlation_id"], "ts" => now.iso8601
        } ]
      )
      snapshot = episode.to_h.deep_dup
      walked[raw["turn"]] = {
        raw: raw, text: composed.text, composed: composed, published: published,
        episode: Rag::ActiveEpisode.parse(snapshot), history: history.map(&:deep_dup), session: session,
        interpreter_reason: interpreter_result&.reason
      }
    end
    [ walked, document ]
  end

  # The captured tool says answer_pending. record_user_turn! runs the same
  # validation as the GUI. This does not build a perception or an answer first.
  def record_captured_turn(session, raw, now)
    result = nil
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      result = session.record_user_turn!(
        raw["user"],
        user_id: @user.id,
        correlation_id: raw["correlation_id"],
        now: now,
        interpreter_client: CapturedPerceptionClient.new(raw["interpreter"])
      )
    end
    result
  end

  def recompose(snapshot, applicable: nil, led_context: true, unknown_match: nil)
    with_previous_applicable(applicable == :previous) do
      with_led_context(led_context) do
        with_unknown_match(unknown_match) do
          episode = Rag::ActiveEpisode.parse(snapshot[:episode].to_h)
          snapshot[:session].update!(
            active_episode: episode.to_h,
            conversation_history: snapshot[:history]
          )
          compose(snapshot[:raw], episode, snapshot[:session])
        end
      end
    end
  end

  def compose(raw, episode, session)
    chunks = raw["chunks"].map { |chunk|
      { content: chunk["content"], metadata: chunk["metadata"], identity_applicability: "compatible" }
    }
    prepared = Rag::CompanionPlan.prepare(
      raw_question: raw["user"], chunks: chunks, episode: episode, session: session,
      correlation_id: raw["correlation_id"]
    )
    Rag::CompanionPlan.compose(CompanionPlanResponse.build(raw["tool_input"]), prepared)
  end

  def publish(composed, raw, episode, session)
    chunks = raw["chunks"].pluck("content")
    sources = chunks.each_with_index.map { |content, index|
      { "index" => index + 1, "content" => content, "applicability" => "compatible", "reference_only" => false }
    }
    Rag::CompanionTurnPublication.call(
      text: composed.text,
      sources: sources,
      technician_texts: BedrockRagService.allocate.send(:companion_technician_texts, session, episode, raw["user"]),
      manufacturer: episode.fact("manufacturer")&.dig("value"),
      stop_reason: "tool_use"
    )
  end

  def turns
    @turns ||= Rails.root.glob("test/fixtures/vf5_gui_replay/t*.json").sort.map { |path|
      JSON.parse(File.read(path))
    }
  end

  def fermator_catalog
    uid = SecureRandom.uuid
    document = KbDocument.create!(
      account: @account, s3_key: "manuals/#{uid}.pdf", display_name: "VF5", document_uid: uid, aliases: []
    )
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [ {
        "account_id" => @account.id.to_s,
        "document_id" => uid,
        "s3_key" => document.s3_key,
        "display_name" => "VF5",
        "brands" => [ "Fermator" ],
        "designators" => [ "VF5+" ],
        "generic" => false,
        "confirmed" => true
      } ]
    })
    [ catalog, document ]
  end

  def with_previous_applicable(enabled)
    return yield unless enabled

    original = Rag::CompanionPlanRender.method(:applicable?)
    Rag::CompanionPlanRender.define_singleton_method(:applicable?) do |item, facts|
      goal = facts.respond_to?(:goal) ? facts.goal : nil
      next false if goal.nil? || item.blank?

      wanted = symptom_stems(goal.text)
      offered = symptom_stems(item)
      shared = wanted & offered
      next false if wanted.empty? || offered.empty?

      shared.size >= [ 2, wanted.size ].min &&
        shared.size >= wanted.size * Rag::CompanionPlanRender::APPLICABLE_SHARE &&
        shared.size >= offered.size * Rag::CompanionPlanRender::APPLICABLE_SHARE
    end
    yield
  ensure
    Rag::CompanionPlanRender.define_singleton_method(:applicable?, original) if enabled && original
  end

  def with_led_context(enabled)
    return yield if enabled

    original = Rag::CompanionPlanCheck.instance_method(:led_context_reason)
    Rag::CompanionPlanCheck.define_method(:led_context_reason) { |*| nil }
    yield
  ensure
    Rag::CompanionPlanCheck.define_method(:led_context_reason, original) if !enabled && original
  end

  def with_unknown_match(mode)
    return yield unless mode == :exact

    original = Rag::CompanionPlanCheck.instance_method(:declared_unknown_question?)
    Rag::CompanionPlanCheck.define_method(:declared_unknown_question?) do |text|
      normal = self.class.normal(text)
      @facts.facts.any? { |fact|
        answers = fact.answers
        answers.is_a?(Hash) && answers["r"].to_s == "unknown" &&
          self.class.normal(answers["q"].to_s) == normal
      }
    end
    yield
  ensure
    Rag::CompanionPlanCheck.define_method(:declared_unknown_question?, original) if mode == :exact && original
  end
end

# Converse response whose only content is the captured turn_perception tool.
class CapturedPerceptionClient
  def initialize(input)
    @input = input
  end

  def converse(_params)
    tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, @input)
    block = Struct.new(:tool_use).new(tool)
    message = Struct.new(:content).new([ block ])
    output = Struct.new(:message).new(message)
    usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
    Struct.new(:output, :usage).new(output, usage)
  end
end
