# frozen_string_literal: true

require "test_helper"

class Rag::ExplicitRetrieveOverlapTest < ActiveSupport::TestCase
  SAME = { equipment: "MonoSpace", component_span: "freno", fault: nil, constraints: [] }.freeze

  test "serial is the default and a fingerprint match does not reuse" do
    assert_not Rag::ExplicitRetrieveOverlap.enabled?
    assert_equal "off", Rag::ExplicitRetrieveOverlap.decision(before: SAME, after: SAME)
  end

  test "an enabled fingerprint match is the only reuse" do
    with_flag("1") do
      assert_equal "reused", Rag::ExplicitRetrieveOverlap.decision(before: SAME, after: SAME)
    end
  end

  test "fingerprint mismatch discards" do
    with_flag("1") do
      changed = SAME.merge(component_span: "polea")
      assert_equal "discarded", Rag::ExplicitRetrieveOverlap.decision(before: SAME, after: changed)
    end
  end

  test "switch correct ambiguity deixis and photo scope discard" do
    with_flag("1") do
      assert_equal "discarded", Rag::ExplicitRetrieveOverlap.decision(before: SAME, after: SAME, relation: "switch")
      assert_equal "discarded", Rag::ExplicitRetrieveOverlap.decision(before: SAME, after: SAME, relation: "correct")
      assert_equal "discarded", Rag::ExplicitRetrieveOverlap.decision(before: SAME, after: SAME, ambiguous: true)
      assert_equal "discarded", Rag::ExplicitRetrieveOverlap.decision(before: SAME, after: SAME, deixis: true)
      assert_equal "discarded", Rag::ExplicitRetrieveOverlap.decision(before: SAME, after: SAME, photo_scope_changed: true)
    end
  end

  test "the gate does not call RetrieveAndGenerate" do
    source = Rails.root.join("app/services/rag/explicit_retrieve_overlap.rb").read
    assert_not_includes source, "retrieve_and_generate"
    assert_not_includes source, ".retrieve"
  end

  test "percentiles stay inside one series" do
    samples = (1..100).to_a
    assert_equal 51.0, Rag::PhaseLatency.percentile(samples, 50)
    assert_equal 95.0, Rag::PhaseLatency.percentile(samples, 95)
    assert_operator Rag::PhaseLatency.percentile(samples, 95) + Rag::PhaseLatency.percentile([ 5 ], 95), :>, Rag::PhaseLatency.percentile(samples, 95)
  end

  test "deferred P5 heuristics remain" do
    source = Rails.root.join("app/services/rag/technical_referent_resolver.rb").read
    assert_includes source, "def common_noun?"
    assert_includes source, "def identity_complement?"
  end

  private

  def with_flag(value)
    previous = ENV[Rag::ExplicitRetrieveOverlap::ENV_KEY]
    ENV[Rag::ExplicitRetrieveOverlap::ENV_KEY] = value
    yield
  ensure
    previous.nil? ? ENV.delete(Rag::ExplicitRetrieveOverlap::ENV_KEY) : ENV[Rag::ExplicitRetrieveOverlap::ENV_KEY] = previous
  end
end
