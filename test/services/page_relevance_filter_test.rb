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
end
