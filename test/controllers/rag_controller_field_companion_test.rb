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

  def with_episode_flag(value)
    previous = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    value.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous
  end
end
