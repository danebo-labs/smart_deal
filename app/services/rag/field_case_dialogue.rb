# frozen_string_literal: true

module Rag
  # One row per stored field turn. The published message, answer, citations
  # and checkpoint come from field_turns. The technical trace is joined by
  # correlation_id and does not replace that text.
  class FieldCaseDialogue
    DEVICE_NOTE = "El campo de dispositivo solo dice web; no distingue escritorio de móvil."
    CHANGE_KEYS = %w[goal identifiers facts observations rejected pending_question episode].freeze

    def self.call(range:, user_ids:, traces:)
      new(range: range, user_ids: user_ids, traces: traces).call
    end

    def initialize(range:, user_ids:, traces:)
      @range = range
      @user_ids = Array(user_ids).filter_map { |value| Integer(value, exception: false) }.uniq
      @traces = Array(traces).index_by { |turn| turn[:correlation_id].to_s }
    end

    def call
      load_turns.group_by(&:field_case_id).map { |_case_id, rows|
        kase = rows.first.field_case
        {
          field_case_id: kase.id,
          episode_id: kase.episode_id,
          account_id: kase.account_id,
          user_id: kase.user_id,
          device_channel: "web",
          device_distinction: "uncaptured",
          device_note: DEVICE_NOTE,
          turns: rows.sort_by(&:sequence).map { |turn| export_turn(kase, turn) }
        }
      }.sort_by { |thread| thread[:field_case_id] }
    end

    def correlation_ids
      @correlation_ids ||= load_turns.map(&:correlation_id).to_set
    end

    private

    def load_turns
      @turns ||= begin
        scope = FieldTurn.joins(:field_case).includes(:field_case).where(admitted_at: @range)
        scope = scope.where(field_cases: { user_id: @user_ids }) if @user_ids.any?
        scope.order(:field_case_id, :sequence).to_a
      end
    end

    def export_turn(kase, turn)
      response = turn.response.is_a?(Hash) ? turn.response : {}
      {
        field_case_id: kase.id,
        episode_id: kase.episode_id,
        field_turn_id: turn.id,
        sequence: turn.sequence,
        correlation_id: turn.correlation_id,
        status: turn.status,
        attempt: turn.attempt,
        message: turn.message,
        published_text: response["published_text"],
        citations: Array(response["citations"]),
        checkpoint: turn.checkpoint || {},
        trace: linked_trace(@traces[turn.correlation_id.to_s], turn)
      }
    end

    def missing_trace
      {
        status: "missing",
        attempts: [],
        uncaptured: %w[entry interpretation query evidence publication],
        note: "No hay captura para este correlation_id. El diálogo guardado se conserva."
      }
    end

    def linked_trace(trace, turn)
      events = events_for(turn.correlation_id)
      attempts = (capture_attempts(turn.correlation_id) + events.filter_map { |event| event["attempt"] } + [ turn.attempt ]).uniq
      if events.empty? && trace.nil?
        return missing_trace
      end

      {
        status: events.empty? ? "partial" : "linked",
        attempts: attempts,
        entry: entry_layer(events, turn),
        interpretation: interpretation_layer(events, turn),
        query: query_layer(events),
        evidence: evidence_layer(events),
        publication: publication_layer(events, turn)
      }
    end

    def events_for(correlation_id)
      matching_captures(correlation_id).flat_map { |row|
        Array(row.payload["events"]).filter_map { |event|
          next unless event.is_a?(Hash)
          next if event["correlation_id"].present? && event["correlation_id"] != correlation_id

          event.merge("attempt" => event["attempt"] || row.attempt)
        }
      }.sort_by { |event| [ event["attempt"].to_i, event["sequence"].to_i ] }
    end

    def matching_captures(correlation_id)
      captures.select { |row|
        row.correlation_id == correlation_id || Array(row.payload["events"]).any? { |event|
          event.is_a?(Hash) && event["correlation_id"] == correlation_id
        }
      }
    end

    def capture_attempts(correlation_id)
      matching_captures(correlation_id).filter_map(&:attempt)
    end

    def captures
      @captures ||= begin
        scope = FieldCompanionTrace.where(kind: "capture", occurred_at: @range)
        ids = account_ids
        scope = scope.where(account_id: ids) if ids.any?
        scope.order(:attempt, :occurred_at, :id).to_a
      end
    end

    def account_ids
      return [] if @user_ids.empty?

      User.where(id: @user_ids).distinct.pluck(:account_id)
    end

    def entry_layer(events, turn)
      request = events.find { |event| event["kind"] == "interpreter_request" }
      structured = request.is_a?(Hash) ? request["structured"] : nil
      input = structured.is_a?(Hash) && structured.present? ? structured : request&.dig("message_text")
      {
        message: turn.message,
        interpreter_input: input,
        provenance: input.present? ? "observed" : "uncaptured",
        uncaptured: input.present? ? [] : [ "interpreter_input" ]
      }
    end

    def interpretation_layer(events, turn)
      raw = events.find { |event| event["kind"] == "interpreter_raw" }
      applied = events.select { |event| event["kind"] == "perception_applied" }
      delta = events.find { |event| event["kind"] == "episode_delta" }
      observed = delta&.dig("episode_after")
      missing = []
      missing << "interpreter_output" unless raw
      missing << "rules_applied" if applied.empty?
      missing << "state_observed" unless observed.is_a?(Hash)
      {
        interpreter_output: raw&.dig("tool_input") || raw&.dig("output"),
        rules: applied,
        episode_before: delta&.dig("episode_before"),
        changes: delta.is_a?(Hash) ? delta.slice(*CHANGE_KEYS) : nil,
        observed_state: observed,
        saved_checkpoint: turn.checkpoint || {},
        checkpoint_matches_observed: observed.is_a?(Hash) ? checkpoint_match?(observed, turn.checkpoint) : "uncaptured",
        provenance: missing.empty? ? "observed" : "partial",
        uncaptured: missing
      }
    end

    def query_layer(events)
      steps = events.select { |event| %w[effective_query retrieve companion_turn_retrieve].include?(event["kind"]) }
      rewrites = events.select { |event| event["kind"] == "query_rewrite" }
      {
        steps: steps.map { |event| query_step(event) },
        rewrites: rewrites,
        provenance: steps.any? ? "observed" : "uncaptured",
        uncaptured: rewrites.any? ? [] : [ "query_rewrite" ]
      }
    end

    def query_step(event)
      {
        kind: event["kind"],
        sequence: event["sequence"],
        attempt: event["attempt"],
        sent_turn: event["sent_turn"],
        composed: event["composed"],
        effective: event["effective"] || event["retrieval_query_text"] || retrieval_text(event) || event["query"],
        filter: query_filter(event),
        components: event["components"]
      }.compact
    end

    def retrieval_text(event)
      query = event["retrieval_query"]
      return unless query.is_a?(Hash)

      query["text"].presence
    end

    def query_filter(event)
      return event["filter"] if event.key?("filter")
      return event["filter_fingerprint"] if event["filter_fingerprint"].present?

      event.dig("retrieval_configuration", "vector_search_configuration", "filter")
    end

    def evidence_layer(events)
      retrieved = events.select { |event| event["kind"] == "retrieval_results" }
      rerank = events.select { |event| event["kind"] == "companion_rerank" }
      delivered = events.select { |event| %w[companion_sources generator_evidence].include?(event["kind"]) }
      missing = []
      missing << "retrieved_chunks" if retrieved.empty?
      missing << "rerank" if rerank.empty?
      missing << "generator_evidence" if delivered.empty?
      {
        retrieved: retrieved,
        rerank: rerank,
        delivered_to_generator: delivered,
        pages: pages_of(delivered),
        provenance: missing.empty? ? "observed" : "partial",
        uncaptured: missing
      }
    end

    def publication_layer(events, turn)
      model = events.find { |event| event["kind"] == "companion_direct" }
      backing = events.select { |event| event["kind"] == "companion_claim_backing" }
      published = events.find { |event| event["kind"] == "companion_publication" }
      missing = []
      missing << "model_output" unless model
      missing << "citation_guard" if backing.empty? && published.nil?
      {
        model_output: model&.dig("text"),
        citation_guard: backing,
        publication_decision: published,
        published_text: turn.response.is_a?(Hash) ? turn.response["published_text"] : nil,
        citations: turn.response.is_a?(Hash) ? Array(turn.response["citations"]) : [],
        provenance: "field_turn",
        uncaptured: missing
      }
    end

    def pages_of(events)
      events.flat_map { |event|
        Array(event["kept"]).filter_map { |row| row["page"] if row.is_a?(Hash) } +
          Array(event["passages"]).filter_map { |row| row["page"] if row.is_a?(Hash) }
      }.uniq
    end

    def checkpoint_match?(observed, checkpoint)
      left = stringify(observed).except("case_evidence", "updated_at")
      right = stringify(checkpoint || {}).except("case_evidence", "updated_at")
      left == right
    end

    def stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), copy| copy[key.to_s] = stringify(item) }
      when Array
        value.map { |item| stringify(item) }
      else
        value
      end
    end
  end
end
