# frozen_string_literal: true

require "digest"

module Rag
  # Case file owned by code for one episode of the direct companion.
  # It stores the technician's literal turns only by reading them, the
  # passages cited in a published answer, and the turn outcome. It does not
  # store an applicability judgment: that stays on the fresh chunk and the
  # publication gate reads it on the turn that retrieved the chunk.
  class CompanionCaseRecord
    MAX_PASSAGES = 8
    MAX_PASSAGE_CHARS = 12_000
    SEPARATOR = "\n"
    MARKER = /\[(\d+)\]/
    PROVENANCE = "published_citation"

    Retrieval = Data.define(:text, :included, :omitted, :current_truncated)
    Recorded = Data.define(:state, :history_text, :ledger_full, :unresolved)

    class << self
      # Current turn, then the episode's first turn, then the rest from newest
      # to oldest. A turn is copied whole or left out. When the current turn
      # alone is longer than FollowupQueryRewriter::MAX_COMPOSED_CHARS, Retrieve
      # receives its leading characters, current_truncated is true, and every
      # other turn is omitted. The stored message is not cut here.
      def retrieval_text(session, raw_question, now: Time.current, correlation_id: nil)
        ordered = ordered_turns(session, raw_question, now, correlation_id)
        return Retrieval.new(text: "", included: [], omitted: [], current_truncated: false) if ordered.empty?

        compose_retrieval(ordered)
      end

      def retrieval_trace(retrieval)
        {
          "text" => retrieval.text.to_s,
          "included" => retrieval.included,
          "omitted" => retrieval.omitted,
          "current_truncated" => retrieval.current_truncated == true
        }
      end

      # Ledger passages keep the number of their first citation. Fresh chunks
      # that are not already in the ledger take the following numbers. A retired
      # number stays a gap so it cannot name a different passage.
      def sources(session, episode_id, fresh_chunks)
        align(episode_state(read_state(session), episode_id), Array(fresh_chunks))
      end

      def marker_numbers(session, episode_id)
        episode_state(read_state(session), episode_id)["sources"].map { |row| row["n"].to_i }
      end

      def column_revision(state)
        normalize(state)["revision"]
      end

      # outcome "abstained" keeps the passages and still advances the revision,
      # so a second writer that read the previous snapshot cannot commit.
      # A different episode_id starts from an empty passage list and keeps the
      # column revision as the optimistic token.
      def record(state:, episode_id:, chunks:, published_text:, correlation_id:, outcome:)
        stored = normalize(state)
        origin = stored["revision"]
        working = if episode_id.present? && stored["episode_id"] == episode_id.to_s
          stored.deep_dup
        else
          empty_state(episode_id).merge("revision" => origin)
        end
        if outcome.to_s == "abstained"
          working["revision"] = origin + 1
          return Recorded.new(state: working, history_text: nil, ledger_full: working["ledger_full"] == true, unresolved: [])
        end

        unresolved = []
        marker_sequence(published_text).each do |number|
          next if working["sources"].any? { |row| row["n"].to_i == number }

          chunk = chunks[number - 1]
          if chunk.nil? || gap?(chunk)
            unresolved << number
            next
          end

          entry = entry_for(chunk, number, correlation_id)
          if room_for?(working, entry)
            working["sources"] << entry
          else
            working["ledger_full"] = true
            working["retired"] = (Array(working["retired"]) + [ number ]).uniq.sort
            unresolved << number
          end
        end
        working["revision"] = origin + 1
        kept = working["sources"].map { |row| row["n"].to_i }
        Recorded.new(
          state: working,
          history_text: history_copy(published_text, kept),
          ledger_full: working["ledger_full"] == true,
          unresolved: unresolved
        )
      end

      def episode_id_of(episode)
        return nil if episode.nil?
        return episode.episode_id if episode.respond_to?(:episode_id)

        episode["episode_id"] || episode[:episode_id] if episode.is_a?(Hash)
      end

      def technician_text(message)
        return "" unless message.is_a?(Hash)

        message["full_content"].presence || message["content"].to_s
      end

      def gap?(chunk)
        value(chunk, :case_gap) == true
      end

      def number_of(chunk, index = nil)
        number = value(chunk, :case_number)
        return number.to_i unless number.nil?
        return nil if index.nil?

        index + 1
      end

      def text_of(chunk)
        value(chunk, :content).to_s
      end

      def digest(text)
        Digest::SHA256.hexdigest(text.to_s)
      end

      private

      def compose_retrieval(ordered)
        limit = FollowupQueryRewriter::MAX_COMPOSED_CHARS
        current = ordered.first
        return truncated_current(current, ordered.drop(1), limit) if current["text"].length > limit

        included = []
        omitted = []
        parts = []
        used = 0
        ordered.each do |turn|
          text = turn["text"]
          extra = parts.empty? ? 0 : SEPARATOR.length
          if used + extra + text.length <= limit
            parts << text
            used += extra + text.length
            included << { "correlation_id" => turn["correlation_id"], "chars" => text.length, "truncated" => false }
          else
            omitted << { "correlation_id" => turn["correlation_id"], "chars" => text.length, "reason" => "budget" }
          end
        end
        Retrieval.new(text: parts.join(SEPARATOR), included: included, omitted: omitted, current_truncated: false)
      end

      def truncated_current(current, others, limit)
        full = current["text"]
        text = full[0, limit]
        omitted = [ {
          "correlation_id" => current["correlation_id"],
          "chars" => full.length - text.length,
          "reason" => "current_over_limit"
        } ]
        others.each do |turn|
          omitted << {
            "correlation_id" => turn["correlation_id"],
            "chars" => turn["text"].length,
            "reason" => "current_over_limit"
          }
        end
        Retrieval.new(
          text: text,
          included: [ {
            "correlation_id" => current["correlation_id"],
            "chars" => text.length,
            "total_chars" => full.length,
            "truncated" => true
          } ],
          omitted: omitted,
          current_truncated: true
        )
      end

      def ordered_turns(session, raw_question, now, correlation_id)
        turns = user_turns(session, now)
        current = select_current(turns, raw_question, correlation_id)
        if current.nil?
          text = raw_question.to_s
          return [] if text.blank?

          current = { "correlation_id" => correlation_id.to_s, "text" => text, "synthetic" => true }
        else
          current = prefer_original(current, raw_question)
        end
        first = turns.first
        rest = turns.reverse.reject { |turn| same_turn?(turn, current) || same_turn?(turn, first) }
        list = []
        list << current if current["text"].present?
        list << first if first && !same_turn?(first, current)
        rest.each { |turn| list << turn }
        list
      end

      def prefer_original(current, raw_question)
        original = raw_question.to_s
        stored = current["text"].to_s
        return current if original.blank? || original.length <= stored.length
        return current.merge("text" => original) if original.start_with?(stored)

        prefix = stored.sub(/(?:\.{3}|…)\z/, "")
        return current if prefix.empty? || prefix == stored
        return current unless original.start_with?(prefix)

        current.merge("text" => original)
      end

      def select_current(turns, raw_question, correlation_id)
        if correlation_id.present?
          found = turns.find { |turn| turn["correlation_id"] == correlation_id.to_s }
          return found if found
        end
        needle = raw_question.to_s.strip
        return nil if needle.empty?

        turns.reverse.find { |turn| turn["text"].strip == needle }
      end

      def user_turns(session, now)
        return [] unless session.respond_to?(:conversation_history)

        cutoff = session.episode_history_cutoff(now) if session.respond_to?(:episode_history_cutoff)
        Array(session.conversation_history).filter_map do |message|
          next unless message.is_a?(Hash) && message["role"].to_s == "user"

          ts = parse_time(message["ts"])
          next if ts.nil? || (cutoff && ts < cutoff) || ts > now

          text = technician_text(message)
          next if text.strip.empty?

          { "correlation_id" => message["correlation_id"].to_s, "text" => text }
        end
      end

      def same_turn?(left, right)
        return false if left.nil? || right.nil?
        return true if left.equal?(right)

        left_id = left["correlation_id"].to_s
        right_id = right["correlation_id"].to_s
        left_id.present? && left_id == right_id
      end

      def align(state, fresh_chunks)
        sources = state["sources"]
        retired = state["retired"]
        max_number = [ sources.map { |row| row["n"].to_i }.max.to_i, retired.max.to_i ].max
        slots = Array.new(max_number)
        sources.each do |row|
          number = row["n"].to_i
          slots[number - 1] = ledger_chunk(row) if number.positive?
        end
        retired.each do |number|
          slots[number - 1] ||= gap_chunk(number) if number.positive?
        end
        slots.map!.with_index { |slot, index| slot || gap_chunk(index + 1) } if max_number.positive?
        known = sources.map { |row| [ row["location_uri"].to_s, row["sha256"].to_s ] }
        next_number = max_number
        fresh_chunks.each do |chunk|
          next if gap?(chunk)

          identity = [ uri_of(chunk), digest(text_of(chunk)) ]
          next if known.include?(identity)

          next_number += 1
          known << identity
          slots << annotate(chunk, next_number, "fresh")
        end
        slots
      end

      def ledger_chunk(row)
        metadata = {}
        metadata["page_number"] = row["page"] unless row["page"].nil?
        filename = File.basename(row["location_uri"].to_s)
        metadata["original_filename"] = filename if filename.present? && filename != "." && filename != "/"
        {
          content: row["text"].to_s,
          location_uri: row["location_uri"].to_s,
          metadata: metadata,
          chunk_sha256: row["sha256"].to_s,
          case_number: row["n"].to_i,
          case_origin: "ledger",
          case_provenance: row["provenance"].to_s
        }
      end

      def gap_chunk(number)
        {
          content: "",
          case_gap: true,
          case_number: number,
          case_origin: "retired",
          identity_applicability: "reference_only"
        }
      end

      def annotate(chunk, number, origin)
        copy = chunk.dup
        copy[:case_number] = number
        copy[:case_origin] = origin
        copy[:chunk_sha256] = digest(text_of(copy))
        copy
      end

      def entry_for(chunk, number, correlation_id)
        text = text_of(chunk)
        {
          "n" => number,
          "location_uri" => uri_of(chunk),
          "page" => page_of(chunk),
          "sha256" => digest(text),
          "text" => text,
          "first_cid" => correlation_id.to_s,
          "provenance" => PROVENANCE
        }
      end

      def room_for?(state, entry)
        return false if state["ledger_full"] == true
        return false if state["sources"].size >= MAX_PASSAGES

        used = state["sources"].sum { |row| row["text"].to_s.length }
        used + entry["text"].to_s.length <= MAX_PASSAGE_CHARS
      end

      def history_copy(text, kept)
        kept_numbers = kept.each_with_object({}) { |number, map| map[number] = true }
        text.to_s.gsub(MARKER) { |marker| kept_numbers[Regexp.last_match(1).to_i] ? marker : "" }
      end

      def marker_sequence(text)
        seen = []
        text.to_s.scan(MARKER) do
          number = Regexp.last_match(1).to_i
          seen << number unless seen.include?(number)
        end
        seen
      end

      def episode_state(state, episode_id)
        normalized = normalize(state)
        return empty_state(episode_id) if episode_id.blank? || normalized["episode_id"] != episode_id.to_s

        normalized
      end

      def empty_state(episode_id)
        {
          "episode_id" => episode_id.to_s,
          "revision" => 0,
          "ledger_full" => false,
          "retired" => [],
          "sources" => []
        }
      end

      def read_state(session)
        return {} unless session.respond_to?(:case_evidence)

        session.case_evidence
      end

      def normalize(state)
        raw = state.is_a?(Hash) ? state.deep_stringify_keys : {}
        {
          "episode_id" => raw["episode_id"].to_s,
          "revision" => raw["revision"].to_i,
          "ledger_full" => raw["ledger_full"] == true,
          "retired" => Array(raw["retired"]).map(&:to_i).select(&:positive?).uniq.sort,
          "sources" => Array(raw["sources"]).filter_map { |row| source_row(row) }
        }
      end

      def source_row(row)
        return nil unless row.is_a?(Hash)

        item = row.deep_stringify_keys
        number = item["n"].to_i
        return nil if number < 1

        {
          "n" => number,
          "location_uri" => item["location_uri"].to_s,
          "page" => item.key?("page") ? item["page"] : nil,
          "sha256" => item["sha256"].to_s,
          "text" => item["text"].to_s,
          "first_cid" => item["first_cid"].to_s,
          "provenance" => item["provenance"].to_s
        }
      end

      def page_of(chunk)
        metadata = value(chunk, :metadata)
        return nil unless metadata.respond_to?(:[])

        page = metadata["page_number"]
        page = metadata[:page_number] if page.nil?
        page.presence
      end

      def uri_of(chunk)
        value(chunk, :location_uri).to_s
      end

      def value(chunk, key)
        return nil unless chunk.is_a?(Hash)

        chunk[key] || chunk[key.to_s] || chunk[key.to_sym]
      end

      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue StandardError
        nil
      end
    end
  end
end
