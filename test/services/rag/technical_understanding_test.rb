# frozen_string_literal: true

require "test_helper"

class Rag::TechnicalUnderstandingTest < ActiveSupport::TestCase
  setup do
    @episode_flag = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    @catalog = Rag::DocumentIdentityCatalog.current
  end

  teardown do
    if @episode_flag.nil?
      ENV.delete("FIELD_COMPANION_EPISODE_ENABLED")
    else
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] = @episode_flag
    end
  end

  test "Q2 without focus or identity asks once and does not search outside" do
    decision = understand("¿Qué es Q2?")

    assert_equal "clarify_first", decision.decision
    assert_equal false, decision.outside_discovery
    assert_includes decision.clarification, "Q2"
    assert_includes decision.clarification, "controlador"
    assert_not_includes decision.clarification, "Thyssen"
  end

  test "Q2 inside a manual asks only when that manual does not define it" do
    decision = understand("¿Qué es Q2?", focus_count: 1)

    assert_equal "search_and_clarify", decision.decision
    assert_equal false, decision.outside_discovery
    assert_equal :absence, decision.ask_when
    assert_includes decision.clarification, "Q2"
  end

  test "ROS inside a manual is not an outside search" do
    decision = understand("¿Qué es ROS?", focus_count: 1)

    assert_equal "search_and_clarify", decision.decision
    assert_equal false, decision.outside_discovery
    assert_includes decision.clarification, "ROS"
  end

  test "VF5 stays a direct suggestion and does not ask first" do
    decision = understand("¿Cómo uso el módulo electrónico VF5?", focus_count: 1)

    assert_equal "ready", decision.decision
    assert_equal true, decision.outside_discovery
    assert_nil decision.clarification
    assert_equal false, decision.owns_query
  end

  test "a known manufacturer and controller search Q2 without asking again" do
    episode = opened
    episode.write_fact!("manufacturer", status: "known", value: "MONARCH", source: "user", correlation_id: "c", at: now)
    episode.write_fact!("controller", status: "known", value: "NICE3000", source: "user", correlation_id: "c", at: now)
    decision = understand("¿Qué es Q2?", episode: episode)

    assert_equal "ready", decision.decision
    assert_nil decision.clarification
    assert_includes decision.retrieval_query, "Q2"
    assert_includes decision.retrieval_query, "NICE3000"
    assert_includes decision.retrieval_query, "MONARCH"
  end

  test "no se busca con eso is best effort and does not ask the same question" do
    episode = opened
    episode.write_fact!("controller", status: "unknown_confirmed", source: "user", correlation_id: "c", at: now)
    decision = understand(
      "No sé, busca con eso",
      episode: episode,
      prior_turns: [ { "content" => "¿Qué es Q2?" } ]
    )

    assert_equal "best_effort", decision.decision
    assert_equal true, decision.outside_discovery
    assert_nil decision.pending_subject
    assert_includes decision.clarification, "No puedo confirmar"
    assert_not_includes decision.clarification, "¿Qué ascensor"
    assert_includes decision.retrieval_query, "Q2"
  end

  test "a correction removes the old controller from the query and from catalog manufacturer" do
    episode = opened
    episode.write_fact!("controller", status: "known", value: "NICE3000", source: "catalog", correlation_id: "c", at: now)
    episode.write_fact!("manufacturer", status: "known", value: "MONARCH", source: "catalog", correlation_id: "c", at: now)
    episode.assign_goal!("NICE3000 E51", correlation_id: "c")
    decision = understand("No, no es NICE3000. Es NICE1000.", episode: episode)
    Rag::TechnicalUnderstanding.apply!(episode, decision)

    assert_includes decision.retrieval_query, "NICE1000"
    assert_not_includes decision.retrieval_query.downcase, "nice3000"
    assert_not_includes decision.retrieval_query.downcase, "monarch"
    assert_equal "NICE1000", episode.fact("controller")["value"]
    assert_equal "user", episode.fact("controller")["source"]
    assert_nil episode.fact("manufacturer")
    assert_not_includes episode.goal["text"].downcase, "nice3000"
  end

  test "the technical window keeps the current code, the designator, the problem, and a recent observation" do
    episode = opened
    episode.write_fact!("manufacturer", status: "known", value: "Elemont", source: "user", correlation_id: "c", at: now)
    episode.assign_goal!("las puertas no cierran", correlation_id: "c")
    decision = understand(
      "Marca E03",
      episode: episode,
      prior_turns: [
        { "content" => "las puertas no cierran" },
        { "content" => "Es VF5" },
        { "content" => "vuelve a abrir" }
      ]
    )

    query = decision.retrieval_query
    assert_includes query, "E03"
    assert_includes query, "VF5"
    assert_includes query, "puertas"
    assert_includes query, "abrir"
  end

  test "NICE3000 is an exact controller and writes Monarch from the catalog" do
    resolution = @catalog.resolve_designator("NICE3000")
    assert_equal :exact, resolution.status
    assert_equal "controller", resolution.type
    assert_equal "MONARCH", resolution.manufacturer

    result = Rag::ActiveEpisodeTurn.call(
      state: {},
      text: "Es Monarch NICE3000",
      correlation_id: "query:nice",
      now: Time.current
    )

    assert_equal "NICE3000", result.state.dig("facts", "controller", "value")
    assert_equal "catalog", result.state.dig("facts", "controller", "source")
    assert_equal "MONARCH", result.state.dig("facts", "manufacturer", "value")
    assert_equal "catalog", result.state.dig("facts", "manufacturer", "source")
    assert_nil result.state["document_focus"]
  end

  test "an untyped designator is only a query signal" do
    resolution = @catalog.resolve_designator("VF5")
    assert_equal :exact, resolution.status
    assert_nil resolution.type

    result = Rag::ActiveEpisodeTurn.call(
      state: {},
      text: "¿Cómo uso el módulo electrónico VF5?",
      correlation_id: "query:vf5",
      now: Time.current
    )

    assert_nil result.state.dig("facts", "controller")
    assert_nil result.state.dig("facts", "model")
  end

  test "nice300 stays ambiguous and does not choose a controller" do
    resolution = @catalog.resolve_designator("nice300")
    assert_equal :ambiguous, resolution.status
    assert_nil resolution.manufacturer
    assert_includes resolution.candidates, "NICE3000"
    assert_includes resolution.candidates, "NICE3000new"

    decision = understand("nice300")
    assert_equal "search_and_clarify", decision.decision
    assert_includes decision.clarification, "NICE3000"
    assert_includes decision.clarification, "NICE3000new"
    assert decision.mutations.none? { |item| item[:op] == :write }
  end

  test "a unique prefix may complete and a short token may not" do
    completed = @catalog.resolve_designator("NICE3000n")
    assert_equal :prefix, completed.status
    assert_equal "NICE3000new", completed.value
    assert_equal "controller", completed.type

    %w[ni nic vf].each do |token|
      assert_equal :none, @catalog.resolve_designator(token).status, token
    end
  end

  test "a greeting is not a field identifier and a short code still is" do
    assert_nil understand("hola").bare_identifier
    assert_equal "ros", understand("ROS").bare_identifier
  end

  test "a follow-up does not repeat a manufacturer the goal already names" do
    episode = opened
    episode.write_fact!("manufacturer", status: "known", value: "Elemont", source: "user", correlation_id: "c", at: now)
    episode.assign_goal!(
      "Elemont MH con placa CEA15, falla en puerta 1: el imán no magnetiza. ¿Qué reviso?",
      correlation_id: "c"
    )
    decision = understand("código 8", episode: episode)

    assert_equal(
      "código 8 Elemont MH con placa CEA15, falla en puerta 1: el imán no magnetiza. ¿Qué reviso?",
      decision.retrieval_query
    )
  end

  test "NICE3000 E51 is ready and the query carries the code and the catalog identity" do
    decision = understand("NICE3000 E51, ¿qué reviso?")

    assert_equal "ready", decision.decision
    assert_nil decision.clarification
    assert_includes decision.retrieval_query, "NICE3000"
    assert_includes decision.retrieval_query, "E51"
    assert_includes decision.retrieval_query, "MONARCH"
  end

  private

  def understand(text, episode: nil, focus_count: 0, prior_turns: [])
    Rag::TechnicalUnderstanding.call(
      text: text,
      episode: episode || Rag::ActiveEpisode.new,
      focus_count: focus_count,
      prior_turns: prior_turns
    )
  end

  def opened
    Rag::ActiveEpisode.open(correlation_id: "query:open", now: Time.current)
  end

  def now
    Time.current.iso8601
  end
end
