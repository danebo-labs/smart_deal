# frozen_string_literal: true

load Rails.root.join("script/field_companion/run_stage1_live.rb") unless Stage1Live.respond_to?(:judge, true)

# Offline replay of a captured live run of Otis case 29. The including test
# defines FIXTURE (label => captured turn). Nothing is injected between turns:
# the episode a turn leaves after publication and reload is the one the next
# turn starts from. Perception, routing, reduction, claim backing, publication,
# pending storage, reload, the runner summary and the rubric are the real code.
module Otis29Replay
  private

  def fixture
    self.class::FIXTURE
  end

  def allowed_documents
    Stage1Live::OTIS.map { |_uid, key| File.basename(key, ".pdf") }
  end


  # Set STAGE1_EVIDENCE_DIR to keep, per turn, the published text, the state a
  # reload reads and the verdict, for the flag in force.
  def record_evidence(rows)
    directory = ENV["STAGE1_EVIDENCE_DIR"].to_s
    return if directory.empty?

    mode = ENV["FIELD_CHECK_OUTCOME"].presence || "off"
    FileUtils.mkdir_p(directory)
    rows.each do |label, row|
      File.write(File.join(directory, "full-replay-#{mode}-#{label}.json"), JSON.pretty_generate(
        "label" => label, "flag" => mode, "published" => row[:published],
        "reloaded" => { "pending_question" => row[:reloaded].pending_question, "checks" => row[:reloaded].checks,
                        "observations" => row[:reloaded].observations,
                        "declared_unverified_codes" => Rag::DeclaredUnverified.open_codes(row[:reloaded]) },
        "claim_backing_removed" => row[:backing_removed],
        "verdict" => row[:summary].slice("accepted", "expected", "observed", "reason")
                       .merge("failed" => row[:summary].dig("rubric", "failed")),
        "live_run" => fixture.dig(label, "live").slice("accepted", "failed", "removed")
      ))
    end
  end

  def with_owner_mode
    previous = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    yield
  ensure
    previous.nil? ? ENV.delete("HAIKU_QUERY_ANALYSIS_MODE") : ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous
  end

  # One full pass over the script. The state is chained, never restored.
  def replay
    @replay ||= with_owner_mode do
      episode = nil
      rows = fixture.each_with_object({}) do |(label, turn), rows|
        now = Time.iso8601(turn.fetch("at"))
        travel_to(now) do
          episode ||= Rag::ActiveEpisode.parse(turn.fetch("episode_before"), now: now)
          before = Rag::ActiveEpisode.parse(episode.to_h, now: now)
          opened = label == "t1" ? nil : Rag::ActiveEpisode.parse(episode.to_h, now: now)
          reduce(turn, episode, now)
          context = reference_context(turn, episode)
          reduced = Rag::ActiveEpisode.parse(episode.to_h, now: now)
          result, removed = publish(turn, episode)
          stored = Rag::ActiveEpisodeTurn.apply_assistant(
            state: episode, text: result[:answer], correlation_id: turn.fetch("correlation_id"),
            pending_question: result[:pending_question], now: now
          ).state
          reloaded = Rag::ActiveEpisode.parse(stored, now: now)
          summary = summarize(turn, result, reloaded, opened)
          verdict = Stage1Live.send(:judge, turn.fetch("label"), opened, summary)
          summary.merge!(verdict)
          rows[label] = {
            result: result, published: result[:answer], reloaded: reloaded, summary: summary,
            episode_before: before, backing_removed: removed, context: context,
            episode_after_reduction: reduced
          }
          # The next turn starts from a copy of what was stored, so it cannot
          # change what this turn left.
          episode = Rag::ActiveEpisode.parse(stored, now: now)
        end
      end
      record_evidence(rows)
      rows
    end
  end

  def reduce(turn, episode, now)
    text = turn.fetch("message")
    perception = Rag::TurnPerception.build(
      turn.fetch("tool"), turn: text, episode: episode, catalog: nil, viewer_account: nil, require_work_change_evidence: true
    )
    assert perception.valid, perception.invalid_reason
    route = Rag::RoutePolicy.call(previous: episode, perception: perception, turn: text, focus_count: 1)
    Rag::WorkContextReducer.apply!(
      episode: episode, perception: perception, decision: route, turn: text,
      correlation_id: turn.fetch("correlation_id"), now: now
    )
  end

  # The reference line the generator receives, built on the reduced episode.
  def reference_context(turn, episode)
    BedrockRagService.allocate.send(
      :reference_context_text, nil, episode,
      documented_question: (episode.pending_question["question"] if episode.pending_question&.dig("type") == "documented_context"),
      raw_question: turn.fetch("message"), correlation_id: turn.fetch("correlation_id")
    )
  end

  def publish(turn, episode)
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_turn, true)
    service.instance_variable_set(:@citation_processor, Bedrock::CitationProcessor.new)
    removed = []
    service.define_singleton_method(:record_companion_claim_backing) { |backing| removed.concat(backing.removed.pluck("reason")) }
    pending = service.send(
      :controller_label_pending, episode, controller: episode.fact("controller"),
      documented_question: (episode.pending_question["question"] if episode.pending_question&.dig("type") == "documented_context"),
      incompatible: false, conv_session: nil, locale: :es
    )
    result = service.send(
      :finish_companion_turn_generation,
      question: turn.fetch("message"), raw_answer: turn.fetch("raw_draft"),
      chunks: chunks(turn), response_locale: :es, retrieval: {}, stop_reason: "end_turn",
      technician_texts: service.send(:companion_technician_texts, nil, episode, turn.fetch("message")),
      manufacturer: nil, correlation_id: turn.fetch("correlation_id"), reference_pending: pending,
      reference_mode: true, reference_confirmed: false, episode: episode
    )
    [ result, removed ]
  end

  # A citation [n] reads position n of the pack. The live pack had gaps (T3 and
  # T4 start at [2]: [1] was carried by the case and not delivered), so a gap
  # is a chunk with no text and nobody cites it.
  def chunks(turn)
    by_number = turn.fetch("sources").index_by { |source| source.fetch("n") }
    (1..by_number.keys.max).map do |number|
      source = by_number[number]
      next { content: "", case_number: number, metadata: {} } unless source

      {
        content: source.fetch("text"), location_uri: source.fetch("uri"), case_number: number,
        metadata: { "canonical_name" => source.fetch("title"), "page_number" => source.fetch("page"),
                    "original_filename" => "#{source.fetch('title')}.pdf",
                    "original_source_uri" => source.fetch("document_uri") }
      }
    end
  end

  # What the runner reads from the stored case, without the database.
  def summarize(turn, result, reloaded, opened)
    cid = turn.fetch("correlation_id")
    published = result[:answer]
    citations = Bedrock::CitationProcessor.new.transport_references(result[:citations]).map { |item| item.to_h.deep_stringify_keys }
    static = turn.dig("live", "static")
    {
      "label" => turn.fetch("label"), "correlation_id" => cid, "published" => published, "turn_status" => "completed",
      "pending" => reloaded.pending_question, "pending_before" => opened&.pending_question,
      "part_states" => Stage1Live.send(:part_states, reloaded),
      "checks" => reloaded.checks, "replies" => reloaded.replies,
      "asked_again" => Stage1Live.send(:asked_question, published),
      "citations" => citations, "identifiers" => reloaded.identifiers,
      "generator_sources" => turn.fetch("sources").to_h { |source| [ source.fetch("n").to_s, source.fetch("text").to_s ] },
      "photo_turns" => static["photo_turns"], "visible_text" => static["visible_text"], "photo" => static["photo"],
      "observations" => Stage1Live.send(:episode_texts, reloaded.observations, cid, same: true),
      "earlier_observations" => Stage1Live.send(:episode_texts, reloaded.observations, cid, same: false),
      "all_observations" => Array(reloaded.observations).map { |row| row["text"].to_s },
      "earlier_checks" => Array(reloaded.checks).reject { |row| row["correlation_id"] == cid }
    }
  end
end
