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
  SHORT_TOKEN  = 3
  TOKEN_RE     = /[\p{L}\d]{#{SHORT_TOKEN},}/.freeze

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

  # Bare brand mentions are never specific enough to auto-scope retrieval —
  # see #specific_token?. Model/part designators (MPK, LCB, BL6...) are not
  # brands and stay eligible.
  BRANDS = Set.new(%w[
    otis kone thyssen tke blt mitsubishi fuji yida schindler fermator hyundai orona
  ]).freeze

  # @document [KbDocument] @score [Integer] distinct matched tokens
  # @matched_tokens [Array<String>] ORIGINAL-CASE substrings from the question
  #   that matched (not downcased) — callers use case/digits to gate specificity.
  MatchResult = Data.define(:document, :score, :matched_tokens)

  # @param question [String]
  # @param account [Account]
  # @return [Array<KbDocument>] ranked by match score, max MAX_MATCHES rows
  def self.resolve(question, account:)
    resolve_scoped(question, account: account).map(&:document)
  end

  # Same SQL fetch and word-boundary post-filter as #resolve, but also returns
  # the score and the original-case matched tokens so callers (auto-scope
  # gate) can tell a specific model/part designator from a bare brand mention
  # without re-scanning the question.
  # @return [Array<MatchResult>] ranked by match score, max MAX_MATCHES rows
  def self.resolve_scoped(question, account:)
    raise ArgumentError, "account is required" unless account

    scanned = scan_tokens(question)
    return [] if scanned.empty?

    tokens = scanned.pluck(:token)
    candidates = candidates_for(tokens, account: account)
    return [] if candidates.empty?

    scored = candidates.map do |doc|
      haystack = build_haystack(doc)
      matched  = scanned.select { |t| haystack.match?(/\b#{Regexp.escape(t[:token])}\b/) }
      [ doc, matched ]
    end

    scored
      .select { |_, matched| matched.any? }
      .sort_by { |doc, matched| [ -matched.size, -doc.created_at.to_f ] }
      .first(MAX_MATCHES)
      .map { |doc, matched| MatchResult.new(document: doc, score: matched.size, matched_tokens: matched.map { |t| t[:raw] }) }
  end

  def self.tokenize(text)
    scan_tokens(text).pluck(:token)
  end

  # A token is specific enough to scope retrieval to the documents it matched
  # when it contains a digit (708a, mpdk136, bl6) or appears fully uppercase
  # in the question and is not a brand name (otis, kone, ...). Bare brand
  # mentions or lowercase generic words must never narrow retrieval alone —
  # see the auto-scope plan's gate.
  def self.specific_token?(raw)
    return true if raw.match?(/\d/)

    raw.match?(/\A[A-Z]+\z/) && BRANDS.exclude?(raw.downcase)
  end

  # Scans 3+ char tokens preserving original casing. A 3-char token only
  # survives when #specific_token? holds for it — MIN_TOKEN stays 4 for
  # everything else, so ordinary short words are never widened.
  def self.scan_tokens(text)
    text.to_s.scan(TOKEN_RE).uniq.filter_map do |raw|
      token = raw.downcase
      next if STOPWORDS.include?(token)
      next if token.length < MIN_TOKEN && !specific_token?(raw)

      { token: token, raw: raw }
    end
  end
  private_class_method :scan_tokens

  # Single SQL fetch: any row whose display_name OR any alias CONTAINS any
  # query token as a substring. ILIKE is index-friendly (pg_trgm GIN) while
  # the regex \m...\M (POSIX word boundary) was NOT — it forced a seq scan.
  #
  # Word-boundary semantics are preserved by post-filtering in Ruby inside
  # `resolve` (the `haystack.match?(/\b...\b/)` call). The pre-filter widens
  # the candidate set conservatively (LIMIT 50) so the post-filter still
  # rejects substring noise like "esquemadocumento" for "esquema".
  def self.candidates_for(tokens, account:)
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

    prelim = KbDocument.where(account_id: account.id)
                       .where(conditions.join(" OR "), *params)
                       .limit(50)
                       .to_a

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
