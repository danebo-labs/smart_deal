# frozen_string_literal: true

module Rag
  # Publication contract for identity_unknown_reference only.
  #
  # The model fills a semantic envelope. This class validates it and renders
  # the technician-facing prose. There is no current-job action field.
  # A malformed envelope falls back to the existing prose path. One rejected
  # field does not erase the fields that validate.
  class UnknownIdentityPublication
    MODE_CONTRACT = "unknown_identity_contract"
    MODE_FALLBACK = "unknown_identity_contract_fallback"
    TOOL_NAME = "unknown_identity_publication"
    MAX_TOKENS = 600
    MAX_FACT_CHARS = 240
    MEASURED_VALUE = /
      \b\d+(?:[.,]\d+)?\s*(?:s|seg|segs|segundos?|seconds?)\b
    /ix

    PROMPT = <<~PROMPT.freeze
      You fill the unknown_identity_publication tool. You do not write the answer the technician will read.

      The equipment in service is not confirmed. Retrieved text may describe other equipment.

      observations: checks that only look, read, or listen. Allowed topics: car position, doors, people inside, display text, sounds, lights, and the nameplate. Do not name a selector, a terminal, a wait, inspection mode, a power cut, a reset, a code meaning, or another manual's steps. Do not refuse an action by naming it.
      nameplate_question: null. The publisher asks for the nameplate text.
      reference_fact: null unless the technician asked what a retrieved manual says or what a displayed code means. citation is the evidence number. fact is the single documentary fact from that evidence. It is not a procedure, a value to apply, or a setting.
      Do not add any other field.
    PROMPT

    Result = Data.define(
      :mode, :answer, :prompt, :reference_status, :rejected_fields, :fallback_reason, :envelope
    ) do
      def accepted?
        mode == MODE_CONTRACT
      end
    end

    def self.tool_schema
      {
        type: "object",
        properties: {
          observations: { type: "array", items: { type: "string" } },
          nameplate_question: { type: %w[string null] },
          reference_fact: {
            type: %w[object null],
            properties: {
              citation: { type: "integer" },
              fact: { type: "string" }
            },
            required: %w[fact]
          }
        },
        required: %w[observations]
      }
    end

    def self.attempt(client:, question:, chunks:, locale:, tracking: nil)
      unless client.respond_to?(:converse)
        return fallback(reason: "unavailable")
      end

      generate(client:, question:, chunks:, locale:, tracking:)
    rescue StandardError => error
      log_fallback("transport", error)
      fallback(reason: "transport")
    end

    def self.generate(client:, question:, chunks:, locale:, tracking: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      prompt = tool_prompt(question, chunks)
      response = client.converse(converse_params(prompt))
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      track_usage(response, prompt, latency_ms, tracking)
      envelope = extract_tool_input(response_content(response))
      return fallback(reason: "unparsed", prompt: prompt) unless envelope.is_a?(Hash)

      compose(envelope, chunks: chunks, question: question, locale: locale, prompt: prompt)
    rescue StandardError => error
      log_fallback("transport", error)
      fallback(reason: "transport")
    end

    def self.compose(envelope, chunks:, question:, locale:, prompt: nil)
      parsed = parse_envelope(envelope)
      return fallback(reason: "malformed", prompt: prompt) unless parsed

      rejected = parsed[:ignored].dup
      observations = []
      parsed[:observations].each_with_index do |item, index|
        if observation_allowed?(item, chunks, question)
          observations << item.squish
        else
          rejected << "observations[#{index}]"
        end
      end
      nameplate = parsed[:nameplate_question]
      if nameplate.present? && !observation_allowed?(nameplate, chunks, question)
        rejected << "nameplate_question"
      end

      reference = resolve_reference(parsed[:reference_fact], chunks, question)
      reference_status = if !parsed[:reference_supplied]
        "absent"
      elsif reference
        "accepted"
      else
        rejected << "reference_fact"
        "rejected"
      end
      answer = render(
        observations: observations,
        reference: reference,
        locale: locale
      )
      log_contract(reference_status, rejected)
      Result.new(
        mode: MODE_CONTRACT,
        answer: answer,
        prompt: prompt,
        reference_status: reference_status,
        rejected_fields: rejected,
        fallback_reason: nil,
        envelope: envelope
      )
    end

    def self.converse_params(prompt)
      {
        model_id: BedrockClient::QUERY_MODEL_ID,
        system: [ { text: PROMPT } ],
        messages: [ { role: "user", content: [ { text: prompt } ] } ],
        inference_config: { temperature: 0, max_tokens: MAX_TOKENS },
        tool_config: {
          tools: [
            {
              tool_spec: {
                name: TOOL_NAME,
                description: "Semantic fields for an unknown-identity answer. No current-job actions.",
                input_schema: { json: tool_schema }
              }
            }
          ],
          tool_choice: { tool: { name: TOOL_NAME } }
        }
      }
    end

    def self.tool_prompt(question, chunks)
      evidence = Array(chunks).each_with_index.map { |chunk, index|
        meta = metadata(chunk)
        "[#{index + 1}] Manual: #{document_name(meta)}. Page: #{meta["page_number"].presence || "DATA_NOT_AVAILABLE"}.\n#{chunk_content(chunk)}"
      }.join("\n\n")
      JSON.generate("question" => question.to_s, "evidence" => evidence)
    end

    def self.parse_envelope(envelope)
      return nil unless envelope.is_a?(Hash)

      data = envelope.deep_stringify_keys
      return nil unless data["observations"].is_a?(Array)

      reference = data["reference_fact"]
      ignored = []
      ignored << "current_job_actions" if data.key?("current_job_actions")
      nameplate = data["nameplate_question"]
      if !nameplate.nil? && !nameplate.is_a?(String)
        ignored << "nameplate_question"
        nameplate = nil
      end
      {
        observations: data["observations"],
        reference_fact: reference.is_a?(Hash) ? reference : nil,
        reference_supplied: !reference.nil?,
        nameplate_question: nameplate,
        ignored: ignored
      }
    end

    def self.observation_allowed?(text, chunks, question)
      return false unless text.is_a?(String)

      sentence = text.squish
      return false if sentence.blank?
      return false if DocumentIdentityScope.unconfirmed_operation?(sentence, question)
      return false if measured_value?(sentence)
      return false if DocumentIdentityScope.unconfirmed_identity_assertion?(sentence, chunks)

      DocumentIdentityScope.unconfirmed_applicability_violation(sentence, nil, chunks, question).nil?
    end

    def self.resolve_reference(fact, chunks, question)
      return nil unless fact.is_a?(Hash)

      body = clean_fact(fact["fact"])
      return nil if body.blank? || body.length > MAX_FACT_CHARS
      return nil if AnswerSafetyProcessor.fragments(body).size > 1
      return nil if DocumentIdentityScope.unconfirmed_operation?(body, question)
      return nil if measured_value?(body)
      return nil if DocumentIdentityScope.unconfirmed_identity_assertion?(body, chunks)

      index = citation_index(fact["citation"], chunks)
      return nil unless index

      meta = metadata(chunks[index - 1])
      manual = document_name(meta)
      return nil if manual.blank? || manual == "DATA_NOT_AVAILABLE"

      { citation: index, fact: body, manual: manual, page: meta["page_number"].presence }
    end

    def self.citation_index(citation, chunks)
      number = Integer(citation, exception: false)
      return nil unless number&.between?(1, Array(chunks).size)

      number
    end

    def self.clean_fact(text)
      text.to_s.gsub(/\s*\[\d+\]/, "").gsub(/\s+/, " ").strip.sub(/[.!?]+\z/, "")
    end

    def self.measured_value?(text)
      value = text.to_s
      value.match?(AnswerSafetyProcessor::EVIDENCE_SENSITIVE_VALUE_PATTERN) || value.match?(MEASURED_VALUE)
    end

    def self.render(observations:, reference:, locale:)
      loc = locale.to_s == "en" ? :en : :es
      parts = [ I18n.t("rag.unknown_identity_opening", locale: loc) ]
      if observations.any?
        lines = observations.each_with_index.map { |item, index| "#{index + 1}. #{item}" }
        parts << "#{I18n.t("rag.unknown_identity_observation_intro", locale: loc)}\n#{lines.join("\n")}"
      end
      parts << reference_paragraph(reference, loc) if reference
      parts << I18n.t("rag.unknown_identity_nameplate_question", locale: loc)
      parts.join("\n\n")
    end

    def self.reference_paragraph(reference, locale)
      fact = reference[:fact].to_s.gsub("%", "%%")
      sentence = if reference[:page].present?
        I18n.t(
          "rag.unknown_identity_reference",
          locale: locale,
          manual: reference[:manual],
          page: reference[:page],
          citation: reference[:citation],
          fact: fact
        )
      else
        I18n.t(
          "rag.unknown_identity_reference_without_page",
          locale: locale,
          manual: reference[:manual],
          citation: reference[:citation],
          fact: fact
        )
      end
      "#{sentence} #{I18n.t("rag.unknown_identity_disclaimer", locale: locale)}"
    end

    def self.metadata(chunk)
      (chunk[:metadata] || chunk["metadata"]).to_h.stringify_keys
    end

    def self.chunk_content(chunk)
      chunk[:content] || chunk["content"]
    end

    def self.document_name(meta)
      meta["canonical_name"].presence || meta["original_filename"].presence || "DATA_NOT_AVAILABLE"
    end

    def self.response_content(response)
      output = response.respond_to?(:output) ? response.output : response["output"] || response[:output]
      message = output.respond_to?(:message) ? output.message : output && (output["message"] || output[:message])
      message.respond_to?(:content) ? message.content : message && (message["content"] || message[:content])
    end

    def self.extract_tool_input(content)
      block = Array(content).find { |item|
        tool = tool_use_of(item)
        tool_name(tool) == TOOL_NAME
      }
      return nil unless block

      input = tool_input(tool_use_of(block))
      input.is_a?(Hash) ? input : nil
    end

    def self.tool_use_of(item)
      return item.tool_use if item.respond_to?(:tool_use)

      item["tool_use"] || item[:tool_use] if item.is_a?(Hash)
    end

    def self.tool_name(tool)
      return nil unless tool
      return tool.name if tool.respond_to?(:name)

      tool["name"] || tool[:name]
    end

    def self.tool_input(tool)
      return nil unless tool
      return tool.input if tool.respond_to?(:input)

      tool["input"] || tool[:input]
    end

    def self.track_usage(response, prompt, latency_ms, tracking)
      usage = response.respond_to?(:usage) ? response.usage : nil
      input_tokens = usage_token(usage, :input_tokens)
      return if input_tokens <= 0

      extra = tracking.to_h.symbolize_keys
      route = extra.delete(:route) || "identity_unknown_reference"
      attempt = extra.delete(:attempt) || 1
      TrackBedrockQueryJob.perform_later(
        source: "query",
        route: route,
        model_id: BedrockClient::QUERY_MODEL_ID,
        token_source: "provider_usage",
        input_tokens: input_tokens,
        output_tokens: usage_token(usage, :output_tokens),
        latency_ms: latency_ms,
        user_query: prompt.to_s.truncate(500),
        attempt: attempt,
        **extra
      )
    rescue StandardError => error
      Rails.logger.warn("UnknownIdentityPublication usage tracking failed #{error.class}")
    end

    def self.usage_token(usage, name)
      return 0 if usage.nil?

      value = if usage.is_a?(Hash)
        usage[name] || usage[name.to_s]
      elsif usage.respond_to?(name)
        usage.public_send(name)
      end
      value.to_i
    end

    def self.fallback(reason:, prompt: nil)
      Result.new(
        mode: MODE_FALLBACK,
        answer: nil,
        prompt: prompt,
        reference_status: nil,
        rejected_fields: [],
        fallback_reason: reason,
        envelope: nil
      )
    end

    def self.log_contract(reference_status, rejected)
      Rails.logger.info(
        "[UNKNOWN_IDENTITY_PUBLICATION] #{ {
          mode: MODE_CONTRACT,
          reference: reference_status,
          rejected_fields: rejected
        }.to_json }"
      )
    end

    def self.log_fallback(reason, error)
      Rails.logger.info(
        "[UNKNOWN_IDENTITY_PUBLICATION] #{ {
          mode: MODE_FALLBACK,
          fallback_reason: reason,
          error: error.class.name
        }.to_json }"
      )
    end

    private_class_method :converse_params, :tool_prompt, :parse_envelope, :observation_allowed?,
      :resolve_reference, :citation_index, :clean_fact, :measured_value?, :render, :reference_paragraph,
      :metadata, :chunk_content, :document_name, :response_content, :extract_tool_input, :tool_use_of,
      :tool_name, :tool_input, :track_usage, :usage_token, :fallback, :log_contract, :log_fallback
  end
end
