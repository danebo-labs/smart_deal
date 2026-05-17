# frozen_string_literal: true

# Ports the Lambda `generate_aliases` function (Python) to Ruby.
# Used as a fallback when the LLM returns an empty aliases array so that no chunk
# is ever written with `[SEARCH_ALIASES: ]\n\n` (empty string).
#
# Algorithm matches the Lambda exactly:
#   1. Strip file extension.
#   2. Normalize: replace [-_] with space, downcase, split into tokens.
#   3. Single tokens with length >= 4.
#   4. Consecutive bigrams where BOTH words have length >= 4.
#   5. Combine, deduplicate, sort alphabetically.
#
# Applies to BOTH the web custom chunking path AND the existing bulk path.
module LambdaParityAliasFallback
  # @param filename [String] e.g. "952408286-Orona-basic-arc-arca-I.pdf"
  # @return [Array<String>] sorted aliases derived from the filename
  def self.generate(filename)
    return [] if filename.blank?

    base   = File.basename(filename.to_s, ".*")
    words  = base.gsub(/[-_]/, " ").downcase.split.reject(&:empty?)

    tokens = words.select { |w| w.length >= 4 }

    bigrams = words.each_cons(2).filter_map do |a, b|
      "#{a} #{b}" if a.length >= 4 && b.length >= 4
    end

    (tokens + bigrams).uniq.sort
  end
end
