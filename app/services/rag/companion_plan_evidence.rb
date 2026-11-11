# frozen_string_literal: true

module Rag
  # Whether a question about a plan or schematic can stay on the companion
  # turn: the labels it names must be printed in a citable retrieved source,
  # and it must not depend on an image that this turn does not carry.
  class CompanionPlanEvidence
    # A printed label carries a digit or an inner capital: PasCom, 24V, RE-OPEN, #21.
    LABEL_TOKEN = /(?<![[:alnum:]])#?(?:[[:alnum:]]*\d[[:alnum:]+\-]*|[[:upper:]][[:alnum:]]*[[:upper:]][[:alnum:]\-]*)(?![[:alnum:]])/.freeze
    IMAGE_REFERENCE = /\b(?:foto(?:graf[ií]a)?s?|imagen(?:es)?|captura|adjunt[oa]s?|photo|image|picture|attached)\b/i.freeze
    MIN_LABEL_CHARS = 2

    def self.sufficient?(question:, chunks:)
      new(question, chunks).sufficient?
    end

    def initialize(question, chunks)
      @question = question.to_s
      @chunks = Array(chunks)
    end

    def sufficient?
      return false if @question.match?(IMAGE_REFERENCE)

      wanted = labels
      return false if wanted.empty?

      bodies = citable_bodies
      wanted.all? { |label| bodies.any? { |body| body.include?(label) } }
    end

    def labels
      @question.scan(LABEL_TOKEN).map { |token| token.delete_prefix("#") }
               .select { |token| token.length >= MIN_LABEL_CHARS }.uniq
    end

    private

    def citable_bodies
      @chunks.filter_map do |chunk|
        next if DocumentIdentityScope.reference_only_chunk?(chunk)

        content = chunk[:content] || chunk["content"]
        DocumentIdentityScope.omit_terminal_evidence_records(content.to_s).presence
      end
    end
  end
end
