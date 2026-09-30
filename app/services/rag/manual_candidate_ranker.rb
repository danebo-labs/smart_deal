# frozen_string_literal: true

module Rag
  # Runtime copy of FieldCompanion::DiscoveryScore (plan section 5).
  # Points, tie-break, and the fixed card texts stay the same. Scope filters
  # eligibility after the score and does not add or remove points. A suggestion
  # does not write a pin and does not retrieve.
  class ManualCandidateRanker
    BRAND_ONLY_LABEL = "BRAND_ONLY"
    EXACT_DESIGNATOR_LABEL = "EXACT_DESIGNATOR"
    BRAND_ONLY_TEXT = "manual de la misma marca; compatibilidad con este equipo no confirmada"
    EXACT_DESIGNATOR_TEXT = "el documento coincide con el modelo/designador indicado"
    EMPTY_TEXT = "No encontré un manual claramente asociado a esa identidad en la biblioteca actual."
    GENERAL_PROVENANCE = "Biblioteca general de Danebo"
    PRIVATE_PROVENANCE = "Tu biblioteca"
    GENERAL_SCOPE = KbDocument::KNOWLEDGE_SCOPE_GENERAL
    PRIVATE_SCOPE = KbDocument::KNOWLEDGE_SCOPE_PRIVATE
    APPROVED = "GENERAL_APPROVED"
    PRIVATE_CLASS = "PRIVATE"
    UNCLASSIFIED = "UNCLASSIFIED"
    MAX_CARDS = 3

    Candidate = Data.define(
      :document_id, :display_name, :score, :label, :brands,
      :owner_account_id, :classification, :s3_key, :catalog_account_id
    )
    ScoreResult = Data.define(:candidates, :tie_at_top, :reason, :manufacturer, :model_tokens)
    Card = Data.define(
      :document_uid, :display_name, :score, :label, :text,
      :knowledge_scope, :provenance
    )
    Suggestion = Data.define(
      :cards, :tie_at_top, :reason, :manufacturer, :model_tokens,
      :message, :selected_document_uid, :scored_document_ids
    ) do
      def chat_payload
        return nil if reason == "no_manufacturer"

        {
          cards: cards.map { |card|
            {
              document_uid: card.document_uid,
              display_name: card.display_name,
              label: card.label,
              text: card.text,
              knowledge_scope: card.knowledge_scope,
              provenance: card.provenance
            }
          },
          tie_at_top: tie_at_top,
          selected_document_uid: nil,
          message: cards.empty? ? message : nil
        }
      end
    end

    class << self
      def score(text, entries)
        rank_unscoped(text, entries)
      end

      # documents_for receives the scored candidates and returns KbDocument
      # rows. A card exists only when the catalog entry binds to exactly one
      # authorized physical row. document_uid alone is not that bind.
      def suggest(text, entries, viewer_account: nil, viewer_account_id: nil, documents_for: nil)
        scored = score(text, entries)
        viewer = viewer_account || viewer_from_id(viewer_account_id)
        rows = documents_for_candidates(scored.candidates, documents_for)
        cards = scored.candidates.filter_map { |candidate|
          document = Rag::KnowledgeScopePolicy.bind_catalog_candidate(candidate, rows: rows, viewer_account: viewer)
          card_for(candidate, document, viewer) if document
        }
        max_score = cards.first&.score
        tie = cards.count { |card| card.score == max_score } >= 2

        Suggestion.new(
          cards: cards,
          tie_at_top: tie,
          reason: scored.reason,
          manufacturer: scored.manufacturer,
          model_tokens: scored.model_tokens,
          message: cards.empty? ? EMPTY_TEXT : nil,
          selected_document_uid: nil,
          scored_document_ids: scored.candidates.map(&:document_id)
        )
      end

      private

      def viewer_from_id(viewer_account_id)
        return nil if viewer_account_id.blank?

        Account.find_by(id: viewer_account_id) || Account.new.tap { |account| account.id = viewer_account_id }
      end

      def documents_for_candidates(candidates, documents_for)
        return [] if candidates.empty? || documents_for.nil?

        Array(documents_for.call(candidates))
      end

      def card_for(candidate, document, viewer)
        scope = Rag::KnowledgeScopePolicy.scope_for(document, viewer_account: viewer)
        Card.new(
          document_uid: candidate.document_id,
          display_name: candidate.display_name,
          score: candidate.score,
          label: candidate.label,
          text: candidate.label == EXACT_DESIGNATOR_LABEL ? EXACT_DESIGNATOR_TEXT : BRAND_ONLY_TEXT,
          knowledge_scope: scope,
          provenance: scope == GENERAL_SCOPE ? GENERAL_PROVENANCE : PRIVATE_PROVENANCE
        )
      end

      def rank_unscoped(text, entries)
        list = Array(entries)
        normalized = Rag::FollowupQueryRewriter.normalize_label(text)
        found = manufacturers_in(normalized)
        tokens = model_tokens(text, normalized, list)

        if found.empty?
          return ScoreResult.new(candidates: [], tie_at_top: false, reason: "no_manufacturer", manufacturer: nil, model_tokens: tokens)
        end
        if found.size > 1
          return ScoreResult.new(candidates: [], tie_at_top: false, reason: "multiple_manufacturers", manufacturer: nil, model_tokens: tokens)
        end

        manufacturer = found.first
        scored = list.filter_map { |entry| score_entry(entry, manufacturer, tokens) }
        scored.sort_by! { |candidate| [ -candidate.score, normalize(candidate.display_name), candidate.document_id ] }
        top = scored.first(MAX_CARDS)
        max_score = top.first&.score
        tie = top.count { |candidate| candidate.score == max_score } >= 2

        ScoreResult.new(candidates: top, tie_at_top: tie, reason: nil, manufacturer: manufacturer, model_tokens: tokens)
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
        points = 100
        points += 80 if exact
        points += 40 if Rag::DocumentIdentityCatalog.effectively_confirmed?(as_catalog_entry(entry))

        Candidate.new(
          document_id: value(entry, :document_id).to_s,
          display_name: value(entry, :display_name).to_s,
          score: points,
          label: exact ? EXACT_DESIGNATOR_LABEL : BRAND_ONLY_LABEL,
          brands: Array(value(entry, :brands)).map(&:to_s),
          owner_account_id: value(entry, :owner_account_id),
          classification: classification_value(entry),
          s3_key: value(entry, :s3_key).to_s,
          catalog_account_id: value(entry, :account_id).presence || value(entry, :owner_account_id).presence
        )
      end

      def classification_value(entry)
        raw = value(entry, :classification).to_s
        return raw if [ APPROVED, PRIVATE_CLASS, UNCLASSIFIED ].include?(raw)

        nil
      end

      def brand_match?(entry, manufacturer)
        Array(value(entry, :brands)).any? { |brand| normalize(brand) == manufacturer }
      end

      def designator_match?(entry, tokens)
        labels = Array(value(entry, :designators)).map { |item| normalize(item) }
        tokens.any? { |token| labels.include?(token) }
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

      def evidence_page_of(raw)
        return nil if raw.nil? || raw.to_s.strip.empty?

        Integer(raw)
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

      def normalize(raw)
        Rag::FollowupQueryRewriter.normalize_label(raw)
      end
    end
  end
end
