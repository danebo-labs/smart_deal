# frozen_string_literal: true

require "digest"

module Rag
  # Deterministic line-based parser for canonical FIELD_RECORD blocks embedded
  # in KB chunks (written by BatchResultsParserService#render_field_record).
  #
  # Strictness contract (benchmark plan, Fase 6):
  #   - a block starts at a line equal to "FIELD_RECORD:" and ends at
  #     "END_FIELD_RECORD"; a block left open (EOF or a new "FIELD_RECORD:"
  #     before END) is invalid;
  #   - every line inside a block must be "<KNOWN_LABEL>: <value>";
  #     unknown labels or duplicate labels invalidate the record;
  #   - mandatory labels: RECORD_ID, SOURCE_SECTION_OR_PAGE, RECORD_TYPE,
  #     ACTION, EXPECTED_RESULT, EVIDENCE;
  #   - STOP_WORK_TRIGGER and STOP_WORK_REQUIRED_ACTION must appear as a
  #     complete pair or not at all;
  #   - nothing is inferred from narrative outside blocks;
  #   - the parser NEVER consults any corpus-specific manifest.
  #
  # Ledger semantics across chunks (parse_chunks):
  #   - exact physical duplicates (same RECORD_ID + identical field content)
  #     are deduplicated, keeping every provenance (rank/uri/chunk hash);
  #   - the same RECORD_ID with DIFFERENT content is a ledger-level conflict
  #     that invalidates the whole ledger (callers must fail safe).
  class FieldRecordParser
    BLOCK_START = "FIELD_RECORD:"
    BLOCK_END   = "END_FIELD_RECORD"

    MANDATORY_LABELS = %w[
      RECORD_ID SOURCE_SECTION_OR_PAGE RECORD_TYPE ACTION EXPECTED_RESULT EVIDENCE
    ].freeze
    OPTIONAL_LABELS = %w[
      DETAILS STOP_WORK_TRIGGER STOP_WORK_REQUIRED_ACTION REPAIR_AUTHORITY UNCERTAINTY
    ].freeze
    KNOWN_LABELS = (MANDATORY_LABELS + OPTIONAL_LABELS).freeze

    LABEL_TO_ATTRIBUTE = {
      "RECORD_ID"                 => :record_id,
      "SOURCE_SECTION_OR_PAGE"    => :source,
      "RECORD_TYPE"               => :type,
      "ACTION"                    => :action,
      "EXPECTED_RESULT"           => :expected_result,
      "DETAILS"                   => :details,
      "STOP_WORK_TRIGGER"         => :stop_trigger,
      "STOP_WORK_REQUIRED_ACTION" => :stop_action,
      "REPAIR_AUTHORITY"          => :repair_authority,
      "UNCERTAINTY"               => :uncertainty,
      "EVIDENCE"                  => :evidence
    }.freeze

    Record = Struct.new(
      :record_id, :type, :source, :action, :expected_result, :details,
      :stop_trigger, :stop_action, :repair_authority, :uncertainty, :evidence,
      :rank, :uri, :chunk_sha256, :provenances,
      keyword_init: true
    ) do
      # Field content only — provenance excluded, so physically identical
      # records from different chunks compare equal.
      def content_fingerprint
        Digest::SHA256.hexdigest(
          [ record_id, type, source, action, expected_result, details,
            stop_trigger, stop_action, repair_authority, uncertainty, evidence ].join("")
        )
      end

      def stop_work?
        type == "STOP_WORK_CONDITION"
      end
    end

    InvalidRecord = Struct.new(:reason, :lines, :uri, :rank, :chunk_sha256, keyword_init: true)

    Ledger = Struct.new(:records, :invalid_records, :conflicting_ids, keyword_init: true) do
      def valid?
        invalid_records.empty? && conflicting_ids.empty?
      end

      def record_ids
        records.map(&:record_id)
      end
    end

    # @param text [String] one chunk body
    # @return [Hash] { records: [Record], invalid: [InvalidRecord] }
    def self.parse_text(text, uri: nil, rank: nil, chunk_sha256: nil)
      new.parse_text(text, uri: uri, rank: rank, chunk_sha256: chunk_sha256)
    end

    # @param chunks [Array<Hash>] entries from BedrockRagService#retrieve_chunks
    #   (keys :content, :rank, :original_source_uri / :location_uri, :chunk_sha256)
    #   or any hash with the same keys (ingestion evaluator).
    # @return [Ledger]
    def self.parse_chunks(chunks)
      new.parse_chunks(chunks)
    end

    def parse_chunks(chunks)
      records = []
      invalid = []

      Array(chunks).each do |chunk|
        chunk = chunk.transform_keys(&:to_sym)
        result = parse_text(
          chunk[:content] || chunk[:text],
          uri:          chunk[:original_source_uri] || chunk[:location_uri] || chunk[:uri],
          rank:         chunk[:rank],
          chunk_sha256: chunk[:chunk_sha256] || (chunk[:content] && Digest::SHA256.hexdigest(chunk[:content]))
        )
        records.concat(result[:records])
        invalid.concat(result[:invalid])
      end

      deduped, conflicting = dedupe_and_detect_conflicts(records)
      Ledger.new(records: deduped, invalid_records: invalid, conflicting_ids: conflicting)
    end

    def parse_text(text, uri: nil, rank: nil, chunk_sha256: nil)
      records = []
      invalid = []
      block   = nil

      text.to_s.each_line do |raw_line|
        line = raw_line.chomp.strip

        if line == BLOCK_START
          if block
            invalid << invalid_record("unterminated block (new FIELD_RECORD before END)", block, uri, rank, chunk_sha256)
          end
          block = []
          next
        end

        next unless block

        if line == BLOCK_END
          record, reason = build_record(block, uri: uri, rank: rank, chunk_sha256: chunk_sha256)
          if record
            records << record
          else
            invalid << invalid_record(reason, block, uri, rank, chunk_sha256)
          end
          block = nil
        else
          block << line
        end
      end

      invalid << invalid_record("unterminated block (EOF before END)", block, uri, rank, chunk_sha256) if block

      { records: records, invalid: invalid }
    end

    private

    def invalid_record(reason, lines, uri, rank, chunk_sha256)
      InvalidRecord.new(reason: reason, lines: Array(lines).dup, uri: uri, rank: rank, chunk_sha256: chunk_sha256)
    end

    # @return [record, nil] or [nil, reason]
    def build_record(lines, uri:, rank:, chunk_sha256:)
      values = {}

      lines.each do |line|
        next if line.empty?

        label, _, value = line.partition(": ")
        unless KNOWN_LABELS.include?(label)
          return [ nil, "unknown or malformed line: #{line.truncate(80)}" ]
        end
        return [ nil, "duplicate label #{label}" ] if values.key?(label)
        return [ nil, "empty value for #{label}" ] if value.strip.empty?

        values[label] = value.strip
      end

      missing = MANDATORY_LABELS.reject { |label| values.key?(label) }
      return [ nil, "missing #{missing.join(', ')}" ] if missing.any?

      if values.key?("STOP_WORK_TRIGGER") ^ values.key?("STOP_WORK_REQUIRED_ACTION")
        return [ nil, "incomplete stop-work pair" ]
      end

      attributes = values.each_with_object({}) do |(label, value), memo|
        memo[LABEL_TO_ATTRIBUTE.fetch(label)] = value
      end

      record = Record.new(
        **attributes,
        rank: rank,
        uri: uri,
        chunk_sha256: chunk_sha256,
        provenances: [ { rank: rank, uri: uri, chunk_sha256: chunk_sha256 } ]
      )
      [ record, nil ]
    end

    def dedupe_and_detect_conflicts(records)
      conflicting = []
      grouped = records.group_by(&:record_id)

      deduped = grouped.filter_map do |record_id, group|
        fingerprints = group.map(&:content_fingerprint).uniq
        if fingerprints.size > 1
          conflicting << record_id
          next
        end

        canonical = group.first
        canonical.provenances = group.flat_map(&:provenances).uniq
        canonical
      end

      [ deduped, conflicting.sort ]
    end
  end
end
