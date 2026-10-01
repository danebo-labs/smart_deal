# frozen_string_literal: true

module Rag
  # Suggests manuals. It does not write Document Focus and it does not add
  # chunks to the answer. Badge 0 offers a catalog designator or the one
  # cited document that outranks the rest. Badge N offers something outside
  # the focus, and an abstention may run one direct Retrieve whose chunks
  # stay out of the prompt.
  class DocumentDiscovery
    MAX_CARDS = 2
    ABSTENTION_TOP_K = 3
    CITED_LABEL = "CITED"
    OUTSIDE_LABEL = "OUTSIDE_FOCUS"

    Result = Data.define(:cards, :action, :manufacturer, :label) do
      def payload
        return nil if cards.empty?

        {
          cards: cards.map { |card| card_hash(card, label) },
          tie_at_top: false,
          selected_document_uid: nil,
          message: nil,
          focus_mode: action,
          focus_action: label
        }
      end

      private

      def card_hash(card, label)
        {
          document_uid: card.document_uid,
          kb_document_id: card.kb_document_id,
          display_name: card.display_name,
          label: card.label,
          text: card.text,
          knowledge_scope: card.knowledge_scope,
          provenance: card.provenance,
          action: action,
          action_label: label
        }
      end
    end

    class << self
      def call(question:, viewer_account:, session: nil, doc_refs: [], abstained: false, retriever: nil, entries: nil)
        new(
          question: question,
          viewer_account: viewer_account,
          session: session,
          doc_refs: doc_refs,
          abstained: abstained,
          retriever: retriever,
          entries: entries
        ).call
      end
    end

    def initialize(question:, viewer_account:, session:, doc_refs:, abstained:, retriever:, entries:)
      @question = question.to_s
      @viewer_account = viewer_account
      @session = session
      @doc_refs = Array(doc_refs)
      @abstained = abstained
      @retriever = retriever
      @entries = entries || Rag::DocumentIdentityCatalog.current.entries
    end

    def call
      return Result.new(cards: [], action: "add", manufacturer: nil, label: nil) if @viewer_account.nil? || @question.blank?

      focus_ids = focused_ids
      action = contradiction? ? "replace" : "add"
      cards = if focus_ids.any? && @abstained
        abstention_cards(focus_ids)
      elsif focus_ids.any?
        focused_cards(focus_ids)
      else
        open_cards
      end
      Result.new(
        cards: dedupe(cards).first(MAX_CARDS),
        action: action,
        manufacturer: mentioned_manufacturer,
        label: action_label(action, focus_ids)
      )
    end

    private

    def action_label(action, focus_ids)
      if action == "replace"
        I18n.t("rag.manual_focus_replace")
      elsif focus_ids.empty?
        I18n.t("rag.manual_focus_select")
      else
        I18n.t("rag.manual_focus_add")
      end
    end

    def open_cards
      designator_cards + citation_cards
    end

    def focused_cards(focus_ids)
      pool = contradiction? ? designator_cards + brand_cards : designator_cards
      pool.reject { |card| focus_ids.include?(card.kb_document_id.to_i) }
    end

    def abstention_cards(focus_ids)
      retrieved = outside_cards(focus_ids)
      return retrieved if retrieved.any?

      focused_cards(focus_ids)
    end

    def designator_cards
      offer(exact_entries, Rag::ManualCandidateRanker::EXACT_DESIGNATOR_LABEL, Rag::ManualCandidateRanker::EXACT_DESIGNATOR_TEXT)
    end

    def brand_cards
      offer(brand_entries, Rag::ManualCandidateRanker::BRAND_ONLY_LABEL, Rag::ManualCandidateRanker::BRAND_ONLY_TEXT)
    end

    def offer(list, label, text)
      Rag::ManualCandidateRanker.offer_entries(
        list,
        viewer_account: @viewer_account,
        label: label,
        text: text
      )
    end

    def citation_cards
      uri = dominant_uri
      return [] if uri.blank?

      document = document_for_uri(uri)
      return [] unless document

      [ cited_card(document) ]
    end

    def outside_cards(focus_ids)
      return [] unless @retriever

      result = @retriever.call(@question, ABSTENTION_TOP_K)
      chunks = result.is_a?(Hash) ? (result[:chunks] || result["chunks"]) : result
      uris = focus_uris
      Array(chunks).filter_map { |chunk|
        uri = chunk_uri(chunk)
        next if uri.blank? || uris.include?(uri)

        document = document_for_uri(uri)
        next unless document
        next if focus_ids.include?(document.id)

        outside_card(document)
      }
    rescue StandardError => e
      Rails.logger.warn("Document discovery retrieve failed: #{e.message}")
      []
    end

    def cited_card(document)
      manual_card(document, CITED_LABEL, I18n.t("rag.manual_discovery_cited"))
    end

    def outside_card(document)
      manual_card(document, OUTSIDE_LABEL, I18n.t("rag.manual_discovery_outside"))
    end

    def manual_card(document, label, text)
      scope = Rag::KnowledgeScopePolicy.scope_for(document, viewer_account: @viewer_account)
      Rag::ManualCandidateRanker::Card.new(
        document_uid: document.document_uid.to_s,
        display_name: document.display_name.to_s,
        score: 0,
        label: label,
        text: text,
        knowledge_scope: scope,
        provenance: scope == Rag::ManualCandidateRanker::GENERAL_SCOPE ? Rag::ManualCandidateRanker::GENERAL_PROVENANCE : Rag::ManualCandidateRanker::PRIVATE_PROVENANCE,
        kb_document_id: document.id
      )
    end

    def exact_entries
      words = normalize(@question).split
      @entries.select { |entry|
        Array(entry_value(entry, :designators)).any? { |item| words.include?(normalize(item)) }
      }
    end

    def brand_entries
      brand = mentioned_manufacturer
      return [] if brand.blank?

      @entries.select { |entry|
        Array(entry_value(entry, :brands)).any? { |item| normalize(item) == brand }
      }
    end

    def dominant_uri
      counts = Hash.new(0)
      @doc_refs.each do |ref|
        uri = ref_value(ref, :source_uri).to_s
        counts[uri] += 1 if uri.present?
      end
      return nil if counts.empty?

      top_count = counts.values.max
      winners = counts.select { |_uri, count| count == top_count }.keys
      return nil unless winners.one?

      winners.first
    end

    def document_for_uri(uri)
      identity = KbDocument.canonical_source(uri)
      return nil if identity.nil?

      _bucket, key = identity
      scope = KbDocument.where(account_id: @viewer_account.id).or(KbDocument.danebo_general)
      matches = scope.where(s3_key: [ key, uri ]).select { |row| row.canonical_source == identity }
      return nil unless matches.one?
      return nil unless Rag::KnowledgeScopePolicy.authorized?(matches.first, viewer_account: @viewer_account)

      matches.first
    end

    def contradiction?
      return false if focused_ids.empty?

      brand = mentioned_manufacturer
      return false if brand.blank? || @session.nil?

      suggestion = Struct.new(:manufacturer, :model_tokens).new(brand, [])
      Rag::FocusNotice.pin_conflict(session: @session, suggestion: suggestion).present?
    end

    def mentioned_manufacturer
      normalized = normalize(@question)
      labels = Rag::ActiveEpisodeTurn::MANUFACTURERS.map { |brand| normalize(brand) }
      labels += @entries.flat_map { |entry| Array(entry_value(entry, :brands)).map { |brand| normalize(brand) } }
      labels.compact_blank.uniq.sort_by { |label| -label.length }.find { |label|
        normalized.match?(/\b#{Regexp.escape(label)}\b/)
      }
    end

    def focused_ids
      return [] unless @session.respond_to?(:document_focus_entries)
      return [] if @session.respond_to?(:uses_document_focus?) && !@session.uses_document_focus?

      @session.document_focus_entries.map { |entry| entry["kb_document_id"].to_i }
    end

    def focus_uris
      return [] unless @session.respond_to?(:document_focus_entries)

      @session.document_focus_entries.map { |entry| entry["source_uri"].to_s }.compact_blank
    end

    def chunk_uri(chunk)
      return chunk.to_s unless chunk.is_a?(Hash)

      chunk[:original_source_uri].presence ||
        chunk["original_source_uri"].presence ||
        chunk[:location_uri].presence ||
        chunk["location_uri"].presence ||
        chunk[:bedrock_source_uri].presence ||
        chunk["bedrock_source_uri"].presence
    end

    def dedupe(cards)
      seen = {}
      cards.each_with_object([]) do |card, kept|
        id = card.kb_document_id.to_i
        next if id.zero? || seen[id]

        seen[id] = true
        kept << card
      end
    end

    def entry_value(entry, key)
      if entry.is_a?(Hash)
        entry[key] || entry[key.to_s]
      elsif entry.respond_to?(key)
        entry.public_send(key)
      end
    end

    def ref_value(ref, key)
      return nil unless ref.is_a?(Hash)

      ref[key] || ref[key.to_s]
    end

    def normalize(raw)
      Rag::FollowupQueryRewriter.normalize_label(raw)
    end
  end
end
