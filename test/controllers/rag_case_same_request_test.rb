# frozen_string_literal: true

require "test_helper"

class RagCaseSameRequestTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  OPENING = "Cómo se ajustan los resortes de la fijación de cables ?"
  NEW_CASE = "Ahora estoy revisando un KONE que no nivela en planta 3"
  CORRECTION = "No, no es Elemont. Es KONE"
  KONE_QUERY = "En el KONE, ¿cómo se ajustan los resortes de la fijación de cables?"

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @user.update!(account: @account)
  end

  test "the request that crosses expiry still sends the selected manual" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    doc = manual("elemont-expiry.pdf")
    session = user_session
    travel_to(at) do
      session.update!(expires_at: 30.days.from_now)
      seed_episode(session, "ep_old", at)
      session.pin_kb_document!(doc)
    end

    sign_in @user
    captured = nil
    travel_to(at + ConversationSession::EPISODE_WINDOW + 1.second) do
      with_case_flags do
        captured = ask(OPENING)
      end
    end

    uri = doc.display_s3_uri(KbDocument::KB_BUCKET)
    assert_includes Array(captured[:entity_s3_uris]), uri
    assert_equal true, captured[:force_entity_filter]
    assert_includes SessionContextBuilder.entity_s3_uris(session.reload), uri
    assert_equal "pin_only", retrieval_scope([ uri ]).reason
  end

  test "hola after expiry leaves the next KONE query on the selected manual" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    doc = manual("elemont-hola.pdf")
    session = user_session
    travel_to(at) do
      session.update!(expires_at: 30.days.from_now)
      seed_episode(session, "ep_hola", at)
      session.pin_kb_document!(doc)
    end

    sign_in @user
    captured = nil
    travel_to(at + ConversationSession::EPISODE_WINDOW + 1.second) do
      with_case_flags do
        ask("hola")
        captured = ask(KONE_QUERY)
      end
    end

    uri = doc.display_s3_uri(KbDocument::KB_BUCKET)
    assert_includes Array(captured[:entity_s3_uris]), uri
    assert_includes SessionContextBuilder.entity_s3_uris(session.reload), uri
  end

  test "the request that corrects the manufacturer still sends the selected manual" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    doc = manual("elemont-correct-request.pdf")
    session = user_session
    travel_to(at) do
      session.update!(expires_at: 30.days.from_now)
      seed_episode(
        session, "ep_correct", at,
        facts: { "manufacturer" => { "status" => "known", "value" => "Elemont", "source" => "user", "correlation_id" => "seed", "at" => at.iso8601 } }
      )
      session.pin_kb_document!(doc)
    end

    sign_in @user
    captured = nil
    travel_to(at + 1.minute) do
      with_case_flags do
        captured = ask(CORRECTION)
      end
    end

    uri = doc.display_s3_uri(KbDocument::KB_BUCKET)
    assert_includes Array(captured[:entity_s3_uris]), uri
    assert_equal true, captured[:force_entity_filter]
    assert session.reload.find_entity_by_kb_document_id(doc.id)
    assert_equal "KONE", session.active_episode.dig("facts", "manufacturer", "value")
  end

  test "the request that opens a new episode still sends the previous pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    doc = manual("elemont-new-request.pdf")
    session = user_session
    travel_to(at) do
      session.update!(expires_at: 30.days.from_now)
      seed_episode(session, "ep_live", at)
      session.pin_kb_document!(doc)
    end

    sign_in @user
    captured = nil
    travel_to(at + 1.minute) do
      with_case_flags do
        captured = ask(NEW_CASE)
      end
    end

    uri = doc.display_s3_uri(KbDocument::KB_BUCKET)
    assert_includes Array(captured[:entity_s3_uris]), uri
    assert_equal true, captured[:force_entity_filter]
    assert session.reload.find_entity_by_kb_document_id(doc.id)
    assert_not_equal "ep_live", session.active_episode["episode_id"]
  end

  private

  def user_session
    ConversationSession.find_or_create_for(
      identifier: @user.id.to_s, channel: "web", user_id: @user.id, account_id: @account.id
    )
  end

  def manual(key)
    KbDocument.create!(
      s3_key: "uploads/2026/same-request/#{key}",
      display_name: "Elemont Montacargas Hidraulico Modelo MH",
      aliases: [],
      account: @account
    )
  end

  def seed_episode(session, episode_id, at, facts: {})
    session.update!(
      active_episode: {
        "v" => 1,
        "episode_id" => episode_id,
        "status" => "active",
        "opened_at" => at.iso8601,
        "updated_at" => at.iso8601,
        "facts" => facts,
        "identifiers" => [],
        "conflicts" => []
      }
    )
  end

  def ask(question)
    captured = {}
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured.replace(kwargs)
      obj = Object.new
      obj.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: nil } }
      obj
    end
    post rag_ask_url, params: { question: question }, as: :json
    assert_response :ok
    captured
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  def with_case_flags
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") { yield }
      end
    end
  end

  def retrieval_scope(uris)
    Object.new.extend(RagQueryConcern).send(:resolve_retrieval_scope, pinned_uris: uris)
  end
end
