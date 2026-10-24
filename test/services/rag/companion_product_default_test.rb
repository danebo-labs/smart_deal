# frozen_string_literal: true

require "test_helper"

class Rag::CompanionProductDefaultTest < ActiveSupport::TestCase
  test "absent companion switches are on and the explicit kill switches are off" do
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", nil) do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", nil) do
        isolate_env("DOCUMENT_IDENTITY_SCOPE_ENABLED", nil) do
          isolate_env("RAG_COMPANION_TURN", nil) do
            isolate_env("HAIKU_QUERY_ANALYSIS_MODE", nil) do
              assert Rag::FieldCompanionEpisodeFlag.enabled?
              assert Rag::FieldCompanionTurnFlag.enabled?
              assert Rag::DocumentIdentityScopeFlag.enabled?
              assert Rag::HaikuQueryAnalysisFlag.owner?
              assert BedrockRagService.allocate.send(:companion_turn_enabled?)
            end
          end
        end
      end
    end

    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "false") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "false") do
        isolate_env("DOCUMENT_IDENTITY_SCOPE_ENABLED", "false") do
          isolate_env("RAG_COMPANION_TURN", "0") do
            isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") do
              assert_not Rag::FieldCompanionEpisodeFlag.enabled?
              assert_not Rag::FieldCompanionTurnFlag.enabled?
              assert_not Rag::DocumentIdentityScopeFlag.enabled?
              assert_not Rag::HaikuQueryAnalysisFlag.owner?
              assert_not BedrockRagService.allocate.send(:companion_turn_enabled?)
            end
          end
        end
      end
    end
  end

  test "an explicit plan question skips companion generation and leaves the episode unchanged" do
    episode = Rag::ActiveEpisode.open(correlation_id: "plan", now: Time.current)
    episode.assign_goal!("la puerta vuelve a abrirse", correlation_id: "plan")
    before = episode.to_h.deep_dup
    applied = Struct.new(:status).new(:scoped)
    service = BedrockRagService.allocate

    reason = isolate_env("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE", nil) do
      service.send(
        :companion_turn_skip_reason,
        applied: applied,
        chunks: [],
        episode: episode,
        raw_question: "Según el plano, ¿dónde está el contactor?"
      )
    end

    assert_equal :plan, reason
    assert_equal before, episode.to_h
  end

  test "pinning a manual does not clear episode facts" do
    user = users(:one)
    session = ConversationSession.create!(
      account: accounts(:legacy),
      user: user,
      identifier: "pin-keeps-episode",
      channel: "web",
      expires_at: 1.hour.from_now
    )
    episode = Rag::ActiveEpisode.open(correlation_id: "pin", now: Time.current)
    episode.assign_goal!("la puerta vuelve a abrirse", correlation_id: "pin")
    session.update!(active_episode: episode.to_h)
    before = session.active_episode.deep_dup

    assert session.pin_kb_document!(kb_documents(:manual_uno))

    stored = session.reload.active_episode
    assert_equal before["episode_id"], stored["episode_id"]
    assert_equal before["facts"], stored["facts"]
    assert_equal before["goal"], stored["goal"]
    assert_equal 1, session.document_focus_entries.size
  end

  test "a shown answer longer than 600 characters is stored in full_content" do
    session = ConversationSession.create!(
      account: accounts(:legacy),
      user: users(:one),
      identifier: "archive-answer",
      channel: "web",
      expires_at: 1.hour.from_now
    )
    shown = "N" * 900
    antecedent = "A" * 700

    session.add_to_history("assistant", shown, prompt_reply: antecedent)
    row = session.reload.conversation_history.last

    assert_equal ConversationSession::MAX_MSG_LENGTH, row["content"].length
    assert_equal shown, row["full_content"]
    assert_not row.key?("full_content_truncated")
    assert_equal antecedent, row["prompt_reply"]
  end

  test "raw audit text follows the account list and still keeps hashes" do
    common = {
      correlation_id: "query:archive",
      route: "text",
      outcome: "answered",
      original_query: "pregunta completa del tecnico",
      effective_query: "pregunta efectiva",
      answer: "respuesta presentada completa"
    }

    isolate_env("PILOT_AUDIT_CAPTURE", "true") do
      isolate_env("PILOT_AUDIT_CAPTURE_ACCOUNT_IDS", "1") do
        included = Rag::TurnEvidence.build(**common, account_id: 1)
        excluded = Rag::TurnEvidence.build(**common, account_id: 2)
        unknown = Rag::TurnEvidence.build(**common, account_id: nil)

        assert_equal common[:answer], included["answer"]
        assert_not excluded.key?("answer")
        assert_not unknown.key?("answer")
        assert_equal Digest::SHA256.hexdigest(common[:answer]), excluded["answer_sha256"]
      end

      isolate_env("PILOT_AUDIT_CAPTURE_ACCOUNT_IDS", nil) do
        global = Rag::TurnEvidence.build(**common, account_id: nil)
        assert_equal common[:answer], global["answer"]
      end
    end
  end

  test "the pilot export carries full_content and prompt_reply from the session" do
    user = users(:one)
    shown = "R" * 800
    antecedent = "P" * 650
    question = "Q" * 700
    session = ConversationSession.create!(
      account: accounts(:legacy),
      user: user,
      identifier: "export-archive",
      channel: "web",
      expires_at: 1.hour.from_now,
      updated_at: Time.current,
      conversation_history: [
        {
          "role" => "user",
          "content" => question[0, ConversationSession::MAX_MSG_LENGTH],
          "full_content" => question,
          "user_id" => user.id,
          "correlation_id" => "query:export",
          "ts" => Time.current.iso8601
        },
        {
          "role" => "assistant",
          "content" => shown[0, ConversationSession::MAX_MSG_LENGTH],
          "full_content" => shown,
          "prompt_reply" => antecedent,
          "correlation_id" => "query:export",
          "ts" => Time.current.iso8601
        }
      ]
    )
    file = Tempfile.new("pilot-archive")
    file.puts("[PILOT_USAGE] #{JSON.generate(
      event: "interaction_completed", ts: Time.current.iso8601, account_id: accounts(:legacy).id,
      user_id: user.id, conversation_session_id: session.id, correlation_id: "query:export",
      outcome: "answered", route: "text"
    )}")
    file.flush

    report = PilotMetricsReport.new(date: Time.zone.today, usage_log_path: file.path, user_ids: [ user.id ]).as_json
    turns = report.dig(:interactions, :by_correlation).sole[:session_turns]
    archive = report[:session_archive].select { |row| row[:correlation_id] == "query:export" }

    assert_equal question, turns.find { |turn| turn[:role] == "user" }[:full_content]
    assert_equal shown, turns.find { |turn| turn[:role] == "assistant" }[:full_content]
    assert_equal antecedent, turns.find { |turn| turn[:role] == "assistant" }[:prompt_reply]
    assert_equal [ question, shown ], archive.filter_map { |row| row[:full_content] }
    assert_equal ConversationSession::MAX_MSG_LENGTH, archive.first[:content].length
  ensure
    file&.close!
  end
end
