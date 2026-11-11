# frozen_string_literal: true

require "test_helper"

class Rag::Haiku55CompanionNetworkTest < ActiveSupport::TestCase
  KEYS = %w[OPUS55_REQUIRE GUION2_DIRECT_REQUIRE].freeze

  setup do
    @saved = KEYS.to_h { |key| [ key, ENV[key] ] }
    ENV["OPUS55_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/run_haiku55_companion.rb") unless defined?(Haiku55Companion)
  end

  teardown do
    @saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def reachability(results, calls)
    ->(host) { calls << host; results.shift }
  end

  test "a dropped link waits without sending and passes once every endpoint answers" do
    io = StringIO.new
    calls = []
    hosts = Haiku55Companion::NETWORK_HOSTS.size
    results = [ false ] + [ true ] * (hosts - 1) + [ true ] * hosts

    assert Haiku55Companion.network_ready?(io, probes: 3, wait: 0, reachable: reachability(results, calls))
    assert_equal hosts * 2, calls.size
    assert_equal "network_wait", JSON.parse(io.string.lines.first)["status"]
  end

  test "a link that never returns stops before the turn" do
    io = StringIO.new

    assert_not Haiku55Companion.network_ready?(io, probes: 2, wait: 0, reachable: reachability([ false ] * 30, []))
    assert_equal 2, io.string.lines.size
  end
end
