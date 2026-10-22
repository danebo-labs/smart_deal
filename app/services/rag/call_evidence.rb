# frozen_string_literal: true

module Rag
  # One directory per model call. The files are the request that was sent,
  # the raw client payload, the text shown to the technician, the state and
  # history used for that call, the sources, and the token consumption.
  # linkage.json joins them by correlation_id. A missing price stays absent.
  class CallEvidence
    FILES = {
      "request" => "request.txt",
      "raw_response" => "raw_response.txt",
      "presented_response" => "presented_response.txt",
      "state" => "state.json",
      "history" => "history.json",
      "sources" => "sources.json",
      "consumption" => "consumption.json"
    }.freeze

    def self.capture_call(directory:, client:, correlation_id:, prompt:, state:, history:, sources:, presenter:, model_id: nil, max_tokens: nil, temperature: nil)
      events = ValidationCapture.capture do
        ValidationCapture.correlation = correlation_id
        client.generate_text(
          prompt,
          model_id: model_id,
          max_tokens: max_tokens,
          temperature: temperature,
          tracking: { correlation_id: correlation_id }
        )
      end
      materialize(
        directory,
        events,
        contexts: {
          "generate_text" => {
            request: prompt,
            presented: nil,
            presenter: presenter,
            state: state,
            history: history,
            sources: sources
          }
        }
      )
    end

    # events are the in-memory capture, before large strings are spilled.
    # contexts is keyed by operation. A call whose context is missing still
    # keeps the request and the raw payload from the events.
    def self.materialize(directory, events, contexts: {})
      extract_calls(events).map.with_index(1) do |call, index|
        context = contexts[call[:operation]] || {}
        raw_text = raw_text_of(call[:raw])
        presented = context.key?(:presented) && !context[:presenter] ? context[:presented] : nil
        presented = context[:presenter].call(raw_text) if context[:presenter] && raw_text
        write(
          directory,
          index: index,
          correlation_id: call[:correlation_id],
          operation: call[:operation],
          attempt: call[:attempt],
          request: text_of(call[:request], request_key(call[:operation])) || context[:request],
          raw_response: raw_text,
          presented_response: presented,
          state: context[:state],
          history: context[:history],
          sources: context.fetch(:sources, nil),
          consumption: consumption_of(call)
        )
      end
    end

    def self.write(directory, index:, correlation_id:, operation:, attempt:, request:, raw_response:, presented_response:, state:, history:, sources:, consumption:)
      safe = correlation_id.to_s.gsub(/[^A-Za-z0-9_-]/, "_")
      attempt_label = attempt.nil? ? "na" : attempt.to_s
      folder = Pathname(directory).join(format("%02d-%s-%s-%s", index, operation, attempt_label, safe))
      folder.mkpath
      request_text = request.to_s
      raw_text = raw_response.is_a?(String) ? raw_response : raw_response.nil? ? nil : JSON.generate(raw_response.as_json)
      presented_text = presented_response.nil? ? nil : presented_response.to_s
      folder.join(FILES["request"]).binwrite(request_text)
      folder.join(FILES["raw_response"]).binwrite(raw_text.to_s)
      folder.join(FILES["presented_response"]).binwrite(presented_text.to_s)
      write_json(folder.join(FILES["state"]), envelope(correlation_id, operation, "state", state))
      write_json(folder.join(FILES["history"]), envelope(correlation_id, operation, "history", history))
      write_json(folder.join(FILES["sources"]), envelope(correlation_id, operation, "sources", sources))
      write_json(folder.join(FILES["consumption"]), consumption.merge("correlation_id" => correlation_id, "operation" => operation))
      linkage = {
        "correlation_id" => correlation_id,
        "operation" => operation,
        "attempt" => attempt,
        "files" => FILES,
        "request_sha256" => Digest::SHA256.hexdigest(request_text),
        "raw_sha256" => raw_text.nil? ? nil : Digest::SHA256.hexdigest(raw_text),
        "presented_sha256" => presented_text.nil? ? nil : Digest::SHA256.hexdigest(presented_text),
        "request_absent" => request.nil?,
        "raw_absent" => raw_text.nil?,
        "presented_absent" => presented_text.nil?
      }
      write_json(folder.join("linkage.json"), linkage)
      folder
    end

    def self.extract_calls(events)
      calls = []
      Array(events).each do |event|
        next unless event.is_a?(Hash)

        if (operation = request_operation(event))
          calls << {
            operation: operation,
            request: event,
            raw: nil,
            correlation_id: event["correlation_id"].to_s,
            attempt: event["attempt"]
          }
          next
        end

        operation = result_operation(event)
        next if operation.nil?

        call = calls.reverse.find { |item|
          item[:operation] == operation && item[:raw].nil? &&
            item[:correlation_id] == event["correlation_id"].to_s &&
            (item[:attempt].nil? || event["attempt"].nil? || item[:attempt] == event["attempt"])
        }
        call[:raw] = event if call
      end
      calls
    end

    def self.request_operation(event)
      return "generate_text" if event["kind"] == "generate_text" && event["result"] == "prepared"
      return "interpreter" if event["kind"] == "interpreter_request" && event["result"] == "prepared"

      nil
    end

    def self.result_operation(event)
      return "generate_text" if event["kind"] == "generation_result"
      return "interpreter" if event["kind"] == "interpreter_raw"

      nil
    end

    def self.request_key(operation)
      operation == "interpreter" ? "message_text" : "prompt"
    end

    def self.text_of(event, key)
      return nil unless event.is_a?(Hash)

      value = event[key]
      value.is_a?(String) ? value : nil
    end

    def self.raw_text_of(event)
      return nil unless event.is_a?(Hash)

      if event["kind"] == "generation_result"
        value = event["answer"]
        return value if value.is_a?(String) || value.nil?

        return JSON.generate(value.as_json)
      end

      value = event["tool_input"]
      return nil if value.nil?
      return value if value.is_a?(String)

      JSON.generate(value.as_json)
    end

    def self.consumption_of(call)
      raw = call[:raw]
      input = raw.is_a?(Hash) ? raw["input_tokens"] : nil
      output = raw.is_a?(Hash) ? raw["output_tokens"] : nil
      model_id = call[:request].is_a?(Hash) ? call[:request]["model_id"] : nil
      row = {
        "attempt" => call[:attempt],
        "model_id" => model_id,
        "input_tokens" => input.is_a?(Numeric) ? input.to_i : nil,
        "output_tokens" => output.is_a?(Numeric) ? output.to_i : nil
      }
      if input.is_a?(Numeric) && output.is_a?(Numeric) && model_id.present?
        row["cost_usd"] = format("%.6f", LocalPassLedger.price(model_id, input, output))
        row["cost_kind"] = "calculated"
      else
        row["cost_kind"] = "unavailable"
      end
      row
    end

    def self.envelope(correlation_id, operation, field, value)
      {
        "correlation_id" => correlation_id,
        "operation" => operation,
        "provenance" => value.nil? ? "uncaptured" : "observed",
        field => value.nil? ? nil : value.as_json
      }
    end

    def self.write_json(path, payload)
      path.write(JSON.generate(payload))
    end
    private_class_method :write_json, :envelope, :consumption_of, :raw_text_of, :text_of, :request_key,
      :result_operation, :request_operation, :extract_calls
  end
end
