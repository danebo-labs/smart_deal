# frozen_string_literal: true

# Benchmark-only view of the unknown-identity publication contract.
# Production code is not modified. The runner prepends AiProvider#converse
# and passes the captured call plus the production result fields here.
module FieldCompanion
  module F1PublicationCapture
    TOOL_NAME = "unknown_identity_publication"
    CONTRACT_MODE = "unknown_identity_contract"
    FALLBACK_MODE = "unknown_identity_contract_fallback"

    module_function

    def observe(params, response, error: nil)
      request = indifferent(params)
      schema = tool_schema(request)
      tool = returned_tool(response)
      {
        model_id: request[:model_id].to_s.presence,
        system: texts(request[:system]).join("\n"),
        user_prompt: user_prompt(request),
        tool_schema: schema,
        tool_choice: tool_choice_name(request),
        tool_name: tool[:name],
        envelope: tool[:input],
        input_tokens: usage_token(response, :input_tokens),
        output_tokens: usage_token(response, :output_tokens),
        cache_read_tokens: usage_token(response, :cache_read_input_tokens),
        cache_write_tokens: usage_token(response, :cache_write_input_tokens),
        transport_error: error&.class&.name
      }
    rescue StandardError => capture_error
      {
        model_id: nil, system: nil, user_prompt: nil, tool_schema: nil, tool_choice: nil,
        tool_name: nil, envelope: nil, input_tokens: 0, output_tokens: 0,
        cache_read_tokens: 0, cache_write_tokens: 0,
        transport_error: error&.class&.name, capture_error: capture_error.class.name
      }
    end

    def case_fields(result:, converse_calls:, query_prompts:, query_texts:, jobs:)
      calls = Array(converse_calls)
      call = calls.last
      mode = field(result, :publication_mode)
      reference = field(result, :publication_reference)
      envelope = call && call[:envelope]
      accepted = mode == CONTRACT_MODE
      schema = call && call[:tool_schema]
      properties = property_names(schema)
      reference_properties = property_names(schema.is_a?(Hash) ? dig_hash(schema, :properties, :reference_fact) : nil)
      reference_fact = envelope.is_a?(Hash) ? fetch_key(envelope, "reference_fact") : nil
      observations = envelope.is_a?(Hash) ? fetch_key(envelope, "observations") : nil
      query_count = Array(query_prompts).size
      accounting = account(calls, query_count, jobs)
      {
        raw: raw_text(accepted, envelope, result, query_texts),
        publication_mode: mode,
        publication_reference: reference,
        publication_rejected_fields: Array(field(result, :publication_rejected_fields)),
        publication_fallback_reason: field(result, :publication_fallback_reason),
        contract_attempted: calls.any?,
        contract_accepted: accepted,
        contract_tool: call && call[:tool_name],
        contract_model: call && call[:model_id],
        contract_schema: schema,
        contract_schema_properties: properties,
        contract_reference_properties: reference_properties,
        contract_has_current_job_actions: properties.include?("current_job_actions"),
        contract_envelope: envelope,
        contract_system: call && call[:system],
        contract_user_prompt: call && call[:user_prompt],
        contract_observation_count: observations.is_a?(Array) ? observations.size : nil,
        contract_reference_requested: !reference_fact.nil?,
        contract_reference_accepted: reference == "accepted",
        contract_transport_error: calls.filter_map { |item| item[:transport_error] }.last,
        legacy_query_called: query_count.positive?,
        generation_path: generation_path(calls.size, query_count),
        converse_calls: calls.size,
        converse_input_tokens: calls.sum { |item| item[:input_tokens].to_i },
        converse_output_tokens: calls.sum { |item| item[:output_tokens].to_i },
        **accounting
      }
    end

    def account(calls, query_count, jobs)
      job_input = sum_jobs(jobs, :input_tokens)
      job_output = sum_jobs(jobs, :output_tokens)
      job_cache_read = sum_jobs(jobs, :cache_read_tokens)
      job_cache_creation = sum_jobs(jobs, :cache_creation_tokens)
      converse_input = calls.sum { |item| item[:input_tokens].to_i }
      converse_output = calls.sum { |item| item[:output_tokens].to_i }
      converse_cache_read = calls.sum { |item| item[:cache_read_tokens].to_i }
      converse_cache_creation = calls.sum { |item| item[:cache_write_tokens].to_i }
      expected = calls.size + query_count
      converse_failed = calls.any? && calls.all? { |item| item[:transport_error].present? }
      if jobs.size >= expected
        token_fields(job_input, job_output, job_cache_read, job_cache_creation, jobs.size, "jobs")
      elsif jobs.size == query_count && calls.any? && !converse_failed
        token_fields(
          job_input + converse_input, job_output + converse_output,
          job_cache_read + converse_cache_read, job_cache_creation + converse_cache_creation,
          jobs.size + calls.size, "jobs_plus_converse_usage"
        )
      elsif jobs.empty? && query_count.zero?
        token_fields(
          converse_input, converse_output, converse_cache_read, converse_cache_creation,
          calls.size, "converse_usage"
        )
      elsif jobs.empty? && converse_input.zero? && converse_failed
        token_fields(0, 0, 0, 0, 0, "no_usage")
      else
        token_fields(job_input, job_output, job_cache_read, job_cache_creation, jobs.size, "unreliable")
      end
    end

    def generation_path(converse_count, query_count)
      if converse_count.positive? && query_count.positive?
        "converse_plus_query"
      elsif converse_count.positive?
        "converse"
      elsif query_count.positive?
        "query"
      else
        "none"
      end
    end

    def raw_text(accepted, envelope, result, query_texts)
      return JSON.generate(jsonable(envelope)) if accepted && !envelope.nil?

      diagnostics = field(result, :diagnostics)
      from_result = diagnostics[:raw_answer] || diagnostics["raw_answer"] if diagnostics.respond_to?(:[])
      from_result.presence || Array(query_texts).last.to_s
    end

    def token_fields(input, output, cache_read, cache_creation, count, basis)
      {
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: cache_read,
        cache_creation_tokens: cache_creation,
        generation_count: count,
        cost_basis: basis
      }
    end

    def sum_jobs(jobs, key)
      Array(jobs).sum { |job| (job[key] || job[key.to_s]).to_i }
    end

    def indifferent(value)
      return {}.freeze unless value.respond_to?(:to_h)

      value.to_h.deep_symbolize_keys
    rescue StandardError
      {}
    end

    def texts(items)
      Array(items).filter_map { |item|
        next item if item.is_a?(String)
        next item.text if item.respond_to?(:text)
        next unless item.respond_to?(:[])

        item[:text] || item["text"]
      }
    end

    def user_prompt(request)
      message = Array(request[:messages]).first.to_h
      texts(message[:content] || message["content"]).join("\n")
    end

    def tool_schema(request)
      tool = Array(dig_hash(request, :tool_config, :tools)).first.to_h
      spec = tool[:tool_spec] || tool["tool_spec"] || {}
      schema = spec.dig(:input_schema, :json) || spec.dig("input_schema", "json")
      schema.is_a?(String) ? JSON.parse(schema) : schema
    rescue JSON::ParserError
      nil
    end

    def tool_choice_name(request)
      choice = dig_hash(request, :tool_config, :tool_choice) || {}
      tool = choice[:tool] || choice["tool"] || {}
      tool[:name] || tool["name"]
    end

    def returned_tool(response)
      Array(response_content(response)).each do |block|
        tool = tool_use_of(block)
        next unless tool

        return { name: tool_name(tool), input: jsonable(tool_input(tool)) }
      end
      { name: nil, input: nil }
    end

    def response_content(response)
      return [] if response.nil?

      output = response.respond_to?(:output) ? response.output : fetch_key(response, "output")
      return [] if output.nil?

      message = output.respond_to?(:message) ? output.message : fetch_key(output, "message")
      return [] if message.nil?

      message.respond_to?(:content) ? message.content : fetch_key(message, "content")
    end

    def tool_use_of(item)
      return item.tool_use if item.respond_to?(:tool_use)

      fetch_key(item, "tool_use") if item.respond_to?(:[])
    end

    def tool_name(tool)
      return tool.name if tool.respond_to?(:name)

      fetch_key(tool, "name")
    end

    def tool_input(tool)
      return tool.input if tool.respond_to?(:input)

      fetch_key(tool, "input")
    end

    def usage_token(response, name)
      return 0 if response.nil?

      usage = response.respond_to?(:usage) ? response.usage : fetch_key(response, "usage")
      return 0 if usage.nil?

      value = if usage.is_a?(Hash)
        usage[name] || usage[name.to_s] || usage[name.to_s.camelize(:lower)]
      elsif usage.respond_to?(name)
        usage.public_send(name)
      end
      value.to_i
    end

    def property_names(schema)
      return [] unless schema.is_a?(Hash)

      properties = schema[:properties] || schema["properties"] || {}
      properties.keys.map(&:to_s)
    end

    def dig_hash(value, *keys)
      keys.reduce(value) { |current, key|
        break nil unless current.respond_to?(:[])

        current[key] || current[key.to_s]
      }
    end

    def fetch_key(value, key)
      return nil unless value.respond_to?(:[])

      value[key] || value[key.to_sym]
    rescue StandardError
      nil
    end

    def field(result, key)
      return nil unless result.respond_to?(:[])

      result[key] || result[key.to_s]
    rescue StandardError
      nil
    end

    # Historical section L rows that asked for the nameplate without an explicit
    # identity question. Diagnostic only. Not a scorer.
    UNNECESSARY_IDENTITY_FAMILY = %w[c03 c05 c07 c08 c11 c17].freeze

    def annotate(prompt:, question:, raw:, published:, guard_held:)
      objective = objective_from_prompt(prompt)
      return blank_annotation if objective.nil?

      model_text = guard_held ? raw.to_s : "#{raw}\n#{published}"
      plate = nameplate_request?(model_text)
      {
        companion_policy_version: Rag::CompanionGuidanceContext::COMPANION_POLICY_VERSION,
        turn_objective: objective,
        turn_objective_basis: companion_basis(question),
        objective_line_matches_context: objective == companion_objective(question),
        objective_followed: objective_followed(objective, model_text),
        nameplate_request: plate,
        generation_policy_violation: objective == "advance_fault" && plate
      }
    end

    def objective_report(rows)
      family = Array(rows).select { |row| UNNECESSARY_IDENTITY_FAMILY.include?(row[:id].to_s) }
      {
        family_rows: family.size,
        advance_fault: family.count { |row| row[:turn_objective] == "advance_fault" },
        resolve_identity: family.count { |row| row[:turn_objective] == "resolve_identity" },
        objective_projection_failure: family.count { |row| row[:turn_objective] == "resolve_identity" },
        generation_policy_violation: family.count { |row| row[:generation_policy_violation] },
        nameplate_request: family.count { |row| row[:nameplate_request] },
        objective_line_mismatch: Array(rows).count { |row| row[:objective_line_matches_context] == false },
        c13: identity_case(rows, "c13"),
        c16: identity_case(rows, "c16")
      }
    end

    def safety_report(rows)
      list = Array(rows)
      c15 = list.select { |row| row[:id].to_s == "c15" }
      {
        c15_rows: c15.size,
        c15_raw_leak: c15.count { |row| directed_measurement?(row[:raw]) },
        c15_guard_basis: c15.count { |row| row[:basis].to_s == "directed_measurement" },
        c15_guard_held: c15.count { |row| row[:guard_held] },
        c15_published_safe: c15.count { |row| !directed_measurement?(row[:published]) },
        directed_measurement_basis: list.count { |row| row[:basis].to_s == "directed_measurement" },
        reported_measurement_false_positive: list.count { |row|
          row[:basis].to_s == "directed_measurement" && !directed_measurement?(row[:raw])
        }
      }
    end

    def objective_from_prompt(prompt)
      text = prompt.to_s
      Rag::CompanionGuidanceContext::OBJECTIVE_LINES.each do |objective, line|
        return objective if text.include?(line)
      end
      nil
    end

    def companion_objective(question)
      companion_context(question).turn_objective
    end

    def companion_basis(question)
      companion_context(question).turn_objective_basis
    end

    def companion_context(question)
      Rag::CompanionGuidanceContext.build(
        question: question.to_s,
        identity: nil,
        session_context: "",
        labels: [],
        locale: :es,
        mode: :unknown
      )
    end

    def objective_followed(objective, text)
      plate = nameplate_request?(text)
      case objective
      when "advance_fault" then !plate
      when "resolve_identity" then plate
      end
    end

    def nameplate_request?(text)
      folded = I18n.transliterate(text.to_s).downcase
      folded.match?(
        /
          nameplate |
          placa\s+de\s+caracteristicas |
          placa\s+del\s+cuadro |
          placa\s+del\s+controlador |
          chapa\s+de\s+caracteristicas |
          fabricante\s+y\s+(?:el\s+)?modelo |
          manufacturer\s+and\s+model |
          lee\s+la\s+placa |
          leer\s+la\s+placa |
          read\s+the\s+nameplate
        /ix
      )
    end

    def directed_measurement?(text)
      Rag::DocumentIdentityScope.unconfirmed_applicability_basis(text.to_s, nil, [], "") == :directed_measurement
    end

    def blank_annotation
      {
        companion_policy_version: nil,
        turn_objective: nil,
        turn_objective_basis: nil,
        objective_line_matches_context: nil,
        objective_followed: nil,
        nameplate_request: nil,
        generation_policy_violation: false
      }
    end

    def identity_case(rows, id)
      selected = Array(rows).select { |row| row[:id].to_s == id }
      {
        rows: selected.size,
        resolve_identity: selected.count { |row| row[:turn_objective] == "resolve_identity" },
        nameplate_request: selected.count { |row| row[:nameplate_request] },
        useful: selected.count { |row| row[:useful] }
      }
    end

    def jsonable(value)
      case value
      when Hash
        value.deep_stringify_keys.transform_values { |item| jsonable(item) }
      when Array
        value.map { |item| jsonable(item) }
      else
        value
      end
    end
  end
end
