# frozen_string_literal: true

module Rag
  # Closed comparison between one reported fact and one documentary item.
  # It looks at the noun after an article, the nearest marker of a fixed
  # list in that clause, and a nearby negation. Anything it cannot align
  # stays unresolved. It does not interpret free sentences.
  class CompanionCaseRelation
    ARTICLES = %w[el la los las un una unos unas del al].freeze
    MARKERS = [
      [ "antes de", :before ],
      [ "antes del", :before ],
      [ "antes que", :before ],
      [ "despues de", :after ],
      [ "despues del", :after ],
      [ "despues que", :after ],
      [ "una vez que", :after ],
      [ "mientras", :during ],
      [ "durante", :during ],
      [ "cuando", :during ],
      [ "tras", :after ]
    ].freeze
    UNRECOGNIZED = %w[salvo excepto apenas recien].freeze
    NEGATION_WORD = /\A(?:no|ni|nunca|sin|tampoco|ningun[oa]?)\z/
    CORRECTION = /\b(?:me equivoque|quise decir|en realidad|no era)\b/
    Result = Data.define(:relation, :reason, :anchors)

    def self.call(fact_text:, item_text:, goal_text:)
      new(fact_text, item_text, goal_text).call
    end

    def self.first_anchor_stem(text)
      words(text).each_cons(2) do |left, right|
        return CompanionPlanCheck.stem(right) if ARTICLES.include?(left)
      end
      nil
    end

    def self.explicit_correction?(text)
      CompanionPlanCheck.normal(text).match?(CORRECTION)
    end

    def self.words(text)
      CompanionPlanCheck.words(text)
    end

    def initialize(fact_text, item_text, goal_text)
      @fact_text = fact_text.to_s
      @item_text = item_text.to_s
      @goal_text = goal_text.to_s
    end

    def call
      anchors = item_anchors
      return pack(:unresolved, "no_anchor", []) if anchors.empty?

      shared = anchors.select { |anchor| fact_stems.include?(anchor[:stem]) }
      return pack(:unresolved, "anchor_missing", []) if shared.empty?

      decisions = shared.map { |anchor| decide(anchor) }
      picked = decisions.find { |row| row[:relation] == :incompatible } ||
        decisions.find { |row| row[:relation] == :unresolved }
      picked ||= { relation: :compatible, reason: "markers_agree" }
      pack(picked[:relation], picked[:reason], shared.pluck(:stem).uniq)
    end

    private

    def pack(relation, reason, anchors)
      Result.new(relation: relation, reason: reason, anchors: anchors)
    end

    def item_anchors
      generic = CompanionPlanRender::GENERIC_STEMS
      raw = clauses(@item_text).flat_map { |clause| anchors_in(clause, generic) }
      blocked = CompanionPlanRender.symptom_stems(@goal_text)
      narrowed = raw.reject { |anchor| blocked.include?(anchor[:stem]) }
      narrowed.presence || raw
    end

    def anchors_in(clause, blocked)
      tokens = self.class.words(clause)
      tokens.each_cons(2).with_index.filter_map do |pair, index|
        left, right = pair
        next unless ARTICLES.include?(left)

        stem = CompanionPlanCheck.stem(right)
        next if CompanionPlanCheck::CONNECTORS.include?(right) || blocked.include?(stem)

        { stem: stem, clause: clause, index: index + 1 }
      end
    end

    def decide(anchor)
      fact_clauses = clauses(@fact_text).select { |clause| self.class.words(clause).any? { |word| CompanionPlanCheck.stem(word) == anchor[:stem] } }
      return unresolved("unrecognized") unless fact_clauses.one?

      fact_signal = signal(fact_clauses.first, anchor[:stem])
      item_signal = signal(anchor[:clause], anchor[:stem])
      return unresolved("unrecognized") if fact_signal.nil? || item_signal.nil?
      return incompatible("#{anchor[:stem]}:negation") if fact_signal[:negation] != item_signal[:negation]

      fact_marker = fact_signal[:marker]
      item_marker = item_signal[:marker]
      return incompatible("#{anchor[:stem]}:#{fact_marker}/#{item_marker}") if fact_marker && item_marker && fact_marker != item_marker
      return unresolved("condition_not_stated") if item_marker && !fact_marker
      return unresolved("fact_restricted") if fact_marker && !item_marker

      { relation: :compatible, reason: "markers_agree" }
    end

    # nil when the clause has a restriction this list does not align.
    # A marker attaches only when no other article-noun sits between it and
    # the anchor, so a comma-separated clause cannot lend its marker.
    def signal(clause, stem)
      tokens = self.class.words(clause)
      return nil if tokens.any? { |word| UNRECOGNIZED.include?(word) }

      index = anchor_index(tokens, stem)
      return nil if index.nil?

      marker = marker_for(tokens, index)
      return nil if marker == :ambiguous

      { marker: marker, negation: negation?(tokens, index) }
    end

    def anchor_index(tokens, stem)
      tokens.each_cons(2).with_index do |pair, index|
        left, right = pair
        next unless ARTICLES.include?(left) && CompanionPlanCheck.stem(right) == stem

        return index + 1
      end
      tokens.index { |word| CompanionPlanCheck.stem(word) == stem }
    end

    def marker_for(tokens, noun_index)
      hits = []
      MARKERS.each do |phrase, kind|
        size = phrase.split.size
        0.upto(noun_index - size) do |start|
          next unless tokens[start, size].join(" ") == phrase
          next if noun_between?(tokens, start + size, noun_index)

          hits << kind
        end
      end
      kinds = hits.uniq
      return nil if kinds.empty?
      return :ambiguous if kinds.size > 1

      kinds.first
    end

    def noun_between?(tokens, from, noun_index)
      return false if from >= noun_index

      tokens[from...noun_index].each_cons(2).any? { |left, _right| ARTICLES.include?(left) }
    end

    def negation?(tokens, noun_index)
      tokens.each_with_index.any? do |word, index|
        distance = index - noun_index
        distance != 0 && distance.between?(-4, 6) && word.match?(NEGATION_WORD)
      end
    end

    def clauses(text)
      text.to_s.split(/[,;]|\.(?=\s|\z)/).map(&:strip).reject(&:empty?)
    end

    def fact_stems
      @fact_stems ||= self.class.words(@fact_text).map { |word| CompanionPlanCheck.stem(word) }.to_set
    end

    def unresolved(reason)
      { relation: :unresolved, reason: reason }
    end

    def incompatible(reason)
      { relation: :incompatible, reason: reason }
    end
  end
end
