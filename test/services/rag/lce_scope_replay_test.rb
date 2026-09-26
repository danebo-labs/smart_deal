# frozen_string_literal: true

require "test_helper"

class Rag::LceScopeReplayTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-09-25 20:43:02 -03:00")
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/real_gonzalo/lce_episode.json").read).freeze
  CATALOG_DESIGNATORS = [ "LCE", "LCB II", "CMC-3" ].freeze
  UNACCENTED_LCE = "¿Qué hace la tarjeta LCE y donde esta su configuracion?"
  SPRING_GOAL = "Cómo se ajustan los resortes de la fijación de cables?"
  POLEA = "esta polea tractora, ¿cómo se ajusta?"
  FUSIBLE = "¿dónde está el fusible F1 de la placa?"

  setup do
    @account = accounts(:legacy)
    @fixture = FIXTURE
  end

  test "fixture questions match the production original_sha256" do
    @fixture.fetch("questions").each_value do |row|
      assert_equal row.fetch("original_sha256"), Digest::SHA256.hexdigest(row.fetch("text")), row.fetch("correlation_id")
    end
    assert_nil @fixture.fetch("manufacturer")
    assert_equal [ "CMC-3", "LCB II" ], @fixture.fetch("identifiers")
  end

  test "catalog_identity_for LCE returns the LCE model" do
    with_catalog do
      identity = classifier("LCE").send(:catalog_identity_for, "LCE")

      assert_equal "LCE", identity["model"], identity.inspect
      assert identity.key?("manufacturer")
    end
  end

  test "the accented and unaccented LCE question opens a new episode" do
    with_mode("conditional") do
      with_catalog do
        [ lce_text, UNACCENTED_LCE ].each do |text|
          result = classify(text, lcb_episode, analysis: perception("continue"))
          effective = result.composed.presence || text

          assert_equal :new_episode, result.decision, text
          assert_not_includes effective, "LCB II"
          assert_not_includes effective, "CMC-3"
          assert_not_includes episode_identity(result), "LCB II"
          assert_not_includes episode_identity(result), "CMC-3"
          assert_equal text, result.state.dig("goal", "text")
        end
      end
    end
  end

  test "a failed perception still resets the LCE question" do
    with_mode("conditional") do
      with_catalog do
        result = classify(lce_text, lcb_episode, analysis: :failed)

        assert_equal :new_episode, result.decision
        assert_not_includes episode_identity(result), "CMC-3"
      end
    end
  end

  test "an owned correction returns before the catalog reset" do
    text = "¿Qué hace la tarjeta LCE de KONE y donde esta su configuracion?"
    with_mode("conditional") do
      with_catalog do
        result = classify(text, lcb_episode, analysis: perception("correct"))

        assert_equal :corrected, result.decision
      end
    end
  end

  test "an owned switch writes the catalog model before the deterministic reset" do
    with_mode("conditional") do
      with_catalog do
        result = classify(lce_text, lcb_episode, analysis: perception("switch", [ [ "LCE", "equipment" ] ]))

        assert_equal :new_episode, result.decision
        assert_equal "LCE", result.state.dig("facts", "model", "value")
      end
    end
  end

  test "the LCB II fusible question stays on the LCB II episode" do
    with_catalog do
      episode = lcb_episode
      result = classify(FUSIBLE, episode, analysis: perception("continue"))

      assert_not_equal :new_episode, result.decision
      assert_equal episode.episode_id, result.state["episode_id"]
      assert_includes result.state["identifiers"].pluck("value"), "CMC-3"
    end
  end

  test "what to check first on the spring episode still composes the cable fixing" do
    with_catalog do
      result = classify("¿Qué reviso primero?", spring_episode)

      assert_equal :continued_elliptical, result.decision
      assert_includes result.composed, "fijación de cables"
    end
  end

  test "the traction sheave question keeps its current result" do
    goal = "Cómo se ajusta el resorte de la fijación de cables?"
    with_catalog do
      result = classify(
        POLEA,
        opened_episode(goal),
        prior_turns: [ { "content" => goal, "correlation_id" => "query:prior", "ts" => (NOW - 5.minutes).iso8601 } ]
      )

      assert_not_equal :new_episode, result.decision
      assert_not_includes result.composed.to_s.downcase, "fijación de cables"
    end
  end

  test "a short LCE follow-up stays on the current episode" do
    with_catalog do
      episode = lcb_episode
      result = classify("y en el LCE?", episode)

      assert_not_equal :new_episode, result.decision
      assert_equal episode.episode_id, result.state["episode_id"]
    end
  end

  private

  def lce_text
    @fixture.dig("questions", "lce", "text")
  end

  def lcb_episode
    episode = Rag::ActiveEpisode.open(
      correlation_id: @fixture.dig("questions", "cmc3", "correlation_id"),
      now: NOW - 2.minutes
    )
    episode.assign_goal!(
      @fixture.dig("questions", "lcbii", "text"),
      correlation_id: @fixture.dig("questions", "lcbii", "correlation_id")
    )
    @fixture.fetch("identifiers").each do |value|
      episode.append_identifier!(value, correlation_id: @fixture.dig("questions", "lcbii", "correlation_id"))
    end
    episode
  end

  def spring_episode
    opened_episode(SPRING_GOAL)
  end

  def opened_episode(goal)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:prior", now: NOW - 10.minutes)
    episode.assign_goal!(goal, correlation_id: "query:prior")
    episode
  end

  def classify(text, episode, analysis: nil, prior_turns: [])
    Rag::ActiveEpisodeTurn.call(
      state: episode.to_h,
      text: text,
      now: NOW,
      enabled: true,
      correlation_id: @fixture.fetch("lce_correlation_id"),
      analysis: analysis,
      account: @account,
      prior_user_turns: prior_turns
    )
  end

  def classifier(text)
    Rag::ActiveEpisodeTurn.new(
      state: {},
      text: text,
      role: "user",
      now: NOW,
      selection_turn: false,
      pending_fact: Rag::ActiveEpisodeTurn::FROM_STATE,
      correlation_id: "query:catalog",
      channel: "web",
      enabled: true,
      shared: false,
      account: @account
    )
  end

  def episode_identity(result)
    [
      result.state.dig("facts", "model", "value"),
      result.state.dig("goal", "text"),
      *Array(result.state["identifiers"]).pluck("value")
    ].compact.join("\n")
  end

  def perception(relation, mentions = [])
    Rag::ConversationalTurnAnalysis.new(
      relation: relation,
      mentions: mentions.map { |span, role| { "span" => span, "role" => role } }
    )
  end

  def with_catalog
    rows = catalog_rows
    documents = rows.map do |row|
      KbDocument.create!(
        s3_key: row.fetch("s3_key"),
        display_name: row.fetch("display_name"),
        aliases: Array(row["designators"]),
        account: @account
      )
    end
    catalog = Rag::DocumentIdentityCatalog.new({ "documents" => rows })
    Rag::DocumentIdentityCatalog.with_catalog(catalog) { yield documents }
  end

  def catalog_rows
    raw = YAML.safe_load_file(Rag::DocumentIdentityCatalog::PATH, permitted_classes: [], aliases: false)
    raw.fetch("documents").select do |row|
      Array(row["designators"]).intersect?(CATALOG_DESIGNATORS)
    end
  end

  def with_mode(value)
    previous = ENV.fetch("HAIKU_QUERY_ANALYSIS_MODE", nil)
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("HAIKU_QUERY_ANALYSIS_MODE") : ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous
  end
end
