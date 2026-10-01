# frozen_string_literal: true

module Rag
  # Deterministic answer when the question is only a pinned document's name.
  # Mirrors the Rag::AmbiguousModelResponder
  # contract: self.build returns nil or an instance, #execute returns the
  # answer Hash or nil.
  class DocumentOverviewResponder
    MAX_OVERVIEW_DOCUMENTS = 4
    # Bounds synchronous S3 manifest GETs per response (Rag::DocumentOverviewBuilder
    # falls back to S3 on a cache miss). Cache is expected to be warm for pinned
    # documents (PinnedDocumentsController enqueues DocumentOverviewWarmJob on every
    # pin) — this only guards the exceptional cold path.
    MAX_MANIFEST_FETCHES = 2

    def self.build(question:, account:, conv_session:, response_locale: nil)
      pins = focus_pins(conv_session)
      return nil if pins.empty?

      documents = visible_documents(account, pins.pluck("kb_document_id"))
      pinned_names = pins.flat_map { |entry|
        document = documents[entry["kb_document_id"]]
        [ entry["display_name"], *(document ? Array(document.aliases) : []) ]
      }
      return nil unless Rag::DeterministicIntent.document_overview_query?(question, pinned_names)

      ordered_docs = pins.filter_map { |entry| documents[entry["kb_document_id"]] }
      return nil if ordered_docs.empty?

      new(account: account, kb_documents: ordered_docs, response_locale: response_locale)
    end

    def self.focus_pins(conv_session)
      return [] unless conv_session.respond_to?(:uses_document_focus?) && conv_session.uses_document_focus?
      return [] unless conv_session.respond_to?(:document_focus_entries)

      conv_session.document_focus_entries
                  .sort_by { |entry| entry["added_at"].to_s }
                  .last(MAX_OVERVIEW_DOCUMENTS)
    end
    private_class_method :focus_pins

    def self.visible_documents(account, ids)
      return {} unless account

      KbDocument.where(account_id: account.id).or(KbDocument.danebo_general).where(id: ids).index_by(&:id)
    end
    private_class_method :visible_documents

    def initialize(account:, kb_documents:, response_locale: nil)
      @account      = account
      @kb_documents = kb_documents
      @locale       = response_locale.presence&.to_sym || I18n.locale
    end

    def execute
      hits = build_hits
      return nil if hits.empty?

      {
        answer:              render_answer(hits),
        citations:           [],
        retrieved_citations: [],
        doc_refs:            hits.map { |hit| doc_ref(hit[:kb_document]) },
        retrieval_trace:     retrieval_trace(hits),
        session_id:          nil,
        generation_mode:     "deterministic_document_overview",
        model_invoked:       false
      }
    end

    private

    # V4: resolves all N documents' overviews with a single Solid Cache
    # read_multi instead of N x Rails.cache.read. Only cache misses fall back
    # to Rag::DocumentOverviewBuilder (1 S3 GET each), capped at
    # MAX_MANIFEST_FETCHES — the rest are treated the same as "no manifest"
    # (block omitted), never a synchronous cold-build in the request path.
    def build_hits
      cached = Rag::DocumentOverviewCache.read_multi(
        account_id: @account.id, kb_document_ids: @kb_documents.map(&:id)
      )

      manifest_fetches = 0
      @kb_documents.filter_map do |kb_document|
        overview = cached[kb_document.id]

        if overview.nil?
          next if manifest_fetches >= MAX_MANIFEST_FETCHES

          manifest_fetches += 1
          overview = Rag::DocumentOverviewBuilder.call(
            account: @account, kb_document: kb_document, allow_cold_build: false
          )
        end

        { kb_document: kb_document, overview: overview } if overview.present?
      end
    end

    def doc_ref(kb_document)
      { "canonical_name" => kb_document.display_name,
        "original_source_uri" => kb_document.display_s3_uri(KbDocument::KB_BUCKET) }
    end

    def retrieval_trace(hits)
      {
        "mode" => "document_overview",
        "sections_by_document" => hits.to_h { |hit| [ hit[:kb_document].id, hit[:overview][:sections].size ] },
        "source" => hits.map { |hit| hit[:overview][:source] }.uniq.join(",")
      }
    end

    def render_answer(hits)
      blocks = hits.map { |hit| render_block(hit[:kb_document], hit[:overview]) }
      (blocks + [ I18n.t("rag.document_overview.closing_question", locale: @locale) ]).join("\n\n")
    end

    def render_block(kb_document, overview)
      lines = [ I18n.t("rag.document_overview.document_heading", locale: @locale, name: kb_document.display_name) ]
      lines.concat(overview[:sections].map { |section| section_line(section) })
      lines.join("\n")
    end

    def section_line(section)
      I18n.t("rag.document_overview.section_line", locale: @locale,
                                                     label: section[:label], pages: page_label(section))
    end

    def page_label(section)
      first = section[:first_page]
      last  = section[:last_page]
      return I18n.t("rag.document_overview.page_unknown", locale: @locale) if first.blank?
      return I18n.t("rag.document_overview.page_single", locale: @locale, page: first) if first == last

      I18n.t("rag.document_overview.page_range", locale: @locale, first: first, last: last)
    end
  end
end
