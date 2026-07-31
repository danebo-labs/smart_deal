# frozen_string_literal: true

require "set"

module Rag
  # Extractor for Rag::QueryAnalysis (docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md
  # §2). Builds identifiers and requested_relation per §4; the evidence selector itself
  # is separate, later work.
  class QueryEntities
    Normalized = Data.define(:raw, :key, :model_key, :variant)

    # Terms that put a following candidate token in :labelled position (§4). Matched
    # case-insensitively with simple Spanish plurals (LED/LEDs, borne/bornes, …) — the
    # position rule is about recognizing trigger vocabulary, not the token's own case.
    LABEL_STEMS = %w[LED SERIE BORNE TERMINAL CONECTOR PLACA PIN].freeze

    # Spanish conjunctions inside an enumeration ("LED SPM, SPH y SEG") that keep a
    # label's :labelled streak alive without resetting it or being identifiers themselves.
    CONNECTOR_WORDS = %w[Y O E].freeze

    # A candidate is an uppercase alphanumeric run with optional internal separators.
    # Minimum 2 significant characters excludes bare unit letters ("24 V") from ever
    # matching — every real identifier in the corpus is 2+ characters; single letters
    # are units, not identifiers.
    IDENTIFIER_SHAPE = /\A[A-Z0-9]+(?:[-._][A-Z0-9]+)*\z/

    # Relation triggers (§4 table). Matched as accent-folded, lowercase substrings.
    RELATION_TRIGGERS = {
      attribution: [ "indica", "corresponde", "señala", "identifica", "a qué serie" ],
      state: [ "cuándo se enciende", "condición normal", "en fallo", "apagado" ],
      connection: [ "conector", "borne", "terminal", "cableado", "en qué placa" ],
      location: [ "en qué placa", "dónde", "en qué página" ]
    }.freeze

    # Space, hyphen-minus, en dash, em dash, underscore, dot. En/em dash are folded
    # alongside the hyphen because the source PDF prints the same model with either
    # ("TOKIBAT 2007" vs "TOKIBAT – 2.007") — the same dash-family equivalence already
    # established for series names in seguridades_rubric_calibration_test.rb.
    SEPARATOR = "[ \\-\u2013\u2014_.]"
    VERSION_SUFFIX = /\A(.+?)#{SEPARATOR}*(V\d+)\z/

    # Folds `raw` into a comparison-only `key`, then splits a trailing version suffix
    # (`V1`, `V2`, …) into `variant`, leaving `model_key` as the base identity.
    # `raw` is never altered for display — only `key`/`model_key`/`variant` exist to compare.
    def self.normalize(raw)
      key = fold(raw)
      model_key, variant = split_variant(key)
      Normalized.new(raw: raw, key: key, model_key: model_key, variant: variant)
    end

    def self.fold(raw)
      text = raw.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").upcase
      loop do
        before = text
        # Letters-to-letters or letters-to-digits: glue "EM 4000" / "TPR-50" / "EDEL K3".
        # The left side must be letters, so a digit-to-letter separator (CN-112.SC's
        # dot before "SC") is never folded by this branch — see §3 prohibition list.
        text = text.gsub(/(\p{L}+)#{SEPARATOR}+(\p{L}+|\d+)/) { "#{$1}#{$2}" }
        # Thousands separator only: a dot between digit runs where the right run is
        # exactly 3 digits ("2.007" -> "2007"). Any other digit-to-digit separator is
        # left alone so CN7/CN8/CN9 are never folded into each other.
        text = text.gsub(/(\d+)\.(\d{3})(?!\d)/) { "#{$1}#{$2}" }
        break if text == before
      end
      text
    end
    private_class_method :fold

    def self.split_variant(key)
      match = key.match(VERSION_SUFFIX)
      match ? [ match[1], match[2] ] : [ key, nil ]
    end
    private_class_method :split_variant

    # Builds the Rag::QueryAnalysis for a question. Only identifiers and
    # requested_relation are populated here (§4); intents/manufacturer/model/board/
    # confidence belong to other extraction work and stay at their neutral default.
    def self.analyze(question)
      Rag::QueryAnalysis.new(
        intents: Set.new,
        manufacturer: nil,
        model: nil,
        board: nil,
        identifiers: identifiers(question),
        requested_relation: requested_relation(question),
        confidence: {},
        question: question
      )
    end

    # Separator-tolerant, boundary-anchored containment of a canonical identifier
    # in evidence text: "ABC12" matches "ABC-12" and "ABC 12", never "ABC120".
    # Shared by Rag::StructuredEvidenceRoute's generation cover and
    # Rag::FamilyAmbiguityDetector so both agree on what "this chunk contains that
    # identifier" means.
    def self.identifier_present?(content, canonical)
      characters = canonical.to_s.scan(/[[:alnum:]]/)
      return false if characters.empty?

      pattern = characters.map { |character| Regexp.escape(character) }.join("[\\s\\-._]*")
      content.to_s.match?(/(?<![[:alnum:]_])#{pattern}(?![[:alnum:]_])/i)
    end

    # Public shape query: does the question contain any label term at all? Position-
    # independent, unlike `identifiers`' adjacency streak. Exposed so the retrieval
    # profile can reuse the single trigger vocabulary instead of duplicating it.
    def self.label_terms?(question)
      question.to_s.scan(/\S+/).any? do |token|
        core = token.gsub(/\A[^\p{L}\p{N}]+/, "").gsub(/[^\p{L}\p{N}]+\z/, "")
        core.present? && label_term?(core)
      end
    end

    # Identifiers by shape and position (§4). A token is a candidate if it is an
    # uppercase alphanumeric run with optional internal separators; :labelled means it
    # follows a label term (or sits inside an enumeration headed by one). A numeric
    # candidate only counts as an identifier when :labelled — otherwise "p. 31", "24 V"
    # and "3 pasos" would read as identifiers and the guard would become unusable.
    def self.identifiers(question)
      labelled = false

      question.scan(/\S+/).each_with_object([]) do |token, results|
        core = token.gsub(/\A[^\p{L}\p{N}]+/, "").gsub(/[^\p{L}\p{N}]+\z/, "")
        next if core.empty?

        if label_term?(core)
          labelled = true
          next
        end

        if identifier_candidate?(core)
          position = labelled ? :labelled : :bare
          shape = shape_of(core)
          results << Rag::QueryAnalysis::Identifier.new(
            raw: core, canonical: canonical_of(core), shape: shape, position: position
          ) unless shape == :numeric && position == :bare
        elsif !connector_word?(core)
          labelled = false
        end
      end
    end

    # Relation(s) requested by the question (§4 table), as a Set<Symbol> — never a
    # scalar, since some questions request more than one relation at once (F4).
    def self.requested_relation(question)
      folded = strip_diacritics(question).downcase
      RELATION_TRIGGERS.each_with_object(Set.new) do |(relation, triggers), set|
        set << relation if triggers.any? { |trigger| folded.include?(strip_diacritics(trigger).downcase) }
      end
    end

    def self.label_term?(core)
      normalized = strip_diacritics(core).upcase
      LABEL_STEMS.any? { |stem| normalized == stem || normalized == "#{stem}S" || normalized == "#{stem}ES" }
    end
    private_class_method :label_term?

    def self.connector_word?(core)
      CONNECTOR_WORDS.include?(strip_diacritics(core).upcase)
    end
    private_class_method :connector_word?

    def self.identifier_candidate?(core)
      return false unless IDENTIFIER_SHAPE.match?(core)

      core.delete("-._").length.between?(2, 12)
    end
    private_class_method :identifier_candidate?

    def self.shape_of(core)
      return :numeric if core.match?(/\A[0-9]+\z/)
      return :connector if core.match?(/[-._]/)
      return :alpha if core.match?(/\A[A-Z]+\z/)

      :alnum
    end
    private_class_method :shape_of

    def self.canonical_of(core)
      core.delete("-._").upcase
    end
    private_class_method :canonical_of

    def self.strip_diacritics(text)
      text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "")
    end
    private_class_method :strip_diacritics
  end
end
