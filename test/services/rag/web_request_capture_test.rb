# frozen_string_literal: true

require "test_helper"

class Rag::WebRequestCaptureTest < ActiveSupport::TestCase
  setup do
    @previous_run = ENV["RAG_VALIDATION_CAPTURE_RUN"]
    @run_id = "webcap#{SecureRandom.hex(4)}"
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = @run_id
    Rag::LocalPassLedger.reset_local_process!
  end

  teardown do
    @previous_run.nil? ? ENV.delete("RAG_VALIDATION_CAPTURE_RUN") : ENV["RAG_VALIDATION_CAPTURE_RUN"] = @previous_run
    FileUtils.rm_rf(Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id))
    Thread.current[:rag_validation_capture] = nil
  end

  test "an error still exports the request and a later wrap does not keep it" do
    assert Rag::WebRequestCapture.enabled?

    assert_raises(RuntimeError) do
      Rag::WebRequestCapture.wrap(controller: fake_controller("primero")) do
        Rag::ValidationCapture.record(
          "user_message",
          "original" => "texto del request",
          "sent" => "texto del request",
          "transform" => "none"
        )
        seen = Queue.new
        Thread.new do
          Rag::ValidationCapture.record(
            "user_message",
            "original" => "texto de otro hilo",
            "sent" => "texto de otro hilo",
            "transform" => "none"
          )
          seen << Rag::ValidationCapture.active?
        end.join
        assert_equal false, seen.pop
        raise "fallo de prueba"
      end
    end

    assert_nil Thread.current[:rag_validation_capture]
    first = capture_for("primero")
    originals = event_values(first, "user_message", "original")
    assert_includes originals, "texto del request"
    assert_not_includes originals, "texto de otro hilo"
    assert_equal "primero", first["events"].first["question"]

    Rag::WebRequestCapture.wrap(controller: fake_controller("segundo")) do
      Rag::ValidationCapture.record(
        "user_message",
        "original" => "solo el segundo",
        "sent" => "solo el segundo",
        "transform" => "none"
      )
    end

    second = capture_for("segundo")
    second_originals = event_values(second, "user_message", "original")
    assert_equal [ "solo el segundo" ], second_originals
    assert_not_includes event_values(first, "user_message", "original"), "solo el segundo"
  end

  private

  def fake_controller(question)
    request = Struct.new(:request_id).new(SecureRandom.uuid)
    params = ActionController::Parameters.new("question" => question)
    controller = Object.new
    controller.define_singleton_method(:request) { request }
    controller.define_singleton_method(:params) { params }
    controller.define_singleton_method(:controller_path) { "rag" }
    controller.define_singleton_method(:action_name) { "ask" }
    controller.define_singleton_method(:current_user) { Struct.new(:id).new(7) }
    controller.define_singleton_method(:current_account) { Struct.new(:id).new(1) }
    controller
  end

  def capture_paths
    Dir[Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id, "*", "capture.json").to_s].sort
  end

  def capture_for(question)
    found = capture_paths.map { |path| JSON.parse(File.read(path)) }.find { |document|
      document["events"].first["question"] == question
    }
    assert found, "missing capture for #{question}"
    found
  end

  def event_values(document, kind, field)
    document["events"].filter_map { |event| event[field] if event["kind"] == kind }
  end
end
