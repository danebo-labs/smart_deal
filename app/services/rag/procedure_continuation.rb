# frozen_string_literal: true

module Rag
  # The next numbered step of the section whose quote the previous answer
  # already used. A question, a quote outside a table, and the last step of
  # a section produce nothing. The text is copied from that section.
  class ProcedureContinuation
    QUOTE = /«([^»]+)»/
    HEADING = /\A\s*\*\*([^*]+)\*\*\s*\z/
    MIN_WORDS = 4

    STOP_WORDS = %w[esta estan este para como desde hasta sobre entre cuando donde tiene tienen].freeze
    # A procedure that says to start over after a skipped step or a wrong
    # value. The sentence is copied from that source; it is not a new step.
    GATE = /
      \b[Ss]i\b
      [^.]{0,180}?
      \b(?:olvid|incorrect|equivoc|omit|salt)\p{L}*
      [^.]{0,180}?
      \b(?:empez|reinici|repet|rehac|recomenz)\p{L}*
    /ix
    # A reported unit. A digit glued to a model token («KDL16 y») is not one.
    READING = /(?<![[:alnum:]])\d+(?:[.,]\d+)?\s*[A-Za-zµ%]{1,6}/

    def self.prompt(...)
      new(...).prompt
    end

    # The generator can name the section and drop a condition the technician
    # already gave. The omitted excerpt is their words, placed ahead of the
    # answer. An excerpt already reflected, or one that is this turn, stays out.
    # A restart condition of a source the answer cites is quoted after it
    # while the technician has not confirmed that condition.
    def self.carry(text, episode:, question:, sources: [])
      new(history: [], chunks: sources, question: question, episode: episode).carry(text)
    end

    def initialize(history:, chunks:, question:, episode: nil)
      @history = Array(history)
      @chunks = Array(chunks)
      @question = question.to_s.strip
      @episode = episode
    end

    def prompt
      return nil if @question.blank? || @question.match?(/[?¿]/)

      number, heading, action = continuation_for(last_assistant)
      return nil if action.blank?

      [ continuation_text(number, heading, action), prior_conditions ].compact_blank.join(" ")
    end

    def carry(text)
      body = text.to_s
      missing = missing_conditions(body)
      step = omitted_step(body)
      gate = open_prerequisite(body)
      return body if missing.empty? && step.nil? && gate.nil?

      [
        missing.map { |excerpt| "Condición ya reportada: #{excerpt}." }.join("\n"),
        body,
        step,
        gate
      ].compact_blank.join("\n\n").strip
    end

    private

    def continuation_text(number, heading, action)
      "Apartado en curso de la fuente [#{number}], título «#{heading}». " \
        "El paso que sigue en ese mismo apartado es: «#{action}» [#{number}]. " \
        "Nombra ese título y cita ese paso literal, con su [n]. " \
        "La lectura, la intervención y quién la reportó van en otra oración, sin [n]. " \
        "No lo cambies por un ajuste de otro apartado."
    end

    # A section title does not replace a condition the technician already gave.
    def condition_texts
      active = @episode.is_a?(ActiveEpisode) ? @episode : ActiveEpisode.parse(@episode)
      return [] if active.blank?

      folded = I18n.transliterate(@question).downcase
      Array(active.excerpts).filter_map { |row| row["text"].to_s.strip.presence }.uniq.reject { |text|
        folded.include?(I18n.transliterate(text).downcase)
      }
    end

    def prior_conditions
      kept = condition_texts.first(3)
      return nil if kept.empty?

      "El técnico ya dijo: #{kept.join(' / ')}. Si esa condición sigue vigente, consérvala en la oración de la lectura y no la sustituyas por el título del apartado."
    end

    def missing_conditions(answer)
      active = @episode.is_a?(ActiveEpisode) ? @episode : ActiveEpisode.parse(@episode)
      return [] if active.blank?

      folded_answer = I18n.transliterate(answer.to_s).downcase
      condition_texts.reject { |text|
        folded = I18n.transliterate(text).downcase
        folded_answer.include?(folded) || reflected?(folded, folded_answer)
      }
    end

    # The cited source's own restart condition, still unconfirmed. A source
    # the answer does not cite contributes nothing.
    def open_prerequisite(answer)
      numbers = answer.scan(/\[(\d+)\]/).flatten.map(&:to_i).uniq
      numbers.filter_map { |number|
        body = source_body(number)
        sentence = gate_sentence(body)
        next if sentence.nil? || answer.include?(sentence) || already_stated?(sentence)

        "Prerrequisito de la fuente [#{number}], todavía sin confirmar: «#{sentence}» [#{number}]."
      }.first
    end

    def gate_sentence(body)
      return nil if body.blank?

      body.each_line do |line|
        line.strip.split(/(?<=[.!?])\s+/).each do |sentence|
          candidate = sentence.strip.sub(/[.!?]+\z/, "").strip
          next unless candidate.match?(GATE) && words(candidate) >= MIN_WORDS && body.include?(candidate)

          return candidate
        end
      end
      nil
    end

    def already_stated?(sentence)
      folded = I18n.transliterate(sentence).downcase
      blob = I18n.transliterate([ @question, *condition_texts ].join("\n")).downcase
      blob.include?(folded)
    end

    def reflected?(excerpt, folded_answer)
      words = excerpt.scan(/[[:alpha:]]{4,}/).uniq.reject { |word| STOP_WORDS.include?(word) }
      words.empty? || words.all? { |word| folded_answer.match?(/\b#{Regexp.escape(word)}\b/) }
    end

    # The last step quoted before the answer's question. A later section named
    # after that question, and a restart sentence that is not a table row, do
    # not replace it. With no question, the last row that still has a next
    # step is the one in progress.
    def continuation_for(text)
      return nil if text.blank?

      boundary = text.rindex(/[?¿]/)
      scoped = boundary ? text[0...boundary] : text
      actionable_quote(scoped) || (boundary ? actionable_quote(text) : nil)
    end

    def actionable_quote(text)
      found = nil
      text.to_enum(:scan, QUOTE).each do
        match = Regexp.last_match
        quoted = match[1].to_s.strip
        next if words(quoted) < MIN_WORDS

        number = text[match.end(0), 24].to_s[/\A\s*\[(\d+)\]/, 1]&.to_i
        number = source_containing(quoted) if number.nil? || number < 1
        next unless number

        body = source_body(number)
        next unless body&.include?(quoted)

        heading, action = next_action(body, quoted)
        next if heading.blank? || action.blank?

        found = [ number, heading, action ]
      end
      found
    end

    # The technician already reported a reading and the answer cited the
    # current row, but left out that row's next step.
    def omitted_step(answer)
      return nil unless @question.match?(READING)

      number, heading, action = continuation_for(answer)
      return nil if action.blank? || answer.include?(action)

      "El paso que sigue de #{heading} es: «#{action}» [#{number}]."
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
