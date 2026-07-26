# frozen_string_literal: true

require "json"
require "fileutils"

rubric_path = Rails.root.join("script/fixtures/rag_seguridades_rubric.json")
input_path = ENV.fetch(
  "RAG_SEGURIDADES_INPUT",
  Rails.root.join("tmp/rag_seguridades_benchmark.json").to_s
)
output_path = ENV.fetch(
  "RAG_SEGURIDADES_EVALUATION_OUTPUT",
  Rails.root.join("tmp/rag_seguridades_evaluation.json").to_s
)

rubric = JSON.parse(File.read(rubric_path))
payload = JSON.parse(File.read(input_path))

case_ids = ENV["RAG_SEGURIDADES_CASE_IDS"].to_s.split(",").map(&:strip).reject(&:empty?)
if case_ids.any?
  cases = rubric.fetch("cases").select { |definition| case_ids.include?(definition["id"]) }
  raise ArgumentError, "No rubric cases match RAG_SEGURIDADES_CASE_IDS=#{case_ids.join(",")}" if cases.empty?

  rubric = rubric.merge("cases" => cases)
end

evaluation = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload).evaluate

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate(evaluation))
puts JSON.pretty_generate(evaluation.fetch("summary").merge("passed" => evaluation.fetch("passed")))
