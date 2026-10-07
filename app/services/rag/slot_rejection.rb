# frozen_string_literal: true

module Rag
  # A rejected slot value is removed only where the text states that slot.
  # The digit in "LED 8" is not the rejected fault code 8.
  module SlotRejection
    module_function

    def attributable?(text, slot, value)
      normalized = FollowupQueryRewriter.normalize_label(text)
      label = FollowupQueryRewriter.normalize_label(value)
      return false if label.blank?
      return code_statement?(normalized, label) if slot.to_s == "fault_code"
      return false if label.match?(/\A\d+\z/)

      normalized.match?(/(?<![[:alnum:]])#{Regexp.escape(label)}(?![[:alnum:]])/)
    end

    def code_statement?(normalized, label)
      normalized.match?(/\b(?:codigo|code|error|fault)\s+(?:n\s+)?#{Regexp.escape(label)}\b/)
    end

    def excise_text(text, slot, value)
      source = text.to_s
      number = Regexp.escape(value.to_s)
      cleaned = if slot.to_s == "fault_code"
        source
          .gsub(/\b(?:c[oó]digo|code|error|fault)\s+(?:n\s+)?#{number}\b/i, " ")
          .gsub(/\bno\s+#{number}\b/i, " ")
      elsif value.to_s.match?(/\A\d+\z/)
        source
      else
        source.gsub(/(?<![[:alnum:]])#{number}(?![[:alnum:]])/i, " ")
      end
      cleaned.squish
    end
  end
end
