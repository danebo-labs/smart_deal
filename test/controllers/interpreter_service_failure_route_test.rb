# frozen_string_literal: true

require "test_helper"

class InterpreterServiceFailureRouteTest < ActiveSupport::TestCase
  test "an exhausted interpreter does not call generation" do
    called = false
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*| called = true; raise "generation started" }
    host = Class.new do
      include RagQueryConcern

      def run(...)
        execute_rag_query(...)
      end
    end.new
    turn = Struct.new(:reason).new("service_failure")
    result = nil
    events = Rag::ValidationCapture.capture do
      result = host.run(
        "la puerta vuelve a abrirse",
        episode_turn: turn,
        correlation_id: "query:service"
      )
    end

    assert_equal false, called
    assert_equal false, result.model_invoked
    assert_equal "service_failure", result.generation_mode
    assert_equal I18n.t("rag.interpreter_service_failure", locale: :es), result.answer
    assert_not_includes result.answer, "placa"
    published = events.select { |event| event["kind"] == "published_answer" }
    assert_equal 1, published.size
    assert_equal result.answer, published.first["answer"]
    assert_equal false, published.first["model_invoked"]
  ensure
    QueryOrchestratorService.define_singleton_method(:new, original) if original
  end
end
