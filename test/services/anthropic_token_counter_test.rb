# frozen_string_literal: true

require "test_helper"
require "net/http"

class AnthropicTokenCounterTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @orig_key = ENV["ANTHROPIC_API_KEY"]
    Rails.cache.clear
  end

  teardown do
    if @orig_key
      ENV["ANTHROPIC_API_KEY"] = @orig_key
    else
      ENV.delete("ANTHROPIC_API_KEY")
    end
    Rails.cache.clear
  end

  # --- LocalTokenizer ---

  test "LocalTokenizer.estimate returns 0 for blank" do
    assert_equal 0, AnthropicTokenCounter::LocalTokenizer.estimate("")
    assert_equal 0, AnthropicTokenCounter::LocalTokenizer.estimate(nil)
  end

  test "LocalTokenizer.estimate uses chars/3.5" do
    text = "a" * 350
    assert_equal 100, AnthropicTokenCounter::LocalTokenizer.estimate(text)
  end

  # --- Fallback when no API key ---

  test "count falls back to LocalTokenizer when api_key is blank" do
    ENV["ANTHROPIC_API_KEY"] = ""
    text = "a" * 700
    result = AnthropicTokenCounter.count(text: text)
    assert_equal AnthropicTokenCounter::LocalTokenizer.estimate(text), result
  end

  test "count returns 0 for blank text" do
    assert_equal 0, AnthropicTokenCounter.count(text: "")
  end

  # --- HTTP stub helpers ---

  def stub_http_response(code:, body:)
    fake_response = Class.new do
      define_method(:code) { code.to_s }
      define_method(:body) { body.to_json }
    end.new

    Net::HTTP.define_singleton_method(:new) do |*|
      obj = Object.new
      obj.define_singleton_method(:use_ssl=) { |_| }
      obj.define_singleton_method(:read_timeout=) { |_| }
      obj.define_singleton_method(:open_timeout=) { |_| }
      obj.define_singleton_method(:request) { |_| fake_response }
      obj
    end
  end

  def restore_http
    Net::HTTP.singleton_class.remove_method(:new) if Net::HTTP.singleton_class.method_defined?(:new)
  rescue NameError
    # already restored
  end

  # --- API success path ---

  test "count calls Anthropic API and returns token count" do
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
    stub_http_response(code: 200, body: { "input_tokens" => 1234 })

    result = AnthropicTokenCounter.count(text: "hello world")
    assert_equal 1234, result
  ensure
    restore_http
  end

  # --- Cache ---

  test "count returns cached value without hitting API when cache is populated" do
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

    text = "unique text #{SecureRandom.hex(6)}"
    cache_key = "atc/v1/#{Digest::SHA1.hexdigest(text)}"

    # Pre-seed the cache directly. In :null_store this is a no-op, so we verify
    # the short-circuit path using a direct Rails.cache.write via a swapped store
    # that does NOT touch the Rails module singleton (avoids breaking other tests).
    original = Rails.cache
    begin
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Rails.cache.write(cache_key, 999, expires_in: 1.hour)

      # No HTTP call should happen — result served from MemoryStore
      call_count = 0
      Net::HTTP.define_singleton_method(:new) do |*|
        call_count += 1
        raise "API should NOT be called — result should be served from cache"
      end

      result = AnthropicTokenCounter.count(text: text)
      assert_equal 999, result
      assert_equal 0, call_count
    ensure
      Rails.cache = original
      restore_http
    end
  end

  # --- HTTP error codes ---

  test "count falls back on 429 rate limit" do
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
    stub_http_response(code: 429, body: { "error" => "rate_limited" })

    text = "test text for fallback"
    result = AnthropicTokenCounter.count(text: text)
    assert_equal AnthropicTokenCounter::LocalTokenizer.estimate(text), result
  ensure
    restore_http
  end

  test "count falls back on 500 server error" do
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
    stub_http_response(code: 500, body: { "error" => "server_error" })

    text = "another fallback text"
    result = AnthropicTokenCounter.count(text: text)
    assert_equal AnthropicTokenCounter::LocalTokenizer.estimate(text), result
  ensure
    restore_http
  end

  # --- Timeout ---

  test "count falls back on timeout" do
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

    Net::HTTP.define_singleton_method(:new) do |*|
      obj = Object.new
      obj.define_singleton_method(:use_ssl=) { |_| }
      obj.define_singleton_method(:read_timeout=) { |_| }
      obj.define_singleton_method(:open_timeout=) { |_| }
      obj.define_singleton_method(:request) { |_| raise Net::ReadTimeout }
      obj
    end

    text = "timeout test text"
    result = AnthropicTokenCounter.count(text: text)
    assert_equal AnthropicTokenCounter::LocalTokenizer.estimate(text), result
  ensure
    restore_http
  end

  # --- count_query ---

  test "count_query returns hash with input and output tokens" do
    ENV["ANTHROPIC_API_KEY"] = ""
    prompt = "a" * 700
    answer = "b" * 350

    result = AnthropicTokenCounter.count_query(prompt: prompt, answer: answer)

    assert_equal [ :input_tokens, :output_tokens ].sort, result.keys.sort
    assert_equal AnthropicTokenCounter::LocalTokenizer.estimate(prompt), result[:input_tokens]
    assert_equal AnthropicTokenCounter::LocalTokenizer.estimate(answer), result[:output_tokens]
  end
end
