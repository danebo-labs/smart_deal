# frozen_string_literal: true

# Renders a bounded-length, plain-text digest of a page's resolved topology,
# for Fase 4 of docs/rag/plan_conocimiento_visual.md (not built yet) to place
# in user content ahead of the ingestion prompt. Offline groundwork only —
# nothing calls this in production.
#
# Deliberately NOT a dump of PdfLayoutExtractor#words: only what generation
# actually needs — resolved edges, the bboxes of the labels those edges name,
# and the image inventory (size_class + bbox) that anchors T2 crops. Over
# MAX_TOKENS, returns nil rather than silently truncate.
class PageLayoutDigest
  MAX_TOKENS = 400

  # @param layout [Hash] a PdfLayoutExtractor.extract result
  # @param edges  [Array<Hash>] TopologyEdgeDeriver.derive result (Fase 3, empty for now)
  # @return [String, nil]
  def self.render(layout, edges)
    new(layout, edges).render
  end

  def initialize(layout, edges)
    @layout = layout || {}
    @edges  = Array(edges)
  end

  def render
    text = build_text
    return nil if text.blank?

    if estimate_tokens(text) > MAX_TOKENS
      Rails.logger.warn("PageLayoutDigest: page #{@layout[:page_number].inspect} digest exceeds #{MAX_TOKENS} tokens, dropped")
      return nil
    end

    text
  end

  private

  def build_text
    [ edges_section, labels_section, images_section ].compact.join("\n\n")
  end

  def edges_section
    return nil if @edges.empty?

    lines = @edges.map { |e| "#{e[:from]} -> #{e[:to]} (#{e[:method]}): #{e[:evidence]}" }
    ([ "EDGES:" ] + lines).join("\n")
  end

  def labels_section
    return nil if @edges.empty?

    names = @edges.flat_map { |e| [ e[:from], e[:to] ] }.uniq
    words = Array(@layout[:words])
    lines = names.filter_map do |name|
      word = words.find { |w| w[:text] == name }
      "#{name}: #{word[:bbox]}" if word
    end

    return nil if lines.empty?

    ([ "LABELS:" ] + lines).join("\n")
  end

  def images_section
    images = Array(@layout[:images])
    return nil if images.empty?

    lines = images.map { |img| "#{img[:name]} #{img[:size_class]} #{img[:bbox]}" }
    ([ "IMAGES:" ] + lines).join("\n")
  end

  # No tokenizer dependency exists on this offline path (no new gems).
  # Whitespace-delimited word count is a deliberately generous proxy — short
  # all-caps labels and coordinate tuples tokenize close to 1:1, so this
  # under-counts, if at all, by too little to let a truly oversized digest
  # through.
  def estimate_tokens(text)
    text.split(/\s+/).length
  end
end
