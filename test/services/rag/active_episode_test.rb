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

  test "catalog source is kept and photo is only manufacturer or model" do
    episode = Rag::ActiveEpisode.parse(valid_payload(
      "facts" => {
        "manufacturer" => known_fact("KONE", source: "photo"),
        "model" => known_fact("MH", source: "catalog"),
        "controller" => known_fact("NICE3000", source: "catalog"),
        "fault_code" => known_fact("8", source: "photo")
      }
    ), now: NOW)

    assert_equal %w[controller manufacturer model], episode.facts.keys.sort
    assert_equal "photo", episode.facts["manufacturer"]["source"]
    assert_equal "catalog", episode.facts["model"]["source"]
    assert_equal "catalog", episode.facts["controller"]["source"]
    assert_nil episode.facts["fault_code"]
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

  test "a catalog expansion does not displace declared or photo identifiers" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:1", now: NOW)
    declared = (1..5).map { |index| "User #{index}" }
    declared.each { |value| episode.append_identifier!(value, correlation_id: "query:1", source: "user") }
    episode.append_identifier!("Catalog Manual Name", correlation_id: "query:1", source: "catalog")

    assert_equal declared, episode.identifiers.pluck("value")
    assert episode.identifiers.none? { |item| item["source"] == "catalog" }

    mixed = [
      { "value" => "User A", "source" => "user", "correlation_id" => "query:1" },
      { "value" => "Photo B", "source" => "photo", "correlation_id" => "photo:1" },
      { "value" => "Older Catalog", "source" => "catalog", "correlation_id" => "query:1" },
      { "value" => "User C", "source" => "user", "correlation_id" => "query:1" },
      { "value" => "Newer Catalog", "source" => "catalog", "correlation_id" => "query:1" },
      { "value" => "Photo D", "source" => "photo", "correlation_id" => "photo:1" }
    ]
    parsed = Rag::ActiveEpisode.parse(valid_payload("identifiers" => mixed), now: NOW)
    parsed.append_identifier!("User E", correlation_id: "query:2", source: "user")

    assert_equal [ "User A", "Photo B", "User C", "Photo D", "User E" ], parsed.identifiers.pluck("value")
    assert parsed.identifiers.none? { |item| item["source"] == "catalog" }

    reloaded = Rag::ActiveEpisode.parse(parsed.to_h, now: NOW)
    assert_equal parsed.identifiers.pluck("value"), reloaded.identifiers.pluck("value")
    assert_equal parsed.identifiers.pluck("source"), reloaded.identifiers.pluck("source")
    assert_equal Rag::ActiveEpisode::MAX_IDENTIFIERS, reloaded.identifiers.size
  end

  test "a catalog expansion is kept when a declared slot is free" do
    raw = [
      { "value" => "User A", "source" => "user", "correlation_id" => "query:1" },
      { "value" => "Photo B", "source" => "photo", "correlation_id" => "photo:1" },
      { "value" => "User C", "source" => "user", "correlation_id" => "query:1" },
      { "value" => "Older Catalog", "source" => "catalog", "correlation_id" => "query:1" },
      { "value" => "Newer Catalog", "source" => "catalog", "correlation_id" => "query:1" },
      { "value" => "Photo D", "source" => "photo", "correlation_id" => "photo:1" }
    ]
    episode = Rag::ActiveEpisode.parse(valid_payload("identifiers" => raw), now: NOW)

    assert_equal [ "User A", "Photo B", "User C", "Newer Catalog", "Photo D" ], episode.identifiers.pluck("value")
    assert_equal "catalog", episode.identifiers[3]["source"]

    reloaded = Rag::ActiveEpisode.parse(episode.to_h, now: NOW)
    assert_equal episode.identifiers.pluck("value"), reloaded.identifiers.pluck("value")
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

  test "a capped episode plus rejected facts has a fixed byte size and a smaller core" do
    payload = capped_episode_payload
    saturated = JSON.generate(payload).bytesize
    core = payload.except("conflicts", "observations", "identifiers")
    nucleus = JSON.generate(core).bytesize

    assert_equal 4218, saturated
    assert_equal 2167, nucleus
    assert_operator nucleus, :<=, 4096
    assert_operator saturated, :>, 4096
  end

  test "serialization over the byte budget drops conflicts and keeps identifiers that still fit" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:1", now: NOW)
    episode.assign_goal!("Cómo se ajustan los resortes?", correlation_id: "query:1")
    episode.add_conflict!(fact: "manufacturer", user: "Fuji Yida", photo: "K" * 5000, correlation_id: "photo:1")
    5.times { |index| episode.append_identifier!("ID#{index}X", correlation_id: "c" * 500) }

    payload = episode.to_h
    assert_empty payload["conflicts"]
    assert_equal 5, payload["identifiers"].size
    assert_operator JSON.generate(payload).bytesize, :<=, Rag::ActiveEpisode::MAX_BYTES
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

  test "sanitize_photo keeps the photo ids and drops the visual reading" do
    episode = Rag::ActiveEpisode.parse(valid_payload(
      "active_photo" => {
        "field_photo_id" => 42,
        "sha256" => "abc123",
        "correlation_id" => "photo:1",
        "visual_observation" => { "manufacturer" => "KONE", "summary" => "prosa" },
        "summary" => "prosa de build_analysis",
        "manufacturer" => "KONE",
        "model" => "MonoSpace"
      }
    ), now: NOW)

    photo = episode.active_photo
    assert_equal 42, photo["field_photo_id"]
    assert_equal "abc123", photo["sha256"]
    assert_equal "photo:1", photo["correlation_id"]
    assert_equal %w[correlation_id field_photo_id sha256], photo.keys.sort
    assert_nil photo["visual_observation"]
    assert_nil photo["summary"]
    assert_nil photo["manufacturer"]
  end

  test "the cross-turn observation store keeps a case longer than the per-turn cap" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: NOW)
    stored = Rag::ActiveEpisode::MAX_STORED_OBSERVATIONS
    texts = Array.new(stored) { |index| "observacion de campo #{index} sigue vigente" }
    texts.each { |text| episode.append_observation!(text, correlation_id: "seed") }

    assert_equal stored, episode.observations.size
    assert_equal texts.first, episode.observations.first["text"]

    episode.append_observation!("observacion de campo extra que desplaza la primera", correlation_id: "seed")
    assert_equal stored, episode.observations.size
    assert_equal texts.second, episode.observations.first["text"]

    reloaded = Rag::ActiveEpisode.parse(episode.to_h, now: NOW)
    assert_equal stored, reloaded.observations.size
    assert_equal texts.second, reloaded.observations.first["text"]
  end

  test "a repeated click and a continuity echo do not grow the list" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: NOW)
    episode.assign_goal!("la puerta 1 no termina de cerrar el imán no magnetiza", correlation_id: "seed")
    episode.append_observation!("Al pedir cierre se oye un clic y la puerta no termina de cerrar", correlation_id: "seed")
    episode.append_observation!("la puerta no cierra", correlation_id: "seed")
    before = episode.observations.pluck("text")

    episode.append_observation!("Sigue igual", correlation_id: "seed")
    episode.append_observation!("Al pedir cierre se oye un clic y la puerta no termina de cerrar. Sigue igual.", correlation_id: "seed")
    episode.append_observation!("Al pedir cierre se oye un clic, pero no termina de cerrar", correlation_id: "seed")
    episode.append_observation!("la puerta cierra", correlation_id: "seed")

    texts = episode.observations.pluck("text")
    assert_equal before + [
      "Al pedir cierre se oye un clic, pero no termina de cerrar",
      "la puerta cierra"
    ], texts
  end

  test "the observation that originated the goal survives the store cap" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: NOW)
    episode.assign_goal!("la puerta 1 no termina de cerrar el imán no magnetiza", correlation_id: "seed")
    episode.append_observation!("la puerta 1 no termina de cerrar", correlation_id: "seed")
    episode.append_observation!("el imán no magnetiza", correlation_id: "seed")
    filler = Array.new(Rag::ActiveEpisode::MAX_STORED_OBSERVATIONS - 2) { |index| "comprobacion distinta #{index}" }
    filler.each { |text| episode.append_observation!(text, correlation_id: "seed") }

    episode.append_observation!("la cabina está detenida cerca de planta 2", correlation_id: "seed")

    texts = episode.observations.pluck("text")
    assert_equal Rag::ActiveEpisode::MAX_STORED_OBSERVATIONS, texts.size
    assert_includes texts, "la puerta 1 no termina de cerrar"
    assert_includes texts, "el imán no magnetiza"
    assert_includes texts, "la cabina está detenida cerca de planta 2"
    assert_not_includes texts, filler.first
  end

  test "field companion flags are off unless the env value is the string true" do
    with_flags(nil) do
      assert_not Rag::FieldCompanionEpisodeFlag.enabled?
      assert_not Rag::FieldCompanionTurnFlag.enabled?
    end

    with_flags("false") do
      assert_not Rag::FieldCompanionEpisodeFlag.enabled?
    end

    with_flags("true") do
      assert Rag::FieldCompanionEpisodeFlag.enabled?
      assert Rag::FieldCompanionTurnFlag.enabled?
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

  def capped_episode_payload
    stamp = NOW.iso8601
    correlation = "query:#{'a' * 32}"
    fact = {
      "status" => "known",
      "value" => "V" * Rag::ActiveEpisode::MAX_VALUE_CHARS,
      "source" => "catalog",
      "correlation_id" => correlation,
      "at" => stamp
    }
    {
      "v" => 1,
      "episode_id" => "ep_#{'b' * 16}",
      "status" => "active",
      "opened_at" => stamp,
      "updated_at" => stamp,
      "opened_by" => correlation,
      "goal" => { "text" => "G" * Rag::ActiveEpisode::MAX_GOAL_CHARS, "correlation_id" => correlation, "truncated" => true },
      "facts" => Rag::ActiveEpisode::FACT_KEYS.index_with { fact },
      "identifiers" => Array.new(Rag::ActiveEpisode::MAX_IDENTIFIERS) { |index|
        { "value" => format("I%02d%s", index, "x" * 27), "source" => "user", "correlation_id" => correlation }
      },
      "observations" => Array.new(Rag::ActiveEpisode::MAX_OBSERVATIONS) { |index|
        { "text" => "O" * Rag::ActiveEpisode::MAX_OBSERVATION_CHARS, "correlation_id" => correlation }
      },
      "pending_fact" => { "subject" => "controller", "correlation_id" => correlation },
      "pending_question" => { "type" => "controller", "carry" => %w[Q2 E03] },
      "rejected" => Array.new(4) { |index|
        { "slot" => "controller", "value" => format("R%d%s", index, "y" * 58) }
      },
      "active_photo" => { "field_photo_id" => 999_999, "sha256" => "ab" * 32, "correlation_id" => correlation },
      "conflicts" => Array.new(Rag::ActiveEpisode::MAX_CONFLICTS) {
        {
          "fact" => "manufacturer",
          "user" => "U" * Rag::ActiveEpisode::MAX_VALUE_CHARS,
          "photo" => "P" * Rag::ActiveEpisode::MAX_VALUE_CHARS,
          "correlation_id" => correlation
        }
      }
    }
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
    keys = %w[FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED]
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
