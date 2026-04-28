# frozen_string_literal: true

require "test_helper"

module Rag
  class WhatsappPostResetStateTest < ActiveSupport::TestCase
    setup do
      @prev_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @to = "whatsapp:+56911112222"
    end

    teardown do
      Rails.cache = @prev_cache
    end

    test "writes/reads phase + source + doc_ids" do
      WhatsappPostResetState.write(
        @to,
        phase:   WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
        source:  :recent,
        doc_ids: [ 1, 2, 3 ]
      )
      state = WhatsappPostResetState.read(@to)

      assert_equal WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
                   WhatsappPostResetState.phase_of(state)
      assert_equal :recent, WhatsappPostResetState.source_of(state)
      assert_equal [ 1, 2, 3 ], WhatsappPostResetState.doc_ids_of(state)
    end

    test "round-trips :origin and exposes it via origin_of" do
      WhatsappPostResetState.write(
        @to,
        phase:  WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
        source: :recent,
        origin: WhatsappPostResetState::ORIGIN_FACETED_CACHED
      )
      state = WhatsappPostResetState.read(@to)
      assert_equal WhatsappPostResetState::ORIGIN_FACETED_CACHED,
                   WhatsappPostResetState.origin_of(state)
    end

    test "origin_of defaults to :reset_picker for legacy payloads without :origin" do
      # Simulate a payload written by the previous deploy (no :origin field).
      Rails.cache.write(
        WhatsappPostResetState.key(@to),
        { "phase" => "picking_from_list", "source" => "recent", "doc_ids" => [ 7 ] },
        expires_in: WhatsappPostResetState::TTL
      )
      state = WhatsappPostResetState.read(@to)
      assert_equal WhatsappPostResetState::ORIGIN_RESET_PICKER,
                   WhatsappPostResetState.origin_of(state)
    end

    test "origin_of returns :reset_picker for blank state" do
      assert_equal WhatsappPostResetState::ORIGIN_RESET_PICKER,
                   WhatsappPostResetState.origin_of(nil)
    end

    test "default origin when not specified is :reset_picker (back-compat)" do
      WhatsappPostResetState.write(@to, phase: WhatsappPostResetState::PHASE_PICKING_SOURCE)
      assert_equal WhatsappPostResetState::ORIGIN_RESET_PICKER,
                   WhatsappPostResetState.origin_of(WhatsappPostResetState.read(@to))
    end

    test "clear removes the entry" do
      WhatsappPostResetState.write(@to, phase: WhatsappPostResetState::PHASE_PICKING_SOURCE)
      WhatsappPostResetState.clear(@to)
      assert_nil WhatsappPostResetState.read(@to)
    end

    test "round-trips :page and exposes it via page_of" do
      WhatsappPostResetState.write(
        @to,
        phase:   WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
        source:  :all,
        doc_ids: [ 1, 2 ],
        page:    3
      )
      assert_equal 3, WhatsappPostResetState.page_of(WhatsappPostResetState.read(@to))
    end

    test "page_of defaults to 1 for legacy payloads without :page" do
      Rails.cache.write(
        WhatsappPostResetState.key(@to),
        { "phase" => "picking_from_list", "source" => "all", "doc_ids" => [ 7 ] },
        expires_in: WhatsappPostResetState::TTL
      )
      assert_equal 1, WhatsappPostResetState.page_of(WhatsappPostResetState.read(@to))
    end

    test "page_of returns 1 for blank state" do
      assert_equal 1, WhatsappPostResetState.page_of(nil)
    end

    test "page_of clamps non-positive values to 1" do
      WhatsappPostResetState.write(
        @to,
        phase: WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
        page:  0
      )
      assert_equal 1, WhatsappPostResetState.page_of(WhatsappPostResetState.read(@to))
    end
  end
end
