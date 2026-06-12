# frozen_string_literal: true

# Gate 9R — finite technical limits per commercial unit (query / photo / manual).
#
# These constants are the SOLE input for the deterministic `contractual_max`
# scenario in Gate9CostMatrix (script/gate9_cost_matrix.rb): every billable unit
# priced at the most expensive permitted route, no cache, bounded retries.
# p50/p95 telemetry describes observed usage; it NEVER substitutes these limits.
#
# Provider context windows are the final technical input bound when the
# application cannot set a lower input-token cap on a multimodal request.
# Product output/top-k limits are enforced in the runtime paths and tested.
module ContractualLimits
  HAIKU_CONTEXT_TOKENS = 200_000
  INGESTION_CONTEXT_TOKENS = 1_000_000

  # ── Queries (RAG turn via retrieve_and_generate) ──────────────────────────
  QUERY = {
    # Billable Claude invocations per turn: filtered attempt + at most one
    # global no-results fallback (BedrockRagService#query). The Retrieve-API
    # source_uri fallback is vector-only (no model tokens).
    max_model_calls:       2,
    # RagRetrievalProfile::EXHAUSTIVE_CANDIDATES — largest permitted top-k.
    max_top_k:             15,
    # SessionContextBuilder::MAX_CONTEXT_CHARS hard budget.
    max_context_chars:     2_000,
    # BedrockRagService::DEFAULT_RAG_CONFIG[:generation_max_tokens].
    max_output_tokens:     3_000,
    # Bedrock RetrieveAndGenerate has no lower application input-token control.
    # A successful Haiku call is therefore bounded by its 200k context window
    # minus the product-enforced 3k output cap.
    max_input_tokens:      HAIKU_CONTEXT_TOKENS - 3_000,
    # Allowed generation models for queries (Haiku global profile only).
    allowed_models:        [ "haiku" ].freeze,
    # Monthly package quota (L1).
    included_per_month:    1_000
  }.freeze

  # ── Photos (web/chat field photo, sync direct) ────────────────────────────
  PHOTO = {
    # FieldPhotoDensityGate routes; no other models are permitted.
    allowed_models:        [ BatchChunkingPrompt::MODEL_TEXT, BatchChunkingPrompt::MODEL_MULTIMODAL ].freeze,
    # SingleFileChunkingService::PAGE_TOKEN_LADDER — bounded escalation.
    max_attempts:          3,
    output_token_ladder:   [ 8_000, 16_000, 32_000 ].freeze,
    # Sonnet 4.6 / current Opus ingestion models expose a 1M context window.
    # The matrix subtracts each ladder rung from this value; normal photos are
    # far smaller, but dimensions/bytes are not yet an enforced token ceiling.
    context_window_tokens: INGESTION_CONTEXT_TOKENS,
    # Monthly package quota (L1).
    included_per_month:    200
  }.freeze

  # ── Manuals (onboarding L2, Batch route mandatory for long manuals) ───────
  MANUAL = {
    # Onboarding includes ONE digital/textual manual up to this many pages.
    # Predominantly scanned manuals: surcharge / limit / quote (plan §4.1).
    max_pages_included:    200,
    # The historical target is <15%, but runtime does not yet reject or quote
    # before exceeding it. Until E3a enforces that policy, the true technical
    # maximum must assume every kept page can route to Opus.
    max_opus_page_fraction: 1.0,
    # Batch first attempt + bounded direct retries (BatchPageRetryService
    # RETRY_TOKEN_LADDER, on truncation OR invalid JSON): 8k batch → 16k → 32k direct.
    max_attempts_per_page: 3,
    output_token_ladder:   [ 8_000, 16_000, 32_000 ].freeze,
    # No lower token cap exists for a PDF page request. The matrix derives the
    # per-rung input ceiling from the 1M model context window.
    context_window_tokens: INGESTION_CONTEXT_TOKENS,
    # PageRelevanceFilter Haiku windows: ceil(pages / BATCH_WINDOW_SIZE) windows,
    # each retried at most once on JSON parse failure.
    filter_window_size:        20,
    max_filter_attempts_per_window: 2,
    max_filter_context_tokens: HAIKU_CONTEXT_TOKENS,
    max_filter_output_tokens_per_window: 704,
    # Final retained output is capped at 32k/page; this bounds the content sent
    # to Titan for one included 200-page manual before deterministic metadata.
    max_embedding_tokens:  6_400_000
  }.freeze

  # Behavior when a quota above is exceeded (contract rule, enforced with E3a):
  # the unit is rejected, surcharged or quoted BEFORE incurring model cost.
  ON_QUOTA_EXCEEDED = "reject_surcharge_or_quote_before_cost"

  def self.to_h
    { query: QUERY, photo: PHOTO, manual: MANUAL, on_quota_exceeded: ON_QUOTA_EXCEEDED }
  end
end
