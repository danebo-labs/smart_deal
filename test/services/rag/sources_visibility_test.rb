# frozen_string_literal: true

require "test_helper"

class Rag::SourcesVisibilityTest < ActiveSupport::TestCase
  test "enabled? is true only when SHOW_RAG_SOURCES is the literal string true" do
    with_env("SHOW_RAG_SOURCES" => "true") do
      assert Rag::SourcesVisibility.enabled?
    end
  end

  test "enabled? is false when SHOW_RAG_SOURCES is absent" do
    with_env("SHOW_RAG_SOURCES" => nil) do
      assert_not Rag::SourcesVisibility.enabled?
    end
  end

  test "enabled? is false for any non-'true' value" do
    with_env("SHOW_RAG_SOURCES" => "1") do
      assert_not Rag::SourcesVisibility.enabled?
    end
  end

  private

  def with_env(vars)
    original = {}
    vars.each do |key, value|
      original[key] = ENV.fetch(key, nil)
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
