# frozen_string_literal: true

module TurnInterpreterEval
  Outcome = Struct.new(
    :episode, :decision, :query, :perception, :fallback,
    :latency_ms, :input_tokens, :output_tokens, :field_rejections,
    :photo_in_prompt, :photo_in_query, :photo_in_generation,
    keyword_init: true
  )

  module_function

  def run(fixture = "test/fixtures/files/field_companion/turn_interpreter_eval.yml")
    path = Rails.root.join(fixture)
    label = fixture.include?("holdout") ? "turn_interpreter:holdout" : "turn_interpreter:eval"
    cases = YAML.safe_load_file(path)
    account = Account.order(:id).first || abort("turn_interpreter:eval needs an account")
    catalog = Rag::DocumentIdentityCatalog.current
    now = Time.current
    latencies = []
    input_tokens = 0
    output_tokens = 0
    fallbacks = 0
    field_rejections = 0
    mismatches = []
    clarification_hits = 0
    clarification_total = 0
    photo_hits = 0
    photo_total = 0
    created_photos = []

    cases.each do |row|
      episode, photos = seed(row, now, account)
      created_photos.concat(photos)
      outcome = nil
      Array(row["turns"] || [ row["turn"] ]).each do |turn|
        outcome = play(
          turn: turn, episode: episode, account: account, catalog: catalog,
          focus_count: row["focus_count"].to_i, now: now
        )
        episode = outcome.episode
        latencies << outcome.latency_ms
        input_tokens += outcome.input_tokens
        output_tokens += outcome.output_tokens
        fallbacks += 1 if outcome.fallback
        field_rejections += outcome.field_rejections
        if outcome.field_rejections.positive?
          puts "field_rejection #{row["id"]} #{outcome.perception&.field_rejections.inspect}"
        end
      end
      problems = problems_for(row, outcome)
      score_accuracy(row, outcome, problems) do |kind, hit|
        if kind == :clarification
          clarification_total += 1
          clarification_hits += 1 if hit
        else
          photo_total += 1
          photo_hits += 1 if hit
        end
      end
      if problems.empty?
        puts "PASS #{row["id"]}"
      else
        mismatches << "#{row["id"]}: #{problems.join("; ")}"
        puts "FAIL #{row["id"]}: #{problems.join("; ")}"
      end
    end

    rates = BedrockQuery::BEDROCK_PRICING[Rag::TurnInterpreter::MODEL_ID] || { input: 0, output: 0 }
    cost = (input_tokens / 1000.0 * rates[:input].to_f) + (output_tokens / 1000.0 * rates[:output].to_f)
    prefix = label == "turn_interpreter:holdout" ? "holdout_" : ""
    puts "#{prefix}passes=#{cases.size - mismatches.size} #{prefix}mismatches=#{mismatches.size} #{prefix}fallbacks=#{fallbacks} #{prefix}field_rejections=#{field_rejections}"
    puts "clarification_target_accuracy=#{accuracy(clarification_hits, clarification_total)} photo_context_accuracy=#{accuracy(photo_hits, photo_total)}"
    puts "p50_ms=#{percentile(latencies, 50)} p95_ms=#{percentile(latencies, 95)}"
    puts "input_tokens=#{input_tokens} output_tokens=#{output_tokens} estimated_usd=#{format("%.6f", cost)}"
    mismatches.each { |line| puts "mismatch #{line}" }
    abort "#{label} failed" if mismatches.any? || fallbacks.positive? || field_rejections.positive?
  ensure
    created_photos.each { |photo| photo.destroy if photo&.persisted? }
  end

  def seed(row, now, account)
    episode = if row["goal"].present? || row["facts"].present? || row["active_photo"].present? || row["observations"].present? || row["pending_slot"].present?
      Rag::ActiveEpisode.open(correlation_id: "eval-seed", now: now)
    elsif row["id"].to_s.start_with?("correction")
      opened = Rag::ActiveEpisode.open(correlation_id: "eval-seed", now: now)
      opened.write_fact!(
        "controller", status: "known", value: "NICE3000", source: "user",
        correlation_id: "eval-seed", at: now.iso8601
      )
      opened
    else
      Rag::ActiveEpisode.new
    end
    episode.assign_goal!(row["goal"], correlation_id: "eval-seed") if row["goal"].present? && episode.respond_to?(:assign_goal!)
    (row["facts"] || {}).each do |slot, spec|
      spec = spec.stringify_keys
      episode.write_fact!(
        slot.to_s, status: spec["status"].presence || "known", value: spec["value"],
        source: spec["source"].presence || "user", correlation_id: "eval-seed", at: now.iso8601
      )
    end
    Array(row["observations"]).each { |text| episode.append_observation!(text, correlation_id: "eval-seed") }
    Array(row["rejected"]).each do |item|
      item = item.stringify_keys
      episode.append_rejected!(item["slot"], item["value"])
    end
    if row["pending_slot"].present?
      slot = row["pending_slot"].to_s
      episode.pending_question = { "type" => slot }
      if Rag::PendingQuestion::FACT_TYPES.include?(slot)
        episode.pending_fact = { "subject" => slot, "correlation_id" => "eval-seed" }
      end
      carry = Array(row["pending_carry"])
      episode.pending_question["carry"] = carry if carry.any?
    end
    photos = []
    if row["active_photo"].is_a?(Hash)
      photo = create_photo(account, row["active_photo"])
      photos << photo
      episode.active_photo = {
        "field_photo_id" => photo.id,
        "sha256" => photo.sha256,
        "correlation_id" => "eval-photo"
      }
    end
    [ episode, photos ]
  end

  def create_photo(account, spec)
    spec = spec.stringify_keys
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: account,
      sha256: sha,
      s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 32
    )
    stored = FieldPhotoObservation.persist!(photo, {
      "schema_version" => 1,
      "prompt_fingerprint" => "ab" * 32,
      "model_id" => "eval-turn-interpreter",
      "canonical_component" => spec["component"].presence || "controlador",
      "manufacturer" => spec["manufacturer"].presence || "UNKNOWN",
      "model" => spec["model"].presence || "UNKNOWN",
      "subsystem" => spec["subsystem"].presence || "UNKNOWN",
      "condition" => spec["condition"].presence || "UNKNOWN",
      "visible_text" => Array(spec["visible_text"]),
      "target_visible" => spec.fetch("target_visible", true),
      "relevance_to_goal" => spec["relevance_to_goal"]
    })
    abort "turn_interpreter:eval could not store the synthetic photo" if stored.nil?

    photo
  end

  def play(turn:, episode:, account:, catalog:, focus_count:, now:)
    photo_context = Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: account)
    interpreted = Rag::TurnInterpreter.call(
      turn: turn, episode: episode, viewer_account: account, catalog: catalog,
      correlation_id: "eval:#{SecureRandom.hex(4)}", active_photo_context: photo_context
    )
    perception = interpreted.perception
    if interpreted.fallback || perception.nil? || !perception.valid
      decision = Rag::RoutePolicy.fallback(
        episode: episode, turn: turn, focus_count: focus_count, focus_document_ids: [],
        focus_uris: [], catalog: catalog, viewer_account: account
      )
      return outcome(episode, decision, interpreted, perception, decision.retrieval_query, photo_context, false, false)
    end

    policy_previous = perception.move == "new_work" ? Rag::ActiveEpisode.new : episode
    decision = Rag::RoutePolicy.call(
      previous: policy_previous, perception: perception, focus_count: focus_count,
      focus_document_ids: [], focus_uris: [], relevant_photo: photo_context.relevant?
    )
    working = if perception.move == "new_work" || episode.blank?
      Rag::ActiveEpisode.open(correlation_id: "eval", now: now)
    else
      episode
    end
    Rag::WorkContextReducer.apply!(
      episode: working, perception: perception, decision: decision,
      turn: turn, correlation_id: "eval", now: now
    )
    query = Rag::QueryComposer.call(
      state: working, turn: turn, perception: perception, decision: decision,
      active_photo_context: photo_context
    )
    decision = decision.with(retrieval_query: query, owns_query: query.present?)
    photo_id = working.active_photo&.dig("field_photo_id")
    in_query = photo_context.query_terms.any? { |term| query.to_s.match?(/#{Regexp.escape(term)}/i) }
    in_generation = photo_context.matches?(photo_id) && photo_context.generation_block.present?
    outcome(working, decision, interpreted, perception, query, photo_context, in_query, in_generation)
  end

  def outcome(episode, decision, interpreted, perception, query, photo_context, in_query, in_generation)
    Outcome.new(
      episode: episode, decision: decision.decision, query: query, perception: perception,
      fallback: interpreted.fallback, latency_ms: interpreted.latency_ms.to_i,
      input_tokens: interpreted.input_tokens.to_i, output_tokens: interpreted.output_tokens.to_i,
      field_rejections: Array(perception&.field_rejections).size,
      photo_in_prompt: photo_context.to_prompt.present?,
      photo_in_query: in_query,
      photo_in_generation: in_generation
    )
  end

  def problems_for(row, outcome)
    expected = row["expected"] || {}
    problems = []
    problems << "decision #{outcome.decision}" if expected["decision"] && outcome.decision != expected["decision"]
    problems << "move #{outcome.perception&.move}" if expected["move"] && outcome.perception&.move != expected["move"]
    if expected["not_move"] && outcome.perception&.move == expected["not_move"]
      problems << "move #{expected["not_move"]}"
    end
    if expected.key?("clarification_target") && outcome.perception&.clarification_target != expected["clarification_target"]
      problems << "clarification_target #{outcome.perception&.clarification_target.inspect}"
    end
    if expected.key?("retrieval")
      retrieves = %w[ready search_and_clarify best_effort].include?(outcome.decision)
      problems << "retrieval #{retrieves}" if retrieves != expected["retrieval"]
    end
    query = outcome.query.to_s
    Array(expected["query_contains"]).each do |token|
      problems << "missing #{token}" unless query.match?(/#{Regexp.escape(token.to_s)}/i)
    end
    Array(expected["query_excludes"]).each do |token|
      problems << "includes #{token}" if query.match?(/#{Regexp.escape(token.to_s)}/i)
    end
    problems.concat(fact_problems(expected, outcome))
    problems.concat(state_problems(expected, outcome))
    problems << "fault stored" if expected["fault_code"] == false && outcome.episode.fact("fault_code").present?
    problems << "expected a mention" if expected["perception"] == "mention" && outcome.perception&.mentions.blank?
    problems << "observation" if expected["observations"] == [] && outcome.perception&.observations&.any?
    if expected["catalog_typed"] == false && outcome.perception&.facts&.any? { |item| item.source == "catalog" }
      problems << "catalog typed a private identity"
    end
    problems << "manufacturer leaked" if expected["manufacturer_leaked"] == false && outcome.episode.fact("manufacturer").present?
    if expected["carry_discarded"] && Array(outcome.episode.identifiers).any? { |item| item["value"] == "Q2" }
      problems << "Q2 carry kept"
    end
    problems << "clarified again" if expected["repeated_clarification"] == false && outcome.decision == "clarify_first"
    problems << "controller was required" if expected["requires_controller"] == false && outcome.decision == "search_and_clarify"
    problems << "fallback" if outcome.fallback
    problems
  end

  def state_problems(expected, outcome)
    problems = []
    episode = outcome.episode
    problems << "goal present" if expected["goal_nil"] && episode.goal.present?
    problems << "goal #{episode.goal&.dig("text")}" if expected["goal_text"] && episode.goal&.dig("text") != expected["goal_text"]
    problems << "facts kept" if expected["facts_empty"] && episode.facts.any?
    problems << "observations kept" if expected["observations_empty"] && episode.observations.any?
    problems << "rejected kept" if expected["rejected_empty"] && episode.rejected.any?
    problems << "photo kept" if expected["photo_absent"] && episode.active_photo.present?
    problems << "photo dropped" if expected["photo_kept"] && episode.active_photo.blank?
    problems << "pending #{episode.pending_question&.dig("type")}" if expected["pending_type"] && episode.pending_question&.dig("type") != expected["pending_type"]
    problems << "photo prompt" if expected.key?("photo_in_prompt") && outcome.photo_in_prompt != expected["photo_in_prompt"]
    problems << "photo query" if expected.key?("photo_in_query") && outcome.photo_in_query != expected["photo_in_query"]
    problems << "photo generation" if expected.key?("photo_in_generation") && outcome.photo_in_generation != expected["photo_in_generation"]
    problems
  end

  def score_accuracy(row, outcome, problems)
    expected = row["expected"] || {}
    if expected.key?("clarification_target")
      yield :clarification, problems.none? { |item| item.start_with?("clarification_target") }
    end
    photo_keys = %w[photo_in_prompt photo_in_query photo_in_generation photo_absent photo_kept]
    return unless photo_keys.any? { |key| expected.key?(key) }

    yield :photo, problems.none? { |item| item.start_with?("photo") }
  end

  def accuracy(hits, total)
    return "n/a" if total.zero?

    "#{hits}/#{total}"
  end

  def fact_problems(expected, outcome)
    problems = []
    fact = expected["fact"]
    if fact.is_a?(Hash)
      stored = outcome.episode.fact(fact["slot"].to_s)
      problems << "fact #{fact["slot"]}" if stored.nil?
      problems << "status #{stored&.dig("status")}" if fact["status"] && stored&.dig("status") != fact["status"].to_s
      problems << "value #{stored&.dig("value")}" if fact["value"] && stored&.dig("value") != fact["value"].to_s
      problems << "source #{stored&.dig("source")}" if fact["source"] && stored&.dig("source") != fact["source"].to_s
    end
    Array(expected["rejected"]).each do |value|
      rejected = Array(outcome.episode.rejected).any? { |item| item["value"].to_s.casecmp?(value.to_s) }
      problems << "rejected #{value}" unless rejected
    end
    Array(expected["active"]).each do |value|
      active = outcome.episode.facts.values.any? { |item| item.is_a?(Hash) && item["value"].to_s.casecmp?(value.to_s) }
      problems << "active #{value}" unless active
    end
    problems
  end

  def percentile(values, percentile)
    sorted = values.compact.sort
    return 0 if sorted.empty?

    index = ((percentile / 100.0) * (sorted.length - 1)).round
    sorted[index]
  end
end

namespace :turn_interpreter do
  desc "Run the TurnInterpreter fixture against Haiku. CI must not call this."
  task eval: :environment do
    TurnInterpreterEval.run
  end

  desc "Run the TurnInterpreter holdout against Haiku. CI must not call this."
  task holdout: :environment do
    TurnInterpreterEval.run("test/fixtures/files/field_companion/turn_interpreter_holdout.yml")
  end

  desc "Read recent turn_interpreter events after the owner canary"
  task smoke_check: :environment do
    since = 2.hours.ago
    events = PilotEvent.where(event: "turn_interpreter").where(occurred_at: since..)
    puts "events=#{events.count} since=#{since.iso8601}"
    abort "no turn_interpreter events in the last 2 hours" if events.none?

    fallbacks = events.count { |event| event.payload["turn_interpreter_fallback"] == true }
    puts "fallbacks=#{fallbacks}"
  end
end
