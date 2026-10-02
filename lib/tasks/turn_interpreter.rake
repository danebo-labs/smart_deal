# frozen_string_literal: true

module TurnInterpreterEval
  Outcome = Struct.new(
    :episode, :decision, :query, :perception, :fallback,
    :latency_ms, :input_tokens, :output_tokens, :field_rejections,
    keyword_init: true
  )

  module_function

  def run
    path = Rails.root.join("test/fixtures/files/field_companion/turn_interpreter_eval.yml")
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

    cases.each do |row|
      episode = seed(row, now)
      outcome = nil
      Array(row["turns"] || [ row["turn"] ]).each do |turn|
        outcome = play(turn: turn, episode: episode, account: account, catalog: catalog, focus_count: row["focus_count"].to_i, now: now)
        episode = outcome.episode
        latencies << outcome.latency_ms
        input_tokens += outcome.input_tokens
        output_tokens += outcome.output_tokens
        fallbacks += 1 if outcome.fallback
        field_rejections += outcome.field_rejections
      end
      problems = problems_for(row, outcome)
      if problems.empty?
        puts "PASS #{row["id"]}"
      else
        mismatches << "#{row["id"]}: #{problems.join("; ")}"
        puts "FAIL #{row["id"]}: #{problems.join("; ")}"
      end
    end

    rates = BedrockQuery::BEDROCK_PRICING[Rag::TurnInterpreter::MODEL_ID] || { input: 0, output: 0 }
    cost = (input_tokens / 1000.0 * rates[:input].to_f) + (output_tokens / 1000.0 * rates[:output].to_f)
    puts "passes=#{cases.size - mismatches.size} mismatches=#{mismatches.size} fallbacks=#{fallbacks} field_rejections=#{field_rejections}"
    puts "p50_ms=#{percentile(latencies, 50)} p95_ms=#{percentile(latencies, 95)}"
    puts "input_tokens=#{input_tokens} output_tokens=#{output_tokens} estimated_usd=#{format("%.6f", cost)}"
    mismatches.each { |line| puts "mismatch #{line}" }
    abort "turn_interpreter:eval failed" if mismatches.any?
  end

  def seed(row, now)
    if row["pending_slot"].present?
      episode = Rag::ActiveEpisode.open(correlation_id: "eval-seed", now: now)
      episode.pending_question = { "type" => row["pending_slot"] }
      episode.pending_fact = { "subject" => row["pending_slot"], "correlation_id" => "eval-seed" }
      return episode
    end
    return Rag::ActiveEpisode.new unless row["id"].to_s.start_with?("correction")

    episode = Rag::ActiveEpisode.open(correlation_id: "eval-seed", now: now)
    episode.write_fact!(
      "controller", status: "known", value: "NICE3000", source: "user",
      correlation_id: "eval-seed", at: now.iso8601
    )
    episode
  end

  def play(turn:, episode:, account:, catalog:, focus_count:, now:)
    interpreted = Rag::TurnInterpreter.call(
      turn: turn, episode: episode, viewer_account: account, catalog: catalog,
      correlation_id: "eval:#{SecureRandom.hex(4)}"
    )
    perception = interpreted.perception
    if interpreted.fallback || perception.nil? || !perception.valid
      decision = Rag::RoutePolicy.fallback(
        episode: episode, turn: turn, focus_count: focus_count, focus_document_ids: [],
        focus_uris: [], catalog: catalog, viewer_account: account
      )
      return outcome(episode, decision, interpreted, perception, decision.retrieval_query)
    end

    policy_previous = perception.move == "new_work" ? Rag::ActiveEpisode.new : episode
    decision = Rag::RoutePolicy.call(
      previous: policy_previous, perception: perception, focus_count: focus_count,
      focus_document_ids: [], focus_uris: []
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
    query = Rag::QueryComposer.call(state: working, turn: turn, perception: perception, decision: decision)
    decision = decision.with(retrieval_query: query, owns_query: query.present?)
    outcome(working, decision, interpreted, perception, query)
  end

  def outcome(episode, decision, interpreted, perception, query)
    Outcome.new(
      episode: episode, decision: decision.decision, query: query, perception: perception,
      fallback: interpreted.fallback, latency_ms: interpreted.latency_ms.to_i,
      input_tokens: interpreted.input_tokens.to_i, output_tokens: interpreted.output_tokens.to_i,
      field_rejections: Array(perception&.field_rejections).size
    )
  end

  def problems_for(row, outcome)
    expected = row["expected"] || {}
    problems = []
    problems << "decision #{outcome.decision}" if expected["decision"] && outcome.decision != expected["decision"]
    query = outcome.query.to_s
    Array(expected["query_contains"]).each do |token|
      problems << "missing #{token}" unless query.match?(/#{Regexp.escape(token.to_s)}/i)
    end
    Array(expected["query_excludes"]).each do |token|
      problems << "includes #{token}" if query.match?(/#{Regexp.escape(token.to_s)}/i)
    end
    problems.concat(fact_problems(expected, outcome))
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
