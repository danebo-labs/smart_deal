# frozen_string_literal: true

require "digest"

# Direct, non-persistent field-photo analysis for the authenticated web chat.
# The image is sent once to Anthropic and is never written to S3 or the KB.
class FieldPhotoAnalysisService
  class ParseError < StandardError; end

  VISIBLE_CODE_LIMIT = 8
  CHAT_CONTEXT_LIMIT = ConversationSession::MAX_MSG_LENGTH
  RELEVANCE_VALUES = %w[relevant unrelated uncertain].freeze
  MISSING_DETAIL_LIMIT = 200
  # Field Companion F2 letter B. Chat photos only. Document ingestion stays on
  # BatchChunkingPrompt::MODEL_TEXT.
  DEFAULT_MODEL = "claude-sonnet-5-5"

  def initialize(binary:, content_type:, filename:, locale:, account_id:, user_id:,
                 conv_session_id:, correlation_id:, client: nil, photo_intent: nil)
    @binary = binary
    @content_type = content_type
    @filename = filename
    @locale = normalize_locale(locale)
    @account_id = account_id
    @user_id = user_id
    @conv_session_id = conv_session_id
    @correlation_id = correlation_id
    @client = client
    @photo_intent = coerce_photo_intent(photo_intent)
  end

  def call
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    route = FieldPhotoDensityGate.decide(
      binary: @binary,
      content_type: @content_type,
      filename: @filename,
      correlation_id: @correlation_id
    )
    model = route == :opus ? BatchChunkingPrompt::MODEL_MULTIMODAL : DEFAULT_MODEL
    client = @client || ClaudeChunkingClient.new(model: model, system: FieldPhotoPrompt::SYSTEM_BLOCKS)

    response = client.call(
      user_content: FieldPhotoPrompt.user_content(
        binary: @binary,
        content_type: @content_type,
        filename: @filename,
        locale: @locale,
        photo_intent: @photo_intent&.dig(:text)
      ),
      filename: @filename,
      max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
      tracking_prefix: "field_photo_query",
      correlation_id: @correlation_id,
      route: "visual_query",
      telemetry: telemetry
    )

    parsed = parse(response.fetch(:text))
    latency_ms = elapsed_ms(started_at)
    result = {
      analysis: build_analysis(parsed),
      compact_context: build_compact_context(parsed),
      canonical_name: value_or_unknown(parsed["canonical_component"]),
      aliases: Array(parsed["aliases"]).map(&:to_s).compact_blank.first(10),
      target_visible: normalized_target_visible(parsed),
      relevance_to_goal: normalized_relevance(parsed),
      missing_view_or_detail: normalized_missing(parsed),
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

  # What the technician reads for a photo alone (CG-D19): prose, no headings,
  # no suggested queries. UNKNOWN, DEGRADED, and the other enum values stay in
  # `parsed`; the text says only what the photo shows, in words.
  def build_analysis(parsed)
    I18n.with_locale(@locale) do
      paragraphs = [
        parsed["summary"].to_s.presence,
        identity_sentences(parsed),
        uncertainty_text(parsed),
        I18n.t("rag.photo_guidance")
      ]
      paragraphs << I18n.t("rag.photo_manual_absent") unless pinned_manual_available?
      paragraphs.compact_blank.join("\n\n")
    end
  end

  def identity_sentences(parsed)
    sentences = []
    if (component = known(parsed["canonical_component"]))
      sentences << I18n.t("rag.photo_identity.component", component: component)
    end
    if (manufacturer = known(parsed["manufacturer"]))
      sentences << I18n.t("rag.photo_identity.manufacturer", manufacturer: manufacturer)
    end
    if (model = known(parsed["model"]))
      sentences << I18n.t("rag.photo_identity.model", model: model)
    end
    codes = visible_codes(parsed)
    sentences << I18n.t("rag.photo_identity.codes", codes: codes.join(", ")) if codes.any?
    condition = parsed["condition"].to_s.strip.downcase
    sentences << I18n.t("rag.photo_identity.condition.#{condition}") if %w[good degraded damaged].include?(condition)
    sentences.join(" ").presence
  end

  # The vision contract prefixes its notes with REQUIRES_FIELD_VERIFICATION.
  # That marker is metadata: the note is shown as a sentence.
  def uncertainty_text(parsed)
    notes = parsed["anti_hallucination_notes"].to_s
      .gsub(/\bREQUIRES?_FIELD_VERIFICATION\b\s*:?\s*/, "")
      .strip
    notes.present? ? notes.upcase_first : I18n.t("rag.photo_uncertainty_default")
  end

  def known(value)
    text = value.to_s.strip
    return nil if text.blank? || text.casecmp("UNKNOWN").zero?

    text
  end

  def build_compact_context(parsed)
    line = [
      "[FOTO] Componente: #{value_or_unknown(parsed['canonical_component'])}",
      "Fabricante: #{value_or_unknown(parsed['manufacturer'])}",
      "Modelo: #{value_or_unknown(parsed['model'])}",
      "Códigos: #{visible_codes(parsed).presence&.join(', ') || 'UNKNOWN'}",
      "Condición: #{value_or_unknown(parsed['condition'])}"
    ].join(" | ").squish
    line = "#{line} | Objetivo visible: #{visibility_label(parsed)}" if intent_sent?

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
    return nil if usage.nil?
    return hash_token(usage, name) if usage.is_a?(Hash)
    return hash_token(usage.to_h, name) if defined?(OpenStruct) && usage.is_a?(OpenStruct)

    if usage.respond_to?(:to_h)
      table = usage.to_h
      if table.is_a?(Hash) && (table.key?(name) || table.key?(name.to_s))
        return hash_token(table, name)
      end
    end

    return nil unless usage.respond_to?(name)

    raw = usage.public_send(name)
    raw.nil? ? nil : raw.to_i
  end

  def hash_token(hash, name)
    key = if hash.key?(name)
      name
    elsif hash.key?(name.to_s)
      name.to_s
    end
    return nil unless key

    raw = hash[key]
    raw.nil? ? nil : raw.to_i
  end

  def usage_payload(usage)
    payload = {
      input_tokens: token_value(usage, :input_tokens),
      output_tokens: token_value(usage, :output_tokens)
    }
    cache_read = token_value(usage, :cache_read_input_tokens)
    cache_creation = token_value(usage, :cache_creation_input_tokens)
    payload[:cache_read_tokens] = cache_read unless cache_read.nil?
    payload[:cache_creation_tokens] = cache_creation unless cache_creation.nil?
    payload
  end

  def intent_sent?
    @photo_intent.present?
  end

  def coerce_photo_intent(photo_intent)
    return nil if photo_intent.blank?

    text, source = if photo_intent.is_a?(Hash)
      [ photo_intent["text"] || photo_intent[:text], photo_intent["source"] || photo_intent[:source] ]
    else
      [ photo_intent, nil ]
    end
    text = text.to_s.squish
    return nil if text.blank?

    { text: text, source: source.to_s.presence }
  end

  def normalized_target_visible(parsed)
    return nil unless intent_sent?

    value = parsed["target_visible"]
    value == true || value == false ? value : nil
  end

  def normalized_relevance(parsed)
    return nil unless intent_sent?

    value = parsed["relevance_to_goal"].to_s
    RELEVANCE_VALUES.include?(value) ? value : nil
  end

  def normalized_missing(parsed)
    return nil unless intent_sent?

    parsed["missing_view_or_detail"].to_s.squish.first(MISSING_DETAIL_LIMIT).presence
  end

  def visibility_label(parsed)
    case normalized_target_visible(parsed)
    when true then "sí"
    when false then "no"
    else "sin confirmar"
    end
  end

  def intent_digest
    return nil unless intent_sent?

    Digest::SHA256.hexdigest(@photo_intent[:text])
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
      intent_source: @photo_intent&.dig(:source),
      intent_sha256: intent_digest,
      target_visible: normalized_target_visible(parsed),
      relevance_to_goal: normalized_relevance(parsed),
      result: result,
      error_class: error_class
    }
    Rails.logger.info("[IMAGE_ANALYSIS] #{JSON.generate(payload)}")
  rescue StandardError => e
    Rails.logger.warn("FieldPhotoAnalysisService: telemetry failed — #{e.message}")
  end
end
