# frozen_string_literal: true

module Rag
  # The next numbered step of the section whose quote the previous answer
  # already used. A question, a quote outside a table, and the last step of
  # a section produce nothing. The text is copied from that section.
  class ProcedureContinuation
    QUOTE = /«([^»]+)»/
    HEADING = /\A\s*\*\*([^*]+)\*\*\s*\z/
    MIN_WORDS = 4

    def self.prompt(...)
      new(...).prompt
    end

    def initialize(history:, chunks:, question:)
      @history = Array(history)
      @chunks = Array(chunks)
      @question = question.to_s.strip
    end

    def prompt
      return nil if @question.blank? || @question.match?(/[?¿]/)

      quoted, number = last_cited_quote
      return nil unless quoted && number

      body = source_body(number)
      return nil unless body&.include?(quoted)

      heading, action = next_action(body, quoted)
      return nil if heading.blank? || action.blank?

      "Apartado en curso de la fuente [#{number}], título «#{heading}». " \
        "El paso que sigue en ese mismo apartado es: «#{action}» [#{number}]. " \
        "Nombra ese título y cita ese paso literal, con su [n]. " \
        "La lectura, la intervención y quién la reportó van en otra oración, sin [n]. " \
        "No lo cambies por un ajuste de otro apartado."
    end

    private

    def last_cited_quote
      text = last_assistant
      return nil if text.blank?

      found = nil
      text.to_enum(:scan, QUOTE).each do
        match = Regexp.last_match
        quoted = match[1].to_s.strip
        next if words(quoted) < MIN_WORDS

        number = text[match.end(0), 24].to_s[/\A\s*\[(\d+)\]/, 1]&.to_i
        number = source_containing(quoted) if number.nil? || number < 1
        found = [ quoted, number ] if number
      end
      found
    end

    def last_assistant
      turn = @history.reverse.find { |item| (item[:role] || item["role"]).to_s == "assistant" }
      (turn&.[](:text) || turn&.[]("text")).to_s
    end

    def source_containing(quoted)
      hits = []
      @chunks.each_with_index do |chunk, index|
        next if CompanionCaseRecord.gap?(chunk)
        next unless CompanionCaseRecord.text_of(chunk).include?(quoted)

        hits << CompanionCaseRecord.number_of(chunk, index)
      end
      hits.one? ? hits.first : nil
    end

    def source_body(number)
      @chunks.each_with_index do |chunk, index|
        next if CompanionCaseRecord.gap?(chunk)
        return CompanionCaseRecord.text_of(chunk) if CompanionCaseRecord.number_of(chunk, index) == number
      end
      nil
    end

    def next_action(body, quoted)
      lines = body.lines.map { |line| line.delete_suffix("\n") }
      quote_index = lines.each_index.select { |index| lines[index].include?(quoted) && row_cells(lines[index]) }.last
      return nil unless quote_index

      heading_index = (0..quote_index).reverse_each.find { |index| lines[index].match?(HEADING) }
      return nil unless heading_index

      stop = lines[(heading_index + 1)..].index { |line| line.match?(HEADING) }
      finish = stop.nil? ? lines.length - 1 : heading_index + stop
      rows = lines[heading_index..finish].filter_map { |line| row_cells(line) }
      current = rows.find { |cells| cells.any? { |cell| cell.include?(quoted) } }
      return nil unless current&.first.to_s.match?(/\A\d+\z/)

      step = current.first.to_i
      later = rows.select { |cells| cells.first.to_s.match?(/\A\d+\z/) && cells.first.to_i > step }
      return nil if later.empty?

      following = later.map { |cells| cells.first.to_i }.min
      action = later.select { |cells| cells.first.to_i == following }.map { |cells| cells[1].to_s.strip }.find { |text|
        words(text) >= MIN_WORDS && body.include?(text)
      }
      heading = lines[heading_index][HEADING, 1].to_s.strip.sub(/:\z/, "").strip
      [ heading, action ]
    end

    def row_cells(line)
      stripped = line.to_s.strip
      return nil unless stripped.start_with?("|")
      return nil if stripped.match?(/\A\|[\s:|-]+\|\s*\z/)

      cells = stripped.split("|").map(&:strip).reject(&:empty?)
      cells.presence
    end

    def words(text)
      text.to_s.split.count { |word| word.match?(/[[:alnum:]]/) }
    end
  end
end
