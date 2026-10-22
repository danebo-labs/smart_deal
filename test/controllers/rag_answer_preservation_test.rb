# frozen_string_literal: true

require "test_helper"

class RagAnswerPreservationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @user.update!(account: @account)
  end

  test "the presented answer and the model history keep the checks the sanitizer used to drop" do
    raw = <<~TEXT.strip
      Según la documentación [3]:

      **1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**
      **2. Comprobar que la fotocélula no esté activada.**
      El LED está **encendido**.
      **3. Comprobar que no hay una obstrucción mecánica en la puerta.**
    TEXT
    session = ConversationSession.find_or_create_for(
      identifier: @user.id.to_s,
      channel: "web",
      user_id: @user.id,
      account_id: @account.id
    )
    episode = active_case
    session.update!(active_episode: episode.to_h, conversation_history: [])

    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", nil) do
      isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") do
        sign_in @user
        with_mock_orchestrator(orchestrator(raw)) do
          post rag_ask_url, params: { question: "¿Qué compruebo ahora?" }, as: :json
        end
      end
    end

    assert_response :success
    answer = json_response["answer"]
    assert_includes answer, "Registro del caso."
    assert_includes answer, "Comprobar que la fotocélula no esté activada."
    assert_includes answer, "Comprobar que no hay una obstrucción mecánica en la puerta."
    assert_includes answer, "El LED está **encendido**."
    assert_not_includes answer, "**2. Comprobar que la fotocélula no esté activada.**"
    assert_not_includes answer, "**3. Comprobar que no hay una obstrucción mecánica en la puerta.**"

    stored = session.reload.conversation_history.reverse.find { |row| row["role"] == "assistant" }
    reply = stored["prompt_reply"].to_s
    assert_includes reply, "Comprobar que la fotocélula no esté activada."
    assert_includes reply, "Comprobar que no hay una obstrucción mecánica en la puerta."
    assert_includes reply, "El LED está **encendido**."
    assert_not_includes reply, "Registro del caso"
    assert_includes stored["content"], "Registro del caso."
  end

  test "a 746 character message records the original and sent lengths without changing the cut" do
    tail = " no está activada"
    question = ("x" * (746 - tail.length)) + tail
    assert_equal 746, question.length
    sent = []

    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
          sign_in @user
          with_interpreter_stub(sent) do
            with_mock_orchestrator(orchestrator("Respuesta breve.")) do
              output = capture_pilot_log do
                post rag_ask_url, params: { question: question }, as: :json
              end
              assert_response :success
              payload = interaction_payload(output)
              assert_equal 746, payload["interpreter_original_chars"]
              assert_equal 600, payload["interpreter_sent_chars"]
              assert_equal question.length, payload["interpreter_original_chars"]
              assert_equal sent.fetch(0).length, payload["interpreter_sent_chars"]
              assert_equal Rag::TurnText.truncate(question), sent.fetch(0)
              assert_equal 600, sent.fetch(0).length
              assert_not_includes sent.fetch(0), tail.strip
              payload.each_value do |value|
                next unless value.is_a?(String)

                assert_not_includes value, question[0, 40]
                assert_not_includes value, tail.strip
              end
            end
          end
        end
      end
    end
  end

  test "a message inside the interpreter limit omits the truncation lengths" do
    question = "¿El LED está encendido?"
    sent = []

    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
          sign_in @user
          with_interpreter_stub(sent) do
            with_mock_orchestrator(orchestrator("Respuesta breve.")) do
              output = capture_pilot_log do
                post rag_ask_url, params: { question: question }, as: :json
              end
              assert_response :success
              payload = interaction_payload(output)
              assert_nil payload["interpreter_original_chars"]
              assert_nil payload["interpreter_sent_chars"]
              assert_equal [ question ], sent
            end
          end
        end
      end
    end
  end

  private

  def active_case
    now = Time.current
    episode = Rag::ActiveEpisode.open(correlation_id: "case", now: now)
    episode.assign_goal!("La puerta se reabre sola", correlation_id: "case")
    episode.write_fact!(
      "manufacturer", status: "known", value: "Fermator", source: "user",
      correlation_id: "case", at: now.iso8601
    )
    episode.append_observation!("La puerta se reabre sola", correlation_id: "case")
    episode.upsert_check!({ "subject" => "#54", "status" => "not_done" }, correlation_id: "case")
    episode
  end

  def orchestrator(answer)
    mock = Object.new
    mock.define_singleton_method(:execute) do
      {
        answer: answer,
        citations: [],
        session_id: "preservation",
        generation_mode: Rag::FieldCaseRecord::DOCUMENT_IDENTITY
      }
    end
    mock
  end

  def with_mock_orchestrator(mock)
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_args, **_kwargs| mock }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def with_interpreter_stub(sent)
    original = Rag::TurnInterpreter.method(:call)
    Rag::TurnInterpreter.define_singleton_method(:call) do |**kwargs|
      sent << kwargs.fetch(:turn)
      Rag::TurnInterpreter::Result.new(
        perception: nil,
        fallback: true,
        status: "empty",
        latency_ms: 0,
        input_tokens: 0,
        output_tokens: 0,
        model_id: nil,
        error_class: nil,
        error_reason: nil,
        stage: "extract"
      )
    end
    yield
  ensure
    Rag::TurnInterpreter.define_singleton_method(:call) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def capture_pilot_log
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    output.string
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  def interaction_payload(output)
    line = output.lines.find { |entry| entry.include?("[PILOT_USAGE]") && entry.include?('"interaction_completed"') }
    assert line.present?, "interaction_completed must be emitted"
    JSON.parse(line.sub(/\A.*\[PILOT_USAGE\]\s*/, ""))
  end

  def json_response
    response.parsed_body
  end
end
