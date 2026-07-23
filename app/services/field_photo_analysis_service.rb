# frozen_string_literal: true

# Direct, non-persistent field-photo analysis for the authenticated web chat.
# The image is sent once to Anthropic and is never written to S3 or the KB.
class FieldPhotoAnalysisService
  class ParseError < StandardError; end

  VISIBLE_CODE_LIMIT = 8
  CHAT_CONTEXT_LIMIT = ConversationSession::MAX_MSG_LENGTH

  def initialize(binary:, content_type:, filename:, locale:, account_id:, user_id:,
                 conv_session_id:, correlation_id:, client: nil)
    @binary = binary
    @content_type = content_type
    @filename = filename
    @locale = normalize_locale(locale)
    @account_id = account_id
    @user_id = user_id
    @conv_session_id = conv_session_id
    @correlation_id = correlation_id
    @client = client
  end

  def call
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    route = FieldPhotoDensityGate.decide(
      binary: @binary,
      content_type: @content_type,
      filename: @filename,
      correlation_id: @correlation_id
    )
    model = route == :opus ? BatchChunkingPrompt::MODEL_MULTIMODAL : BatchChunkingPrompt::MODEL_TEXT
    client = @client || ClaudeChunkingClient.new(model: model, system: FieldPhotoPrompt::SYSTEM_BLOCKS)

    response = client.call(
      user_content: FieldPhotoPrompt.user_content(
        binary: @binary,
        content_type: @content_type,
        filename: @filename,
        locale: @locale
      ),
      filename: @filename,
      max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
      tracking_prefix: "field_photo_query",
      correlation_id: @correlation_id,
      route: "visual_query",
      telemetry: telemetry
    )

    parsed = parse(response.fetch(:text))
    envelope = FieldPhotoResultsParser.to_envelope(response.fetch(:text))
    latency_ms = elapsed_ms(started_at)
    result = {
      analysis: build_analysis(parsed, envelope),
      compact_context: build_compact_context(parsed),
      canonical_name: value_or_unknown(parsed["canonical_component"]),
      aliases: Array(parsed["aliases"]).map(&:to_s).compact_blank.first(10),
      parsed: parsed,
      model: model,
      usage: usage_payload(response[:usage]),
      latency_ms: latency_ms
    }

    log_analysis(
      parsed: parsed,
      model: model,
      latency_ms: latency_ms,
      usage: response[:usage],
      result: "ok"
    )
    result
  rescue StandardError => e
    log_analysis(
      parsed: (defined?(parsed) && parsed ? parsed : {}),
      model: defined?(model) ? model : nil,
      latency_ms: elapsed_ms(started_at),
      usage: defined?(response) ? response&.dig(:usage) : nil,
      result: "error",
      error_class: e.class.name
    )
    raise
  end

  private

  def parse(text)
    LlmJsonParser.parse(text)
  rescue JSON::ParserError => e
    raise ParseError, "Invalid field-photo JSON: #{e.message}"
  end

  def build_analysis(parsed, envelope)
    evidence_body = envelope.dig("chunks", 0, "text").to_s
    evidence_body = evidence_body.lines.reject { |line| line.start_with?("Notes:") }.join.strip
    component = value_or_unknown(parsed["canonical_component"])
    visible_code = visible_codes(parsed).first || "UNKNOWN"

    I18n.with_locale(@locale) do
      sections = [
        [ I18n.t("rag.photo_observed_heading"), [ parsed["summary"].to_s.presence, evidence_body ].compact.join("\n\n") ],
        [ I18n.t("rag.photo_uncertainty_heading"), uncertainty_text(parsed) ],
        [ I18n.t("rag.photo_guidance_heading"), I18n.t("rag.photo_guidance") ],
        [ I18n.t("rag.photo_next_queries_heading"), suggested_queries(component, visible_code) ]
      ]
      sections << [ I18n.t("rag.photo_manual_heading"), I18n.t("rag.photo_manual_absent") ] unless pinned_manual_available?

      sections.map { |heading, body| "**#{heading}**\n#{body}" }.join("\n\n")
    end
  end

  def uncertainty_text(parsed)
    parsed["anti_hallucination_notes"].to_s.presence ||
      "REQUIRES_FIELD_VERIFICATION: #{I18n.t('rag.photo_uncertainty_default')}"
  end

  def suggested_queries(component, visible_code)
    [
      I18n.t("rag.photo_query_code", code: visible_code),
      I18n.t("rag.photo_query_inspections", component: component),
      I18n.t("rag.photo_query_verify")
    ].map { |query| "- #{query}" }.join("\n")
  end

  def build_compact_context(parsed)
    line = [
      "[FOTO] Componente: #{value_or_unknown(parsed['canonical_component'])}",
      "Fabricante: #{value_or_unknown(parsed['manufacturer'])}",
      "Modelo: #{value_or_unknown(parsed['model'])}",
      "Códigos: #{visible_codes(parsed).presence&.join(', ') || 'UNKNOWN'}",
      "Condición: #{value_or_unknown(parsed['condition'])}"
    ].join(" | ").squish

    line.truncate(CHAT_CONTEXT_LIMIT, omission: "...")
  end

  def visible_codes(parsed)
    Array(parsed["visible_text"]).map(&:to_s).compact_blank.first(VISIBLE_CODE_LIMIT)
  end

  def value_or_unknown(value)
    value.to_s.strip.presence || "UNKNOWN"
  end

  def pinned_manual_available?
    return false unless @conv_session_id

    session = ConversationSession.select(:account_id, :active_entities).find_by(id: @conv_session_id)
    return false unless session
    return false if @account_id && session.account_id != @account_id

    session.active_entities.any? do |_name, metadata|
      type = metadata["entity_type"].to_s
      source_uri = metadata["source_uri"].to_s
      type == "document" || (type.blank? && source_uri.present? && source_uri !~ /\.(gif|jpe?g|png|webp)\z/i)
    end
  end

  def telemetry
    {
      account_id: @account_id,
      user_id: @user_id,
      conversation_session_id: @conv_session_id
    }
  end

  def normalize_locale(locale)
    candidate = locale.to_s.presence&.to_sym
    I18n.available_locales.include?(candidate) ? candidate : I18n.default_locale
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end

  def token_value(usage, name)
    return usage.public_send(name).to_i if usage&.respond_to?(name)
    return usage[name].to_i if usage.respond_to?(:[]) && usage[name]
    return usage[name.to_s].to_i if usage.respond_to?(:[]) && usage[name.to_s]

    nil
  end

  def usage_payload(usage)
    {
      input_tokens: token_value(usage, :input_tokens),
      output_tokens: token_value(usage, :output_tokens)
    }
  end

  def log_analysis(parsed:, model:, latency_ms:, usage:, result:, error_class: nil)
    payload = {
      correlation_id: @correlation_id,
      user_id: @user_id,
      account_id: @account_id,
      conversation_session_id: @conv_session_id,
      model: model,
      latency_ms: latency_ms,
      input_tokens: token_value(usage, :input_tokens),
      output_tokens: token_value(usage, :output_tokens),
      manufacturer: parsed["manufacturer"],
      model_visible: parsed["model"],
      visible_codes: visible_codes(parsed),
      component: parsed["canonical_component"],
      condition: parsed["condition"],
      result: result,
      error_class: error_class
    }
    Rails.logger.info("[IMAGE_ANALYSIS] #{JSON.generate(payload)}")
  rescue StandardError => e
    Rails.logger.warn("FieldPhotoAnalysisService: telemetry failed — #{e.message}")
  end
end
