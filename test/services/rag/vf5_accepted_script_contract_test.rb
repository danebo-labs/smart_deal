# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../support/companion_plan_response"

# The five phrases of the accepted VF5 script, walked on a new episode.
# ep_63de315872dfed14, image 4a6deb9, is a later web check of those phrases.
# The tool bodies and chunks here are the earlier capture in
# test/fixtures/vf5_gui_replay, not that GUI packet. T5 names the part ids
# this run published. Nothing calls Bedrock. The legacy replays stay separate.
class Rag::Vf5AcceptedScriptContractTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FOCUS_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
  ABSTAIN = "No pude preparar una orientación fiable"

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "the accepted five messages keep continuity on a new contract episode" do
    previous = [
      ENV["HAIKU_QUERY_ANALYSIS_MODE"], ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    document = nil
    session = nil
    catalog, document = fermator_catalog
    turns = load_turns
    compound = turns.fetch("t2").dig("tool_input", "question")
    contact = turns.fetch("t5").dig("tool_input", "question")

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      assert_no_enqueued_jobs only: TrackBedrockQueryJob do
        session = open_session(document)
        opening = Rag::ValidationCapture.capture { ask(session, turns.fetch("t1")) }
        selected = opening.find { |event| event["kind"] == "answer_contract" }
        request = opening.find { |event| event["kind"] == "interpreter_request" }
        opened = reload_episode(session)

        assert_equal "contract", selected["result"]
        assert_equal 1, selected["qc"]
        assert_equal "prepare", selected["stage"]
        assert_operator selected["sequence"], :<, request["sequence"]
        assert_equal 1, opened.qc
        assert_equal opened.episode_id, selected["episode_id"]
        episode_id = opened.episode_id

        oriented = publish_turn(session, turns.fetch("t1"))
        after_open = reload_episode(session)

        assert_equal "Fermator", after_open.fact("manufacturer")["value"]
        assert_includes after_open.identifiers.pluck("value"), "Fermator VF5+"
        assert_includes after_open.goal["text"], "durante el cierre"
        assert_includes oriented.text, "no se aplica"
        assert_includes oriented.text, compound
        assert_equal compound, after_open.pending_question["question"]
        assert_equal "not_done", check_status(after_open, "ajuste de #54")
        assert_equal "not_done", check_status(after_open, "mediciones")
        assert after_open.observations.any? { |item| item["text"].match?(/obstrucci[oó]n/i) }
        assert oriented.publication.accepted?, oriented.publication.reasons.inspect
        ask(session, turns.fetch("t2"))
        published = publish_turn(session, turns.fetch("t2"))
        corrected = reload_episode(session)

        assert_equal episode_id, corrected.episode_id
        assert_equal 1, corrected.qc
        assert_equal "el LED está encendido", led_text(corrected)
        assert corrected.observations.none? { |item| item["text"].match?(/apagado/i) }
        assert_includes published.text, "Fotocélula"
        assert_includes published.text, "Estado"
        assert_match(/LED está encendido/i, published.text)
        assert_includes turns.fetch("t2").dig("tool_input", "links").pluck("reading").join(" "), "parpadeante"
        assert_not_includes published.text, "parpadeante"
        assert_not_includes published.text, "apagado"
        assert_equal compound, corrected.pending_question["question"]
        assert_match(/Fotoc[eé]lula/, corrected.pending_question.dig("shown", "question").to_s)
        assert_match(/Estado/, corrected.pending_question.dig("shown", "question").to_s)
        assert published.publication.accepted?, published.publication.reasons.inspect

        ask(session, turns.fetch("t3"))
        checked = publish_turn(session, turns.fetch("t3"))
        after_check = reload_episode(session)

        assert_equal episode_id, after_check.episode_id
        assert_includes turns.fetch("t3")["captured_answer"], ABSTAIN
        assert_includes checked.text, "Revisé la fotocélula y no está activada"
        assert_includes checked.text, "potenciómetro"
        assert_includes checked.text, "sigue pendiente"
        assert_includes checked.text, "fotocélula"
        assert_includes checked.text, "no consta como hecha"
        assert_not_includes checked.text, ABSTAIN
        assert_nil checked.composed.check.question
        assert_equal "done", check_status(after_check, "fotocélula")
        assert_equal "no está activada", after_check.checks.find { |item| item["subject"] == "fotocélula" }["result"]
        assert_equal "not_done", check_status(after_check, "ajuste de #54")
        assert_equal "not_done", check_status(after_check, "mediciones")
        assert after_check.checks.none? { |item| item["subject"].to_s.match?(/obstruc/) }
        assert_equal compound, after_check.pending_question["question"]
        assert after_check.observations.any? { |item| item["text"].match?(/obstrucci[oó]n/i) }

        ask(session, turns.fetch("t4"))
        followed = publish_turn(session, turns.fetch("t4"))
        after_follow = reload_episode(session)

        assert_equal episode_id, after_follow.episode_id
        assert_includes turns.fetch("t4")["captured_answer"], ABSTAIN
        assert_includes followed.text, "potenciómetro"
        assert_includes followed.text, "sigue pendiente"
        assert_includes followed.text, "fotocélula"
        assert_not_includes followed.text, ABSTAIN
        assert_nil followed.composed.check.question
        assert after_follow.observations.none? { |item| item["text"] == turns.fetch("t4")["user"] }
        assert_equal compound, after_follow.pending_question["question"]
        assert_equal "not_done", check_status(after_follow, "ajuste de #54")

        main = after_follow.pending_question["parts"].find { |part| part["role"] == "main" }
        question_id = after_follow.pending_question["id"]
        # The captured interpreter tool has no part_replies. These two rows are
        # the simulated contract output for this test: the published part, and
        # the contact clause as its own declared slice.
        clause = "si hay un contacto cerrado entre #21 y #23"
        user = turns.fetch("t5")["user"]
        start = user.index(clause)
        reply = [
          { "question_id" => question_id, "part_id" => main["id"], "state" => "unknown" },
          {
            "question_id" => question_id, "part_id" => nil, "state" => "unknown",
            "start" => start, "end" => start + clause.length
          }
        ]
        answered = Rag::ValidationCapture.capture { ask(session, turns.fetch("t5"), part_replies: reply) }
        sent = JSON.parse(interpreter_turn(answered))
        listed = sent.dig("work_context", "pending", "questions").to_a.flat_map { |row| Array(row["parts"]) }
        limited = reload_episode(session)
        final = publish_turn(session, turns.fetch("t5"))
        stored = reload_episode(session)
        reloaded = reload_episode(session)

        assert_equal main["id"], listed.find { |part| part["role"] == "main" }["id"]
        assert_equal question_id, sent.dig("work_context", "pending", "questions", 0, "id")
        assert_equal episode_id, stored.episode_id
        assert_equal 1, stored.qc
        assert_equal 1, reloaded.qc
        declared = stored.pending_question["parts"].find { |part| part["role"] == "declared" }
        main_reply = stored.replies.find { |row| row["p"] == main["id"] }
        declared_reply = stored.replies.find { |row| row["p"] == declared["id"] }
        assert_equal "unknown", Rag::AnswerContract.part_state(stored, main["id"])
        assert_equal question_id, main_reply["q"]
        assert_equal main["id"], main_reply["p"]
        assert_includes Rag::AnswerContract.reconstruct(main_reply, session), "#21"
        assert_includes Rag::AnswerContract.reconstruct(main_reply, session), "#23"
        assert_equal clause, declared["text"]
        assert_equal clause, Rag::AnswerContract.reconstruct(declared_reply, session)
        assert_nil declared_reply["t"]
        assert Rag::AnswerContract.payload_questions(stored).first["parts"].none? { |part| part["id"] == declared["id"] }
        assert Rag::AnswerContract.correction_refs(stored, session).any? { |row| row["part_id"] == declared["id"] }
        assert_includes Rag::CompanionCaseFacts.build(stored, session: session).prompt_block, "Parte declarada #{declared['id']}"
        assert stored.observations.none? { |item| item.dig("answers", "r") == "unknown" }
        assert stored.observations.none? { |item| item.dig("answers", "q").present? }
        assert_match(/LED está encendido/i, limited.pending_question["question"])
        assert_nil limited.pending_question["shown"]
        assert_match(/LED está encendido/i, stored.pending_question["question"])
        assert_match(/Fotoc[eé]lula/, stored.pending_question["question"])
        assert_match(/Estado/, stored.pending_question["question"])
        assert_nil stored.pending_question["shown"]
        # The captured plan has no part_ref. Missing it suppresses the question.
        # That is not a finding that the contact question is the declared clause.
        assert_nil turns.fetch("t5").dig("tool_input", "part_ref")
        assert_equal "part_ref_missing", final.composed.check.rejections.find { |row| row["part"] == "question" }["reason"]
        assert_nil final.composed.check.question
        named = check_plan(session, turns.fetch("t5"), part_ref: declared["id"])
        unnamed = check_plan(session, turns.fetch("t5"), part_ref: "ninguna")
        assert_equal "part_settled", named.rejections.find { |row| row["part"] == "question" }["reason"]
        assert_nil named.question
        # "ninguna" is not in the captured tool. This rule does not block it,
        # and it does not decide whether the contact is another datum.
        assert_equal contact, unnamed.question
        assert unnamed.rejections.none? { |row| row["reason"] == "part_ref_missing" }
        assert_equal final.composed.check.limits, named.limits
        assert_equal named.limits, unnamed.limits
        assert_match(/\AIndicaste que no puedes distinguirlo/, final.text)
        assert_includes final.text, "potenciómetro"
        assert_includes final.text, "ya informaste"
        assert_includes final.text, "no consta como hecha"
        assert_not_includes final.text, contact
        assert_not_includes final.text, "?"
        assert stored.observations.any? { |item|
          text = item["text"].to_s
          text.include?("identificar") && text.include?("#21") && text.include?("#23") && text.include?("contacto cerrado")
        }
        assert_equal "done", check_status(stored, "fotocélula")
        assert_equal "not_done", check_status(stored, "ajuste de #54")
        assert_equal "not_done", check_status(stored, "mediciones")
        assert stored.observations.any? { |item| item["text"].match?(/obstrucci[oó]n/i) }
        assert_equal "el LED está encendido", led_text(stored)
        assert final.publication.accepted?, final.publication.reasons.inspect
      end
    end
  ensure
    ENV["HAIKU_QUERY_ANALYSIS_MODE"], ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous
    session&.destroy
    document&.destroy
  end

  private

  def open_session(document)
    ConversationSession.create!(
      identifier: "web:vf5-contract-#{SecureRandom.hex(3)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: @user,
      account: @account,
      active_episode: {},
      conversation_history: [],
      document_focus: [ {
        "kb_document_id" => document.id,
        "source_uri" => FOCUS_URI,
        "display_name" => "VF5",
        "added_at" => Time.current.iso8601
      } ]
    )
  end

  def ask(session, raw, part_replies: nil)
    input = raw["interpreter"].deep_dup
    input["part_replies"] = part_replies if part_replies
    session.record_user_turn!(
      raw["user"],
      user_id: @user.id,
      correlation_id: raw["correlation_id"],
      interpreter_client: perception_client(input)
    )
  end

  def publish_turn(session, raw)
    episode = reload_episode(session)
    composed = compose(raw, episode, session)
    publication = publish(composed, raw, episode, session)
    session.record_assistant_turn!(
      composed.text,
      user_id: @user.id,
      correlation_id: "#{raw['correlation_id']}:published",
      pending_question: composed.pending,
      expected_episode_id: session.live_episode_id
    )
    Struct.new(:text, :composed, :publication).new(composed.text, composed, publication)
  end

  def check_plan(session, raw, part_ref:)
    episode = reload_episode(session)
    chunks = raw["chunks"].map { |chunk|
      { content: chunk["content"], metadata: chunk["metadata"], identity_applicability: "compatible" }
    }
    prepared = Rag::CompanionPlan.prepare(
      raw_question: raw["user"], chunks: chunks, episode: episode, session: session,
      correlation_id: "#{raw['correlation_id']}:synthetic-ref"
    )
    plan = raw["tool_input"].deep_dup
    plan["part_ref"] = part_ref
    Rag::CompanionPlanCheck.call(plan, facts: prepared.facts, statements: prepared.statements, turns: [])
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
    sources = raw["chunks"].each_with_index.map { |chunk, index|
      { "index" => index + 1, "content" => chunk["content"], "applicability" => "compatible", "reference_only" => false }
    }
    Rag::CompanionTurnPublication.call(
      text: composed.text,
      sources: sources,
      technician_texts: BedrockRagService.allocate.send(:companion_technician_texts, session, episode, raw["user"]),
      manufacturer: episode.fact("manufacturer")&.dig("value"),
      stop_reason: "tool_use"
    )
  end

  def reload_episode(session)
    Rag::ActiveEpisode.parse(session.reload.active_episode)
  end

  def led_text(episode)
    episode.observations.pluck("text").find { |text| text.match?(/\bled\b/i) }
  end

  def check_status(episode, subject)
    episode.checks.find { |item| item["subject"] == subject }&.dig("status")
  end

  def interpreter_turn(events)
    request = events.find { |event| event["kind"] == "interpreter_request" }
    request["message_text"]
  end

  def load_turns
    Rails.root.glob("test/fixtures/vf5_gui_replay/t*.json").sort.to_h { |path|
      raw = JSON.parse(File.read(path))
      [ raw["turn"], raw ]
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

  def perception_client(input)
    Object.new.tap do |client|
      client.define_singleton_method(:converse) do |_params|
        tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, input)
        block = Struct.new(:tool_use).new(tool)
        message = Struct.new(:content).new([ block ])
        output = Struct.new(:message).new(message)
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(output, usage)
      end
    end
  end
end
