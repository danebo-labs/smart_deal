# frozen_string_literal: true

module Rag
  # Detects, from the retrieved evidence alone, that the identifier a question
  # asks about means different things on different boards.
  #
  # "¿A qué serie corresponde el LED SPM?" has three documented answers (Carlos
  # Silva TPR50 p. 9, Sistel Twister p. 88, Sistel Delta+ p. 91), so a confident
  # single-family answer can send a technician to the wrong board. A lexical gate
  # cannot see this: "LED DL2" reads as an explicitly scoped question
  # (Rag::DeterministicIntent::EXPLICIT_EQUIPMENT_PATTERN) even though DL2 is
  # "SERIE CERROJOS CERRADA" on ALJO (p. 3-6) and "SERIE PUERTAS EXTERIORES -
  # CABINA" on KDT 11 (p. 13). The signal is therefore the evidence in hand: one
  # identifier, two or more boards, and no board named in the question.
  class FamilyAmbiguityDetector
    MIN_BOARDS = 2

    Result = Data.define(:ambiguous?, :identifier, :board_keys, :chunks_by_board)

    NOT_AMBIGUOUS = Result.new(
      ambiguous?: false, identifier: nil, board_keys: [], chunks_by_board: {}
    ).freeze

    def call(question_analysis:, chunks:)
      keyed = keyed_chunks(chunks)
      return NOT_AMBIGUOUS if keyed.size < MIN_BOARDS

      question = question_analysis.question.to_s
      covering_identifiers(question_analysis).each do |identifier|
        boards = boards_for(identifier, keyed)
        next if boards.size < MIN_BOARDS
        next if boards.keys.any? { |board| Rag::BoardHeading.mentioned?(board, question) }

        return Result.new(
          ambiguous?: true,
          identifier: identifier.canonical,
          board_keys: boards.keys,
          chunks_by_board: boards
        )
      end

      NOT_AMBIGUOUS
    end

    private

    def boards_for(identifier, keyed)
      keyed
        .select { |_board, chunk| Rag::QueryEntities.identifier_present?(chunk[:content], identifier.canonical) }
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }
    end

    # Per board, not per family: Twister (p. 88) and Delta+ (p. 91) share
    # `section_identity` "SISTEL" and still give SPM two different meanings. A
    # chunk that declares neither a heading nor a section identity cannot be
    # attributed to a board, so it never votes for ambiguity — a document without
    # this metadata must not turn every question into a clarification.
    def keyed_chunks(chunks)
      Array(chunks).filter_map do |chunk|
        board = board_key(chunk)
        [ board, chunk ] if board.present?
      end
    end

    def board_key(chunk)
      heading = Rag::BoardHeading.label(chunk[:content]).presence
      heading = nil if heading && Rag::BoardHeading.board_tokens(heading).empty?

      heading || chunk[:metadata].to_h.stringify_keys["section_identity"].presence
    end

    # Same priority as the generation cover
    # (Rag::StructuredEvidenceRoute#select_generation_chunks): labelled
    # identifiers carry the strongest signal, every extracted identifier is the
    # fallback for a paraphrase where label and identifier are not adjacent.
    def covering_identifiers(analysis)
      labelled = analysis.identifiers.select { |identifier| identifier.position == :labelled }
      (labelled.presence || analysis.identifiers).uniq(&:canonical)
    end
  end
end
