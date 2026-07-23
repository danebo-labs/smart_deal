# frozen_string_literal: true

require "test_helper"
require "ostruct"

class PageRelevanceFilterTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Fakes
  # ---------------------------------------------------------------------------

  class FakeHaikuContent
    attr_reader :type, :text

    def initialize(keep:, reason:)
      @type = "text"
      @text = JSON.generate({ "keep" => keep, "reason" => reason })
    end
  end

  class FakeHaikuResponse
    attr_reader :content, :usage

    def initialize(keep:, reason: "useful content")
      @content = [ FakeHaikuContent.new(keep: keep, reason: reason) ]
      @usage   = OpenStruct.new(input_tokens: 5, output_tokens: 5)
    end
  end

  class FakeHaikuMessages
    def initialize(keep:, reason: "useful content")
      @response = FakeHaikuResponse.new(keep: keep, reason: reason)
    end

    def create(**) = @response
  end

  class FakeHaikuClient
    def initialize(keep:, reason: "useful content")
      @messages = FakeHaikuMessages.new(keep: keep, reason: reason)
    end

    attr_reader :messages
  end

  # Batch fake: returns {"pages":[...]} JSON
  class FakeBatchHaikuContent
    attr_reader :type, :text

    def initialize(pages_array)
      @type = "text"
      @text = JSON.generate({ "pages" => pages_array })
    end
  end

  class FakeBatchHaikuResponse
    attr_reader :content, :usage

    def initialize(pages_array)
      @content = [ FakeBatchHaikuContent.new(pages_array) ]
      @usage   = OpenStruct.new(input_tokens: 20, output_tokens: 40)
    end
  end

  class FakeBatchHaikuMessages
    def initialize(pages_array)
      @response = FakeBatchHaikuResponse.new(pages_array)
    end

    def create(**) = @response
  end

  class FakeBatchHaikuClient
    def initialize(pages_array)
      @messages = FakeBatchHaikuMessages.new(pages_array)
    end

    attr_reader :messages
  end

  class CapturingBatchHaikuResponse
    attr_reader :content, :usage

    def initialize(text)
      @content = [ OpenStruct.new(type: "text", text: text) ]
      @usage   = OpenStruct.new(input_tokens: 20, output_tokens: 40)
    end
  end

  class CapturingBatchHaikuMessages
    attr_reader :calls

    def initialize(&responder)
      @calls     = []
      @responder = responder
    end

    def create(**kwargs)
      @calls << kwargs
      response = @responder.call(kwargs, @calls.size)
      raise response if response.is_a?(Exception)

      text = response.is_a?(String) ? response : JSON.generate({ "pages" => response })
      CapturingBatchHaikuResponse.new(text)
    end
  end

  class CapturingBatchHaikuClient
    attr_reader :messages

    def initialize(&responder)
      @messages = CapturingBatchHaikuMessages.new(&responder)
    end
  end

  FakePage = Struct.new(:number, :binary) unless defined?(FakePage)

  # ---------------------------------------------------------------------------
  # Stubs for PDF analysis
  # ---------------------------------------------------------------------------

  setup do
    @orig_analyzer = PageImageDensityAnalyzer.method(:analyze)
    @orig_reader_new = nil

    # Default: no images, lots of text
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: false, text_layer_chars: 0, image_area_ratio: 0.0 }
    end

    @orig_reader_class_new = PDF::Reader.method(:new)
    # Stub PDF::Reader to return controllable text
    @page_text = "This page has some text about elevator safety systems and specifications."
    self_ref = self
    PDF::Reader.define_singleton_method(:new) do |*|
      OpenStruct.new(
        pages: [ OpenStruct.new(text: self_ref.instance_variable_get(:@page_text)) ]
      )
    end
  end

  teardown do
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
    PDF::Reader.define_singleton_method(:new, @orig_reader_class_new)
  end

  def make_filter(page_number: 1, total_pages: 5, filename: "manual.pdf",
                  repeated_texts: Set.new, haiku_client: nil)
    PageRelevanceFilter.new(
      "fake_binary",
      page_number:    page_number,
      total_pages:    total_pages,
      filename:       filename,
      repeated_texts: repeated_texts,
      haiku_client:   haiku_client || FakeHaikuClient.new(keep: true)
    )
  end

  def stub_density_by_binary(map, calls: nil)
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |binary|
      calls << binary if calls
      map.fetch(binary) { { has_images: false, text_layer_chars: 500, image_area_ratio: 0.0 } }
    end
  end

  def batch_page_numbers(params)
    Array(params[:messages].first[:content]).filter_map do |block|
      next unless block.is_a?(Hash) && block[:type] == "text"

      block[:text].to_s[/\APage (\d+):\z/, 1]&.to_i
    end
  end

  def batch_response_for_params(params, keep: true, reason: "content")
    batch_page_numbers(params).map { |page| { "page" => page, "keep" => keep, "reason" => reason } }
  end

  def with_page_relevance_constant(name, value)
    original = PageRelevanceFilter.const_get(name)
    PageRelevanceFilter.send(:remove_const, name)
    PageRelevanceFilter.const_set(name, value)
    yield
  ensure
    PageRelevanceFilter.send(:remove_const, name)
    PageRelevanceFilter.const_set(name, original)
  end

  test "batch window sizing uses byte_size without loading page binaries" do
    disk_page = Struct.new(:number, :byte_size) do
      def binary
        raise "window sizing must not read binary"
      end
    end
    pages = [ disk_page.new(1, 5), disk_page.new(2, 7) ]

    windows = PageRelevanceFilter.send(:build_batch_windows, pages)

    assert_equal [ pages ], windows
  end

  # ---------------------------------------------------------------------------
  # Heuristic: blank
  # ---------------------------------------------------------------------------

  test "drops blank page (short text, no images)" do
    @page_text = "   "
    PageImageDensityAnalyzer.define_singleton_method(:analyze) { |_| { has_images: false, text_layer_chars: 0, image_area_ratio: 0.0 } }

    result = make_filter.call
    assert_equal false,       result[:keep]
    assert_equal :blank,      result[:reason]
    assert_equal :heuristic,  result[:source]
  end

  test "does NOT drop short page that has images" do
    @page_text = " "
    PageImageDensityAnalyzer.define_singleton_method(:analyze) { |_| { has_images: true, text_layer_chars: 0, image_area_ratio: 0.6 } }

    result = make_filter.call
    # Falls through to scanned_image check or Haiku — either way not :blank
    assert_not_equal :blank, result[:reason]
  end

  # ---------------------------------------------------------------------------
  # Heuristic: title_page
  # ---------------------------------------------------------------------------

  test "drops page 1 that looks like a manual cover" do
    @page_text = "User Manual for Elevator Model X2"
    result = make_filter(page_number: 1).call
    assert_equal false,       result[:keep]
    assert_equal :title_page, result[:reason]
  end

  test "does NOT drop page 2+ with title-like text" do
    @page_text = "User Manual for Elevator Model X2"  # same text but on page 2
    result = make_filter(page_number: 2).call
    # Not dropped by title_page heuristic
    assert_not_equal :title_page, result[:reason]
  end

  # ---------------------------------------------------------------------------
  # Heuristic: table_of_contents
  # ---------------------------------------------------------------------------

  test "drops page with >= 30% lines ending in digits (ToC pattern)" do
    @page_text = (1..15).map { |i| "Chapter #{i} content                    #{i * 2}" }.join("\n")
    result = make_filter(page_number: 2).call
    assert_equal false,              result[:keep]
    assert_equal :table_of_contents, result[:reason]
  end

  # ---------------------------------------------------------------------------
  # Heuristic: boilerplate
  # ---------------------------------------------------------------------------

  test "drops page with boilerplate keywords and short text" do
    @page_text = "Copyright © 2024 Orona S.A. All rights reserved."
    result = make_filter.call
    assert_equal false,       result[:keep]
    assert_equal :boilerplate, result[:reason]
  end

  # ---------------------------------------------------------------------------
  # Heuristic: repeated_artifact
  # ---------------------------------------------------------------------------

  test "drops page whose full text matches a repeated running header" do
    repeated = "Orona Elevator Systems\nPage"
    @page_text = repeated
    result = make_filter(repeated_texts: Set.new([ repeated ])).call
    assert_equal false,             result[:keep]
    assert_equal :repeated_artifact, result[:reason]
  end

  test "guard: does NOT apply repeated_artifact when text.length <= 20" do
    @page_text = "Short"  # <= 20 chars
    result = make_filter(repeated_texts: Set.new([ "Short" ])).call
    # Should NOT be dropped by repeated_artifact (guard prevents false positives)
    assert_not_equal :repeated_artifact, result[:reason]
  end

  # ---------------------------------------------------------------------------
  # Heuristic: scanned_image
  # ---------------------------------------------------------------------------

  test "keeps scanned image page (thin text layer, high image area) with force_opus" do
    @page_text = ""  # very thin text layer
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: true, text_layer_chars: 50, image_area_ratio: 0.85 }
    end

    result = make_filter.call
    assert_equal true,          result[:keep]
    assert_equal :scanned_image, result[:reason]
    assert_equal true,           result[:force_opus]
  end

  # ---------------------------------------------------------------------------
  # Heuristic: cover_slide (only applies when total_pages > 1)
  # ---------------------------------------------------------------------------

  test "drops cover_slide: page 1 of multi-page PDF with rasterized cover" do
    @page_text = ""  # < 50 chars
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: true, text_layer_chars: 5, image_area_ratio: 0.85 }
    end

    result = make_filter(page_number: 1, total_pages: 10).call
    assert_equal false,       result[:keep]
    assert_equal :cover_slide, result[:reason]
    assert_equal :heuristic,  result[:source]
  end

  test "keeps 1-page raster diagram (SOPREL case): cover_slide does NOT apply when total_pages=1" do
    @page_text = ""  # < 50 chars
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: true, text_layer_chars: 5, image_area_ratio: 0.85 }
    end

    # total_pages=1 → cover_slide is skipped → falls through to scanned_image
    result = make_filter(page_number: 1, total_pages: 1, filename: "Esquema SOPREL.pdf").call
    assert_equal true,          result[:keep]
    assert_equal :scanned_image, result[:reason]
    assert_equal :heuristic,    result[:source]
    assert_equal true,          result[:force_opus]
  end

  # ---------------------------------------------------------------------------
  # Heuristic: high_confidence_content
  # ---------------------------------------------------------------------------

  test "keeps page with long text as high_confidence_content" do
    @page_text = "Technical specifications " * 40  # > 800 chars
    result = make_filter.call
    assert_equal true,                    result[:keep]
    assert_equal :high_confidence_content, result[:reason]
  end

  # ---------------------------------------------------------------------------
  # Haiku gating
  # ---------------------------------------------------------------------------

  test "delegates to Haiku for ambiguous page and returns its decision" do
    @page_text = "Some content that is moderate length " * 3  # ~100-800 chars, no clear heuristic

    haiku = FakeHaikuClient.new(keep: false, reason: "boilerplate_index")
    result = make_filter(haiku_client: haiku).call

    assert_equal false,   result[:keep]
    assert_equal :haiku,  result[:source]
  end

  test "Haiku keep=true passes through" do
    @page_text = "Moderate content about the brake system of elevator " * 3

    haiku  = FakeHaikuClient.new(keep: true, reason: "technical_content")
    result = make_filter(haiku_client: haiku).call

    assert_equal true,  result[:keep]
    assert_equal :haiku, result[:source]
  end

  test "defaults to keep=true when Haiku raises an error" do
    @page_text = "Some ambiguous content " * 5

    bad_client = FakeHaikuClient.new(keep: true)
    bad_client.messages.define_singleton_method(:create) { |**| raise RuntimeError, "timeout" }

    result = make_filter(haiku_client: bad_client).call
    assert_equal true,                  result[:keep]
    assert_equal :haiku_error_fallback,  result[:reason]
  end

  test "Haiku with invalid JSON response defaults to keep=true" do
    @page_text = "Ambiguous content " * 5

    bad_response = OpenStruct.new(
      content: [ OpenStruct.new(type: "text", text: "not json {{") ],
      usage:   OpenStruct.new(input_tokens: 5, output_tokens: 5)
    )
    bad_client = FakeHaikuClient.new(keep: true)
    bad_client.messages.define_singleton_method(:create) { |**| bad_response }

    result = make_filter(haiku_client: bad_client).call
    assert_equal true, result[:keep]
  end

  # ---------------------------------------------------------------------------
  # call_batch
  # ---------------------------------------------------------------------------

  setup do
    @orig_tbq_later = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }
  end

  teardown do
    TrackBedrockQueryJob.define_singleton_method(:perform_later, @orig_tbq_later)
  end

  test "call_batch returns empty hash for empty pages" do
    result = PageRelevanceFilter.call_batch(pages: [], filename: "deck.pptx")
    assert_equal({}, result)
  end

  test "call_batch windows by page count and merges all window results" do
    pages = (1..(PageRelevanceFilter::BATCH_WINDOW_SIZE + 1)).map { |n| FakePage.new(n, "fake_p#{n}_bytes") }
    client = CapturingBatchHaikuClient.new do |params, _idx|
      batch_response_for_params(params, keep: true, reason: "window_keep")
    end

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal 2, client.messages.calls.size
    assert_equal (1..PageRelevanceFilter::BATCH_WINDOW_SIZE).to_a, batch_page_numbers(client.messages.calls[0])
    assert_equal [ PageRelevanceFilter::BATCH_WINDOW_SIZE + 1 ], batch_page_numbers(client.messages.calls[1])
    assert_equal pages.map(&:number).sort, result.keys.sort
    assert result.values.all? { |r| r[:keep] }
  end

  test "call_batch windows by bytes and sends oversized page alone" do
    with_page_relevance_constant(:MAX_WINDOW_BYTES, 10) do
      pages = [
        FakePage.new(1, "a" * 6),
        FakePage.new(2, "b" * 6),
        FakePage.new(3, "c" * 20),
        FakePage.new(4, "d" * 4)
      ]
      client = CapturingBatchHaikuClient.new do |params, _idx|
        batch_response_for_params(params, keep: true, reason: "window_keep")
      end

      PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

      assert_equal [ [ 1 ], [ 2 ], [ 3 ], [ 4 ] ], client.messages.calls.map { |params| batch_page_numbers(params) }
    end
  end

  test "call_batch uses one call when pages fit in one window" do
    pages = (1..4).map { |n| FakePage.new(n, "fake_p#{n}_bytes") }
    client = CapturingBatchHaikuClient.new do |params, _idx|
      batch_response_for_params(params, keep: true, reason: "content")
    end

    PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal 1, client.messages.calls.size
    assert_equal [ 1, 2, 3, 4 ], batch_page_numbers(client.messages.calls.first)
  end

  test "call_batch scales max_tokens with window size" do
    pages = (1..10).map { |n| FakePage.new(n, "fake_p#{n}_bytes") }
    client = CapturingBatchHaikuClient.new do |params, _idx|
      batch_response_for_params(params, keep: true, reason: "content")
    end

    PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal 64 + 10 * PageRelevanceFilter::PER_PAGE_OUTPUT_TOKENS,
                 client.messages.calls.first[:max_tokens]
  end

  test "call_batch retries JSON parse failure once then falls back only for that window" do
    pages = (1..(PageRelevanceFilter::BATCH_WINDOW_SIZE + 1)).map { |n| FakePage.new(n, "fake_p#{n}_bytes") }
    client = CapturingBatchHaikuClient.new do |params, idx|
      case idx
      when 1 then "not json {{"
      when 2 then "still not json {{"
      else
        batch_response_for_params(params, keep: false, reason: "cover")
      end
    end

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    expected_initial_tokens = 64 + PageRelevanceFilter::BATCH_WINDOW_SIZE * PageRelevanceFilter::PER_PAGE_OUTPUT_TOKENS
    assert_equal 3, client.messages.calls.size
    assert_equal expected_initial_tokens, client.messages.calls[0][:max_tokens]
    assert_equal expected_initial_tokens * 2, client.messages.calls[1][:max_tokens]
    assert_equal PageRelevanceFilter::HAIKU_BATCH_MAX_TOKENS, client.messages.calls[2][:max_tokens]

    (1..PageRelevanceFilter::BATCH_WINDOW_SIZE).each do |page_number|
      assert_equal true, result[page_number][:keep]
      assert_equal :haiku_batch_error_fallback, result[page_number][:reason]
    end

    assert_equal false, result[PageRelevanceFilter::BATCH_WINDOW_SIZE + 1][:keep]
    assert_equal :cover, result[PageRelevanceFilter::BATCH_WINDOW_SIZE + 1][:reason]
  end

  test "call_batch keeps API error fallback to one window without retry" do
    pages = (1..(PageRelevanceFilter::BATCH_WINDOW_SIZE + 1)).map { |n| FakePage.new(n, "fake_p#{n}_bytes") }
    client = CapturingBatchHaikuClient.new do |params, idx|
      if idx == 1
        RuntimeError.new("payload too large")
      else
        batch_response_for_params(params, keep: false, reason: "cover")
      end
    end

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal 2, client.messages.calls.size
    (1..PageRelevanceFilter::BATCH_WINDOW_SIZE).each do |page_number|
      assert_equal true, result[page_number][:keep]
      assert_equal :haiku_batch_error_fallback, result[page_number][:reason]
    end

    assert_equal false, result[PageRelevanceFilter::BATCH_WINDOW_SIZE + 1][:keep]
    assert_equal :cover, result[PageRelevanceFilter::BATCH_WINDOW_SIZE + 1][:reason]
  end

  test "call_batch tracks real window ranges against total pages" do
    pages = (1..(PageRelevanceFilter::BATCH_WINDOW_SIZE * 2)).map { |n| FakePage.new(n, "fake_p#{n}_bytes") }
    client = CapturingBatchHaikuClient.new do |params, _idx|
      batch_response_for_params(params, keep: true, reason: "content")
    end
    user_queries = []
    TrackBedrockQueryJob.define_singleton_method(:perform_later) do |**kwargs|
      user_queries << kwargs[:user_query]
    end

    PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal [
      "page_filter_batch: manual.pdf 1..20/40",
      "page_filter_batch: manual.pdf 21..40/40"
    ], user_queries
  end

  test "call_batch drops p1/p2 and keeps p3/p4 without force_opus for normal density" do
    pages = [
      FakePage.new(1, "fake_p1_bytes"),
      FakePage.new(2, "fake_p2_bytes"),
      FakePage.new(3, "fake_p3_bytes"),
      FakePage.new(4, "fake_p4_bytes")
    ]

    batch_response = [
      { "page" => 1, "keep" => false, "reason" => "cover" },
      { "page" => 2, "keep" => false, "reason" => "agenda" },
      { "page" => 3, "keep" => true,  "reason" => "diagram" },
      { "page" => 4, "keep" => true,  "reason" => "schematic" }
    ]
    client = FakeBatchHaikuClient.new(batch_response)
    calls = []
    stub_density_by_binary(
      {
        "fake_p3_bytes" => { has_images: false, text_layer_chars: 600, image_area_ratio: 0.1 },
        "fake_p4_bytes" => { has_images: true,  text_layer_chars: 450, image_area_ratio: 0.4 }
      },
      calls: calls
    )

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "deck.pptx", haiku_client: client)

    assert_equal 4, result.size
    assert_equal [ "fake_p3_bytes", "fake_p4_bytes" ], calls

    assert_equal false,       result[1][:keep]
    assert_equal :cover,      result[1][:reason]
    assert_equal :haiku_batch, result[1][:source]
    assert_equal false,       result[1][:force_opus]

    assert_equal false,       result[2][:keep]
    assert_equal :agenda,     result[2][:reason]

    assert_equal true,        result[3][:keep]
    assert_equal :diagram,    result[3][:reason]
    assert_equal :haiku_batch, result[3][:source]
    assert_equal false,       result[3][:force_opus]

    assert_equal true,        result[4][:keep]
    assert_equal :schematic,  result[4][:reason]
    assert_equal false,       result[4][:force_opus]
  end

  test "call_batch force_opus only for kept scanned dense pages" do
    pages = [
      FakePage.new(1, "dense_page_bytes"),
      FakePage.new(2, "normal_page_bytes")
    ]
    batch_response = [
      { "page" => 1, "keep" => true, "reason" => "diagram" },
      { "page" => 2, "keep" => true, "reason" => "procedure" }
    ]
    client = FakeBatchHaikuClient.new(batch_response)
    stub_density_by_binary({
      "dense_page_bytes"  => { has_images: true,  text_layer_chars: 50,  image_area_ratio: 0.85 },
      "normal_page_bytes" => { has_images: false, text_layer_chars: 900, image_area_ratio: 0.0 }
    })

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal true,  result[1][:keep]
    assert_equal true,  result[1][:force_opus]
    assert_equal true,  result[2][:keep]
    assert_equal false, result[2][:force_opus]
  end

  test "call_batch does not analyze dropped pages even when they are dense" do
    pages = [ FakePage.new(1, "dense_cover_bytes") ]
    batch_response = [ { "page" => 1, "keep" => false, "reason" => "cover" } ]
    client = FakeBatchHaikuClient.new(batch_response)
    calls = []
    stub_density_by_binary(
      { "dense_cover_bytes" => { has_images: true, text_layer_chars: 20, image_area_ratio: 0.95 } },
      calls: calls
    )

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal false, result[1][:keep]
    assert_equal false, result[1][:force_opus]
    assert_empty calls
  end

  test "call_batch applies scanned density to missing_in_response fallback pages" do
    pages = [
      FakePage.new(1, "returned_cover_bytes"),
      FakePage.new(2, "missing_dense_bytes"),
      FakePage.new(3, "missing_normal_bytes")
    ]
    batch_response = [ { "page" => 1, "keep" => false, "reason" => "cover" } ]
    client = FakeBatchHaikuClient.new(batch_response)
    calls = []
    stub_density_by_binary(
      {
        "missing_dense_bytes"  => { has_images: true,  text_layer_chars: 10,  image_area_ratio: 0.9 },
        "missing_normal_bytes" => { has_images: false, text_layer_chars: 700, image_area_ratio: 0.0 }
      },
      calls: calls
    )

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal false, result[1][:keep]
    assert_equal true,  result[2][:keep]
    assert_equal :missing_in_response, result[2][:reason]
    assert_equal true,  result[2][:force_opus]
    assert_equal true,  result[3][:keep]
    assert_equal :missing_in_response, result[3][:reason]
    assert_equal false, result[3][:force_opus]
    assert_equal [ "missing_dense_bytes", "missing_normal_bytes" ], calls
  end

  test "call_batch defaults missing page to keep=true with :missing_in_response" do
    pages = [
      FakePage.new(1, "fake_p1_bytes"),
      FakePage.new(2, "fake_p2_bytes")
    ]

    # Haiku only returns page 1; page 2 is absent
    batch_response = [ { "page" => 1, "keep" => false, "reason" => "cover" } ]
    client = FakeBatchHaikuClient.new(batch_response)

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "deck.pptx", haiku_client: client)

    assert_equal true,                  result[2][:keep]
    assert_equal :missing_in_response,  result[2][:reason]
    assert_equal :haiku_batch,          result[2][:source]
  end

  test "call_batch parses JSON wrapped in markdown fences" do
    pages = [
      FakePage.new(1, "fake_p1_bytes"),
      FakePage.new(2, "fake_p2_bytes")
    ]

    fenced_json = "```json\n{\"pages\":[{\"page\":1,\"keep\":false,\"reason\":\"cover\"},{\"page\":2,\"keep\":true,\"reason\":\"diagram\"}]}\n```"
    fenced_response = OpenStruct.new(
      content: [ OpenStruct.new(type: "text", text: fenced_json) ],
      usage:   OpenStruct.new(input_tokens: 20, output_tokens: 40)
    )
    fenced_client = FakeBatchHaikuClient.new([])
    fenced_client.messages.define_singleton_method(:create) { |**| fenced_response }

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "deck.pptx", haiku_client: fenced_client)

    assert_equal false,       result[1][:keep]
    assert_equal :cover,      result[1][:reason]
    assert_equal true,        result[2][:keep]
    assert_equal :diagram,    result[2][:reason]
  end

  test "call_batch parses JSON wrapped in plain markdown fences (no language tag)" do
    pages = [ FakePage.new(1, "fake_p1_bytes") ]

    fenced_json = "```\n{\"pages\":[{\"page\":1,\"keep\":false,\"reason\":\"agenda\"}]}\n```"
    fenced_response = OpenStruct.new(
      content: [ OpenStruct.new(type: "text", text: fenced_json) ],
      usage:   OpenStruct.new(input_tokens: 10, output_tokens: 20)
    )
    fenced_client = FakeBatchHaikuClient.new([])
    fenced_client.messages.define_singleton_method(:create) { |**| fenced_response }

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "deck.pptx", haiku_client: fenced_client)

    assert_equal false,  result[1][:keep]
    assert_equal :agenda, result[1][:reason]
  end

  test "call_batch falls back to keep all on Haiku crash" do
    pages = [
      FakePage.new(1, "fake_p1_bytes"),
      FakePage.new(2, "fake_p2_bytes")
    ]

    crash_client = FakeBatchHaikuClient.new([])
    crash_client.messages.define_singleton_method(:create) { |**| raise RuntimeError, "connection refused" }

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "deck.pptx", haiku_client: crash_client)

    assert_equal 2, result.size
    result.each_value do |r|
      assert_equal true,                        r[:keep]
      assert_equal :haiku_batch_error_fallback,  r[:reason]
      assert_equal :haiku_batch,                 r[:source]
    end
  end

  # ---------------------------------------------------------------------------
  # filter_pages — unified routing
  # ---------------------------------------------------------------------------

  test "filter_pages returns empty hash for empty pages" do
    result = PageRelevanceFilter.filter_pages(pages: [], filename: "empty.pdf")
    assert_equal({}, result)
  end

  test "filter_pages with 2-page PDF delegates to call_batch" do
    pages = [ FakePage.new(1, "fake_p1"), FakePage.new(2, "fake_p2") ]

    batch_response = [
      { "page" => 1, "keep" => false, "reason" => "cover" },
      { "page" => 2, "keep" => true,  "reason" => "diagram" }
    ]
    client = FakeBatchHaikuClient.new(batch_response)

    call_batch_called = false
    orig_cb = PageRelevanceFilter.method(:call_batch)
    PageRelevanceFilter.define_singleton_method(:call_batch) do |**kwargs|
      call_batch_called = true
      orig_cb.call(**kwargs)
    end

    result = PageRelevanceFilter.filter_pages(pages: pages, filename: "test.pdf", haiku_client: client)

    assert call_batch_called, "filter_pages with 2 pages must delegate to call_batch"
    assert_equal 2, result.size
    assert_equal false, result[1][:keep]
    assert_equal true,  result[2][:keep]
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
  end

  test "filter_pages with 1-page PDF uses per-page filter, not call_batch" do
    pages = [ FakePage.new(1, "fake_p1") ]

    call_batch_called = false
    orig_cb  = PageRelevanceFilter.method(:call_batch)
    PageRelevanceFilter.define_singleton_method(:call_batch) { |**| call_batch_called = true; {} }

    @page_text = "Technical specifications for elevator braking system " * 5
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: false, text_layer_chars: 300, image_area_ratio: 0.0 }
    end

    result = PageRelevanceFilter.filter_pages(pages: pages, filename: "single.pdf")

    assert_not call_batch_called, "filter_pages with 1 page must NOT use call_batch"
    assert_equal 1, result.size
    assert result[1][:keep]
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
  end

  test "call_batch enqueues TrackBedrockQueryJob with page_filter_batch user_query" do
    pages = [ FakePage.new(1, "fake_p1_bytes"), FakePage.new(2, "fake_p2_bytes") ]

    batch_response = [
      { "page" => 1, "keep" => false, "reason" => "cover" },
      { "page" => 2, "keep" => true,  "reason" => "diagram" }
    ]
    client = FakeBatchHaikuClient.new(batch_response)

    enqueued_args = nil
    TrackBedrockQueryJob.define_singleton_method(:perform_later) do |**kwargs|
      enqueued_args = kwargs
    end

    PageRelevanceFilter.call_batch(pages: pages, filename: "slides.pptx", haiku_client: client)

    assert_not_nil enqueued_args, "expected TrackBedrockQueryJob to be enqueued"
    assert_match(/page_filter_batch: slides\.pptx/, enqueued_args[:user_query])
    assert_equal PageRelevanceFilter::HAIKU_TRACKING_MODEL_ID, enqueued_args[:model_id]
    assert_equal "ingestion_parse", enqueued_args[:source]
  end

  # ---------------------------------------------------------------------------
  # Safety/action guard (Gate 9R item 32)
  # ---------------------------------------------------------------------------

  test "safety_action_guard rescues batch drop for authorization and coordination requirement" do
    @page_text = "Only authorized and qualified technicians shall perform this procedure. " \
                 "Coordination with a second worker is required at all times."
    pages  = [ FakePage.new(1, "auth_coord_page") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "boilerplate" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal true,                 result[1][:keep]
    assert_equal :safety_action_guard, result[1][:reason]
    assert_equal :haiku_batch,         result[1][:source]
  end

  test "safety_action_guard recognizes requirement nouns" do
    @page_text = "Authorization and multi-worker coordination requirements apply to this operation."
    pages  = [ FakePage.new(1, "requirement_noun_page") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "divider" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal true,                 result[1][:keep]
    assert_equal :safety_action_guard, result[1][:reason]
    assert_equal :haiku_batch,         result[1][:source]
  end

  test "safety_action_guard rescues batch drop for immediate shutdown and conditional restart" do
    @page_text = "De-energize the equipment immediately. Do not restart until successful " \
                 "troubleshooting and correction of the fault have been confirmed."
    pages  = [ FakePage.new(1, "shutdown_restart_page") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "boilerplate" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal true,                 result[1][:keep]
    assert_equal :safety_action_guard, result[1][:reason]
    assert_equal :haiku_batch,         result[1][:source]
  end

  test "safety_action_guard rescues per-page Haiku drop containing actionable safety content" do
    @page_text = "Lockout the power supply before beginning work. Only authorized personnel " \
                 "shall re-energize the system after the procedure is complete."
    haiku  = FakeHaikuClient.new(keep: false, reason: "boilerplate")

    result = make_filter(haiku_client: haiku).call

    assert_equal true,                 result[:keep]
    assert_equal :safety_action_guard, result[:reason]
    assert_equal :haiku,               result[:source]
  end

  test "safety_action_guard rescues Spanish actionable safety content" do
    @page_text = "Solo el personal autorizado debe realizar este procedimiento. " \
                 "Inmediatamente desenergice el sistema antes de intervenir."
    pages  = [ FakePage.new(1, "spanish_safety_page") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "boilerplate" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal true,                 result[1][:keep]
    assert_equal :safety_action_guard, result[1][:reason]
    assert_equal :haiku_batch,         result[1][:source]
  end

  test "safety_action_guard does not rescue batch cover or copyright page" do
    @page_text = "Copyright © 2024 Elevator Systems Inc. Only authorized personnel shall reproduce this document."
    pages  = [ FakePage.new(1, "copyright_page") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "copyright" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal false,      result[1][:keep]
    assert_equal :copyright, result[1][:reason]
    assert_not PageRelevanceFilter.safety_action_guard?(@page_text)
  end

  test "safety_action_guard does not rescue batch TOC drop with safety chapter titles" do
    @page_text = (1..10).map do |page_number|
      "Only authorized personnel shall perform shutdown procedure #{page_number} ........ #{page_number}"
    end.join("\n")
    pages  = [ FakePage.new(1, "toc_page") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "table_of_contents" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal false, result[1][:keep]
    assert PageRelevanceFilter.toc?(@page_text)
    assert_not PageRelevanceFilter.safety_action_guard?(@page_text)
  end

  test "safety_action_guard does not rescue blank or very short page" do
    @page_text = "   "
    pages  = [ FakePage.new(1, "blank_pg") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "blank" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal false,  result[1][:keep]
    assert_equal :blank, result[1][:reason]
  end

  test "safety_action_guard does not rescue glossary with safety nouns but no directive language" do
    @page_text = "Glossary of Terms: Lockout, De-energization, Authorized Personnel, " \
                 "Isolation, Shutdown, Qualified Technician, Coordination, Re-energization."
    pages  = [ FakePage.new(1, "glossary_page") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "glossary" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal false,    result[1][:keep]
    assert_equal :glossary, result[1][:reason]
  end

  test "safety_action_guard does not rescue page with safety signal but no directive language" do
    @page_text = "Information about authorized technicians, shutdown procedures, and troubleshooting."
    pages  = [ FakePage.new(1, "signal_only_page") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "boilerplate" } ])

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal false, result[1][:keep]
  end

  test "safety_action_guard preserves original Haiku drop reason when guard does not rescue" do
    @page_text = "Agenda: Welcome, Introductions, Overview of the Session Topics."
    haiku  = FakeHaikuClient.new(keep: false, reason: "agenda")

    result = make_filter(haiku_client: haiku).call

    assert_equal false,  result[:keep]
    assert_equal :agenda, result[:reason]
    assert_equal :haiku,  result[:source]
  end

  test "safety_action_guard non-rescued batch drop does not trigger density analysis" do
    @page_text = "Title cover page."
    pages  = [ FakePage.new(1, "dropped_cover_bytes") ]
    client = FakeBatchHaikuClient.new([ { "page" => 1, "keep" => false, "reason" => "cover" } ])

    density_calls = []
    stub_density_by_binary(
      { "dropped_cover_bytes" => { has_images: true, text_layer_chars: 10, image_area_ratio: 0.9 } },
      calls: density_calls
    )

    result = PageRelevanceFilter.call_batch(pages: pages, filename: "manual.pdf", haiku_client: client)

    assert_equal false, result[1][:keep]
    assert_empty density_calls
  end
end
