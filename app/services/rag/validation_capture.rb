# frozen_string_literal: true

module Rag
  # In-process record of a request this process is already about to send.
  # Inactive unless a local validation runner opens a capture block.
  # It does not call Bedrock and it does not reconstruct an earlier run.
  module ValidationCapture
    SECRET_KEY = /access.?key|secret|password|token|authorization|credential/i
    SECRET_TEXT = /AKIA[A-Z0-9]{8,}/

    module_function

    def capture
      previous = Thread.current[:rag_validation_capture]
      previous_correlation = Thread.current[:rag_validation_correlation]
      bucket = []
      Thread.current[:rag_validation_capture] = bucket
      yield bucket
      bucket
    ensure
      Thread.current[:rag_validation_capture] = previous
      Thread.current[:rag_validation_correlation] = previous_correlation
    end

    def correlation=(value)
      Thread.current[:rag_validation_correlation] = value
    end

    def record(kind, payload)
      bucket = Thread.current[:rag_validation_capture]
      return unless bucket

      event = {
        "kind" => kind.to_s,
        "correlation_id" => Thread.current[:rag_validation_correlation]
      }
      event.merge!(sanitize(payload))
      bucket << event
      nil
    end

    def sanitize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          name = key.to_s
          next if name.match?(SECRET_KEY)

          out[name] = sanitize(item)
        end
      when Array
        value.map { |item| sanitize(item) }
      when Numeric, TrueClass, FalseClass, NilClass
        value
      else
        value.to_s.gsub(SECRET_TEXT, "[redacted]")
      end
    end
  end
end
