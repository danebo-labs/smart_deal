# frozen_string_literal: true

module Rag
  # Local, explicit record of a flow this process is already running.
  # Inactive until a caller opens #capture. Opening it does not change queries,
  # prompts, routes, responses, or remote calls. Any diagnostic can reuse the
  # same block; nothing here is tied to a fixture or a session id.
  module ValidationCapture
    # Exact credential names. max_tokens, input_tokens, and token_source stay.
    SECRET_KEYS = %w[
      accesskey accesskeyid awsaccesskeyid
      secret secretaccesskey awssecretaccesskey
      password passwordconfirmation
      token sessiontoken securitytoken
      authorization credential credentials apikey
    ].freeze
    SECRET_TEXT = /AKIA[A-Z0-9]{8,}/
    SIGNED_URL = %r{https?://[^\s"']+}i
    SCOPE_KEYS = %w[sha session_id episode_id account_id user_id correlation_root turn run_id].freeze
    TEMPLATE_MARKERS = [ "$search_results$", "$output_format_instructions$", "$query$" ].freeze
    SCHEMA_VERSION = "danebo.audit.v1"
    # Inline text above this length is replaced, at export, by a body file.
    # The file keeps the complete sanitized value.
    SUMMARY_CHARS = 2_000
    SUMMARY_KEEP = 240
    PROVENANCE = %w[observed reconstructed uncaptured not_executed].freeze
    LINKAGE = {
      "join" => "Order events by sequence. Join on correlation_root when it is present. correlation_id is one segment of that turn: the technician segment, then the same id with the :query suffix. run_id, session_id, episode_id, and turn are copied only after the process knows them. An event that omits episode_id was recorded before the episode existed or before it was bound. Join it to later events by correlation_root and session_id. Do not copy a later episode_id backwards and call that copy observed. This run does not bind turn: the correlation is the turn label, and a missing turn is not turn 1.",
      "user_message" => "user_message.original is the technician text before ConversationSession::MAX_MSG_LENGTH. user_message.sent is the text after that limit. transform none means they are the same. transform truncate means original was cut and sent is what later stages received. interpreter_request carries that sent text inside its message. A turn_transform on the request is a second cut applied by TurnInterpreter, with the original it actually received. turn_transform.sent is that cut text. It is not a provider acknowledgement.",
      "model_call" => "prepared means the arguments were built and stored. It does not mean they left this process. attempt_started means this process is entering the client method. When the phase 1 guard is armed, that mark is written only after the guard allows the call. It does not mean the provider received the bytes. blocked means the guard stopped the call before the client method. returned means the client method returned a payload to this process. error means the client method or a later local step raised. Join those events by correlation_id, operation, and attempt when the fields are present. A missing attempt means this capture had not set one. interpreter_attempt with result attempt_started is the interpreter's entry mark. model_call carries attempt_started or blocked for the other guarded operations, and blocked for the interpreter.",
      "provenance" => {
        "observed" => "Read from the request, the response, or the state at the moment it was used.",
        "reconstructed" => "Derived afterwards from code or stored state. It is not proof of what was sent.",
        "uncaptured" => "The value existed or the stage ran, and this capture does not contain it.",
        "not_executed" => "This event says the stage did not run. A missing event is not that mark. A missing event means the stage was not observed. A nested provenance applies only to that field."
      },
      "bodies" => "A string longer than SUMMARY_CHARS is replaced by an evidence object. path is relative to the run directory. sha256 is the SHA-256 of the exported sanitized bytes. truncated false means the file is the complete sanitized value. summary_truncated true means the inline summary was cut. redacted true means a secret or a signed query was removed before export. absent true means the value was not available. An operational summary may be short only when that file is present.",
      "secrets" => "Credential keys, provider access-key tokens, and signed URL queries are removed. Full environment variables, authorization headers, and credentials are not exported."
    }.freeze

    module_function

    def active?
      !Thread.current[:rag_validation_capture].nil?
    end

    def capture
      previous = Thread.current[:rag_validation_capture]
      previous_correlation = Thread.current[:rag_validation_correlation]
      previous_scope = Thread.current[:rag_validation_scope]
      previous_attempt = Thread.current[:rag_validation_attempt]
      bucket = []
      Thread.current[:rag_validation_capture] = bucket
      Thread.current[:rag_validation_scope] = {}
      Thread.current[:rag_validation_attempt] = nil
      yield bucket
      bucket
    ensure
      Thread.current[:rag_validation_capture] = previous
      Thread.current[:rag_validation_correlation] = previous_correlation
      Thread.current[:rag_validation_scope] = previous_scope
      Thread.current[:rag_validation_attempt] = previous_attempt
    end

    def correlation=(value)
      Thread.current[:rag_validation_correlation] = value
    end

    # One turn inside an open capture. Restores the previous correlation and
    # attempt on the way out, including when the block raises. Scope labels
    # such as correlation_root stay in place.
    def with_turn(correlation_id)
      unless active?
        yield
      else
        previous_correlation = Thread.current[:rag_validation_correlation]
        previous_attempt = Thread.current[:rag_validation_attempt]
        self.correlation = correlation_id if correlation_id.present?
        Thread.current[:rag_validation_attempt] = nil
        begin
          yield
        ensure
          Thread.current[:rag_validation_correlation] = previous_correlation
          Thread.current[:rag_validation_attempt] = previous_attempt
        end
      end
    end

    # Labels the activator already knows. Unknown keys are ignored.
    def bind(fields)
      return unless active?

      scope = (Thread.current[:rag_validation_scope] ||= {})
      fields.to_h.each do |key, value|
        name = key.to_s
        next unless SCOPE_KEYS.include?(name)
        next if value.nil?

        scope[name] = value.is_a?(Numeric) || value == true || value == false ? value : value.to_s
      end
      nil
    end

    def attempt=(value)
      return unless active?

      Thread.current[:rag_validation_attempt] = value
    end

    def attempt_unless_set(value)
      return unless active?
      return unless Thread.current[:rag_validation_attempt].nil?

      Thread.current[:rag_validation_attempt] = value
    end

    def documentary_context(prompt)
      text = prompt.to_s
      return "template" if TEMPLATE_MARKERS.any? { |marker| text.include?(marker) }

      "resolved"
    end

    # Boundary of one model call. correlation_id and attempt are copied by
    # record when this capture already has them. Inactive capture stores nothing.
    def record_model_boundary(operation, result)
      record(
        "model_call",
        "operation" => operation.to_s,
        "result" => result.to_s
      )
    end

    def record(kind, payload)
      installed = false
      previous_hook = nil
      bucket = Thread.current[:rag_validation_capture]
      return unless bucket

      event = { "kind" => kind.to_s }
      correlation_id = Thread.current[:rag_validation_correlation]
      event["correlation_id"] = correlation_id if correlation_id.present?
      scope.each do |key, value|
        event[key] = value unless value.nil?
      end
      attempt = Thread.current[:rag_validation_attempt]
      event["attempt"] = attempt unless attempt.nil?
      redacted = false
      previous_hook = Thread.current[:rag_validation_redacting]
      Thread.current[:rag_validation_redacting] = -> { redacted = true }
      installed = true
      sanitized = sanitize(payload)
      event.merge!(sanitized)
      event["kind"] = kind.to_s
      event["sequence"] = bucket.size + 1
      label = sanitized["provenance"].to_s
      event["provenance"] = PROVENANCE.include?(label) ? label : "observed"
      event["redacted"] = true if redacted || sanitized["redacted"] == true
      event.delete("redacted") unless event["redacted"] == true
      bucket << event
      nil
    ensure
      Thread.current[:rag_validation_redacting] = previous_hook if installed
    end

    # Versioned export. events stay in call order. Large sanitized strings
    # move to files under directory/bodies. This does not open a capture and
    # does not call a model.
    def export_capture(events, directory, run_id: nil)
      spilled = spill_events(Array(events), directory)
      audit_document(spilled, run_id: run_id)
    end

    def audit_document(events, run_id: nil)
      document = {
        "schema_version" => SCHEMA_VERSION,
        "linkage" => LINKAGE,
        "summary_chars" => SUMMARY_CHARS
      }
      document["run_id"] = run_id.to_s if run_id.present?
      document["events"] = Array(events)
      document
    end

    def describe_artifact(directory, name, media_type)
      path = Pathname(directory).join(name)
      return { "path" => name, "absent" => true, "media_type" => media_type } unless path.file?

      body = File.binread(path)
      {
        "path" => name,
        "sha256" => Digest::SHA256.hexdigest(body),
        "media_type" => media_type,
        "bytes" => body.bytesize,
        "truncated" => false,
        "redacted" => body.include?("[redacted]"),
        "absent" => false
      }
    end

    def spill_events(events, directory)
      index = 0
      Array(events).map { |event|
        next event unless event.is_a?(Hash)

        sequence = event["sequence"]
        event.each_with_object({}) do |(key, value), out|
          out[key], index = spill_node(value, directory, sequence, key.to_s, index)
        end
      }
    end

    def sanitize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          name = key.to_s
          next if secret_key?(name)

          out[name] = sanitize(item)
        end
      when Array
        value.map { |item| sanitize(item) }
      when Numeric, TrueClass, FalseClass, NilClass
        value
      else
        scrub_text(value.to_s)
      end
    end

    def secret_key?(name)
      secret = SECRET_KEYS.include?(name.to_s.downcase.gsub(/[^a-z0-9]/, ""))
      note_redaction if secret
      secret
    end

    def scope
      Thread.current[:rag_validation_scope] || {}
    end

    def scrub_text(text)
      source = text.to_s
      cleaned = source.gsub(SIGNED_URL) { |url|
        url.match?(/X-Amz-/i) ? url.sub(/\?.*/, "") : url
      }.gsub(SECRET_TEXT, "[redacted]")
      note_redaction if cleaned != source
      cleaned
    end

    def note_redaction
      hook = Thread.current[:rag_validation_redacting]
      hook.call if hook.respond_to?(:call)
    end

    def spill_node(value, directory, sequence, key, index)
      case value
      when Hash
        return [ value, index ] if value["evidence"] == "external"

        spilled = value.each_with_object({}) do |(child_key, child), out|
          out[child_key], index = spill_node(child, directory, sequence, "#{key}-#{child_key}", index)
        end
        [ spilled, index ]
      when Array
        spilled = []
        value.each_with_index do |child, child_index|
          item, index = spill_node(child, directory, sequence, "#{key}-#{child_index}", index)
          spilled << item
        end
        [ spilled, index ]
      when String
        spill_string(value, directory, sequence, key, index)
      else
        [ value, index ]
      end
    end

    def spill_string(text, directory, sequence, key, index)
      return [ text, index ] if text.length <= SUMMARY_CHARS

      index += 1
      bodies = Pathname(directory).join("bodies")
      FileUtils.mkdir_p(bodies)
      filename = format("b%04d.txt", index)
      File.binwrite(bodies.join(filename), text)
      reference = {
        "evidence" => "external",
        "field" => key,
        "sequence" => sequence,
        "path" => "bodies/#{filename}",
        "sha256" => Digest::SHA256.hexdigest(text),
        "media_type" => "text/plain; charset=utf-8",
        "bytes" => text.bytesize,
        "truncated" => false,
        "redacted" => text.include?("[redacted]"),
        "absent" => false,
        "summary" => text[0, SUMMARY_KEEP],
        "summary_truncated" => true
      }
      [ reference, index ]
    end
  end
end
