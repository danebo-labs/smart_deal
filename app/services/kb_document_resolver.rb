# frozen_string_literal: true

# Resolves human-facing document names in a user's query against the KbDocument
# catalog. Returns up to MAX_MATCHES rows whose `display_name` or `aliases`
# contain tokens from the query as whole-word matches.
#
# Why: retrieval + Haiku alone cannot always bridge the gap between what the
# technician calls a document ("Esquema SOPREL") and what the parsed chunk
# calls it internally ("Foremcaro 6118/81"). Both names live in KbDocument
# (one as display_name, the other as alias). This resolver pulls them into
# the RAG pipeline so Bedrock can filter retrieval by source_uri and Haiku
# sees the equivalence in session_context.
#
# Scoring: each KbDocument is scored by the number of DISTINCT query tokens
# matched anywhere in (display_name | aliases). Ties broken by recency.
class KbDocumentResolver
  MAX_MATCHES  = 3
  MIN_TOKEN    = 4
  TOKEN_RE     = /[\p{L}\d]{#{MIN_TOKEN},}/.freeze

  # Language-agnostic low-signal words. Intentionally short; the 4-char floor
  # already rejects almost all function words in both Spanish and English.
  STOPWORDS = Set.new(%w[
    that this those these which what when where
    para por con los las una unos unas esto eso este esta estos estas
    pero porque aunque mientras cuando donde como cual quien
    cuanto esta estan estas estamos tiene tienen tenemos
    puedo puede pueden podemos quiero quieres
    document documento documentos file archivo archivos
    the and from with into
  ]).freeze

  # @param question [String]
  # @return [Array<KbDocument>] ranked by match score, max MAX_MATCHES rows
  def self.resolve(question)
    tokens = tokenize(question)
    return [] if tokens.empty?

    candidates = candidates_for(tokens)
    return [] if candidates.empty?

    scored = candidates.map do |doc|
      haystack = build_haystack(doc)
      score    = tokens.count { |tok| haystack.match?(/\b#{Regexp.escape(tok)}\b/) }
      [ doc, score ]
    end

    scored
      .select { |_, score| score.positive? }
      .sort_by { |doc, score| [ -score, -doc.created_at.to_f ] }
      .first(MAX_MATCHES)
      .map(&:first)
  end

  def self.tokenize(text)
    text.to_s.downcase.scan(TOKEN_RE).uniq.reject { |t| STOPWORDS.include?(t) }
  end

  # Single SQL fetch: any row whose display_name OR any alias CONTAINS any
  # query token as a substring. ILIKE is index-friendly (pg_trgm GIN) while
  # the regex \m...\M (POSIX word boundary) was NOT — it forced a seq scan.
  #
  # Word-boundary semantics are preserved by post-filtering in Ruby inside
  # `resolve` (the `haystack.match?(/\b...\b/)` call). The pre-filter widens
  # the candidate set conservatively (LIMIT 50) so the post-filter still
  # rejects substring noise like "esquemadocumento" for "esquema".
  def self.candidates_for(tokens)
    conditions = []
    params     = []

    tokens.each do |tok|
      pattern = "%#{tok}%"
      conditions << "LOWER(display_name) ILIKE ?"
      params     << pattern
      # Pre-filter against `lower(aliases::text)` — index-friendly. The Ruby
      # post-filter below restores strict word-boundary semantics.
      conditions << "LOWER(aliases::text) ILIKE ?"
      params     << pattern
    end

    prelim = KbDocument.where(conditions.join(" OR "), *params).limit(50).to_a

    # Strict word-boundary post-filter to preserve the resolver's accuracy.
    prelim.select do |doc|
      haystack = build_haystack(doc)
      tokens.any? { |t| haystack.match?(/\b#{Regexp.escape(t)}\b/) }
    end.first(20)
  end

  def self.build_haystack(doc)
    ([ doc.display_name ] + Array(doc.aliases)).compact.map(&:to_s).map(&:downcase).join(" | ")
  end
end
