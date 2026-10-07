# frozen_string_literal: true

require "test_helper"

class Stage2JourneyARunnerTest < ActiveSupport::TestCase
  setup do
    @authorized = ENV["STAGE2_JOURNEY_AUTHORIZED"]
    @require_only = ENV["STAGE2_JOURNEY_A_REQUIRE"]
    ENV["STAGE2_JOURNEY_A_REQUIRE"] = "1"
    ENV.delete("STAGE2_JOURNEY_AUTHORIZED")
    load Rails.root.join("script/field_companion/stage2_journey_a.rb")
  end

  teardown do
    restore_env("STAGE2_JOURNEY_AUTHORIZED", @authorized)
    restore_env("STAGE2_JOURNEY_A_REQUIRE", @require_only)
  end

  test "a refused budget stops before a session, retrieve, or generation" do
    calls = []
    remote = Object.new
    remote.define_singleton_method(:retrieve_chunks) { |*| calls << :retrieve }
    remote.define_singleton_method(:generate_text) { |*| calls << :generate }
    remote.define_singleton_method(:execute) { |*| calls << :generate }
    ENV["STAGE2_JOURNEY_AUTHORIZED"] = "1"
    originals = {
      BedrockRagService => BedrockRagService.method(:new),
      ConversationSession => ConversationSession.method(:create!),
      Stage2QueryHost => Stage2QueryHost.method(:new)
    }
    BedrockRagService.define_singleton_method(:new) { |*| calls << :service; remote }
    ConversationSession.define_singleton_method(:create!) { |*| calls << :session }
    Stage2QueryHost.define_singleton_method(:new) { |*| calls << :host; remote }

    assert_equal :budget, stage2_journey_a_main
    assert_empty calls
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_not Rag::Stage2RunBudget.admit_turn?(new_calls: 0, new_cost_usd: 0)
  ensure
    originals&.each do |klass, method|
      klass.define_singleton_method(method.name) { |*args, **kwargs, &block| method.call(*args, **kwargs, &block) }
    end
  end

  private

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
