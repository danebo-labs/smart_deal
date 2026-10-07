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
    SCOPE_KEYS = %w[sha session_id episode_id account_id user_id correlation_root turn].freeze
    TEMPLATE_MARKERS = [ "$search_results$", "$output_format_instructions$", "$query$" ].freeze

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

    def record(kind, payload)
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
      event.merge!(sanitize(payload))
      bucket << event
      nil
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
      SECRET_KEYS.include?(name.to_s.downcase.gsub(/[^a-z0-9]/, ""))
    end

    def scope
      Thread.current[:rag_validation_scope] || {}
    end

    def scrub_text(text)
      text.to_s.gsub(SIGNED_URL) { |url|
        url.match?(/X-Amz-/i) ? url.sub(/\?.*/, "") : url
      }.gsub(SECRET_TEXT, "[redacted]")
    end
  end
end
