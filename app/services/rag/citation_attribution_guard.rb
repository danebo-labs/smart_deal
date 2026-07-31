# frozen_string_literal: true

require "set"

module Rag
  # Deterministic family/model attribution for answers that carry [n] markers.
  #
  # Bedrock's own spans place each marker at the END of the passage it attributes
  # (Bedrock::CitationProcessor#add_span_citations), so the text between two
  # marker runs is exactly the passage the second run cites. A segment whose
  # markers resolve only to section identities the question does not name is not
  # attributable and is removed.
  #
  # The candidate set is CLOSED to the section identities actually cited in this
  # turn — never a global manufacturer-name regex. With fewer than two cited
  # identities, or with no identity the question names, the guard is inert: a
  # question that is not family-scoped cannot be transplanted across families.
  #
  # Document filtering is not a substitute: one PDF in this corpus carries 14+
  # section identities, and Rag::EvidenceCandidateSelector#family_excluded? only
  # protects the (disabled) selector path.
  class CitationAttributionGuard
    MARKER_RUN = /(?:\[\d+\])+/.freeze
    MIN_IDENTITY_CHARS = 3
    # Bounds the generated pattern; a longer identity fails identification and
    # leaves the guard inert rather than building an unbounded regex.
    MAX_IDENTITY_CHARS = 64
    SEPARATOR_CLASS = "[\\s\\-._]*"

    Result = Data.define(:answer, :dropped_segments, :anchors, :identities) do
      def dropped_any?
        dropped_segments.any?
      end

      def attributed_claims?
        answer.to_s.match?(/\[\d+\]/)
      end
    end

    # Accent-folded, separator-tolerant containment: "THYSSEN" matches
    # "En Thyssen-E, …" and "CARLOS SILVA" matches "Carlos Silva", while "OTIS"
    # matches neither. Same technique as
    # Rag::StructuredEvidenceRoute#identifier_present? — duplicated on purpose so
    # this iteration touches neither the route's predicate nor the selector.
    def self.names?(text, identity)
      characters = identity.to_s.scan(/[[:alnum:]]/)
      return false unless characters.size.between?(MIN_IDENTITY_CHARS, MAX_IDENTITY_CHARS)

      pattern = characters.map { |character| Regexp.escape(character) }.join(SEPARATOR_CLASS)
      fold(text).match?(/(?<![[:alnum:]_])#{pattern}(?![[:alnum:]_])/i)
    end

    def self.fold(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "")
    rescue StandardError
      text.to_s
    end
    private_class_method :fold

    # @param citations [Array<Hash>] the SAME ordered list
    #   Bedrock::CitationProcessor#build_numbered_references indexes: the
    #   #extract_citations output on the generic path, #citation_shaped on the
    #   structured route. Marker n resolves to citations[n - 1] (I7).
    def initialize(question:, citations:)
      @question = question.to_s
      @citations = Array(citations)
    end

    def call(answer)
      text = answer.to_s
      return inert(text) unless Rag::CitationAttributionContractFlag.enabled?
      return inert(text) if text.blank?

      identity_by_number = build_identity_index
      identities = identity_by_number.values.uniq
      return inert(text, identities: identities) if identities.size < 2

      anchors = identities.select { |identity| self.class.names?(@question, identity) }
      if anchors.empty?
        Rails.logger.info(
          "Rag::CitationAttributionGuard: anchor_missing identities=#{identities.inspect}"
        )
        return inert(text, identities: identities)
      end

      segments = split_segments(text)
      foreign = segments.each_index.select do |index|
        foreign_segment?(segments[index], identity_by_number, anchors)
      end
      return inert(text, identities: identities, anchors: anchors) if foreign.empty?

      Result.new(
        answer: rejoin(segments, foreign),
        dropped_segments: foreign.map { |index| segments[index][:text] },
        anchors: anchors,
        identities: identities
      )
    end

    private

    def inert(text, identities: [], anchors: [])
      Result.new(answer: text, dropped_segments: [], anchors: anchors, identities: identities)
    end

    def build_identity_index
      @citations.each_with_index.each_with_object({}) do |(citation, index), resolved|
        metadata = (citation[:metadata] || citation["metadata"] || {}).to_h.stringify_keys
        identity = metadata["section_identity"].presence
        resolved[index + 1] = identity if identity
      end
    end

    # Segment k spans from the end of marker run k-1 through the end of marker run
    # k. The trailing remainder carries no markers and is always kept: an
    # uncited tail (the DATA_NOT_AVAILABLE contract) is not an attributed claim.
    def split_segments(text)
      segments = []
      cursor = 0
      text.scan(MARKER_RUN) do
        match = Regexp.last_match
        segments << {
          text: text[cursor...match.end(0)],
          numbers: match[0].scan(/\d+/).map(&:to_i)
        }
        cursor = match.end(0)
      end
      segments << { text: text[cursor..].to_s, numbers: [] } if cursor < text.length
      segments
    end

    # Unknown is never foreign (I10): a marker with no citation entry, or whose
    # citation carries no section_identity, leaves its segment attributable.
    # A mixed run ([1][3]) that names an anchor is kept.
    def foreign_segment?(segment, identity_by_number, anchors)
      return false if segment[:numbers].empty?

      resolved = segment[:numbers].filter_map { |number| identity_by_number[number] }.uniq
      resolved.any? && (resolved & anchors).empty?
    end

    def rejoin(segments, foreign_indexes)
      dropped = foreign_indexes.to_set
      kept = segments.each_index.reject { |index| dropped.include?(index) }
      kept.each_with_object(+"") do |index, output|
        piece = segments[index][:text]
        piece = repair_seam(output, piece) if index.positive? && dropped.include?(index - 1)
        output << piece
      end
    end

    # One bounded repair per seam, applied only at a seam: a sentence that already
    # closed on the left must not gain a second terminator from the right, and a
    # dropped paragraph must not leave a triple newline behind. Deliberately NOT a
    # global punctuation cleanup — an ellipsis or "?!" elsewhere is untouched.
    def repair_seam(left, right)
      repaired = right
      if left.match?(/[.!?;:][ \t]*\z/)
        repaired = repaired.sub(/\A\s*[.!?;:]/) { |match| match.delete(".!?;:") }
      end
      repaired.sub(/\A\n{3,}/, "\n\n")
    end
  end
end
