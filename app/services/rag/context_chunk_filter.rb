# frozen_string_literal: true

module Rag
  # Keeps a retrieved chunk only when its body, below the alias header, is the
  # equipment and the component in the question. A shared brand stem in
  # [SEARCH_ALIASES:] is not that match.
  class ContextChunkFilter
    HEADER_LINE = /\A\[[A-Z_]+:[^\n]*\]\n?/

    def self.keep?(question, chunk)
      new(question).keep?(chunk)
    end

    def initialize(question)
      @projection = ContextProjection.new(question)
      @question = question.to_s
    end

    def keep?(chunk)
      body = body_below_header(chunk)
      return false unless equipment?(body, section_identity(chunk))
      return false unless component?(body)

      true
    end

    private

    def equipment?(body, section)
      model = @projection.hyphenated_model
      if model
        return true if body.match?(/#{Regexp.escape(model)}/i)

        printed = ContextProjection.printed_section_for(model)
        return false if printed.blank?

        family = model.partition("-").first
        return section.to_s.strip.casecmp?(family) && body.match?(/\b#{Regexp.escape(printed)}\b/i)
      end

      if @projection.fuji_yida?
        return false unless body.match?(/\bfuji\b/i) && body.match?(/\byida\b/i)
      end

      true
    end

    def component?(body)
      return false if @projection.spring_adjustment? && !body.match?(/resortes?/i)

      true
    end

    def body_below_header(chunk)
      text = chunk[:content].to_s.dup
      text.sub!(HEADER_LINE, "") while text.match?(HEADER_LINE)
      text
    end

    def section_identity(chunk)
      chunk[:metadata].to_h.stringify_keys["section_identity"]
    end
  end
end
