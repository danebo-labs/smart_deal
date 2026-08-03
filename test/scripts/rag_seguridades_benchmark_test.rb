# frozen_string_literal: true

require "test_helper"
require "json"
require "tempfile"

ENV["RAG_SEGURIDADES_LIBRARY_ONLY"] = "1"
require Rails.root.join("script/rag_seguridades_benchmark")
ENV.delete("RAG_SEGURIDADES_LIBRARY_ONLY")

class RagSeguridadesBenchmarkTest < ActiveSupport::TestCase
  test "RAG_SEGURIDADES_FIXTURE_PATH parametrizes rubric fixture path" do
    fixture_content = { "version" => "1.0", "cases" => [] }

    Tempfile.open(%w[rubric .json]) do |f|
      f.write(JSON.generate(fixture_content))
      f.flush

      benchmark = RagSeguridadesBenchmark.new(
        env: { "RAG_SEGURIDADES_FIXTURE_PATH" => f.path }
      )

      assert_equal fixture_content, benchmark.instance_variable_get(:@rubric)
    end
  end

  test "RAG_SEGURIDADES_RUBRIC overrides RAG_SEGURIDADES_FIXTURE_PATH" do
    fixture_content_1 = { "version" => "1.0", "cases" => [ "case1" ] }
    fixture_content_2 = { "version" => "2.0", "cases" => [ "case2" ] }

    Tempfile.open(%w[fixture1 .json]) do |f1|
      f1.write(JSON.generate(fixture_content_1))
      f1.flush

      Tempfile.open(%w[fixture2 .json]) do |f2|
        f2.write(JSON.generate(fixture_content_2))
        f2.flush

        benchmark = RagSeguridadesBenchmark.new(
          env: {
            "RAG_SEGURIDADES_FIXTURE_PATH" => f1.path,
            "RAG_SEGURIDADES_RUBRIC" => f2.path
          }
        )

        # RAG_SEGURIDADES_RUBRIC should take precedence
        assert_equal fixture_content_2, benchmark.instance_variable_get(:@rubric)
      end
    end
  end

  test "uses default FIXTURE_PATH when no env variables set" do
    default_path = Rails.root.join("script/fixtures/rag_seguridades_rubric.json")

    if File.exist?(default_path)
      benchmark = RagSeguridadesBenchmark.new(env: {})
      rubric = benchmark.instance_variable_get(:@rubric)

      assert rubric.is_a?(Hash), "Should load default fixture as hash"
    else
      skip "Default fixture file not present in test environment"
    end
  end

  test "RAG_SEGURIDADES_OUTPUT parametrizes output path" do
    fixture_content = { "version" => "1.0", "cases" => [] }

    Tempfile.open(%w[rubric .json]) do |f|
      f.write(JSON.generate(fixture_content))
      f.flush

      output_dir = Dir.mktmpdir
      output_path = File.join(output_dir, "custom_output.json")

      begin
        benchmark = RagSeguridadesBenchmark.new(
          env: {
            "RAG_SEGURIDADES_FIXTURE_PATH" => f.path,
            "RAG_SEGURIDADES_OUTPUT" => output_path
          }
        )

        assert_equal output_path, benchmark.instance_variable_get(:@output_path)
      ensure
        FileUtils.rm_rf(output_dir)
      end
    end
  end
end
