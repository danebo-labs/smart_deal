# frozen_string_literal: true

require "test_helper"

class RagControllerFieldCompanionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  CASE_IDS = %w[T-A T-B T-C T-D T-E T-F T-G T-H].freeze

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @user.update!(account: @account)
    @cases = YAML.load_file(Rails.root.join("test/fixtures/files/field_companion/cases.yml")).index_by { |row| row["id"] }
  end

  test "shadow on and off send the same text to the orchestrator for T-A through T-H" do
    CASE_IDS.each do |case_id|
      row = @cases.fetch(case_id)
      off_queries, off_episode = play(row, flag: nil)
      on_queries, on_episode = play(row, flag: "true")

      assert_equal off_queries, on_queries, "#{case_id} changed the orchestrator text"
      assert_equal({}, off_episode)
      assert on_episode["episode_id"].present?, "#{case_id} did not write an episode"
    end
  end

  REQUEST_CASE_IDS = %w[T-A T-B T-F T-G X-1].freeze

  test "multi-turn requests compose from the episode and do not open a thread menu" do
    REQUEST_CASE_IDS.each do |case_id|
      assert_request_case(@cases.fetch(case_id), case_id)
    end
  end

  test "T-A shadow writes the brand and the confirmed-unknown model without changing the question" do
    row = @cases.fetch("T-A")
    off_queries, = play(row, flag: nil)
    queries, episode = play(row, flag: "true")

    assert_equal off_queries, queries
    assert_equal "Fuji Yida", episode.dig("facts", "manufacturer", "value")
    assert_equal "unknown_confirmed", episode.dig("facts", "model", "status")
  end

  private

  def play(row, flag:)
    ConversationSession.where(identifier: @user.id.to_s, channel: "web").delete_all
    answers = row["turns"].select { |turn| turn["role"] == "assistant" }.pluck("content")
    queries = []
    with_episode_flag(flag) do
      with_orchestrator(queries, answers) do
        sign_in @user
        row["turns"].each do |turn|
          next unless turn["role"] == "user"

          post rag_ask_url, params: { question: turn["content"] }, as: :json
          assert_response :success
        end
      end
    end
    session = ConversationSession.find_by!(identifier: @user.id.to_s, channel: "web", account_id: @account.id)
    [ queries, session.active_episode ]
  end

  def with_orchestrator(queries, answers)
    original = QueryOrchestratorService.method(:new)
    queue = answers.dup
    QueryOrchestratorService.define_singleton_method(:new) do |query, **_kwargs|
      queries << query
      answer = queue.shift || "…"
      service = Object.new
      service.define_singleton_method(:execute) { { answer: answer, citations: [], session_id: "shadow" } }
      service
    end
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def assert_request_case(row, case_id)
    bedrock_calls = { n: 0 }
    queries = []
    snapshots = []
    answers = []
    with_flags do
      with_bedrock_counter(bedrock_calls) do
        with_orchestrator(queries, assistant_answers(row)) do
          sign_in @user
          row["turns"].each do |turn|
            next unless turn["role"] == "user"

            post rag_ask_url, params: { question: turn["content"] }, as: :json
            assert_response :success, case_id
            body = response.parsed_body
            answers << body["answer"]
            assert_not_equal I18n.t("rag.thread_menu_prompt", locale: :es), body["answer"], case_id
            snapshots << ConversationSession.find_by!(
              identifier: @user.id.to_s, channel: "web", account_id: @account.id
            ).active_episode.deep_dup
          end
        end
      end
    end

    assert_equal 0, bedrock_calls[:n], case_id
    assert_equal user_turns(row).size, queries.size, case_id
    state = {}
    user_index = 0
    Array(row["turns"]).each_with_index do |turn, index|
      if turn["role"] == "assistant"
        state = Rag::ActiveEpisodeTurn.apply_assistant(
          state: state, text: turn["content"], now: Time.current, correlation_id: "query:a#{index}"
        ).state
        next
      end

      result = Rag::ActiveEpisodeTurn.call(
        state: state, text: turn["content"], now: Time.current, enabled: true,
        shared: false, channel: "web", correlation_id: "query:u#{index}"
      )
      expected = result.composed.presence || turn["content"]
      assert_operator expected.length, :<=, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS, case_id
      assert_equal expected, queries[user_index], "#{case_id} turn #{index}"
      assert_equal result.state.dig("goal", "text"), snapshots[user_index].dig("goal", "text")
      assert_equal fact_view(result.state), fact_view(snapshots[user_index])
      assert_equal identifier_values(result.state), identifier_values(snapshots[user_index])
      user_index += 1
      state = result.state
    end

    assert_elemont_request(queries) if case_id == "T-B"
    assert_new_kone_request(queries, snapshots) if case_id == "T-G"
    assert answers.none? { |answer| answer == I18n.t("rag.thread_menu_prompt", locale: :es) }
  end

  def assert_elemont_request(queries)
    text = queries.last
    %w[Elemont MH CEA15].each { |part| assert_includes text, part }
    assert_includes text, "puerta 1"
    assert_includes text, "código 8"
  end

  def assert_new_kone_request(queries, snapshots)
    assert_equal "Ahora estoy revisando un KONE que no nivela en planta 3", queries.last
    %w[Elemont CEA15].each { |text| assert_not_includes JSON.generate(snapshots.last), text }
    assert_not_equal snapshots.first["episode_id"], snapshots.last["episode_id"]
  end

  def fact_view(state)
    %w[manufacturer model fault_code].index_with do |key|
      fact = state.dig("facts", key)
      fact&.slice("status", "value", "source")
    end
  end

  def identifier_values(state)
    Array(state["identifiers"]).pluck("value")
  end

  def user_turns(row)
    row["turns"].select { |turn| turn["role"] == "user" }
  end

  def assistant_answers(row)
    row["turns"].select { |turn| turn["role"] == "assistant" }.pluck("content")
  end

  def with_flags
    ConversationSession.where(identifier: @user.id.to_s, channel: "web").delete_all
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") { yield }
    end
  end

  def with_bedrock_counter(counter)
    counter[:n] = 0
    query = BedrockRagService.instance_method(:query)
    retrieve = BedrockRagService.instance_method(:retrieve_chunks)
    BedrockRagService.define_method(:query) do |*args, **kwargs, &block|
      counter[:n] += 1
      query.bind_call(self, *args, **kwargs, &block)
    end
    BedrockRagService.define_method(:retrieve_chunks) do |*args, **kwargs, &block|
      counter[:n] += 1
      retrieve.bind_call(self, *args, **kwargs, &block)
    end
    yield
  ensure
    BedrockRagService.define_method(:query) { |*args, **kwargs, &block| query.bind_call(self, *args, **kwargs, &block) }
    BedrockRagService.define_method(:retrieve_chunks) do |*args, **kwargs, &block|
      retrieve.bind_call(self, *args, **kwargs, &block)
    end
  end

  def with_episode_flag(value)
    previous = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    value.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous
  end
end
