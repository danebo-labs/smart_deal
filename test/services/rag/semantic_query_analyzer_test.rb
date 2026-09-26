# frozen_string_literal: true

require "test_helper"

ENV["HAIKU_SEMANTIC_P0_LIBRARY_ONLY"] = "1"
require Rails.root.join("script/haiku_semantic_perception_p0.rb")

class Rag::SemanticQueryAnalyzerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
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
    Rag::SemanticQueryAnalyzer.clear_observation!
  end

  test "the production prompt keeps the P0 safety rules and rejects invented slots" do
    prompt = Rag::SemanticQueryAnalyzer::PROMPT
    assert_includes prompt, "You are not a technical authority"
    assert_includes prompt, "DO NOT fold accents"
    assert_includes prompt, "If slots is empty, refers_to is []"
    assert_includes prompt, "cambia al"
    assert_not_equal HaikuSemanticPerceptionP0::PROMPT, prompt
  end

  test "an empty slot list closes refers_to and a pending question enumerates its slot" do
    empty = captured_schema(EPISODE)
    assert_equal 0, empty.dig(:properties, :refers_to, :maxItems)

    pending = captured_schema(EPISODE.merge("pending_fact" => { "subject" => "manufacturer" }))
    assert_nil pending.dig(:properties, :refers_to, :maxItems)
    assert_equal [ "pending_question" ], pending.dig(:properties, :refers_to, :items, :properties, :slot, :enum)
  end

  test "an invented slot still rejects an otherwise valid correction" do
    analysis = Rag::SemanticQueryAnalyzer.observe(
      turn: "No, no es MonoSpace. Es MiniSpace.",
      episode: EPISODE,
      correlation_id: "query:slot",
      client: fake_client({
        "relation" => "correct",
        "mentions" => [ { "span" => "MiniSpace", "role" => "equipment" } ],
        "refers_to" => [ { "span" => "MonoSpace", "slot" => "equipment.model" } ],
        "ambiguous" => false
      })
    )
    assert_nil analysis
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

  test "a valid paid call writes one semantic_analysis row with attribution and cache tokens" do
    account = accounts(:legacy)
    user = users(:one)
    session = ConversationSession.create!(
      identifier: "semantic-accounting", channel: "web", account: account, user: user, expires_at: 1.day.from_now
    )
    perform_enqueued_jobs do
      analysis = Rag::SemanticQueryAnalyzer.observe(
        turn: "el freno no suelta",
        episode: EPISODE,
        correlation_id: "query:paid",
        client: fake_client(
          perception("continue", mentions: [ { "span" => "freno", "role" => "component" } ]),
          input_tokens: 20, output_tokens: 5, cache_read_input_tokens: 4, cache_write_input_tokens: 6
        ),
        attribution: { account_id: account.id, user_id: user.id, conversation_session_id: session.id }
      )
      assert_equal "continue", analysis.relation
    end

    rows = BedrockQuery.where(correlation_id: "query:paid")
    assert_equal 1, rows.count
    row = rows.sole
    assert_equal "semantic_analysis", row.source
    assert_equal "semantic_analysis", row.route
    assert_equal Rag::SemanticQueryAnalyzer::MODEL_ID, row.model_id
    assert_equal "provider_usage", row.token_source
    assert_equal 20, row.input_tokens
    assert_equal 5, row.output_tokens
    assert_equal 4, row.cache_read_tokens
    assert_equal 6, row.cache_creation_tokens
    assert_equal "query:paid", row.correlation_id
    assert_equal account.id, row.account_id
    assert_equal user.id, row.user_id
    assert_equal session.id, row.conversation_session_id
    assert_operator row.cost, :>, 0
    assert_equal "ok", Rag::SemanticQueryAnalyzer.current_observation["status"]
  end

  test "invalid_schema still accounts the paid call and leaves analysis nil" do
    perform_enqueued_jobs do
      analysis = Rag::SemanticQueryAnalyzer.observe(
        turn: "el freno no suelta",
        episode: EPISODE,
        correlation_id: "query:invalid",
        client: fake_client({ "relation" => "nope" }, input_tokens: 8, output_tokens: 3)
      )
      assert_nil analysis
    end

    row = BedrockQuery.find_by!(correlation_id: "query:invalid")
    assert_equal "semantic_analysis", row.source
    assert_equal "el freno no suelta", row.user_query
    assert_operator row.cost, :>, 0
    assert_equal "invalid_schema", Rag::SemanticQueryAnalyzer.current_observation["status"]
    assert_nil Rag::SemanticQueryAnalyzer.current_observation["relation"]
  end

  test "hallucinated_spans still accounts the paid call and leaves analysis nil" do
    perform_enqueued_jobs do
      analysis = Rag::SemanticQueryAnalyzer.observe(
        turn: "rele",
        episode: EPISODE,
        correlation_id: "query:hallucinated",
        client: fake_client(
          perception("continue", mentions: [ { "span" => "relé", "role" => "component" } ]),
          input_tokens: 11, output_tokens: 2
        )
      )
      assert_nil analysis
    end

    row = BedrockQuery.find_by!(correlation_id: "query:hallucinated")
    assert_equal "semantic_analysis", row.source
    assert_equal 11, row.input_tokens
    assert_operator row.cost, :>, 0
    assert_equal "hallucinated_spans", Rag::SemanticQueryAnalyzer.current_observation["status"]
  end

  test "a transport failure inserts no usage row" do
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      analysis = Rag::SemanticQueryAnalyzer.observe(
        turn: "el freno no suelta",
        episode: EPISODE,
        correlation_id: "query:timeout",
        client: raising_client(Timeout::Error.new("timed out"))
      )
      assert_nil analysis
    end

    assert_equal 0, BedrockQuery.where(correlation_id: "query:timeout").count
    assert_equal "timeout", Rag::SemanticQueryAnalyzer.current_observation["status"]
  end

  test "a tracking enqueue error does not fail the turn" do
    previous_episode = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV[Rag::HaikuQueryAnalysisFlag::ENV_KEY] = "conditional"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    session = ConversationSession.create!(
      identifier: "semantic-tracking-failure", channel: "web", account: accounts(:legacy),
      user: users(:one), expires_at: 1.day.from_now,
      active_episode: {
        "v" => 1, "episode_id" => "ep_track", "status" => "active",
        "opened_at" => Time.current.iso8601, "updated_at" => Time.current.iso8601,
        "goal" => { "text" => "el freno" }
      }
    )
    client = fake_client(perception("continue", mentions: [ { "span" => "freno", "role" => "component" } ]), input_tokens: 9, output_tokens: 2)
    original_client = BedrockClient.method(:new)
    original_later = TrackBedrockQueryJob.method(:perform_later)
    BedrockClient.define_singleton_method(:new) { |*_, **_| client }
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| raise RuntimeError, "tracking down" }
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    result = session.record_user_turn!("el freno no suelta", user_id: users(:one).id, correlation_id: "query:track-fail")

    assert result
    assert_equal "el freno no suelta", session.reload.conversation_history.last["content"]
    assert_includes output.string, "failed to enqueue usage tracking"
    assert_equal 0, BedrockQuery.where(correlation_id: "query:track-fail").count
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
    BedrockClient.define_singleton_method(:new) { |*args, **kwargs| original_client.call(*args, **kwargs) } if original_client
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**kwargs| original_later.call(**kwargs) } if original_later
    if previous_episode.nil?
      ENV.delete("FIELD_COMPANION_EPISODE_ENABLED")
    else
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous_episode
    end
  end

  test "generation and semantic usage for one turn stay two sources summed once" do
    correlation_id = "query:both"
    perform_enqueued_jobs do
      Rag::SemanticQueryAnalyzer.observe(
        turn: "el freno no suelta",
        episode: EPISODE,
        correlation_id: correlation_id,
        client: fake_client(
          perception("continue", mentions: [ { "span" => "freno", "role" => "component" } ]),
          input_tokens: 20, output_tokens: 4
        )
      )
    end
    BedrockQuery.create!(
      source: "query", route: "rag_global", model_id: Rag::SemanticQueryAnalyzer::MODEL_ID,
      input_tokens: 100, output_tokens: 10, user_query: "el freno no suelta", latency_ms: 8,
      correlation_id: correlation_id, token_source: "estimated"
    )

    rows = BedrockQuery.where(correlation_id: correlation_id).to_a
    assert_equal 2, rows.size
    assert_equal %w[query semantic_analysis], rows.map(&:source).sort
    semantic = rows.find(&:semantic_analysis?)
    generation = rows.find(&:query?)
    assert_equal 1, rows.count(&:semantic_analysis?)
    assert_equal 1, rows.count(&:query?)
    assert_equal (semantic.cost + generation.cost).round(6), rows.sum(&:cost).round(6)
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

  def fake_client(input, input_tokens: 1, output_tokens: 1, cache_read_input_tokens: nil, cache_write_input_tokens: nil)
    tool = Struct.new(:name, :input).new("semantic_perception", input)
    block = Struct.new(:tool_use).new(tool)
    message = Struct.new(:content).new([ block ])
    output = Struct.new(:message).new(message)
    usage = Struct.new(:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_write_input_tokens)
      .new(input_tokens, output_tokens, cache_read_input_tokens, cache_write_input_tokens)
    response = Struct.new(:output, :usage).new(output, usage)
    client = Object.new
    client.define_singleton_method(:converse) { |_params| response }
    client
  end

  def captured_schema(episode)
    schema = nil
    client = fake_client(perception("continue"))
    client.define_singleton_method(:converse) do |params|
      schema = params.dig(:tool_config, :tools, 0, :tool_spec, :input_schema, :json)
      tool = Struct.new(:name, :input).new(
        "semantic_perception",
        { "relation" => "continue", "mentions" => [], "refers_to" => [], "ambiguous" => false }
      )
      block = Struct.new(:tool_use).new(tool)
      Struct.new(:output, :usage).new(
        Struct.new(:message).new(Struct.new(:content).new([ block ])),
        Struct.new(:input_tokens, :output_tokens).new(1, 1)
      )
    end
    Rag::SemanticQueryAnalyzer.observe(
      turn: "el freno",
      episode: episode,
      correlation_id: "query:schema",
      client: client
    )
    schema
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
