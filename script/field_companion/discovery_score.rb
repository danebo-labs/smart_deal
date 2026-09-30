# frozen_string_literal: true

# Pure discovery score from PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29 section 5.
# No network. knowledge_scope is ignored: it filters eligibility elsewhere and
# does not add points. Rag::ManualCandidateRanker is the runtime copy. This
# file stays the F0 original.
module FieldCompanion
  module DiscoveryScore
    Candidate = Data.define(:document_id, :display_name, :score, :label, :brands)
    Result = Data.define(:candidates, :tie_at_top, :reason, :manufacturer, :model_tokens)

    module_function

    def rank(text, entries)
      list = Array(entries)
      normalized = Rag::FollowupQueryRewriter.normalize_label(text)
      found = manufacturers_in(normalized)
      tokens = model_tokens(text, normalized, list)

      if found.empty?
        return Result.new(candidates: [], tie_at_top: false, reason: "no_manufacturer", manufacturer: nil, model_tokens: tokens)
      end
      if found.size > 1
        return Result.new(candidates: [], tie_at_top: false, reason: "multiple_manufacturers", manufacturer: nil, model_tokens: tokens)
      end

      manufacturer = found.first
      scored = list.filter_map { |entry| score_entry(entry, manufacturer, tokens) }
      scored.sort_by! { |candidate| [ -candidate.score, normalize(candidate.display_name), candidate.document_id ] }
      top = scored.first(3)
      max_score = top.first&.score
      tie = top.count { |candidate| candidate.score == max_score } >= 2

      Result.new(candidates: top, tie_at_top: tie, reason: nil, manufacturer: manufacturer, model_tokens: tokens)
    end

    def gold_document_ids(text, entries)
      list = Array(entries)
      normalized = Rag::FollowupQueryRewriter.normalize_label(text)
      found = manufacturers_in(normalized)
      return [] unless found.one?

      tokens = model_tokens(text, normalized, list)
      matched = list.select { |entry| brand_match?(entry, found.first) }
      if tokens.any?
        matched = matched.select { |entry| designator_match?(entry, tokens) }
      end
      matched.map { |entry| value(entry, :document_id).to_s }.uniq
    end

    def phrase_metrics(text, entries)
      result = rank(text, entries)
      ids = result.candidates.map(&:document_id)
      gold = gold_document_ids(text, entries)
      wrong = result.candidates.count { |candidate| wrong_brand?(candidate, result.manufacturer) }

      {
        "text" => text.to_s,
        "manufacturer" => result.manufacturer,
        "model_tokens" => result.model_tokens,
        "reason" => result.reason,
        "tie_at_top" => result.tie_at_top,
        "document_ids" => ids,
        "labels" => result.candidates.map(&:label),
        "scores" => result.candidates.map(&:score),
        "gold_document_ids" => gold,
        "precision_at_3" => precision_at_3(ids, gold),
        "top1_accuracy" => top1_accuracy(ids, gold),
        "wrong_brand_candidate_rate" => rate(wrong, result.candidates.size)
      }
    end

    def precision_at_3(returned, gold)
      returned = Array(returned)
      gold = Array(gold)
      return 1 if returned.empty? && gold.empty?
      return 0 if returned.empty?

      (returned & gold).size.to_f / returned.size
    end

    def top1_accuracy(returned, gold)
      returned = Array(returned)
      gold = Array(gold)
      return 1 if returned.empty? && gold.empty?
      return 0 if returned.empty?

      gold.include?(returned.first) ? 1 : 0
    end

    def manufacturers_in(normalized)
      brands = Rag::ActiveEpisodeTurn::MANUFACTURERS.map { |brand|
        [ brand, normalize(brand) ]
      }.sort_by { |brand, label| [ -label.length, brand ] }

      brands.each_with_object([]) do |(_brand, label), found|
        next if label.empty?
        next unless normalized.match?(/\b#{Regexp.escape(label)}\b/)
        next if found.include?(label)

        found << label
      end
    end

    def model_tokens(original, normalized, entries)
      tokens = []
      capture = original.to_s.match(Rag::ActiveEpisodeTurn::MODEL_VALUE_RE)&.[](1)
      if capture
        label = normalize(capture)
        stop = Rag::ActiveEpisodeTurn::MODEL_DECLARATION_STOPWORDS
        tokens << label if label.present? && stop.exclude?(label)
      end

      known = entries.flat_map { |entry| Array(value(entry, :designators)) }.map { |item| normalize(item) }
      normalized.split.each do |word|
        next unless word.match?(/\d/)
        next unless known.include?(word)

        tokens << word
      end
      tokens.uniq
    end

    def score_entry(entry, manufacturer, tokens)
      return nil unless brand_match?(entry, manufacturer)

      exact = designator_match?(entry, tokens)
      score = 100
      score += 80 if exact
      score += 40 if Rag::DocumentIdentityCatalog.effectively_confirmed?(as_catalog_entry(entry))

      Candidate.new(
        document_id: value(entry, :document_id).to_s,
        display_name: value(entry, :display_name).to_s,
        score: score,
        label: exact ? "EXACT_DESIGNATOR" : "BRAND_ONLY",
        brands: Array(value(entry, :brands)).map(&:to_s)
      )
    end

    def brand_match?(entry, manufacturer)
      Array(value(entry, :brands)).any? { |brand| normalize(brand) == manufacturer }
    end

    def designator_match?(entry, tokens)
      labels = Array(value(entry, :designators)).map { |item| normalize(item) }
      tokens.any? { |token| labels.include?(token) }
    end

    def wrong_brand?(candidate, manufacturer)
      return false if manufacturer.nil?

      candidate.brands.map { |brand| normalize(brand) }.exclude?(manufacturer)
    end

    def as_catalog_entry(entry)
      return entry if entry.is_a?(Rag::DocumentIdentityCatalog::Entry)

      Rag::DocumentIdentityCatalog::Entry.new(
        account_id: value(entry, :account_id).to_s,
        document_id: value(entry, :document_id).to_s,
        s3_key: value(entry, :s3_key).to_s,
        display_name: value(entry, :display_name).to_s,
        brands: Array(value(entry, :brands)).map(&:to_s),
        designators: Array(value(entry, :designators)).map(&:to_s),
        generic: value(entry, :generic) == true,
        confirmed: value(entry, :confirmed) == true,
        evidence_page: evidence_page_of(value(entry, :evidence_page)),
        evidence_text: value(entry, :evidence_text).to_s.presence,
        role: value(entry, :role).to_s.presence
      )
    end

    def evidence_page_of(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def value(entry, key)
      if entry.is_a?(Hash)
        entry[key] || entry[key.to_s]
      elsif entry.respond_to?(key)
        entry.public_send(key)
      end
    end

    def normalize(value)
      Rag::FollowupQueryRewriter.normalize_label(value)
    end

    def rate(numerator, denominator)
      return 0 if denominator.zero?

      numerator.to_f / denominator
    end
  end
end
