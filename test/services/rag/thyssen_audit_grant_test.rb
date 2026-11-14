# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Rag::ThyssenAuditGrantTest < ActiveSupport::TestCase
  test "scope remains bounded across web, worker and worker restart" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "assignment.json")
      fixture = ENV["AUDIT_HAIKU_LEDGER_FIXTURE"]
      previous = File.read(fixture) if fixture
      File.write(path, previous || fixture_ledger.to_json)

      book = spend(path)
      assert_raises(Rag::AssignmentSpend::Stop) { reserve(book, "photo") }
      admitted = book.admit_thyssen_audit!
      assert_equal 1197, admitted.fetch("after_attempt")
      assert_raises(Rag::AssignmentSpend::Stop) { book.admit_thyssen_audit! }

      photo_worker = spend(path)
      id = reserve(photo_worker, "photo")
      photo_worker.unknown!(id)
      assert_raises(Rag::AssignmentSpend::Stop) { reserve(spend(path), "photo") }
      engineering = reserve(spend(path), "engineering")
      book.settle!(engineering, actual_usd: "0.0001")
      assert_equal 1197, book.snapshot.fetch("attempts")
      assert_equal "0.001000", book.snapshot.fetch("unknown_usd") unless previous
    end
  end

  private

  def fixture_ledger
    spend = Rag::AssignmentSpend
    grants = spend::THYSSEN_PRIOR.map do |id, cutoff, usd, calls|
      { "id" => id, "after_attempt" => cutoff, "cost_usd" => usd, "calls" => calls }
    end
    {
      "call_cap" => 1198, "cost_cap_usd" => "4.0", "attempts" => 1195, "seq" => 1197,
      "authorization" => { "call_cap" => 1198, "cost_usd" => "0.75", "after_attempt" => 134 },
      "executions" => grants, "entries" => [], "open" => {}
    }
  end

  def spend(path)
    Rag::AssignmentSpend.new(path: path, call_cap: 1213, cost_cap_usd: 4)
  end

  def reserve(book, scope_id)
    book.reserve!(ceiling_usd: "0.001", required_execution: Rag::AssignmentSpend::THYSSEN_AUDIT_ID,
      scope: { id: scope_id, calls: 1, cost: BigDecimal("0.001") })
  end
end
