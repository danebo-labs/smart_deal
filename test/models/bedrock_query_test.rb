# frozen_string_literal: true

require 'test_helper'

class BedrockQueryTest < ActiveSupport::TestCase
  test 'requires model_id and tokens' do
    I18n.with_locale(:en) do
      q = BedrockQuery.new
      assert_not q.valid?
      assert_includes q.errors[:model_id], "can't be blank"
      assert_includes q.errors[:input_tokens], "can't be blank"
      assert_includes q.errors[:output_tokens], "can't be blank"
    end
  end

  test 'cost calculation works for known model' do
    q = BedrockQuery.new(
      model_id: 'claude-sonnet-4-6-direct',
      input_tokens: 1000,
      output_tokens: 2000
    )

    # input: 1000 → 1 * 0.003 = 0.003
    # output: 2000 → 2 * 0.015 = 0.03
    expected_cost = 0.003 + 0.03

    assert_equal expected_cost.round(6), q.cost
  end

  test 'cost calculation falls back to default model' do
    q = BedrockQuery.new(
      model_id: 'unknown-model',
      input_tokens: 1000,
      output_tokens: 1000
    )

    # default pricing: input=0.00025, output=0.00125 (Haiku pricing)
    expected_cost = (1 * 0.00025) + (1 * 0.00125)

    assert_equal expected_cost.round(6), q.cost
  end

  test 'global haiku 4.5 pricing: $1/$5 per 1M' do
    q = BedrockQuery.new(
      model_id: 'global.anthropic.claude-haiku-4-5-20251001-v1:0',
      input_tokens: 1000, output_tokens: 1000
    )
    # 1 * 0.001 + 1 * 0.005 = 0.006
    assert_equal 0.006, q.cost
  end

  test 'US haiku 4.5 pricing corrected to +10%: $1.1/$5.5 per 1M' do
    q = BedrockQuery.new(
      model_id: 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
      input_tokens: 1000, output_tokens: 1000
    )
    # 1 * 0.0011 + 1 * 0.0055 = 0.0066
    assert_equal 0.0066, q.cost
  end

  test 'haiku direct pricing corrected: $1/$5 per 1M' do
    q = BedrockQuery.new(
      model_id: 'claude-haiku-4-5-20251001-direct',
      input_tokens: 1000, output_tokens: 1000
    )
    # 1 * 0.001 + 1 * 0.005 = 0.006
    assert_equal 0.006, q.cost
  end

  test 'opus 4.7 batch pricing corrected to $2.5/$12.5 per 1M' do
    q = BedrockQuery.new(
      model_id: 'claude-opus-4-7',
      input_tokens: 1000, output_tokens: 1000
    )
    # 1 * 0.0025 + 1 * 0.0125 = 0.015
    assert_equal 0.015, q.cost
  end

  test 'opus 4.7 direct pricing corrected to $5/$25 per 1M' do
    q = BedrockQuery.new(
      model_id: 'claude-opus-4-7-direct',
      input_tokens: 1000, output_tokens: 1000
    )
    # 1 * 0.005 + 1 * 0.025 = 0.03
    assert_equal 0.03, q.cost
  end

  test 'opus 4.7 direct with cache tokens' do
    q = BedrockQuery.new(
      model_id: 'claude-opus-4-7-direct',
      input_tokens: 1000, output_tokens: 1000,
      cache_read_tokens: 500, cache_creation_tokens: 200
    )
    # input: 1*0.005=0.005, output: 1*0.025=0.025
    # cache_read: 0.5*0.0005=0.00025, cache_creation: 0.2*0.00625=0.00125
    expected = (0.005 + 0.025 + 0.00025 + 0.00125).round(6)
    assert_equal expected, q.cost
  end

  test 'opus 4.8 batch pricing: $2.5/$12.5 per 1M' do
    q = BedrockQuery.new(
      model_id: 'claude-opus-4-8-batch',
      input_tokens: 1000, output_tokens: 1000
    )
    assert_equal 0.015, q.cost
  end

  test 'opus 4.8 explicit batch suffix pricing' do
    q = BedrockQuery.new(
      model_id: 'claude-opus-4-8-batch',
      input_tokens: 1000, output_tokens: 1000
    )
    assert_equal 0.015, q.cost
  end

  test 'opus 4.8 direct pricing: $5/$25 per 1M' do
    q = BedrockQuery.new(
      model_id: 'claude-opus-4-8-direct',
      input_tokens: 1000, output_tokens: 1000
    )
    assert_equal 0.03, q.cost
  end

  test 'opus 4.8 direct with cache tokens' do
    q = BedrockQuery.new(
      model_id: 'claude-opus-4-8-direct',
      input_tokens: 1000, output_tokens: 1000,
      cache_read_tokens: 500, cache_creation_tokens: 200
    )
    expected = (0.005 + 0.025 + 0.5 * 0.0005 + 0.2 * 0.00625).round(6)
    assert_equal expected, q.cost
  end

  test 'sonnet 5 direct pricing: $2/$10 per 1M' do
    q = BedrockQuery.new(
      model_id: 'claude-sonnet-5-direct',
      input_tokens: 1000, output_tokens: 1000,
      cache_read_tokens: 500, cache_creation_tokens: 200
    )
    expected = (0.002 + 0.01 + 0.5 * 0.0002 + 0.2 * 0.0025).round(6)
    assert_equal expected, q.cost
  end

  test 'opus 5.5 direct pricing: $4/$20 per 1M' do
    q = BedrockQuery.new(
      model_id: 'claude-opus-5-5-direct',
      input_tokens: 1000, output_tokens: 1000,
      cache_read_tokens: 500, cache_creation_tokens: 200
    )
    expected = (0.004 + 0.02 + 0.5 * 0.0002 + 0.2 * 0.005).round(6)
    assert_equal expected, q.cost
  end

  test "semantic_analysis is an accepted source" do
    query = BedrockQuery.new(
      model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      input_tokens: 10,
      output_tokens: 2,
      source: "semantic_analysis"
    )

    assert query.valid?
    assert_equal "semantic_analysis", query.source
  end

  test "audited semantic aggregate prices to 0.031491" do
    query = BedrockQuery.new(
      model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      input_tokens: 22_896,
      output_tokens: 1_719
    )

    assert_equal 0.031491, query.cost
  end

  test "audited sonnet 4.6 vision cache-creation vector prices to 0.014085" do
    query = BedrockQuery.new(
      model_id: "claude-sonnet-4-6-direct",
      input_tokens: 1430,
      output_tokens: 360,
      cache_creation_tokens: 1172
    )

    assert_equal 0.014085, query.cost
  end

  test 'anthropic batch pricing for upgraded models' do
    sonnet = BedrockQuery.new(model_id: 'claude-sonnet-5-batch', input_tokens: 1000, output_tokens: 1000)
    sonnet55 = BedrockQuery.new(
      model_id: 'claude-sonnet-5-5-batch',
      input_tokens: 1000,
      output_tokens: 1000,
      cache_read_tokens: 1000,
      cache_creation_tokens: 1000
    )
    opus = BedrockQuery.new(model_id: 'claude-opus-5-5-batch', input_tokens: 1000, output_tokens: 1000)

    assert_equal 0.006, sonnet.cost
    assert_equal 0.00735, sonnet55.cost
    assert_same BedrockQuery::BEDROCK_PRICING.fetch('claude-sonnet-5-5-batch'), sonnet55.pricing_for
    assert_not_equal BedrockQuery::BEDROCK_PRICING.fetch('default'), sonnet55.pricing_for
    assert_not_same sonnet.pricing_for, sonnet55.pricing_for
    assert_equal 0.012, opus.cost
  end

  test "grok 4.7 global standard does not fall through to the default rate" do
    query = BedrockQuery.new(
      model_id: "global.xai.grok-4.7",
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      cache_read_tokens: 1_000_000
    )
    fallback = BedrockQuery.new(model_id: "global.xai.grok-4.7", input_tokens: 1000, output_tokens: 1000)
    default_rate = BedrockQuery.new(model_id: "unknown-model", input_tokens: 1000, output_tokens: 1000)

    assert_equal 8.5, query.cost
    assert_equal 0.008, fallback.cost
    assert_not_equal default_rate.cost, fallback.cost
    assert_includes BedrockQuery::AWS_BEDROCK_MODEL_PREFIXES, "global.xai"
  end
end
