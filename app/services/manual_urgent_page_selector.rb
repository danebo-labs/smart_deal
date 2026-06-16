# frozen_string_literal: true

require "set"

# Deterministically chooses a small number of pages to parse immediately when a
# technician uploads a long PDF together with a question. The complete manual
# still goes through Batch; this selector only feeds the urgent direct path.
class ManualUrgentPageSelector
  DEFAULT_MAX_PAGES = 3

  STOPWORDS = Set.new(%w[
    que qué cual cuál como cómo para por con sin los las una uno unos unas del
    este esta estos estas ese esa eso esos esas sobre entre desde donde dónde
    what which where when how this that these those with from about into need
    the and are was were can could should would have has
  ]).freeze

  URGENCY_TERMS = Set.new(%w[
    emergencia emergency rescate rescue seguridad safety riesgo danger falla fault
    alarm alarma error bloqueo bloqueado detener parada stop freno brake evacuacion
    evacuation atrapado trapped reset reinicio
  ]).freeze

  TECHNICAL_TEXT_PATTERN = /
    seguridad|safety|emergencia|emergency|rescate|rescue|fall[ao]|fault|alarm[ao]?|
    error|troubleshooting|diagn[oó]stico|procedimiento|procedure|mantenimiento|
    maintenance|instalaci[oó]n|installation|commissioning|diagrama|diagram|wiring|
    cableado|freno|brake|puerta|door|control|controller|sensor|encoder
  /ix.freeze

  Page = Struct.new(:number, :binary, :model, :score, :reason, keyword_init: true)

  # @return [Array<Page>] selected pages, ordered by page number
  def select(binary:, filename:, query:, max_pages: DEFAULT_MAX_PAGES)
    limit = max_pages.to_i
    return [] unless limit.positive?

    query_tokens = tokenize(query)
    return [] if query_tokens.empty?

    pages = routed_pages(binary: binary, filename: filename)
    return [] if pages.empty?

    scored = pages.map { |page| score_page(page, query_tokens) }
    selected = scored.select { |candidate| candidate[:score].positive? }
                     .sort_by { |candidate| [ -candidate[:score], candidate[:page].number ] }
                     .first(limit)

    selected = fallback_pages(scored, limit) if selected.empty?

    selected.sort_by { |candidate| candidate[:page].number }.map do |candidate|
      page = candidate[:page]
      Page.new(
        number: page.number,
        binary: page.binary,
        model: page.model.presence || BatchChunkingPrompt::MODEL_TEXT,
        score: candidate[:score],
        reason: candidate[:reason]
      )
    end
  end

  private

  def routed_pages(binary:, filename:)
    classification = FileMultimodalRouter.classify(
      binary: binary,
      content_type: "application/pdf",
      filename: filename
    )

    return classification.pages if classification.pages.present?

    pages = []
    PdfPageSplitterService.new(binary).each_page do |page_number, page_binary|
      pages << FileMultimodalRouter::PageInfo.new(
        number: page_number,
        binary: page_binary,
        model: BatchChunkingPrompt::MODEL_TEXT
      )
    end
    pages
  end

  def score_page(page, query_tokens)
    text = extract_text(page.binary)
    normalized = normalize(text)
    page_tokens = tokenize(text).to_set
    matches = query_tokens.select { |token| page_tokens.include?(token) || normalized.include?(token) }

    score = matches.size * 10
    score += matches.count { |token| URGENCY_TERMS.include?(token) } * 8
    score += 3 if normalized.match?(TECHNICAL_TEXT_PATTERN) && matches.any?
    score += 4 if page.model.to_s == BatchChunkingPrompt::MODEL_MULTIMODAL && matches.any?

    reason = matches.any? ? "query_match:#{matches.first(5).join(',')}" : "no_query_match"
    { page: page, score: score, reason: reason, text: text }
  end

  def fallback_pages(scored, limit)
    technical = scored.select do |candidate|
      text = normalize(candidate[:text])
      text.length > 30 && text.match?(TECHNICAL_TEXT_PATTERN)
    end

    pool = technical.presence || scored
    pool.sort_by { |candidate| candidate[:page].number }
        .first(limit)
        .map { |candidate| candidate.merge(score: [ candidate[:score], 1 ].max, reason: "technical_fallback") }
  end

  def extract_text(page_binary)
    reader = PDF::Reader.new(StringIO.new(page_binary))
    reader.pages.first&.text.to_s
  rescue StandardError
    page_binary.to_s
  end

  def tokenize(text)
    normalize(text).scan(/[a-z0-9]{3,}/).reject { |token| STOPWORDS.include?(token) }.uniq
  end

  def normalize(text)
    I18n.transliterate(text.to_s.downcase).gsub(/\s+/, " ").strip
  end
end
