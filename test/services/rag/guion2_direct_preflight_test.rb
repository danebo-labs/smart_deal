# frozen_string_literal: true

require "test_helper"
require "stringio"

class Rag::Guion2DirectPreflightTest < ActiveSupport::TestCase
  setup do
    @previous = ENV["RAG_COMPANION_GENERATION"]
    @require = ENV["GUION2_DIRECT_REQUIRE"]
    ENV["GUION2_DIRECT_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/run_guion2.rb")
  end

  teardown do
    @previous.nil? ? ENV.delete("RAG_COMPANION_GENERATION") : ENV["RAG_COMPANION_GENERATION"] = @previous
    @require.nil? ? ENV.delete("GUION2_DIRECT_REQUIRE") : ENV["GUION2_DIRECT_REQUIRE"] = @require
  end

  test "preflight returns before a model client is constructed" do
    ENV["RAG_COMPANION_GENERATION"] = "direct"
    calls = []
    trace = TracePoint.new(:call) do |event|
      next unless event.method_id == :converse || (event.method_id == :new && event.defined_class.to_s.include?("Bedrock"))

      calls << [ event.defined_class.to_s, event.method_id ]
    end
    io = StringIO.new
    code = trace.enable { Guion2Direct.preflight(io: io) }
    body = JSON.parse(io.string)

    assert_equal 0, code
    assert_equal true, body["stopped_before_model"]
    assert_equal true, body["companion_generation_direct"]
    assert_equal false, body["shared_session"]
    assert_equal 6, body["guion2_calls_without_retry"]
    assert_equal 10, body["guion1_calls_without_retry"]
    assert_equal "not_executed", body["paid_run"]
    assert_equal 211, Rag::AssignmentSpend::CALL_CAP_BUMPS[196]
    assert_includes Rag::LocalPassLedger::ASSIGNMENT_CALL_CAPS, 211
    assert_empty calls
  end
end
