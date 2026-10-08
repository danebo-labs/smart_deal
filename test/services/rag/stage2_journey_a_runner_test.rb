# frozen_string_literal: true

require "test_helper"

class Stage2JourneyARunnerTest < ActiveSupport::TestCase
  setup do
    @authorized = ENV["STAGE2_JOURNEY_AUTHORIZED"]
    @require_only = ENV["STAGE2_JOURNEY_A_REQUIRE"]
    ENV["STAGE2_JOURNEY_A_REQUIRE"] = "1"
    ENV.delete("STAGE2_JOURNEY_AUTHORIZED")
    %w[PROD_KB STAGE2_ISOLATED_DATABASE STAGE2_ISOLATED_CACHE_DATABASE STAGE2_ISOLATED_CABLE_DATABASE UID S3_KEY CEA_UID CEA_KEY DISPLAY STAGE2_EXPECTED_FILTER TRACE_ROOT].each do |name|
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
    original_admit = Rag::Stage2RunBudget.method(:admit_turn?)
    Rag::Stage2RunBudget.define_singleton_method(:admit_turn?) { |**| false }

    assert_equal :budget, stage2_journey_a_main
    assert_empty calls
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_equal 174, Rag::Stage2RunBudget::STAGE2_CALL_CEILING
    assert_equal 216, Rag::Stage2RunBudget::GLOBAL_CALL_CEILING
    assert_equal 3, Rag::Stage2RunBudget::TURN_CALL_MARGIN
    assert_equal 160, Rag::Stage2RunBudget::HISTORICAL_CALLS
    assert_equal BigDecimal("0.343774"), Rag::Stage2RunBudget::HISTORICAL_COST_USD
  ensure
    if defined?(original_admit) && original_admit
      Rag::Stage2RunBudget.define_singleton_method(:admit_turn?) { |**kwargs| original_admit.call(**kwargs) }
    end
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

  test "a failed model attempt consumes the cap and a registered row does not count twice" do
    converse_failure = [ [ {
      "kind" => "interpreter_failure",
      "stage" => "converse",
      "correlation_id" => "stage2:a:t01",
      "error_class" => "Timeout::Error"
    } ] ]
    prepare_failure = [ [ {
      "kind" => "interpreter_failure",
      "stage" => "prepare",
      "correlation_id" => "stage2:a:t00"
    } ] ]
    retrieve_failure = [ [ {
      "kind" => "terminal_error",
      "operation" => "retrieve",
      "correlation_id" => "stage2:a:availability",
      "transport_attempt" => 2
    } ] ]
    paid_local = [ [ {
      "kind" => "interpreter_failure",
      "stage" => "extract",
      "correlation_id" => "stage2:a:t02"
    } ] ]
    paid_row = [ {
      "correlation_id" => "stage2:a:t02",
      "source" => "semantic_analysis",
      "route" => "semantic_analysis",
      "cost_usd" => 0.004
    } ]
    mixed = [ [ {
      "kind" => "converse",
      "correlation_id" => "stage2:a:t03:query"
    }, {
      "kind" => "generate_text",
      "correlation_id" => "stage2:a:t03:query"
    }, {
      "kind" => "generation_result",
      "correlation_id" => "stage2:a:t03:query",
      "error_class" => "Timeout::Error"
    } ] ]
    mixed_row = [ {
      "correlation_id" => "stage2:a:t03:query",
      "source" => "query",
      "route" => "rag_global",
      "cost_usd" => 0.01
    } ]
    both_failed = [ [ {
      "kind" => "converse",
      "correlation_id" => "stage2:a:t04:query"
    }, {
      "kind" => "generate_text",
      "correlation_id" => "stage2:a:t04:query"
    }, {
      "kind" => "generation_result",
      "correlation_id" => "stage2:a:t04:query",
      "error_class" => "Seahorse::Client::NetworkingError"
    } ] ]

    assert_equal 1, stage2_unbilled_attempts(converse_failure, [])
    assert_equal 0, stage2_unbilled_attempts(prepare_failure, [])
    assert_equal 0, stage2_unbilled_attempts(retrieve_failure, [])
    assert_equal 0, stage2_unbilled_attempts(paid_local, paid_row)
    assert_equal 1, stage2_unbilled_attempts(mixed, mixed_row)
    assert_equal 2, stage2_unbilled_attempts(both_failed, [])

    spent = spend_snapshot([], converse_failure)
    assert_equal 0, spent.new_calls
    assert_equal 1, spent.unbilled_attempts
    assert_equal BigDecimal("0.343774"), spent.cost_usd

    hidden = spend_snapshot(mixed_row, mixed)
    assert_equal 1, hidden.new_calls
    assert_equal 1, hidden.unbilled_attempts
    assert_equal 2, hidden.new_attempts
    assert_equal BigDecimal("0.353774"), hidden.cost_usd
  end

  test "turn 1 stops when interpretation fails and keeps a transport failure pending" do
    failed = {
      "success" => true,
      "capture" => [ { "kind" => "interpreter_failure", "stage" => "converse", "error_class" => "Timeout::Error" } ]
    }
    local = {
      "success" => false,
      "capture" => [ { "kind" => "interpreter_failure", "stage" => "perception", "error_class" => "RuntimeError" } ]
    }
    opened = { "success" => true, "capture" => [ { "kind" => "interpreter_raw", "stage" => nil } ] }

    assert stage2_opening_failed?(failed)
    assert_equal "PENDIENTE", stage2_opening_stop(failed)
    assert stage2_opening_failed?(local)
    assert_equal "BLOQUEADA", stage2_opening_stop(local)
    assert_not stage2_opening_failed?(opened)
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
