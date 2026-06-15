# frozen_string_literal: true

# Strict-first JSON parser for LLM outputs.
#
# Claude occasionally returns otherwise-valid JSON with literal double quotes
# inside long markdown strings, especially chunks[].text. The fallback below only
# escapes quotes that cannot legally close the current JSON string based on the
# surrounding JSON state. It does not synthesize keys, braces, commas, or values.
class LlmJsonParser
  def self.parse(text)
    new(text).parse
  end

  def self.parseable?(text)
    parse(text)
    true
  rescue JSON::ParserError
    false
  end

  def initialize(text)
    @text = text
  end

  def parse
    normalized = normalize(@text)
    JSON.parse(normalized)
  rescue JSON::ParserError => original_error
    repaired = repair_unescaped_value_quotes(normalized)
    raise original_error if repaired == normalized

    JSON.parse(repaired)
  end

  private

  def normalize(text)
    s = text.to_s.strip
    return s unless s.start_with?("```")

    s.sub(/\A```(?:json)?\s*\n?/i, "").sub(/\n?```\s*\z/, "").strip
  end

  def repair_unescaped_value_quotes(text)
    output = +""
    stack = []
    in_string = false
    escaped = false
    string_role = nil

    text.each_char.with_index do |char, index|
      if in_string
        if escaped
          output << char
          escaped = false
        elsif char == "\\"
          output << char
          escaped = true
        elsif char == "\""
          if string_closes?(string_role, text, index, stack)
            output << char
            in_string = false
            close_string!(stack, string_role)
            string_role = nil
          else
            output << "\\\""
          end
        else
          output << char
        end
        next
      end

      case char
      when "\""
        in_string = true
        string_role = expecting_object_key?(stack) ? :key : :value
        output << char
      when "{"
        stack << { type: :object, state: :expect_key }
        output << char
      when "["
        stack << { type: :array, state: :expect_value }
        output << char
      when ":"
        stack.last[:state] = :expect_value if stack.last&.fetch(:type) == :object
        output << char
      when ","
        if stack.last
          stack.last[:state] = stack.last[:type] == :object ? :expect_key : :expect_value
        end
        output << char
      when "}", "]"
        stack.pop
        mark_value_complete!(stack)
        output << char
      else
        output << char
      end
    end

    output
  end

  def expecting_object_key?(stack)
    stack.last&.fetch(:type) == :object && stack.last[:state] == :expect_key
  end

  def string_closes?(role, text, index, stack)
    next_index = next_significant_index(text, index + 1)
    next_char = text[next_index]

    if role == :key
      next_char == ":"
    else
      return true if next_char.nil? || [ "}", "]" ].include?(next_char)

      next_char == "," && comma_closes_value?(stack, text, next_index)
    end
  end

  def next_significant_char(text, start_index)
    text[next_significant_index(text, start_index)]
  end

  def next_significant_index(text, start_index)
    index = start_index
    index += 1 while index < text.length && text[index].match?(/\s/)
    index
  end

  def comma_closes_value?(stack, text, comma_index)
    container = stack.last
    return true unless container&.fetch(:type) == :object

    key_start = next_significant_index(text, comma_index + 1)
    return false unless text[key_start] == "\""

    key_end = json_string_end(text, key_start)
    key_end && next_significant_char(text, key_end + 1) == ":"
  end

  def json_string_end(text, quote_index)
    index = quote_index + 1
    escaped = false

    while index < text.length
      char = text[index]
      if escaped
        escaped = false
      elsif char == "\\"
        escaped = true
      elsif char == "\""
        return index
      end
      index += 1
    end

    nil
  end

  def close_string!(stack, role)
    if role == :key
      stack.last[:state] = :expect_colon if stack.last&.fetch(:type) == :object
    else
      mark_value_complete!(stack)
    end
  end

  def mark_value_complete!(stack)
    stack.last[:state] = :after_value if stack.last
  end
end
