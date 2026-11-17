# frozen_string_literal: true

require "base64"
require "digest"

module FieldCases
  # Shape and size checks for case state, pins, and the definitive result.
  # Signed URLs are rejected. Retrieval authorization happens when a later
  # tranche resolves these ids, not here.
  module Payload
    module_function

    MESSAGE_MAX = ConversationSession::USER_TEXT_MAX_CHARS
    PUBLISHED_MAX = ConversationSession::PROMPT_REPLY_MAX_CHARS
    PROMPT_REPLY_MAX = ConversationSession::PROMPT_REPLY_MAX_CHARS
    STATE_MAX_BYTES = 32_768
    RESPONSE_MAX_BYTES = 65_536
    PIN_MAX = ConversationSession::MAX_ENTITIES
    TITLE_MAX = Rag::ActiveEpisode::MAX_GOAL_CHARS
    PAGE_DEFAULT = 20
    PAGE_MAX = 50
    KEY_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/
    UID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    CORRELATION_FORMAT = /\A(?:query|photo):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    FAILURE_FORMAT = /\A[a-z][a-z0-9_]{0,39}\z/
    CONTENT_TYPE_FORMAT = /\Aimage\/[a-z0-9.+-]{1,40}\z/
    SHA_FORMAT = /\A[0-9a-f]{64}\z/
    SIGNED = /(?:X-Amz-[\w-]+|Signature)=/i
    RESPONSE_KEYS = %w[published_text citations provenance render].freeze
    PIN_KEYS = %w[kb_document_id document_uid display_name].freeze

    def blank_key?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def key?(value)
      value.to_s.match?(KEY_FORMAT)
    end

    def digest(message:, attachment_sha256:)
      Digest::SHA256.hexdigest("#{message}\n#{attachment_sha256}")
    end

    def correlation_for(kind)
      prefix = kind == "photo" ? "photo" : "query"
      "#{prefix}:#{SecureRandom.uuid}"
    end

    def correlation_ok?(value, kind)
      text = value.to_s
      prefix = kind == "photo" ? "photo:" : "query:"
      text.start_with?(prefix) && text.match?(CORRELATION_FORMAT)
    end

    def limit(value)
      return PAGE_DEFAULT if value.nil? || value == ""

      number = Integer(value, exception: false)
      return nil unless number&.between?(1, PAGE_MAX)

      number
    end

    def after_sequence(value)
      return 0 if value.nil? || value == ""

      number = Integer(value, exception: false)
      return nil unless number&.>=(0)

      number
    end

    def encode_cursor(kase)
      Base64.strict_encode64("#{kase.last_activity_at.iso8601(6)}|#{kase.id}")
    end

    def cursor(value)
      return [ nil, nil, nil ] if value.nil? || value == ""

      decoded = Base64.strict_decode64(value.to_s)
      time_text, id_text = decoded.split("|", 2)
      time = Time.zone.parse(time_text.to_s)
      id = Integer(id_text, exception: false)
      return [ nil, nil, :cursor ] if time.nil? || id.nil? || id <= 0

      [ time, id, nil ]
    rescue ArgumentError
      [ nil, nil, :cursor ]
    end

    def state(raw)
      return [ :technical_state, nil ] unless raw.is_a?(Hash)

      data = normalize(raw)
      return [ :signed_url, nil ] if signed?(data)
      return [ :too_large, nil ] if data.to_json.bytesize > STATE_MAX_BYTES

      [ nil, data ]
    end

    def checkpoint(raw)
      return [ nil, nil ] if raw.nil?
      return [ :checkpoint, nil ] unless raw.is_a?(Hash)

      data = normalize(raw)
      return [ :signed_url, nil ] if signed?(data)
      return [ :too_large, nil ] if data.to_json.bytesize > RESPONSE_MAX_BYTES

      [ nil, data ]
    end

    def response_envelope(raw, completed:)
      return [ nil, nil ] if raw.nil? && !completed
      return [ :response, nil ] unless raw.is_a?(Hash)

      data = normalize(raw)
      return [ :response, nil ] if (data.keys - RESPONSE_KEYS).any?

      text = data["published_text"]
      if completed
        return [ :published_text, nil ] unless text.is_a?(String) && text.present?
        return [ :published_text, nil ] if text.length > PUBLISHED_MAX
      elsif !text.nil?
        return [ :published_text, nil ] unless text.is_a?(String) && text.length <= PUBLISHED_MAX
      end

      citations = data["citations"]
      if !citations.nil? && !(citations.is_a?(Array) && citations.all? { |item| item.is_a?(Hash) })
        return [ :citations, nil ]
      end

      provenance = data["provenance"]
      return [ :provenance, nil ] if !provenance.nil? && !provenance.is_a?(Array)

      render = data["render"]
      return [ :render, nil ] if !render.nil? && !render.is_a?(Hash)
      return [ :signed_url, nil ] if signed?(data)
      return [ :too_large, nil ] if data.to_json.bytesize > RESPONSE_MAX_BYTES

      [ nil, data ]
    end

    def pins(raw)
      return [ :pins, nil ] unless raw.is_a?(Array)
      return [ :pins, nil ] if raw.size > PIN_MAX

      seen = {}
      entries = []
      raw.each do |item|
        return [ :pins, nil ] unless item.is_a?(Hash)

        data = item.stringify_keys
        return [ :pins, nil ] if (data.keys - PIN_KEYS).any?

        id = Integer(data["kb_document_id"], exception: false)
        return [ :pins, nil ] unless id&.positive?
        return [ :pins, nil ] if seen[id]

        seen[id] = true
        uid = data["document_uid"].to_s
        return [ :pins, nil ] unless uid.match?(UID_FORMAT)

        name = data["display_name"]
        if !name.nil?
          return [ :pins, nil ] unless name.is_a?(String) && name.length <= 200
          return [ :pins, nil ] if signed?(name)
        end

        entry = {
          "kb_document_id" => id,
          "document_uid" => uid,
          "added_at" => Time.current.iso8601
        }
        entry["display_name"] = name if name.present?
        entries << entry
      end
      [ nil, entries ]
    end

    def attachment_for(photo:, sha256:, content_type:, byte_size:)
      sha = photo ? photo.sha256 : sha256.to_s
      return [ :attachment, nil, nil ] if photo && sha256.present? && sha256 != photo.sha256
      return [ :attachment, nil, nil ] if sha.present? && !sha.match?(SHA_FORMAT)

      descriptor = {}
      descriptor["sha256"] = sha if sha.present?
      type = content_type.presence || photo&.content_type
      if type.present?
        return [ :attachment, nil, nil ] unless type.match?(CONTENT_TYPE_FORMAT)

        descriptor["content_type"] = type
      end
      size = byte_size.nil? ? photo&.byte_size : Integer(byte_size, exception: false)
      if !byte_size.nil? && size.nil?
        return [ :attachment, nil, nil ]
      end
      if size
        return [ :attachment, nil, nil ] unless size.positive? && size <= 20_000_000

        descriptor["byte_size"] = size
      end
      descriptor["field_photo_id"] = photo.id if photo
      return [ :signed_url, nil, nil ] if signed?(descriptor)

      [ nil, descriptor, sha.to_s ]
    end

    def title_from(state, current)
      goal = state.is_a?(Hash) ? state["goal"] : nil
      text = goal.is_a?(Hash) ? goal["text"] : goal
      return current unless text.is_a?(String) && text.strip.present?

      text.strip.first(TITLE_MAX)
    end

    def normalize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          copy[key.to_s] = normalize(item)
        end
      when Array
        value.map { |item| normalize(item) }
      else
        value
      end
    end

    def signed?(value)
      case value
      when Hash
        value.any? { |key, item| key.to_s.match?(SIGNED) || signed?(item) }
      when Array
        value.any? { |item| signed?(item) }
      when String
        value.match?(SIGNED)
      else
        false
      end
    end
  end
end
