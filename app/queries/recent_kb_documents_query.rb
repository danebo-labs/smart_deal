# frozen_string_literal: true

# Single source of truth for paginated KbDocument lookups in the home KB list
# (initial render, post-indexing refresh, and infinite-scroll page fetch).
#
# Replaces three near-identical inline queries in HomeController. The
# `KbDocument.count > PAGE_SIZE` pattern was a guaranteed extra COUNT(*) round
# trip on every render; this object uses the standard `limit(per_page + 1)`
# trick so a single SELECT answers BOTH "what to show" AND "is there more?".
class RecentKbDocumentsQuery
  # @param page [Integer] 0-indexed page (0 = first page)
  # @param per_page [Integer] page size; the query fetches per_page + 1 to
  #   detect a next page without a separate COUNT.
  # @return [Array(Array<KbDocument>, Boolean)] [docs_for_page, has_more]
  def self.page(page, per_page:)
    page_index = [ page.to_i, 0 ].max
    docs = KbDocument.includes(:thumbnail)
                     .order(created_at: :desc)
                     .offset(page_index * per_page)
                     .limit(per_page + 1)
                     .to_a
    has_more = docs.size > per_page
    [ docs.first(per_page), has_more ]
  end
end
