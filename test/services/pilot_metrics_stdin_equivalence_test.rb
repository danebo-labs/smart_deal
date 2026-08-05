# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"

class PilotMetricsStdinEquivalenceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    BedrockQuery.delete_all
    BedrockDailyCost.delete_all
    ConversationSession.delete_all
  end

  test "stdin telemetry produces byte-identical JSON to the same file path" do
    now = Time.zone.local(2026, 7, 22, 12)
    content = <<~LOG
      [PILOT_USAGE] {"event":"interaction_completed","ts":"#{now.iso8601}","role":"web","user_id":1,"correlation_id":"query:1","outcome":"answered","route":"text"}
      [RAG_QUALITY] {"ts":"#{now.iso8601}","role":"web","user_id":1,"correlation_id":"query:1","evidence_present":true,"citations_count":1,"chunk_count":1}
    LOG
    file = Tempfile.new("pilot-stdin-equivalence")
    file.write(content)
    file.flush

    travel_to now do
      from_file = PilotMetricsReport.new(
        date: now.to_date,
        usage_log_path: file.path,
        roles: [ "web" ]
      ).as_json
      from_stdin = PilotMetricsReport.new(
        date: now.to_date,
        usage_log_path: StringIO.new(content),
        roles: [ "web" ]
      ).as_json

      assert_equal JSON.generate(from_file), JSON.generate(from_stdin)
    end
  ensure
    file&.close!
  end
end
