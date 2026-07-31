# frozen_string_literal: true

require "set"

module Rag
  # Enforces the [n] numbering contract for a single-evidence generation window.
  #
  # [n] is the 1-based index of an evidence block handed to the generator. With
  # exactly one block the target set has cardinality 1, so a marker can only mean
  # that block — collapsing [2]/[3] to [1] cannot attribute a claim to evidence
  # that does not contain it, because no other evidence was supplied.
  # Rag::AnswerSafetyProcessor still validates every claim against that same
  # block, so normalization launders nothing.
  #
  # With two or more blocks nothing is remapped:
  # Rag::StructuredEvidenceRoute#valid_citations? keeps abstaining on a genuinely
  # ambiguous marker.
  #
  # A manual can print a literal bracketed number ("borne [24]") that is document
  # content, not an attribution marker — the same hazard
  # Bedrock::CitationProcessor#strip_resolved_markers already documents. Any n
  # printed literally in the evidence body is left untouched, so an out-of-range
  # literal still fails the citation gate instead of being laundered into [1].
  class CitationMarkerNormalizer
    MARKER = /\[(\d+)\]/.freeze
    SOLE_EVIDENCE_MARKER = "[1]"

    def self.call(text, evidence_count:, evidence_text:)
      return text unless Rag::CitationAttributionContractFlag.enabled?
      return text if text.blank?
      return text unless evidence_count == 1

      literals = evidence_text.to_s.scan(MARKER).flatten.map(&:to_i).to_set
      normalized = text.gsub(MARKER) do
        literals.include?(Regexp.last_match(1).to_i) ? Regexp.last_match(0) : SOLE_EVIDENCE_MARKER
      end
      collapse_runs(normalized)
    end

    # "[1][1]" / "[1] [1]" inside one contiguous run is one attribution, not two.
    def self.collapse_runs(text)
      text.gsub(/\[1\](?:[ \t]*\[1\])+/, SOLE_EVIDENCE_MARKER)
    end
    private_class_method :collapse_runs
  end
end
