# frozen_string_literal: true

require "test_helper"

ENV["HAIKU_SEMANTIC_P0_LIBRARY_ONLY"] = "1"
require Rails.root.join("script/haiku_semantic_perception_p0.rb")

class Rag::SemanticQueryAnalyzerTest < ActiveSupport::TestCase
  EPISODE = {
    "episode_id" => "ep_p1",
    "facts" => { "model" => { "status" => "known", "value" => "MonoSpace" } },
    "goal" => { "text" => "cómo se ajustan los resortes" }
  }.freeze

  setup do
    @previous = ENV[Rag::HaikuQueryAnalysisFlag::ENV_KEY]
    ENV[Rag::HaikuQueryAnalysisFlag::ENV_KEY] = "shadow"
  end

  teardown do
    if @previous.nil?
      ENV.delete(Rag::HaikuQueryAnalysisFlag::ENV_KEY)
    else
      ENV[Rag::HaikuQueryAnalysisFlag::ENV_KEY] = @previous
    end
  end

  test "the shadow prompt is the frozen P0 prompt" do
    assert_equal HaikuSemanticPerceptionP0::PROMPT, Rag::SemanticQueryAnalyzer::PROMPT
  end

  test "off and an ungated episode do not call the client" do
    ENV[Rag::HaikuQueryAnalysisFlag::ENV_KEY] = "off"
    assert_nil Rag::SemanticQueryAnalyzer.observe(turn: "el otro", episode: EPISODE, correlation_id: "query:1", client: exploding_client)

    ENV[Rag::HaikuQueryAnalysisFlag::ENV_KEY] = "shadow"
    assert_nil Rag::SemanticQueryAnalyzer.observe(turn: "el otro", episode: {}, correlation_id: "query:1", client: exploding_client)
  end

  test "conditional and always do not call" do
    %w[conditional always].each do |mode|
      ENV[Rag::HaikuQueryAnalysisFlag::ENV_KEY] = mode
      assert_nil Rag::SemanticQueryAnalyzer.observe(
        turn: "el otro", episode: EPISODE, correlation_id: "query:1", client: exploding_client
      ), mode
    end
  end

  test "a valid tool input becomes an analysis and does not open a network client" do
    client = fake_client(perception("continue", mentions: [ { "span" => "freno", "role" => "component" } ]))
    called = false
    client.define_singleton_method(:converse) do |_params|
      called = true
      tool = Struct.new(:name, :input).new(
        "semantic_perception",
        { "relation" => "continue", "mentions" => [ { "span" => "freno", "role" => "component" } ], "refers_to" => [], "ambiguous" => false }
      )
      block = Struct.new(:tool_use).new(tool)
      Struct.new(:output, :usage).new(Struct.new(:message).new(Struct.new(:content).new([ block ])), Struct.new(:input_tokens, :output_tokens).new(1, 1))
    end
    analysis = Rag::SemanticQueryAnalyzer.observe(
      turn: "el freno no suelta",
      episode: EPISODE,
      correlation_id: "query:ok",
      client: client
    )
    assert called
    assert_equal "continue", analysis.relation
    assert_equal false, analysis.ambiguous
    assert_equal "freno", analysis.mentions.first["span"]
  end

  test "timeout returns nil" do
    analysis = Rag::SemanticQueryAnalyzer.observe(
      turn: "el freno no suelta",
      episode: EPISODE,
      correlation_id: "query:timeout",
      client: raising_client(Timeout::Error.new("timed out"))
    )
    assert_nil analysis
  end

  test "an invented span returns nil" do
    analysis = Rag::SemanticQueryAnalyzer.observe(
      turn: "rele",
      episode: EPISODE,
      correlation_id: "query:span",
      client: fake_client(perception("continue", mentions: [ { "span" => "relé", "role" => "component" } ]))
    )
    assert_nil analysis
  end

  test "http 5xx returns nil" do
    error = StandardError.new("unavailable")
    context = Struct.new(:http_response).new(Struct.new(:status_code).new(503))
    error.define_singleton_method(:context) { context }
    analysis = Rag::SemanticQueryAnalyzer.observe(
      turn: "el freno no suelta",
      episode: EPISODE,
      correlation_id: "query:5xx",
      client: raising_client(error)
    )
    assert_nil analysis
  end

  test "shadow log records status latency and tokens without the turn" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    Rag::SemanticQueryAnalyzer.observe(
      turn: "el freno no suelta",
      episode: EPISODE,
      correlation_id: "query:log",
      client: fake_client(perception("continue", mentions: [ { "span" => "freno", "role" => "component" } ]), input_tokens: 10, output_tokens: 4)
    )
    event = output.string.lines.filter_map { |line| JSON.parse(line) rescue nil }.find { |row| row["event"] == "haiku_query_analysis_shadow" }
    assert event
    assert_equal "ok", event["analyzer_status"]
    assert_equal "continue", event["relation"]
    assert_equal "query:log", event["correlation_id"]
    assert event["semantic_analysis_ms"].is_a?(Integer)
    assert_equal 10, event["input_tokens"]
    assert_equal 4, event["output_tokens"]
    assert event.key?("cost_usd")
    assert_not_includes event.to_json, "el freno no suelta"
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  private

  def exploding_client
    client = Object.new
    client.define_singleton_method(:converse) { |_params| flunk "converse called" }
    client
  end

  def raising_client(error)
    client = Object.new
    client.define_singleton_method(:converse) { |_params| raise error }
    client
  end

  def fake_client(input, input_tokens: 1, output_tokens: 1)
    tool = Struct.new(:name, :input).new("semantic_perception", input)
    block = Struct.new(:tool_use).new(tool)
    message = Struct.new(:content).new([ block ])
    output = Struct.new(:message).new(message)
    usage = Struct.new(:input_tokens, :output_tokens).new(input_tokens, output_tokens)
    response = Struct.new(:output, :usage).new(output, usage)
    client = Object.new
    client.define_singleton_method(:converse) { |_params| response }
    client
  end

  def perception(relation, mentions: [], refers_to: [], ambiguous: false)
    {
      "relation" => relation,
      "mentions" => mentions,
      "refers_to" => refers_to,
      "ambiguous" => ambiguous
    }
  end
end
