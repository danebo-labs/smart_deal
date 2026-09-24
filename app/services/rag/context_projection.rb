# frozen_string_literal: true

module Rag
  # Search text for one Retrieve. The generation call keeps the technician's
  # question. Measured 22-sep: the words "normal" and "fallo" rank LED-status
  # tables ahead of SEGURIDADES page 93, while "THYSSEN-E SERIE E LED" leaves
  # that page inside the open window of 8.
  class ContextProjection
    HYPHENATED = /\b(\p{L}{3,})-([A-Z0-9]{1,4})\b/
    PRINTED_SECTION = { "THYSSENE" => "SERIE E" }.freeze

    def self.applicable?(question)
      new(question).applicable?
    end

    def self.search_text(question)
      new(question).search_text
    end

    def self.hyphenated_model(question)
      new(question).hyphenated_model
    end

    def self.printed_section_for(model)
      PRINTED_SECTION[model.to_s.upcase.gsub(/[^A-Z0-9]/, "")]
    end

    def initialize(question)
      @question = question.to_s
    end

    def applicable?
      hyphenated_model.present? || spring_adjustment?
    end

    def search_text
      return @question.strip if procedural_query?

      parts = []
      if (model = hyphenated_model)
        parts << model.upcase
        printed = self.class.printed_section_for(model)
        parts << printed if printed
      end
      parts << "Fuji Yida" if fuji_yida?
      parts << "resortes" if spring_adjustment?
      parts << "fijación" if @question.match?(/fijaci[oó]n/i)
      parts << "ajustar" if @question.match?(/ajust/i)
      parts << "LED" if hyphenated_model && @question.match?(/\bLEDs?\b/i)
      parts.uniq.join(" ")
    end

    def hyphenated_model
      match = @question.match(HYPHENATED)
      return nil unless match
      return nil unless KbDocumentResolver::BRANDS.include?(match[1].downcase)

      "#{match[1]}-#{match[2]}"
    end

    def spring_adjustment?
      @question.match?(/resortes?/i) && @question.match?(/ajust/i)
    end

    def procedural_query?
      RagRetrievalProfile.new(question: @question).procedural_query?
    end

    def fuji_yida?
      @question.match?(/\bfuji\b/i) && @question.match?(/\byida\b/i)
    end
  end
end
