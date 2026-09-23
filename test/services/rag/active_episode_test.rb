# frozen_string_literal: true

require "test_helper"

class Rag::ActiveEpisodeTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-09-23 14:00:00 -03:00")

  test "facts keeps only manufacturer, model, and fault_code" do
    episode = Rag::ActiveEpisode.parse(valid_payload(
      "facts" => {
        "manufacturer" => known_fact("Fuji Yida"),
        "symptom" => known_fact("no magnetiza"),
        "component" => known_fact("imán")
      }
    ), now: NOW)

    assert_equal [ "manufacturer" ], episode.facts.keys
    assert_equal "Fuji Yida", episode.facts["manufacturer"]["value"]
  end

  test "status known requires a value, unknown_confirmed is only manufacturer or model, absent_confirmed is only fault_code" do
    episode = Rag::ActiveEpisode.parse(valid_payload(
      "facts" => {
        "manufacturer" => { "status" => "known", "source" => "user", "correlation_id" => "query:1", "at" => NOW.iso8601 },
        "model" => { "status" => "absent_confirmed", "source" => "user", "correlation_id" => "query:1", "at" => NOW.iso8601 },
        "fault_code" => { "status" => "unknown_confirmed", "source" => "user", "correlation_id" => "query:1", "at" => NOW.iso8601 }
      }
    ), now: NOW)

    assert_empty episode.facts

    kept = Rag::ActiveEpisode.parse(valid_payload(
      "facts" => {
        "manufacturer" => { "status" => "unknown_confirmed", "source" => "user", "correlation_id" => "query:1", "at" => NOW.iso8601 },
        "model" => { "status" => "unknown_confirmed", "source" => "user", "correlation_id" => "query:1", "at" => NOW.iso8601 },
        "fault_code" => { "status" => "absent_confirmed", "source" => "user", "correlation_id" => "query:1", "at" => NOW.iso8601 }
      }
    ), now: NOW)

    assert_equal "unknown_confirmed", kept.facts["manufacturer"]["status"]
    assert_equal "unknown_confirmed", kept.facts["model"]["status"]
    assert_equal "absent_confirmed", kept.facts["fault_code"]["status"]
    assert_nil kept.facts["fault_code"]["value"]
  end

  test "source is user or photo, and photo only on manufacturer and model" do
    episode = Rag::ActiveEpisode.parse(valid_payload(
      "facts" => {
        "manufacturer" => known_fact("KONE", source: "photo"),
        "model" => known_fact("MH", source: "catalog"),
        "fault_code" => known_fact("8", source: "photo")
      }
    ), now: NOW)

    assert_equal [ "manufacturer" ], episode.facts.keys
    assert_equal "photo", episode.facts["manufacturer"]["source"]
  end

  test "goal text keeps the first 300 characters and marks truncated" do
    long = "A" * 301
    episode = Rag::ActiveEpisode.open(correlation_id: "query:1", now: NOW)
    episode.assign_goal!(long, correlation_id: "query:1")

    assert_equal 300, episode.goal["text"].length
    assert episode.goal["truncated"]
    assert_equal "A" * 300, episode.goal["text"]
  end

  test "a known value is squished and cut to 60 characters" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:1", now: NOW)
    episode.write_fact!(
      "manufacturer",
      status: "known",
      value: "  Fuji    #{'Y' * 80}  ",
      correlation_id: "query:1",
      at: NOW.iso8601
    )

    stored = episode.facts["manufacturer"]["value"]
    assert_equal 60, stored.length
    assert stored.start_with?("Fuji ")
    assert_not stored.include?("  ")
  end

  test "identifiers are capped at 5, 30 characters, deduped, and drop the oldest" do
    raw = (1..6).map { |index| { "value" => "ID#{index}-#{'Z' * 40}", "source" => "user", "correlation_id" => "query:1" } }
    raw << { "value" => "id6-#{'z' * 40}", "source" => "user", "correlation_id" => "query:2" }

    episode = Rag::ActiveEpisode.parse(valid_payload("identifiers" => raw), now: NOW)
    values = episode.identifiers.pluck("value")

    assert_equal 5, values.size
    assert_equal 30, values.first.length
    assert_equal "ID2-#{'Z' * 26}", values.first
    assert_equal "ID6-#{'Z' * 26}", values.last
  end

  test "conflicts are capped at 3 and drop the oldest" do
    raw = (1..4).map { |index|
      { "fact" => "manufacturer", "user" => "User#{index}", "photo" => "Photo#{index}", "correlation_id" => "photo:#{index}" }
    }
    episode = Rag::ActiveEpisode.parse(valid_payload("conflicts" => raw), now: NOW)

    assert_equal %w[User2 User3 User4], episode.conflicts.pluck("user")
  end

  test "pending_fact subject is manufacturer, model, or fault_code" do
    dropped = Rag::ActiveEpisode.parse(valid_payload(
      "pending_fact" => { "subject" => "voltage", "correlation_id" => "query:1" }
    ), now: NOW)
    assert_nil dropped.pending_fact

    kept = Rag::ActiveEpisode.parse(valid_payload(
      "pending_fact" => { "subject" => "model", "correlation_id" => "query:1" }
    ), now: NOW)
    assert_equal "model", kept.pending_fact["subject"]
  end

  test "serialization over 2048 bytes drops conflicts and then the oldest identifiers" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:1", now: NOW)
    episode.assign_goal!("Cómo se ajustan los resortes?", correlation_id: "query:1")
    episode.add_conflict!(fact: "manufacturer", user: "Fuji Yida", photo: "K" * 3000, correlation_id: "photo:1")
    5.times { |index| episode.append_identifier!("ID#{index}X", correlation_id: "c" * 500) }

    payload = episode.to_h
    assert_empty payload["conflicts"]
    assert_operator JSON.generate(payload).bytesize, :<=, Rag::ActiveEpisode::MAX_BYTES
    assert_operator payload["identifiers"].size, :<, 5
  end

  test "X-11 a foreign version or a string is an empty episode and does not raise" do
    [ '{"v": 9}', "a string", { "v" => 9 }, 12 ].each do |raw|
      episode = nil
      assert_nothing_raised { episode = Rag::ActiveEpisode.parse(raw, now: NOW) }
      assert episode.blank?
      assert_equal({}, episode.to_h)
      assert_equal "invalid_state", episode.reason
    end
  end

  test "an empty payload is no episode and is not invalid_state" do
    episode = Rag::ActiveEpisode.parse({}, now: NOW)
    assert episode.blank?
    assert_nil episode.reason
  end

  test "updated_at older than the episode window is treated as empty" do
    episode = Rag::ActiveEpisode.parse(
      valid_payload("updated_at" => (NOW - 5.hours).iso8601),
      now: NOW
    )

    assert episode.blank?
    assert_equal "expired", episode.reason
    assert_equal({}, episode.to_h)
  end

  test "an episode inside the window round-trips its closed facts" do
    episode = Rag::ActiveEpisode.parse(valid_payload, now: NOW)
    assert_not episode.blank?
    assert_nil episode.reason
    assert_equal "ep_round", episode.to_h["episode_id"]
    assert_equal "Fuji Yida", episode.to_h.dig("facts", "manufacturer", "value")
  end

  test "field companion flags are off unless the env value is the string true" do
    with_flags(nil) do
      assert_not Rag::FieldCompanionEpisodeFlag.enabled?
      assert_not Rag::FieldCompanionTurnFlag.enabled?
      assert_not Rag::FieldCompanionPhotoFlag.enabled?
    end

    with_flags("false") do
      assert_not Rag::FieldCompanionEpisodeFlag.enabled?
    end

    with_flags("true") do
      assert Rag::FieldCompanionEpisodeFlag.enabled?
      assert Rag::FieldCompanionTurnFlag.enabled?
      assert Rag::FieldCompanionPhotoFlag.enabled?
    end
  end

  private

  def valid_payload(overrides = {})
    {
      "v" => 1,
      "episode_id" => "ep_round",
      "status" => "active",
      "opened_at" => (NOW - 1.hour).iso8601,
      "updated_at" => (NOW - 10.minutes).iso8601,
      "opened_by" => "query:1",
      "goal" => { "text" => "Cómo se ajustan los resortes?", "correlation_id" => "query:1", "truncated" => false },
      "facts" => { "manufacturer" => known_fact("Fuji Yida") },
      "identifiers" => [],
      "pending_fact" => nil,
      "active_photo" => nil,
      "conflicts" => []
    }.merge(overrides)
  end

  def known_fact(value, source: "user")
    {
      "status" => "known",
      "value" => value,
      "source" => source,
      "correlation_id" => "query:1",
      "at" => NOW.iso8601
    }
  end

  def with_flags(value)
    keys = %w[FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED FIELD_COMPANION_PHOTO_ENABLED]
    previous = keys.index_with { |key| ENV[key] }
    keys.each do |key|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, old|
      old.nil? ? ENV.delete(key) : ENV[key] = old
    end
  end
end
