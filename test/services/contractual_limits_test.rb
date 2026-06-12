# frozen_string_literal: true

require "test_helper"

class ContractualLimitsTest < ActiveSupport::TestCase
  # ── Finiteness: every numeric limit must be a positive finite bound ────────

  test "all numeric limits are finite and positive" do
    ContractualLimits.to_h.except(:on_quota_exceeded).each do |section, limits|
      limits.each do |key, value|
        case value
        when Numeric
          assert value.finite?,      "#{section}.#{key} must be finite"
          assert_operator value, :>, 0, "#{section}.#{key} must be positive"
        when Array
          assert value.any?, "#{section}.#{key} must not be empty"
        end
      end
    end
  end

  test "quota-exceeded contract rule is declared" do
    assert_equal "reject_surcharge_or_quote_before_cost", ContractualLimits::ON_QUOTA_EXCEEDED
  end

  # ── Alignment with the code constants that enforce each bound ──────────────

  test "manual and photo ladders match the O3' runtime ladder (8k → 16k → 32k)" do
    runtime_ladder = SingleFileChunkingService::PAGE_TOKEN_LADDER

    assert_equal [ 8_000, 16_000, 32_000 ], runtime_ladder
    assert_equal runtime_ladder, ContractualLimits::MANUAL[:output_token_ladder]
    assert_equal runtime_ladder, ContractualLimits::PHOTO[:output_token_ladder]
    assert_equal runtime_ladder.size, ContractualLimits::MANUAL[:max_attempts_per_page]
    assert_equal runtime_ladder.size, ContractualLimits::PHOTO[:max_attempts]
  end

  test "O3' initial cap is universal: sync ladder and Batch builders share 8k" do
    assert_equal 8_000, BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS
    assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS, SingleFileChunkingService::PAGE_TOKEN_LADDER.first
    # Batch retry rungs cover the remainder of the ladder
    assert_equal SingleFileChunkingService::PAGE_TOKEN_LADDER[1..], IngestBatchResultsJob::RETRY_TOKEN_LADDER
  end

  test "query limits match retrieval profile, session context budget and RAG defaults" do
    assert_equal RagRetrievalProfile::EXHAUSTIVE_CANDIDATES, ContractualLimits::QUERY[:max_top_k]
    assert_equal SessionContextBuilder::MAX_CONTEXT_CHARS,   ContractualLimits::QUERY[:max_context_chars]
    assert_equal BedrockRagService::DEFAULT_RAG_CONFIG[:generation_max_tokens],
                 ContractualLimits::QUERY[:max_output_tokens]
    # Filtered attempt + at most one global no-results fallback
    assert_equal 2, ContractualLimits::QUERY[:max_model_calls]
  end

  test "photo limits only allow the two routed models" do
    assert_equal [ BatchChunkingPrompt::MODEL_TEXT, BatchChunkingPrompt::MODEL_MULTIMODAL ],
                 ContractualLimits::PHOTO[:allowed_models]
  end

  test "manual filter limits match PageRelevanceFilter window size and bounded retry" do
    assert_equal PageRelevanceFilter::BATCH_WINDOW_SIZE, ContractualLimits::MANUAL[:filter_window_size]
    # One initial call + one retry on JSON parse failure
    assert_equal 2, ContractualLimits::MANUAL[:max_filter_attempts_per_window]
  end

  test "provider context windows bound successful query and ingestion calls" do
    assert_equal 200_000, ContractualLimits::HAIKU_CONTEXT_TOKENS
    assert_equal 1_000_000, ContractualLimits::INGESTION_CONTEXT_TOKENS
    assert_equal 197_000, ContractualLimits::QUERY[:max_input_tokens]
    assert_equal ContractualLimits::INGESTION_CONTEXT_TOKENS,
                 ContractualLimits::PHOTO[:context_window_tokens]
    assert_equal ContractualLimits::INGESTION_CONTEXT_TOKENS,
                 ContractualLimits::MANUAL[:context_window_tokens]
  end

  test "manual technical maximum assumes every page can route to Opus until policy is enforced" do
    fraction = ContractualLimits::MANUAL[:max_opus_page_fraction]
    assert_equal 1.0, fraction
  end
end
