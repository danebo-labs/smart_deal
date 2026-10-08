# frozen_string_literal: true

require "test_helper"

class Stage2JourneyARunnerTest < ActiveSupport::TestCase
  setup do
    @authorized = ENV["STAGE2_JOURNEY_AUTHORIZED"]
    @require_only = ENV["STAGE2_JOURNEY_A_REQUIRE"]
    ENV["STAGE2_JOURNEY_A_REQUIRE"] = "1"
    ENV.delete("STAGE2_JOURNEY_AUTHORIZED")
    %w[PROD_KB STAGE2_ISOLATED_DATABASE STAGE2_ISOLATED_CACHE_DATABASE STAGE2_ISOLATED_CABLE_DATABASE UID S3_KEY CEA_UID CEA_KEY DISPLAY TRACE_ROOT].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
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

  test "the isolated database guard refuses the ordinary development database" do
    development = ActiveSupport::StringInquirer.new("development")
    endpoint = Struct.new(:database, :host, :adapter)
    ordinary = endpoint.new("smart_deal_development", "localhost", "postgresql")
    remote = endpoint.new(STAGE2_ISOLATED_DATABASE, "smart-deal-db.example.rds.amazonaws.com", "postgresql")
    other_adapter = endpoint.new(STAGE2_ISOLATED_DATABASE, "127.0.0.1", "mysql2")
    isolated = endpoint.new(STAGE2_ISOLATED_DATABASE, "127.0.0.1", "postgresql")

    assert_equal "refuse smart_deal_development@localhost", stage2_database_refusal(ordinary, development)
    assert_match(/\Arefuse /, stage2_database_refusal(remote, development))
    assert_match(/\Arefuse /, stage2_database_refusal(other_adapter, development))
    assert_nil stage2_database_refusal(isolated, development)
    assert_equal "smart_deal_stage2_isolated", STAGE2_ISOLATED_DATABASE
  end

  test "the runner requires the captured accounts and manuals" do
    assert_equal "account 1 missing", stage2_account_refusal(nil)
    assert_match(/slug/, stage2_account_refusal(Struct.new(:id, :slug).new(1, "index-account-1")))
    assert_nil stage2_account_refusal(Struct.new(:id, :slug).new(1, "danebo-legacy"))
    assert_equal "account 3 missing", stage2_pilot_account_refusal(nil)
    assert_nil stage2_pilot_account_refusal(Struct.new(:id, :slug).new(3, "danebo-pilot-elevator"))

    elemont = Struct.new(:document_uid, :s3_key, :knowledge_scope).new(UID, S3_KEY, "tenant_private")
    cea = Struct.new(:document_uid, :s3_key, :knowledge_scope).new(CEA_UID, CEA_KEY, "tenant_private")
    assert_nil stage2_document_refusal(elemont)
    assert_nil stage2_cea_refusal(cea)
    assert_equal "elemont document missing", stage2_document_refusal(nil)
    assert_equal "cea15 document missing", stage2_cea_refusal(nil)
    assert_match(/scope/, stage2_cea_refusal(Struct.new(:document_uid, :s3_key, :knowledge_scope).new(CEA_UID, CEA_KEY, "danebo_general")))
  end

  test "cache and cable configs name isolated local databases" do
    cache = stage2_named_config("cache", STAGE2_ISOLATED_CACHE_DATABASE)
    cable = stage2_named_config("cable", STAGE2_ISOLATED_CABLE_DATABASE)
    cache_name = cache[:database] || cache["database"]
    cable_name = cable[:database] || cable["database"]

    assert_equal "smart_deal_stage2_isolated_cache", cache_name
    assert_equal "smart_deal_stage2_isolated_cable", cable_name
    assert_not_includes [ cache_name, cable_name ], "smart_deal_development_cache"
    assert_not_includes [ cache_name, cable_name ], "smart_deal_development_cable"
    endpoint = Struct.new(:database, :host, :adapter)
    assert_equal "postgresql", (cache[:adapter] || cache["adapter"]).to_s
    assert_equal "postgresql", (cable[:adapter] || cable["adapter"]).to_s
    assert_equal "refuse smart_deal_development_cache@localhost",
      stage2_role_refusal(endpoint.new("smart_deal_development_cache", "localhost", "postgresql"), STAGE2_ISOLATED_CACHE_DATABASE)
    assert_nil stage2_role_refusal(endpoint.new(STAGE2_ISOLATED_CABLE_DATABASE, "127.0.0.1", "postgresql"), STAGE2_ISOLATED_CABLE_DATABASE)
  end

  test "only the inlined tracker bypasses the Solid Queue refusal" do
    refused = Class.new do
      class << self
        def name
          "WarmBedrockKbJob"
        end

        def perform_later(*)
          :queued
        end
      end
    end
    refused.singleton_class.prepend(Stage2QueueRefusal)
    assert_raises(SystemExit) { refused.perform_later }

    tracker = Class.new do
      class << self
        def name
          "TrackBedrockQueryJob"
        end

        def perform_now(*)
          :now
        end

        def perform_later(*)
          :queued
        end
      end
    end
    tracker.singleton_class.prepend(Stage2QueueRefusal)
    tracker.singleton_class.prepend(InlineBedrockQueryTracking)
    assert_equal :now, tracker.perform_later(model_id: "stub")
  end

  private

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
