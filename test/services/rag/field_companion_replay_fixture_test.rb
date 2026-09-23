# frozen_string_literal: true

require "test_helper"
require "json"

class Rag::FieldCompanionReplayFixtureTest < ActiveSupport::TestCase
  PATH = Rails.root.join("test/fixtures/files/field_companion/replay_2026-09-23.json")
  FORBIDDEN = %w[user_id account_id attributed_cost_usd input_tokens output_tokens s3_key].freeze

  setup do
    @payload = JSON.parse(File.read(PATH))
  end

  test "replay fixture is the sanitized 23-sep export" do
    assert_equal %w[R-A R-B], @payload["cases"].pluck("id")
    assert_equal 10, @payload["cases"][0]["turns"].size
    assert_equal 4, @payload["cases"][1]["turns"].size
  end

  test "replay fixture drops identity, cost, and chunk bodies" do
    keys = []
    walk = lambda do |value|
      case value
      when Hash
        keys.concat(value.keys)
        value.each_value { |child| walk.call(child) }
      when Array
        value.each { |child| walk.call(child) }
      end
    end
    walk.call(@payload)

    FORBIDDEN.each { |key| assert_not_includes keys, key }
    flat = JSON.generate(@payload["cases"])
    assert_not_includes flat, "s3://"
    assert_not_includes flat, "FIELD_RECORD"
  end

  test "R-A keeps the logged KONE sentence as continued_elliptical" do
    turn = @payload["cases"][0]["turns"][5]
    assert_equal "Ahora estoy revisando un KONE que no nivela en planta 3", turn["utterance"]
    assert_equal "continued_elliptical", turn["episode_decision"]
  end

  test "R-B correction utterance is the added line" do
    turn = @payload["cases"][1]["turns"][2]
    assert_equal "No, no es Elemont. Es KONE", turn["utterance"]
    assert_equal "corrected", turn["episode_decision"]
  end
end
