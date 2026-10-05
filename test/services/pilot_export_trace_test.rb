# frozen_string_literal: true

require "test_helper"

class PilotExportTraceTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir("pilot-export-trace")
    @source = File.join(@tmpdir, "source_events.jsonl")
  end

  teardown do
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  test "fills a blank interaction from the retrieval trace" do
    monarch = "s3://bucket/bulk_uploads/1/Monarch nice 3000 fallas-1.pdf"
    elemont = "s3://bucket/bulk_uploads/1/Montacargas 2N Temporizado-1.pdf"
    File.write(@source, <<~LOG)
      [TURN_EVIDENCE] {"correlation_id":"query:smoke","original_query":"Que reviso si no nivela ?","answer":"El manual consultado es Monarch.","sources":[{"title":"Monarch nice 3000 fallas-1","page":18},{"title":"Monarch nice 3000 fallas-1","page":19},{"title":"Monarch nice 3000 fallas-1","page":1}]}
      R1A_PROBE {"correlation_id":"query:smoke","stage":"bedrock_request_filter","filter":{"orAll":[{"in":{"value":["#{monarch}","#{elemont}"]}}]}}
      R1A_PROBE {"correlation_id":"query:smoke","stage":"publication_gate","decision":"KEEP","original_source_uri":"#{monarch}"}
      not json [TURN_EVIDENCE] {broken
    LOG
    report = report_with("query:smoke")

    PilotExportTrace.apply!(report, @source)

    interaction = report.dig("interactions", "by_correlation").sole
    assert_equal "Que reviso si no nivela ?", interaction["question"]
    assert_equal "El manual consultado es Monarch.", interaction.dig("audit", "answer")
    assert_equal 3, interaction["citations_count"]
    assert_equal 3, interaction["retrieved_chunks"]
    assert_equal [ 18, 19, 1 ], interaction.dig("audit", "citations").pluck("page")
    assert_equal [ monarch, elemont ], interaction["retrieval_scope"]
    assert_includes interaction["consulted_sources"], "Monarch nice 3000 fallas-1 · p. 18"
    assert_includes interaction["consulted_sources"], monarch
  end

  test "keeps an audit question already present in the report" do
    File.write(@source, <<~LOG)
      [TURN_EVIDENCE] {"correlation_id":"query:kept","original_query":"otra pregunta","answer":"otra respuesta","sources":[{"title":"Otro","page":2}]}
    LOG
    report = report_with("query:kept")
    report.dig("interactions", "by_correlation").sole["audit"] = {
      "question" => "pregunta original",
      "citations" => [ { "title" => "Ya citada", "page" => 4 } ]
    }

    PilotExportTrace.apply!(report, @source)

    interaction = report.dig("interactions", "by_correlation").sole
    assert_equal "pregunta original", interaction.dig("audit", "question")
    assert_equal [ { "title" => "Ya citada", "page" => 4 } ], interaction.dig("audit", "citations")
    assert_equal 1, interaction["citations_count"]
  end

  test "the cohort question is the raw turn and is not backfilled when capture is off" do
    File.write(@source, <<~LOG)
      [TURN_EVIDENCE] {"correlation_id":"query:raw","original_query_sha256":"abc","effective_query":"contexto compuesto"}
      [RAG_QUALITY] {"correlation_id":"query:raw","question":"contexto compuesto"}
      [TURN_EVIDENCE] {"correlation_id":"query:captured","original_query":"No veo ningún código de falla","effective_query":"contexto compuesto"}
      [RAG_QUALITY] {"correlation_id":"query:captured","question":"contexto compuesto"}
    LOG
    report = {
      "interactions" => {
        "by_correlation" => [
          { "correlation_id" => "query:raw", "question" => "contexto compuesto", "citations_count" => 0, "retrieved_chunks" => 0 },
          { "correlation_id" => "query:captured", "question" => "contexto compuesto", "citations_count" => 0, "retrieved_chunks" => 0 }
        ]
      }
    }

    PilotExportTrace.apply!(report, @source)

    raw = report.dig("interactions", "by_correlation").find { |row| row["correlation_id"] == "query:raw" }
    captured = report.dig("interactions", "by_correlation").find { |row| row["correlation_id"] == "query:captured" }
    assert_nil raw["question"]
    assert_equal "No veo ningún código de falla", captured["question"]
  end

  test "leaves the report unchanged when the trace file is missing" do
    report = report_with("query:none")

    assert_equal report, PilotExportTrace.apply!(report, File.join(@tmpdir, "missing.jsonl"))
    assert_nil report.dig("interactions", "by_correlation").sole["question"]
  end

  private

  def report_with(correlation_id)
    {
      "interactions" => {
        "by_correlation" => [
          {
            "correlation_id" => correlation_id,
            "citations_count" => 0,
            "retrieved_chunks" => 0
          }
        ]
      }
    }
  end
end
