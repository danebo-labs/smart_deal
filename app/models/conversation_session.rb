# frozen_string_literal: true

class ConversationSession < ApplicationRecord
  EXPIRY_DURATION = 30.days  # web workspace TTL; sliding window via refresh!
  MAX_HISTORY    = 20
  MAX_ENTITIES   = ENV.fetch('SESSION_MAX_ENTITIES', 10).to_i
  MAX_MSG_LENGTH = 300
  EPISODE_WINDOW = 4.hours
  EPISODE_MAX_USER_MESSAGES = 3
  PINNED_IMAGE_EXTENSIONS = %w[.gif .jpeg .jpg .png .webp].freeze

  # WA channel disabled for MVP. "whatsapp" kept in CHANNELS so legacy rows (if any) remain valid.
  CHANNELS = %w[web shared whatsapp].freeze

  belongs_to :user, optional: true
  belongs_to :account, optional: true

  validates :identifier, presence: true
  validates :channel,    inclusion: { in: CHANNELS }
  validates :expires_at, presence: true

  # Backfill test-only: pre-tenancy tests omit account_id. Mirrors KbDocument#document_uid fallback.
  before_validation { self.account_id ||= Account.minimum(:id) } if Rails.env.test?

  scope :active,  -> { where("expires_at > ?", Time.current) }
  scope :expired, -> { where(expires_at: ..Time.current) }
  scope :web,     -> { where(channel: "web") }

  # ─── Lifecycle ──────────────────────────────────────────────────────────────

  def self.find_or_create_for(identifier:, channel: "web", user_id: nil, account_id: nil)
    if SharedSession::ENABLED
      identifier = SharedSession::IDENTIFIER
      channel    = SharedSession::CHANNEL
    end
    account_id ||= Account.minimum(:id) if Rails.env.test?
    record = find_by(account_id: account_id, identifier: identifier, channel: channel)

    if record.nil? || record.expired?
      record&.destroy
      record = create!(
        identifier:  identifier,
        channel:     channel,
        user_id:     user_id,
        account_id:  account_id,
        expires_at:  EXPIRY_DURATION.from_now
      )
    end

    record
  end

  def expired?
    expires_at <= Time.current
  end

  def refresh!
    update!(expires_at: EXPIRY_DURATION.from_now)
  end

  def reset_procedure!
    update!(current_procedure: {}, session_status: "active")
  end

  # ─── History ────────────────────────────────────────────────────────────────

  def add_to_history(role, content, user_id: nil, correlation_id: nil)
    with_lock do
      history = conversation_history.last(MAX_HISTORY - 1)
      history << history_message(role, content, user_id: user_id, correlation_id: correlation_id)
      update!(conversation_history: history)
    end
  end

  # Combines `refresh!` (TTL bump) + `add_to_history` into a single UPDATE.
  # Used by the request-bound RAG path (RagController#ask) so we save one
  # round-trip to PostgreSQL on every user turn (3 writes → 2).
  # The new history is built inside the lock, after the row is reloaded, so a
  # photo job that loaded the session before vision cannot drop a text turn.
  def add_to_history_and_refresh(role, content, user_id: nil, correlation_id: nil)
    with_lock do
      history = conversation_history.last(MAX_HISTORY - 1)
      history << history_message(role, content, user_id: user_id, correlation_id: correlation_id)
      update!(conversation_history: history, expires_at: EXPIRY_DURATION.from_now)
    end
  end

  # Flag off: the same single UPDATE as add_to_history_and_refresh, and nil.
  # Flag on: history and active_episode in one UPDATE. The caller does not
  # read the Result while the episode flag is the only one enabled.
  def record_user_turn!(content, user_id:, correlation_id:, selection_turn: false, now: Time.current)
    unless episode_recording?
      add_to_history_and_refresh("user", content, user_id: user_id, correlation_id: correlation_id)
      return nil
    end

    result = nil
    with_lock do
      result = Rag::ActiveEpisodeTurn.call(
        state: active_episode,
        text: content.to_s,
        role: "user",
        now: now,
        selection_turn: selection_turn,
        correlation_id: correlation_id,
        channel: channel,
        enabled: true,
        shared: false,
        prior_user_turns: recent_user_turns(now)
      )
      history = conversation_history.last(MAX_HISTORY - 1)
      history << history_message("user", content, user_id: user_id, correlation_id: correlation_id)
      update!(
        conversation_history: history,
        active_episode: result.state,
        expires_at: EXPIRY_DURATION.from_now
      )
    end
    log_field_companion_turn(result, content, correlation_id: correlation_id, user_id: user_id)
    result
  end

  # History stays truncated. pending_fact is calculated from the full reply.
  def record_assistant_turn!(content, user_id:, correlation_id:)
    unless episode_recording?
      add_to_history("assistant", content, user_id: user_id, correlation_id: correlation_id)
      return nil
    end

    result = nil
    with_lock do
      result = Rag::ActiveEpisodeTurn.apply_assistant(
        state: active_episode,
        text: content.to_s,
        now: Time.current,
        correlation_id: correlation_id
      )
      history = conversation_history.last(MAX_HISTORY - 1)
      history << history_message("assistant", content, user_id: user_id, correlation_id: correlation_id)
      attrs = { conversation_history: history }
      attrs[:active_episode] = result.state if result.decision == :assistant
      update!(attrs)
    end
    log_field_companion_turn(result, content, correlation_id: correlation_id, user_id: user_id) if result.decision == :assistant
    result
  end

  def record_photo_observation!(photo_value:, field_photo_id:, sha256:, correlation_id:)
    return nil unless episode_recording?

    with_lock do
      episode = Rag::ActiveEpisode.parse(active_episode, now: Time.current)
      episode = Rag::ActiveEpisode.open(correlation_id: correlation_id, now: Time.current) if episode.blank?
      apply_photo_observation!(episode, photo_value, field_photo_id, sha256, correlation_id)
      episode.touch!(Time.current)
      update!(active_episode: episode.to_h)
    end
  end

  def reset_active_episode!
    with_lock { update!(active_episode: {}) }
  end

  def history_for_prompt
    conversation_history.map { |m| { role: m["role"], content: m["content"] } }
  end

  def recent_history_for_prompt(turns: 3)
    conversation_history.last(turns).map { |m| { role: m["role"], content: m["content"] } }
  end

  # Mensajes del usuario dentro de la ventana del episodio, en orden cronológico.
  # Un mensaje sin `ts` parseable queda fuera. `exclude` descarta la pregunta actual.
  def recent_user_turns(now)
    cutoff = now - EPISODE_WINDOW
    conversation_history.select { |message| message["role"] == "user" }.filter_map { |message|
      ts = parse_history_ts(message["ts"])
      next if ts.nil? || ts < cutoff || ts > now

      {
        "content" => message["content"].to_s,
        "correlation_id" => message["correlation_id"].to_s,
        "ts" => message["ts"].to_s
      }
    }.last(EPISODE_MAX_USER_MESSAGES)
  end

  def episode_user_messages(now: Time.current, exclude: nil)
    cutoff   = now - EPISODE_WINDOW
    excluded = exclude.to_s.strip

    conversation_history
      .select { |message| message["role"] == "user" }
      .filter_map do |message|
        ts = parse_history_ts(message["ts"])
        next if ts.nil? || ts < cutoff || ts > now

        content = message["content"].to_s
        next if excluded.present? && content.strip == excluded

        content
      end
      .last(EPISODE_MAX_USER_MESSAGES)
  end

  def last_assistant_message(now: Time.current)
    cutoff = now - EPISODE_WINDOW
    conversation_history.reverse_each do |message|
      next unless message["role"] == "assistant"

      ts = parse_history_ts(message["ts"])
      next if ts.nil? || ts < cutoff || ts > now

      return message["content"].to_s.presence
    end
    nil
  end

  # ─── Entities ───────────────────────────────────────────────────────────────

  # Stores metadata-only (no chunks). FIFO eviction when count exceeds MAX_ENTITIES.
  # Deduplicates: if name already matches any existing entity (by canonical key,
  # wa_filename, or any alias), the existing record is kept unchanged.
  def add_entity(name, metadata = {})
    return true if find_entity_by_name_or_alias(name)

    entities = active_entities.dup
    entities[name] = metadata.merge("added_at" => Time.current.iso8601)
    evict_oldest!(entities)
    update!(active_entities: entities)
    true
  end

  # Registers a named entity with its full alias set.
  # If any of canonical_name or any alias already matches an existing entity,
  # merges the new aliases into it instead of creating a duplicate.
  # @param canonical_name [String]  human-readable document name (key in hash)
  # @param aliases [Array<String>]  all known aliases (semantic + technical + wa_filename)
  # @param metadata [Hash]
  def add_entity_with_aliases(canonical_name, aliases = [], metadata = {})
    entities = active_entities.dup

    existing_key = find_entity_by_name_or_alias(canonical_name) ||
                   aliases.lazy.filter_map { |a| find_entity_by_name_or_alias(a) }.first

    if existing_key
      existing = entities[existing_key].dup
      merged   = sanitize_aliases(((existing["aliases"] || []) + aliases).map(&:to_s))
      entities[existing_key] = existing.merge("aliases" => merged)
    else
      entities[canonical_name] = metadata.merge(
        "canonical_name" => canonical_name,
        "aliases"        => sanitize_aliases(aliases.map(&:to_s)),
        "added_at"       => Time.current.iso8601
      )
      evict_oldest!(entities)
    end

    update!(active_entities: entities)
    true
  end

  # Physical-identity lookup: returns the canonical key whose entity has the
  # given source_uri. Used to dedup entities across aliases — two different
  # canonical_names with the same s3_uri are the same physical document.
  # @return [String, nil]
  def find_entity_by_source_uri(uri)
    return nil if uri.blank?
    active_entities.each do |key, meta|
      return key if meta["source_uri"].to_s == uri.to_s
    end
    nil
  end

  # Case-insensitive lookup across canonical keys, wa_filename, and aliases.
  # @return [String, nil] the canonical key if found
  def find_entity_by_name_or_alias(name)
    return nil if name.blank?

    term = name.to_s.strip
    active_entities.each_key do |key|
      next unless key.casecmp?(term) ||
                  active_entities[key]["wa_filename"].to_s.casecmp?(term) ||
                  Array(active_entities[key]["aliases"]).any? { |a| a.to_s.casecmp?(term) }

      return key
    end
    nil
  end

  def has_active_entities?
    active_entities.present?
  end

  def active_document_names
    active_entities.keys
  end

  def entity_count
    active_entities.size
  end

  # ─── Pinned KB documents (UI checkbox) ─────────────────────────────────────

  # Pin a KbDocument into the session: registers it as a user-driven entity.
  # Physical identity is source_uri, with kb_document_id as a stable fallback.
  # Names and aliases are descriptive only and never collapse distinct files.
  # @param kb_doc [KbDocument]
  # @return [Boolean] true on success/idempotent re-pin, false if URI cannot be resolved
  def pin_kb_document!(kb_doc)
    s3_uri = kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
    return false if s3_uri.blank?

    entities     = active_entities.dup
    existing_key = find_entity_by_source_uri(s3_uri)
    if existing_key.nil? && kb_doc.id.present?
      existing_key = entities.find { |_, meta| meta["kb_document_id"].to_s == kb_doc.id.to_s }&.first
    end
    canonical = kb_doc.display_name.presence || File.basename(kb_doc.s3_key.to_s, ".*")
    entity_type = pinned_entity_type(kb_doc)

    if existing_key
      existing = entities[existing_key].dup
      merged_aliases = sanitize_aliases(
        (Array(existing["aliases"]) + Array(kb_doc.aliases)).map(&:to_s)
      )
      refreshed = existing.merge(
        "kb_document_id" => kb_doc.id,
        "source_uri"     => s3_uri,
        "wa_filename"    => File.basename(kb_doc.s3_key.to_s),
        "entity_type"    => entity_type,
        "source"         => "user_pin",
        "aliases"        => merged_aliases
      )
      return true if refreshed == existing

      entities[existing_key] = refreshed
    else
      key = canonical
      if entities.key?(key)
        base_key = "#{canonical} (kb##{kb_doc.id})"
        key      = base_key
        suffix   = 2
        while entities.key?(key)
          key = "#{base_key}-#{suffix}"
          suffix += 1
        end
      end

      entities[key] = {
        "canonical_name"    => canonical,
        "kb_document_id"    => kb_doc.id,
        "source"            => "user_pin",
        "entity_type"       => entity_type,
        "source_uri"        => s3_uri,
        "wa_filename"       => File.basename(kb_doc.s3_key.to_s),
        "extraction_method" => "user_pin",
        "aliases"           => sanitize_aliases(Array(kb_doc.aliases).map(&:to_s)),
        "added_at"          => Time.current.iso8601
      }
      evict_oldest!(entities)
    end

    update!(active_entities: entities)
    true
  end

  # Unpin a KbDocument from the session by source_uri match.
  # Returns false if the doc was not pinned (no-op).
  def unpin_kb_document!(kb_doc)
    s3_uri = kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
    return false if s3_uri.blank?

    key = find_entity_by_source_uri(s3_uri)
    return false unless key

    entities = active_entities.dup
    entities.delete(key)
    update!(active_entities: entities)
    true
  end

  private

  def parse_history_ts(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

  def history_message(role, content, user_id:, correlation_id:)
    message = {
      "role" => role,
      "content" => content.to_s.truncate(MAX_MSG_LENGTH),
      "ts" => Time.current.iso8601
    }
    message["user_id"] = user_id if user_id.present?
    message["correlation_id"] = correlation_id if correlation_id.present?
    message
  end

  def episode_recording?
    Rag::FieldCompanionEpisodeFlag.enabled? && channel == "web" && !SharedSession::ENABLED
  end

  def apply_photo_observation!(episode, photo_value, field_photo_id, sha256, correlation_id)
    photo = { "correlation_id" => correlation_id.to_s }
    photo["field_photo_id"] = field_photo_id if field_photo_id.present?
    photo["sha256"] = sha256 if sha256.present?
    episode.active_photo = photo

    readings = photo_value.to_h.stringify_keys
    apply_photo_fact!(episode, "manufacturer", readings["manufacturer"], correlation_id)
    apply_photo_fact!(episode, "model", readings["model_visible"] || readings["model"], correlation_id)
  end

  def apply_photo_fact!(episode, key, raw, correlation_id)
    text = raw.to_s.squish
    return if text.blank? || text.casecmp?("unknown")

    existing = episode.fact(key)
    same = existing && Rag::FollowupQueryRewriter.normalize_label(existing["value"]) == Rag::FollowupQueryRewriter.normalize_label(text)
    if existing.nil? || existing["status"] == "unknown_confirmed" || (existing["source"] == "photo" && !same)
      episode.write_fact!(
        key,
        status: "known",
        value: text,
        source: "photo",
        correlation_id: correlation_id,
        at: Time.current.iso8601
      )
    elsif existing["status"] == "known" && existing["source"] == "user" && !same
      episode.add_conflict!(fact: key, user: existing["value"], photo: text, correlation_id: correlation_id)
    end
  end

  # Shadow does not change the text sent to the orchestrator, so both digests
  # are of that original turn. composed_chars records the unused composition.
  def log_field_companion_turn(result, content, correlation_id:, user_id:)
    digest = Digest::SHA256.hexdigest(content.to_s)
    PilotUsageLog.log(
      "field_companion_turn",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: id,
      correlation_id: correlation_id,
      route: "field_companion",
      result: result.decision.to_s,
      outcome_reason: result.reason,
      episode_id: result.state["episode_id"],
      episode_decision: result.decision.to_s,
      episode_fields_changed: result.fields_changed,
      composed_chars: result.composed&.length,
      original_sha256: digest,
      effective_sha256: digest
    )
  end

  def pinned_entity_type(kb_doc)
    extension = File.extname(kb_doc.s3_key.to_s).downcase
    PINNED_IMAGE_EXTENSIONS.include?(extension) ? "image_upload" : "document"
  end

  def sanitize_aliases(aliases_array)
    seen   = {}
    result = []

    aliases_array.each do |raw|
      s = raw.to_s.strip
      next if s.length < 2 || s.length > 60
      next if s.start_with?("|")
      next if s.include?("|")
      next if s.include?("**")
      next if s.include?("##")
      next if s.include?("⚠️")
      next if s.include?("→")
      next if s.include?("←")
      next if s.include?("http://")
      next if s.include?("https://")
      next if s.include?("s3://")
      next if s.count(" ") > 8

      key = s.downcase
      next if seen[key]

      seen[key] = true
      result << s
      break if result.size >= 15
    end

    result
  end

  def evict_oldest!(entities)
    return unless entities.size > MAX_ENTITIES

    oldest_key = entities.min_by { |_, v| v["added_at"].to_s }.first
    entities.delete(oldest_key)
  end
end
