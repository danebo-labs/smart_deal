# frozen_string_literal: true

require "test_helper"

class Rag::CompanionParameterReviewTest < ActiveSupport::TestCase
  setup do
    @fixture = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/companion_revision/parameter_review.json").read)
    @episode = Rag::ActiveEpisode.open(correlation_id: "first", now: Time.current)
    @episode.assign_goal!(@fixture.fetch("observation"), correlation_id: "first")
    @episode.append_observation!(@fixture.fetch("observation"), correlation_id: "first")
    @parameter = @fixture.fetch("parameter")
    @source = limit_chunk(@parameter, @fixture.fetch("limit"))
  end

  test "a pending reading links a paraphrase to the open job but an explicit other elevator starts new work" do
    first = review(@fixture.fetch("first"), [ @source ])
    assert_equal :reading_pending, first.kind
    @episode.pending_question = Rag::PendingQuestion.coerce(first.pending)
    parsed = Rag::ActiveEpisode.parse(@episode.to_h)

    second = interpret(@fixture.fetch("second"), parsed)
    assert_equal "follow_up", second.move
    assert_includes second.observations, @fixture.fetch("second").split(". ").first + "."
    other = interpret(@fixture.fetch("new_work"), parsed)
    assert_equal "new_work", other.move
    assert_empty other.observations
  end

  test "a different parameter and a reference-only source cannot supply the limit" do
    turn = @fixture.fetch("second")
    @episode.append_observation!(turn.split(". ").first, correlation_id: "second")
    other = limit_chunk(@fixture.fetch("other_parameter"), @fixture.fetch("foreign_limit"))
    foreign = limit_chunk(@parameter, @fixture.fetch("foreign_limit"), @fixture.fetch("other_document")).merge(identity_applicability: "reference_only")
    assert_nil review(turn, [ other, foreign ])

    comparison = review(turn, [ other, foreign, @source ])
    assert_equal :comparison, comparison.kind
    assert_equal @fixture.fetch("reported"), comparison.reading
    assert_equal @fixture.fetch("limit"), comparison.limit.display
    assert_equal @fixture.fetch("condition"), comparison.limit.condition
    assert_equal 3, comparison.limit.source
  end

  test "a proposal can only use the commissioning reference of the bound parameter and document" do
    @episode.append_observation!(@fixture.fetch("second").split(". ").first, correlation_id: "second")
    reference = <<~BODY
      Commissioning
      2.6 Compruebe los valores de referencia en el panel:
      - "#{@parameter}" = [#{@fixture.fetch("proposal")}]
    BODY
    assert_nil review(@fixture.fetch("third"), [ @source, chunk(reference, @fixture.fetch("other_document")) ])
    result = review(@fixture.fetch("third"), [ @source, chunk(reference, @fixture.fetch("document")) ])
    assert_equal :proposed_reference, result.kind
    assert_equal @fixture.fetch("reported"), result.reading
    assert_equal @fixture.fetch("proposal"), result.reference.display
  end

  private

  def interpret(turn, episode)
    tool = { "move" => "new_work", "assertions" => [ { "span" => @parameter.tr("-", " "), "act" => "assert", "slot_hint" => "designator" } ],
      "observations" => [], "pending_resolution" => nil, "clarification_target" => nil }
    Rag::TurnPerception.build(tool, turn: turn, episode: episode, catalog: nil, viewer_account: nil)
  end

  def review(question, chunks)
    Rag::CompanionParameterReview.build(question: question, episode: @episode, chunks: chunks)
  end

  def limit_chunk(parameter, limit, document = @fixture.fetch("document"))
    chunk("3.1 Ajuste del ventilador\n- #{@fixture.fetch('condition')}: reduzca el parámetro \"#{parameter}\", hasta el mínimo de [#{limit}].\n", document)
  end

  def chunk(content, document)
    { content: content, metadata: { "original_source_uri" => document } }
  end
end
