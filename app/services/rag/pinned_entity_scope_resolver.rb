# frozen_string_literal: true

module Rag
  class PinnedEntityScopeResolver
    Result = Data.define(:uris, :matched_keys, :narrowed)

    GENERIC_TOKENS = Set.new(%w[
      archivo archivos document documento documentos file files pdf
      manual manuales image imagen imagenes photo foto fotos
      diagram diagrama diagramas schematic schematics esquema esquemas
      drawing drawings plano planos
      this that these those este esta estos estas ese esa esos esas
      el la los las un una unos unas the a an
      de del en para por con sin from in on for with without
      usar use uses utilice utilices uses no
    ]).freeze

    NEGATIVE_CLAUSE = /
      (?:no\s+(?:uses?|utilic(?:e|es)|usar)|sin\s+(?:usar|utilizar))
      \s+([^.;!?\n]+)
    /ix

    def initialize(question:, active_entities:, allowed_uris:)
      @question = question.to_s
      @active_entities = active_entities.to_h
      @allowed_uris = Array(allowed_uris).compact.to_set
    end

    def resolve
      candidates = eligible_candidates
      original_uris = candidates.filter_map { |candidate| candidate[:uri] }.uniq
      return Result.new(uris: original_uris, matched_keys: [], narrowed: false) if candidates.size <= 1

      negative_text = negative_segments.join(" ")
      positive_text = normalize(@question.gsub(NEGATIVE_CLAUSE, " "))
      negative_text = normalize(negative_text)

      ranked = candidates.filter_map do |candidate|
        next if confident_match_score(candidate, negative_text).positive?

        score = confident_match_score(candidate, positive_text)
        next unless score.positive?

        candidate.merge(score: score)
      end

      winner = unique_winner(ranked)
      return Result.new(uris: original_uris, matched_keys: [], narrowed: false) unless winner

      Result.new(uris: [ winner[:uri] ], matched_keys: [ winner[:key] ], narrowed: true)
    end

    private

    def eligible_candidates
      @active_entities.filter_map do |key, metadata|
        uri = metadata["source_uri"].to_s.presence
        next if uri.blank?
        next if @allowed_uris.any? && @allowed_uris.exclude?(uri)

        labels = [
          key,
          metadata["canonical_name"],
          metadata["wa_filename"],
          File.basename(metadata["source_uri"].to_s, ".*"),
          *Array(metadata["aliases"])
        ].compact_blank

        {
          key: key,
          uri: uri,
          phrases: labels.map { |label| normalize(label) }.compact_blank.uniq
        }
      end
    end

    def negative_segments
      @question.scan(NEGATIVE_CLAUSE).flatten
    end

    def confident_match_score(candidate, normalized_question)
      return 0 if normalized_question.blank?

      question_tokens = distinctive_tokens(normalized_question)

      candidate[:phrases].map do |phrase|
        phrase_tokens = distinctive_tokens(phrase)
        all_phrase_tokens = phrase.scan(/[\p{L}\d]+/)
        overlap = phrase_tokens & question_tokens
        code_match = overlap.any? { |token| code_token?(token) }
        exact_phrase = phrase_tokens.any? &&
                       all_phrase_tokens.size >= 2 &&
                       " #{normalized_question} ".include?(" #{phrase} ")

        next 0 unless exact_phrase || overlap.size >= 2 || code_match

        (exact_phrase ? 100 : 0) + (code_match ? 20 : 0) + overlap.size
      end.max.to_i
    end

    def unique_winner(ranked)
      ranked.one? ? ranked.first : nil
    end

    def distinctive_tokens(text)
      text.scan(/[\p{L}\d]+/).reject { |token| GENERIC_TOKENS.include?(token) }.uniq
    end

    def code_token?(token)
      token.match?(/\A(?=[a-z\d]*\d)[a-z\d]{2,}\z/)
    end

    def normalize(value)
      value.to_s
           .unicode_normalize(:nfkd)
           .gsub(/\p{Mn}/, "")
           .downcase
           .gsub(/[^\p{L}\d]+/, " ")
           .squish
    end
  end
end
