# frozen_string_literal: true

class ConversationSession < ApplicationRecord
  EXPIRY_DURATION = 30.days  # web workspace TTL; sliding window via refresh!
  MAX_HISTORY    = 20
  MAX_ENTITIES   = ENV.fetch('SESSION_MAX_ENTITIES', 10).to_i
  MAX_MSG_LENGTH = 300
  EPISODE_WINDOW = 4.hours
  EPISODE_MAX_USER_MESSAGES = 3
  CaseBoundary = Data.define(:attributes, :case_boundary_reason, :pin_release_reason)
  PhotoTurnContext = Data.define(
    :status, :session_context, :entity_s3_uris, :equipment_identity, :retrieval_question
  )
  PINNED_IMAGE_EXTENSIONS = %w[.gif .jpeg .jpg .png .webp].freeze
  DOCUMENT_FOCUS_KEYS = %w[added_at display_name kb_document_id source_uri].freeze
  PHOTO_PENDING_SLOTS = %w[manufacturer model].freeze

  attr_accessor :turn_active_photo_context, :turn_causal, :context_truncated

  def self.media_type_for(document_or_uri)
    source = document_or_uri.respond_to?(:s3_key) ? document_or_uri.s3_key : document_or_uri
    extension = File.extname(source.to_s).downcase
    PINNED_IMAGE_EXTENSIONS.include?(extension) ? "image_upload" : "document"
  end

  # Copies authorized user_pin rows into the web focus. A pin without
  # kb_document_id is omitted. URI and name come from the KbDocument.
  def self.document_focus_from_legacy(entities, account:)
    return [] unless entities.is_a?(Hash) && account

    pins = entities.values.filter_map { |meta| legacy_pin_candidate(meta) }
    pins = newest_legacy_pins(pins)
    return [] if pins.empty?

    documents = KbDocument.where(id: pins.pluck(:id)).index_by(&:id)
    entries = pins.filter_map { |pin| legacy_focus_entry(documents[pin[:id]], pin, account) }
    entries.uniq { |entry| entry["kb_document_id"] }
           .sort_by { |entry| entry["added_at"].to_s }
           .last(MAX_ENTITIES)
  end

  def self.newest_legacy_pins(pins)
    pins.each_with_object({}) { |pin, best|
      current = best[pin[:id]]
      best[pin[:id]] = pin if current.nil? || pin[:added_at] > current[:added_at]
    }.values
  end
  private_class_method :newest_legacy_pins

  def self.legacy_pin_candidate(meta)
    return nil unless meta.is_a?(Hash) && meta["source"] == "user_pin"

    id = meta["kb_document_id"]
    return nil if id.blank?

    { id: id.to_i, added_at: meta["added_at"].to_s }
  end
  private_class_method :legacy_pin_candidate

  def self.legacy_focus_entry(document, pin, account)
    return nil unless document
    return nil unless Rag::KnowledgeScopePolicy.authorized?(document, viewer_account: account)

    uri = document.display_s3_uri(KbDocument::KB_BUCKET)
    return nil if uri.blank?

    {
      "kb_document_id" => document.id,
      "source_uri" => uri,
      "display_name" => document.display_name.presence || File.basename(document.s3_key.to_s, ".*"),
      "added_at" => pin[:added_at].presence || Time.current.iso8601
    }
  end
  private_class_method :legacy_focus_entry

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

  def add_to_history(role, content, user_id: nil, correlation_id: nil, focus_ids: nil)
    with_lock do
      history = conversation_history.last(MAX_HISTORY - 1)
      history << history_message(role, content, user_id: user_id, correlation_id: correlation_id, focus_ids: focus_ids)
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
  def record_user_turn!(content, user_id:, correlation_id:, selection_turn: false, now: Time.current, locale: :es, interpreter_client: nil)
    unless episode_recording?
      add_to_history_and_refresh("user", content, user_id: user_id, correlation_id: correlation_id)
      return nil
    end
    if owner_typed_turn?(selection_turn)
      return record_owner_turn!(
        content, user_id: user_id, correlation_id: correlation_id, now: now,
        locale: locale, interpreter_client: interpreter_client
      )
    end

    record_legacy_user_turn!(content, user_id: user_id, correlation_id: correlation_id, selection_turn: selection_turn, now: now)
  end

  def record_legacy_user_turn!(content, user_id:, correlation_id:, selection_turn:, now:)
    result = nil
    self.turn_causal = nil
    with_lock do
      stored_episode = active_episode
      result = Rag::ActiveEpisodeTurn.call(
        state: stored_episode,
        text: content.to_s,
        role: "user",
        now: now,
        selection_turn: selection_turn,
        correlation_id: correlation_id,
        channel: channel,
        enabled: true,
        shared: false,
        prior_user_turns: recent_user_turns(now),
        focus_count: focus_document_ids.size,
        account: account,
        attribution: {
          account_id: account_id,
          user_id: user_id,
          conversation_session_id: id
        }
      )
      remember_turn_causal!(stored_episode, result.state)
      persist_user_turn!(stored_episode, result, content, user_id, correlation_id, now)
    end
    log_field_companion_turn(result, content, correlation_id: correlation_id, user_id: user_id)
    result
  end

  # History stays truncated. pending_fact is calculated from the full reply.
  def record_assistant_turn!(content, user_id:, correlation_id:, pending_question: nil, expected_episode_id: nil, writer: "assistant", focus_ids: nil)
    unless episode_recording?
      add_to_history("assistant", content, user_id: user_id, correlation_id: correlation_id, focus_ids: focus_ids)
      return :not_recording if writer == "photo_assistant"

      return nil
    end

    result = nil
    dropped = false
    stale_event = nil
    self.turn_causal = nil
    with_lock do
      current_id = live_episode_id
      expected = expected_episode_id.presence
      if expected != current_id
        stale_event = stale_case_payload(
          writer: writer,
          expected_episode_id: expected,
          current_episode_id: current_id,
          correlation_id: correlation_id
        )
        dropped = true
        next
      end

      if writer == "photo_assistant" && Rag::HaikuQueryAnalysisFlag.owner?
        history = conversation_history.last(MAX_HISTORY - 1)
        history << history_message("assistant", content, user_id: user_id, correlation_id: correlation_id, focus_ids: focus_ids)
        update!(conversation_history: history)
        next
      end

      stored_episode = active_episode
      result = Rag::ActiveEpisodeTurn.apply_assistant(
        state: stored_episode,
        text: content.to_s,
        now: Time.current,
        correlation_id: correlation_id,
        pending_question: pending_question
      )
      remember_turn_causal!(stored_episode, result.state)
      history = conversation_history.last(MAX_HISTORY - 1)
      history << history_message("assistant", content, user_id: user_id, correlation_id: correlation_id, focus_ids: focus_ids)
      attrs = { conversation_history: history }
      attrs[:active_episode] = result.state if result.decision == :assistant
      update!(attrs)
    end
    emit_stale_case_write(stale_event)
    if writer == "photo_assistant"
      return :stale if dropped

      log_field_companion_turn(result, content, correlation_id: correlation_id, user_id: user_id) if result&.decision == :assistant
      return :applied
    end
    return nil if dropped

    log_field_companion_turn(result, content, correlation_id: correlation_id, user_id: user_id) if result.decision == :assistant
    result
  end

  # Photo [FOTO] line plus the generation context of that same case.
  # The context string and the pinned-document URI list are read inside the
  # ownership lock, after the history write. Document Focus rules stay as they
  # are; this only freezes the list SessionContextBuilder already computes.
  # :not_recording has no episode to protect, so the capture follows the
  # history write without treating that path as stale.
  def record_photo_assistant_context!(content, user_id:, correlation_id:, expected_episode_id: nil, question: nil, accepted_observation: nil, confirm_identity: false)
    unless episode_recording?
      add_to_history("assistant", content, user_id: user_id, correlation_id: correlation_id)
      return capture_photo_turn_context(
        :not_recording, question: question, accepted_observation: accepted_observation, correlation_id: correlation_id
      )
    end

    result = nil
    dropped = false
    snapshot = nil
    stale_event = nil
    promotion = nil
    with_lock do
      current_id = live_episode_id
      expected = expected_episode_id.presence
      if expected != current_id
        stale_event = stale_case_payload(
          writer: "photo_assistant",
          expected_episode_id: expected,
          current_episode_id: current_id,
          correlation_id: correlation_id
        )
        dropped = true
        next
      end

      if Rag::HaikuQueryAnalysisFlag.owner?
        history = conversation_history.last(MAX_HISTORY - 1)
        history << history_message("assistant", content, user_id: user_id, correlation_id: correlation_id)
        update!(conversation_history: history)
      else
        stored_episode = active_episode
        result = Rag::ActiveEpisodeTurn.apply_assistant(
          state: stored_episode,
          text: content.to_s,
          now: Time.current,
          correlation_id: correlation_id
        )
        remember_turn_causal!(stored_episode, result.state)
        history = conversation_history.last(MAX_HISTORY - 1)
        history << history_message("assistant", content, user_id: user_id, correlation_id: correlation_id)
        attrs = { conversation_history: history }
        attrs[:active_episode] = result.state if result.decision == :assistant
        update!(attrs)
      end

      if confirm_identity
        promotion = promote_reused_photo_identity!(
          correlation_id: correlation_id,
          question: question,
          accepted_observation: accepted_observation
        )
      end

      snapshot = capture_photo_turn_context(
        :applied, question: question, accepted_observation: accepted_observation, correlation_id: correlation_id
      )
    end
    emit_stale_case_write(stale_event)
    emit_identity_promotion(promotion, user_id: user_id)
    return capture_photo_turn_context(:stale) if dropped

    log_field_companion_turn(result, content, correlation_id: correlation_id, user_id: user_id) if result&.decision == :assistant
    snapshot
  end

  def record_photo_observation!(photo_value:, field_photo_id:, sha256:, correlation_id:, expected_episode_id: nil)
    return :not_recording unless episode_recording?

    stale_event = nil
    promotion = nil
    outcome = with_lock do
      current_id = live_episode_id
      expected = expected_episode_id.presence
      if expected.blank? || expected != current_id
        stale_event = stale_case_payload(
          writer: "photo_observation",
          expected_episode_id: expected,
          current_episode_id: current_id,
          correlation_id: correlation_id
        )
        next :stale
      end

      episode = Rag::ActiveEpisode.parse(active_episode, now: Time.current)
      before = episode.blank? ? nil : episode.fork
      apply_photo_observation!(episode, photo_value, field_photo_id, sha256, correlation_id)
      promotion = first_photo_identity_promotion(before, episode, photo_value, correlation_id) if before
      episode.touch!(Time.current)
      update!(active_episode: episode.to_h)
      :applied
    end
    emit_stale_case_write(stale_event)
    emit_identity_promotion(promotion) if outcome == :applied
    outcome
  end

  # Synchronous case owner for a photo submission. Reuses a live case.
  # Expired or invalid JSON opens a new episode and clears current_procedure.
  # The technician's document selection is not part of that write.
  def ensure_case_for_photo_submission!(correlation_id:, now: Time.current)
    return nil unless episode_recording?

    with_lock do
      stored = active_episode
      parsed = Rag::ActiveEpisode.parse(stored, now: now)
      if parsed.reason == "invalid_state"
        pins = focus_document_ids
        photo_before = photo_marker(stored)
        episode = Rag::ActiveEpisode.open(correlation_id: correlation_id, now: now)
        update!(
          active_episode: episode.to_h,
          current_procedure: {}
        )
        log_case_probe(
          episode_before: raw_episode_id(stored),
          episode_after: episode.episode_id,
          case_boundary_reason: "invalid_state",
          pin_release_reason: nil,
          pins_before: pins,
          pins_after: pins,
          active_photo_before: photo_before,
          active_photo_after: nil
        )
        episode.episode_id
      elsif parsed.reason == "expired"
        pins = focus_document_ids
        photo_before = photo_marker(stored)
        episode = Rag::ActiveEpisode.open(correlation_id: correlation_id, now: now)
        update!(
          active_episode: episode.to_h,
          current_procedure: {}
        )
        log_case_probe(
          episode_before: raw_episode_id(stored),
          episode_after: episode.episode_id,
          case_boundary_reason: "episode_expired",
          pin_release_reason: nil,
          pins_before: pins,
          pins_after: pins,
          active_photo_before: photo_before,
          active_photo_after: nil
        )
        episode.episode_id
      elsif parsed.blank?
        episode = Rag::ActiveEpisode.open(correlation_id: correlation_id, now: now)
        update!(active_episode: episode.to_h)
        episode.episode_id
      else
        parsed.episode_id
      end
    end
  end

  def reset_active_episode!
    with_lock { update!(active_episode: {}) }
  end

  # Future explicit "new case" control. Not wired to a route. One UPDATE:
  # a fresh episode and no procedure. Pins, history, and FieldPhoto rows stay.
  def start_new_case!(now: Time.current, reason:, correlation_id:)
    raise ArgumentError, "reason is required" if reason.blank?

    with_lock do
      pins = focus_document_ids
      photo_before = photo_marker(active_episode)
      episode_before = raw_episode_id(active_episode)
      episode = Rag::ActiveEpisode.open(correlation_id: correlation_id, now: now)
      update!(
        active_episode: episode.to_h,
        current_procedure: {}
      )
      log_case_probe(
        episode_before: episode_before,
        episode_after: episode.episode_id,
        case_boundary_reason: reason.to_s,
        pin_release_reason: nil,
        pins_before: pins,
        pins_after: pins,
        active_photo_before: photo_before,
        active_photo_after: nil
      )
      episode.episode_id
    end
  end

  def live_episode_id(now = Time.current)
    episode = Rag::ActiveEpisode.parse(active_episode, now: now)
    episode.blank? ? nil : episode.episode_id
  end

  def history_for_prompt
    conversation_history.map { |m| { role: m["role"], content: m["content"] } }
  end

  def recent_history_for_prompt(turns: 3)
    conversation_history.last(turns).map { |m| { role: m["role"], content: m["content"] } }
  end

  # Mensajes del usuario dentro de la ventana del episodio, en orden cronológico.
  # Un mensaje sin `ts` parseable queda fuera. `exclude` descarta la pregunta actual.
  def episode_history_cutoff(now = Time.current)
    window_start = now - EPISODE_WINDOW
    episode = Rag::ActiveEpisode.parse(active_episode, now: now)
    return window_start if episode.blank?

    opened = parse_history_ts(episode.opened_at)
    return window_start if opened.nil?

    [ window_start, opened ].max
  end

  def recent_user_turns(now)
    cutoff = episode_history_cutoff(now)
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
    cutoff   = episode_history_cutoff(now)
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
    cutoff = episode_history_cutoff(now)
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

  # Web returns the focus entry. WhatsApp returns the legacy hash key.
  def find_entity_by_kb_document_id(id)
    return nil if id.blank?

    if uses_document_focus?
      return document_focus_entries.find { |entry| entry["kb_document_id"] == id.to_i }
    end

    active_entities.each do |key, meta|
      return key if meta.is_a?(Hash) && meta["kb_document_id"].to_i == id.to_i
    end
    nil
  end

  # Web focus is not the WhatsApp entity hash. Shared sessions use this column too.
  def uses_document_focus?
    channel != "whatsapp"
  end

  # Tolerant reader. A hash, a string, or a row without an id is an empty focus.
  def document_focus_entries
    raw = self[:document_focus]
    return [] unless raw.is_a?(Array)

    entries = raw.filter_map { |item| coerce_focus_entry(item) }
    entries = entries.reverse.uniq { |entry| entry["kb_document_id"] }.reverse
    return entries if entries.size <= MAX_ENTITIES

    kept_ids = entries.sort_by { |entry| entry["added_at"].to_s }.last(MAX_ENTITIES)
                      .pluck("kb_document_id")
    entries.select { |entry| kept_ids.include?(entry["kb_document_id"]) }
  rescue StandardError
    []
  end

  def focus_document_ids
    document_focus_entries.pluck("kb_document_id")
  end

  # Transient index for the selection gate and the N→1 resolver. Aliases are
  # read from KbDocument and are not stored on the focus.
  def document_focus_scope_index
    entries = document_focus_entries
    return {} if entries.empty?

    documents = KbDocument.where(id: entries.pluck("kb_document_id")).index_by(&:id)
    entries.each_with_object({}) do |entry, index|
      document = documents[entry["kb_document_id"]]
      key = entry["display_name"].presence || "doc-#{entry["kb_document_id"]}"
      key = "#{key} (kb##{entry["kb_document_id"]})" while index.key?(key)
      index[key] = {
        "canonical_name" => entry["display_name"],
        "source_uri" => entry["source_uri"],
        "aliases" => document ? Array(document.aliases) : [],
        "kb_document_id" => entry["kb_document_id"]
      }
    end
  end

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

  def stamp_user_retrieval_query!(correlation_id, retrieval_query)
    return false if correlation_id.blank? || retrieval_query.blank?

    with_lock do
      history = conversation_history
      message = history.reverse.find { |row| row["role"] == "user" && row["correlation_id"] == correlation_id }
      next false unless message

      message["retrieval_query"] = retrieval_query.to_s.truncate(MAX_MSG_LENGTH)
      update!(conversation_history: history)
      true
    end
  end

  def user_message_for(correlation_id)
    conversation_history.reverse.find { |row| row["role"] == "user" && row["correlation_id"] == correlation_id }
  end

  def assistant_for_focus(correlation_id, focus_ids)
    key = Array(focus_ids).map(&:to_i).uniq.sort
    conversation_history.reverse.find do |row|
      row["role"] == "assistant" &&
        row["correlation_id"] == correlation_id &&
        Array(row["focus_ids"]).map(&:to_i).uniq.sort == key
    end
  end

  # One write. The selected set becomes this document.
  def replace_document_focus!(kb_doc)
    return false unless uses_document_focus?

    s3_uri = kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
    return false if s3_uri.blank?

    entry = {
      "kb_document_id" => kb_doc.id,
      "source_uri" => s3_uri,
      "display_name" => kb_doc.display_name.presence || File.basename(kb_doc.s3_key.to_s, ".*"),
      "added_at" => Time.current.iso8601
    }
    with_lock do
      update!(document_focus: [ entry ])
      true
    end
  end

  # ─── Pinned KB documents (UI checkbox) ─────────────────────────────────────

  # Pin a KbDocument. Web writes document_focus. WhatsApp keeps active_entities.
  # URI and display name are copied from the KbDocument, never from the client.
  # @param kb_doc [KbDocument]
  # @return [Boolean] true on success/idempotent re-pin, false if URI cannot be resolved
  def pin_kb_document!(kb_doc)
    s3_uri = kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
    return false if s3_uri.blank?

    with_lock { write_focus!(kb_doc, s3_uri) }
  end

  # One lock: reload, compare the submission's episode id, then pin.
  # A missing or mismatched owner does not pin.
  def pin_kb_document_if_episode_owner!(kb_doc, expected_episode_id:, correlation_id: nil)
    s3_uri = kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
    return false if s3_uri.blank?

    stale_event = nil
    pinned = with_lock do
      expected = expected_episode_id.presence
      current = live_episode_id
      if expected.blank? || expected != current
        stale_event = stale_case_payload(
          writer: "auto_pin",
          expected_episode_id: expected,
          current_episode_id: current,
          correlation_id: correlation_id
        )
        next false
      end

      write_focus!(kb_doc, s3_uri)
    end
    emit_stale_case_write(stale_event)
    pinned
  end

  # Unpin this session's focus. Match the stored kb_document_id first so a
  # revoked document can still be removed. source_uri remains the fallback
  # for a pin written before that id was stored.
  def unpin_kb_document!(kb_doc)
    with_lock do
      if uses_document_focus?
        next true if remove_document_focus_id!(kb_doc.id)

        s3_uri = kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
        next false if s3_uri.blank?

        next remove_document_focus_uri!(s3_uri)
      end

      key = find_entity_by_kb_document_id(kb_doc.id)
      if key.nil?
        s3_uri = kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
        next false if s3_uri.blank?

        key = find_entity_by_source_uri(s3_uri)
      end
      next false unless key

      delete_pinned_key!(key)
    end
  end

  # Removes this session's focus by the stored id. The row does not have to
  # still exist or still be readable. This does not grant a read.
  def unpin_kb_document_id!(kb_document_id)
    with_lock do
      if uses_document_focus?
        next remove_document_focus_id!(kb_document_id)
      end

      key = find_entity_by_kb_document_id(kb_document_id)
      next false unless key

      delete_pinned_key!(key)
    end
  end

  private

  def capture_photo_turn_context(status, question: nil, accepted_observation: nil, correlation_id: nil)
    if status == :stale
      return PhotoTurnContext.new(
        status: status, session_context: nil, entity_s3_uris: nil,
        equipment_identity: nil, retrieval_question: nil
      )
    end

    episode = Rag::ActiveEpisode.parse(active_episode, now: Time.current)
    episode = nil if episode.blank?
    derived = Rag::PhotoRetrievalSnapshot.capture(
      episode: episode,
      question: question,
      observation: accepted_observation,
      correlation_id: correlation_id
    )
    PhotoTurnContext.new(
      status: status,
      session_context: SessionContextBuilder.build(self).to_s,
      entity_s3_uris: SessionContextBuilder.entity_s3_uris(self),
      equipment_identity: derived.equipment_identity,
      retrieval_question: derived.retrieval_question
    )
  end

  def owner_typed_turn?(selection_turn)
    Rag::HaikuQueryAnalysisFlag.owner? && !selection_turn
  end

  def record_owner_turn!(content, user_id:, correlation_id:, now:, locale:, interpreter_client:)
    Rag::ValidationCapture.with_turn(correlation_id) do
      apply_recorded_owner_turn!(
        content,
        user_id: user_id,
        correlation_id: correlation_id,
        now: now,
        locale: locale,
        interpreter_client: interpreter_client
      )
    end
  end

  def apply_recorded_owner_turn!(content, user_id:, correlation_id:, now:, locale:, interpreter_client:)
    self.turn_causal = nil
    turn = Rag::TurnText.truncate(content)
    if duplicate_user_correlation?(correlation_id)
      note_owner_exit("duplicate_correlation", "duplicate_user_correlation", correlation_id)
      return duplicate_owner_result(turn)
    end

    snapshot = active_episode
    parsed = Rag::ActiveEpisode.parse(snapshot, now: now)
    context_episode = stale_episode?(parsed) ? Rag::ActiveEpisode.new : parsed
    Rag::ValidationCapture.bind(
      session_id: id,
      account_id: account_id,
      user_id: user_id,
      episode_id: context_episode.episode_id
    )
    photo_context = Rag::ActivePhotoContext.resolve(episode: context_episode, viewer_account: account)
    photo_status = photo_context.status
    interpreted = Rag::TurnInterpreter.call(
      turn: turn,
      episode: context_episode,
      viewer_account: account,
      correlation_id: correlation_id,
      attribution: { account_id: account_id, user_id: user_id, conversation_session_id: id },
      client: interpreter_client,
      active_photo_context: photo_context
    )

    result = nil
    with_lock do
      if duplicate_user_correlation?(correlation_id)
        note_owner_exit("duplicate_correlation", "duplicate_user_correlation", correlation_id)
        result = duplicate_owner_result(turn)
        next
      end

      focus = fresh_focus_snapshot
      if same_episode?(snapshot, active_episode)
        result = apply_owner_perception!(turn, interpreted, correlation_id, user_id, now, locale, focus, photo_context)
      else
        photo_status = photo_context.status == "absent" ? "absent" : "stale"
        self.turn_active_photo_context = nil
        result = apply_owner_fallback!(turn, correlation_id, user_id, now, locale, focus, "snapshot_changed")
      end
    end
    log_turn_interpreter(interpreted, result, correlation_id, user_id, photo_status)
    log_field_companion_turn(result, turn, correlation_id: correlation_id, user_id: user_id) if result&.state.is_a?(Hash)
    result
  end

  def apply_owner_perception!(turn, interpreted, correlation_id, user_id, now, locale, focus, photo_context)
    perception = interpreted.perception
    if interpreted.fallback || perception.nil? || !perception.valid
      self.turn_active_photo_context = nil
      return apply_owner_fallback!(turn, correlation_id, user_id, now, locale, focus, interpreted.status)
    end

    stored = active_episode
    parsed = Rag::ActiveEpisode.parse(stored, now: now)
    base = stale_episode?(parsed) ? Rag::ActiveEpisode.new : parsed
    policy_previous = perception.move == "new_work" ? Rag::ActiveEpisode.new : base
    decision = Rag::RoutePolicy.call(
      previous: policy_previous,
      perception: perception,
      focus_count: focus[:ids].size,
      focus_document_ids: focus[:ids],
      focus_uris: focus[:uris],
      locale: locale,
      relevant_photo: photo_context.relevant?
    )
    before_episode = base.fork
    working = if perception.move == "new_work" || base.blank?
      Rag::ActiveEpisode.open(correlation_id: correlation_id, now: now)
    else
      base
    end
    Rag::WorkContextReducer.apply!(
      episode: working, perception: perception, decision: decision,
      turn: turn, correlation_id: correlation_id, now: now
    )
    payload = working.to_h
    if Rag::ActiveEpisode.budget_refused?(payload)
      Rails.logger.info({ event: "episode_budget_refused", conversation_session_id: id, correlation_id: correlation_id }.to_json)
      self.turn_active_photo_context = nil
      return apply_owner_fallback!(turn, correlation_id, user_id, now, locale, focus, "episode_budget_refused")
    end

    Rag::ValidationCapture.bind(episode_id: working.episode_id)
    Rag::EpisodeDelta.record(before_episode, working, correlation_id: correlation_id)

    explained = Rag::QueryComposer.explain(
      state: working, turn: turn, perception: perception, decision: decision,
      active_photo_context: photo_context
    )
    query = explained[:query]
    remember_turn_causal!(before_episode, payload, components: explained[:components])
    decision = decision.with(retrieval_query: query, owns_query: query.present? && decision.performs_retrieval?)
    self.turn_active_photo_context = if photo_context.matches?(working.active_photo&.dig("field_photo_id"))
      photo_context
    end
    episode_decision = owner_episode_decision(perception, base)
    result = Rag::ActiveEpisodeTurn::Result.new(
      decision: episode_decision,
      reason: perception.move,
      state: payload,
      composed: query,
      fields_changed: Rag::ActiveEpisodeTurn.changed_fields(before_episode, working),
      understanding: decision
    )
    persist_user_turn!(stored, result, turn, user_id, correlation_id, now)
    result
  end

  def apply_owner_fallback!(turn, correlation_id, user_id, now, locale, focus, status)
    stored = active_episode
    parsed = Rag::ActiveEpisode.parse(stored, now: now)
    episode = stale_episode?(parsed) ? Rag::ActiveEpisode.new : parsed
    Rag::ValidationCapture.bind(
      session_id: id,
      account_id: account_id,
      user_id: user_id,
      episode_id: episode.episode_id
    )
    note_owner_exit("fallback", status.to_s, correlation_id)
    before_episode = episode.fork
    if retain_failed_report?(status)
      episode = Rag::WorkContextReducer.retain_uninterpreted_report!(
        episode: episode, turn: turn, correlation_id: correlation_id, now: now
      )
    end
    Rag::EpisodeDelta.record(before_episode, episode, correlation_id: correlation_id)
    decision = Rag::RoutePolicy.fallback(
      episode: episode,
      turn: turn,
      focus_count: focus[:ids].size,
      focus_document_ids: focus[:ids],
      focus_uris: focus[:uris],
      catalog: Rag::DocumentIdentityCatalog.current,
      viewer_account: account,
      locale: locale
    )
    decision = decision.with(fallback: true)
    remember_turn_causal!(before_episode.to_h, episode.to_h)
    opened = before_episode.blank? && episode.present?
    result = Rag::ActiveEpisodeTurn::Result.new(
      decision: opened ? :opened : :continued,
      reason: status.to_s,
      state: episode.to_h,
      composed: decision.retrieval_query,
      fields_changed: Rag::ActiveEpisodeTurn.changed_fields(before_episode, episode),
      understanding: decision
    )
    persist_user_turn!(
      stored, result, turn, user_id, correlation_id, now,
      keep_episode: episode.to_h == before_episode.to_h
    )
    result
  end

  def retain_failed_report?(status)
    %w[snapshot_changed episode_budget_refused].exclude?(status.to_s)
  end

  def note_owner_exit(exit_name, condition, correlation_id)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "route_exit",
      "exit" => exit_name,
      "condition" => condition,
      "correlation_id" => correlation_id
    )
  end

  def duplicate_owner_result(turn)
    remember_turn_causal!(active_episode, active_episode)
    Rag::ActiveEpisodeTurn::Result.new(
      decision: :continued,
      reason: "duplicate_correlation",
      state: active_episode,
      composed: turn,
      fields_changed: [],
      understanding: nil
    )
  end

  def owner_episode_decision(perception, base)
    return :new_episode if perception.move == "new_work"
    return :opened if base.blank?

    :continued
  end

  def stale_episode?(parsed)
    parsed.nil? || parsed.blank? || %w[expired invalid_state].include?(parsed.reason)
  end

  def persist_user_turn!(stored_episode, result, content, user_id, correlation_id, now, keep_episode: false)
    history = conversation_history.last(MAX_HISTORY - 1)
    history << history_message("user", content, user_id: user_id, correlation_id: correlation_id)
    attrs = {
      conversation_history: history,
      expires_at: EXPIRY_DURATION.from_now
    }
    attrs[:active_episode] = result.state unless keep_episode
    pins_before = focus_document_ids
    photo_before = photo_marker(stored_episode)
    episode_before = raw_episode_id(stored_episode)
    boundary = case_boundary_changes(stored_episode, result, now)
    attrs.merge!(boundary.attributes) if boundary
    update!(attrs)
    log_case_boundary!(
      episode_before: episode_before,
      episode_after: raw_episode_id(keep_episode ? stored_episode : result.state),
      boundary: boundary,
      pins_before: pins_before,
      photo_before: photo_before,
      photo_after: photo_marker(keep_episode ? stored_episode : result.state)
    )
  end

  def duplicate_user_correlation?(correlation_id)
    conversation_history.any? { |message|
      message["role"] == "user" && message["correlation_id"].to_s == correlation_id.to_s
    }
  end

  def same_episode?(left, right)
    canonicalize_episode(left) == canonicalize_episode(right)
  end

  def canonicalize_episode(raw)
    case raw
    when Hash
      raw.each_with_object({}) { |(key, value), copy| copy[key.to_s] = canonicalize_episode(value) }
    when Array
      raw.map { |item| canonicalize_episode(item) }
    else
      raw
    end
  end

  def fresh_focus_snapshot
    if uses_document_focus?
      entries = document_focus_entries
      ids = entries.filter_map { |entry| entry["kb_document_id"] }
      uris = SessionContextBuilder.filter_focus_uris(entries.filter_map { |entry| entry["source_uri"] })
    else
      ids = []
      uris = SessionContextBuilder.entity_s3_uris(self)
    end
    { ids: ids, uris: uris }
  end

  def log_turn_interpreter(interpreted, result, correlation_id, user_id, photo_status)
    perception = interpreted.perception
    assertions = interpreter_assertion_tokens(interpreted, result)
    before_state = result&.state
    goal = before_state.is_a?(Hash) ? before_state["goal"] : nil
    goal = goal.is_a?(Hash) ? goal : {}
    PilotUsageLog.log(
      :turn_interpreter,
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: id,
      correlation_id: correlation_id,
      model: interpreted.model_id,
      latency_ms: interpreted.latency_ms,
      input_tokens: interpreted.input_tokens,
      output_tokens: interpreted.output_tokens,
      episode_id: before_state.is_a?(Hash) ? before_state["episode_id"] : nil,
      goal_text: goal["text"].to_s.strip.first(120).presence,
      goal_source_correlation_id: goal["correlation_id"].to_s.presence,
      route: result&.understanding&.decision,
      turn_interpreter_status: interpreted.status,
      turn_interpreter_fallback: interpreted.fallback || result&.understanding&.fallback || false,
      error_class: interpreted.error_class,
      stage: interpreted.stage,
      interpreter_error_reason: interpreted.error_reason,
      prompt_version: Rag::TurnPerception::PROMPT_VERSION,
      schema_version: Rag::TurnPerception::SCHEMA_VERSION,
      catalog_fingerprint: Rag::TurnInterpreter.catalog_fingerprint,
      interpreter_move: perception&.move,
      interpreter_assertions: assertions,
      field_rejections: perception&.field_rejections,
      catalog_disagreement: perception&.catalog_disagreements,
      pending_question_type: result&.understanding&.pending_subject,
      pending_outcome: perception&.pending_resolution,
      clarification_target: perception&.clarification_target,
      active_photo_context_status: photo_status
    )
  rescue StandardError => error
    Rails.logger.warn("turn_interpreter telemetry failed #{error.class}")
  end

  # A case boundary may clear current_procedure. It does not read or write
  # the technician's document selection. Expiry is a property of the stored
  # JSON, not of the classifier decision.
  def case_boundary_changes(stored_episode, result, now)
    if stored_episode_invalid?(stored_episode, now)
      return CaseBoundary.new(
        attributes: { current_procedure: {} },
        case_boundary_reason: "invalid_state",
        pin_release_reason: nil
      )
    end

    if stored_episode_expired?(stored_episode, now)
      return CaseBoundary.new(
        attributes: { current_procedure: {} },
        case_boundary_reason: "episode_expired",
        pin_release_reason: nil
      )
    end

    return unless result.decision == :new_episode

    CaseBoundary.new(
      attributes: { current_procedure: {} },
      case_boundary_reason: "new_episode",
      pin_release_reason: nil
    )
  end

  def log_case_boundary!(episode_before:, episode_after:, boundary:, pins_before:, photo_before:, photo_after:)
    return if boundary.nil?

    pins_after = if boundary.attributes.key?(:active_entities)
      pin_document_ids(boundary.attributes[:active_entities])
    else
      pins_before
    end
    log_case_probe(
      episode_before: episode_before,
      episode_after: episode_after,
      case_boundary_reason: boundary.case_boundary_reason,
      pin_release_reason: boundary.pin_release_reason,
      pins_before: pins_before,
      pins_after: pins_after,
      active_photo_before: photo_before,
      active_photo_after: photo_after
    )
  end

  def log_case_probe(episode_before:, episode_after:, case_boundary_reason:, pin_release_reason:, pins_before:, pins_after:, active_photo_before:, active_photo_after:)
    return if case_boundary_reason.blank? && pin_release_reason.blank?

    Rails.logger.info({
      event: "R1B_CASE_PROBE",
      conversation_session_id: id,
      episode_before: episode_before,
      episode_after: episode_after,
      case_boundary_reason: case_boundary_reason,
      pin_release_reason: pin_release_reason,
      pins_before: pins_before,
      pins_after: pins_after,
      active_photo_before: active_photo_before,
      active_photo_after: active_photo_after
    }.to_json)
  end

  def stale_case_payload(writer:, expected_episode_id:, current_episode_id:, correlation_id:)
    {
      writer: writer,
      expected_episode_id: expected_episode_id,
      current_episode_id: current_episode_id,
      episode_id: current_episode_id,
      correlation_id: correlation_id,
      dropped: true
    }
  end

  def emit_stale_case_write(payload)
    return if payload.blank?

    PilotUsageLog.log(
      "stale_case_write_dropped",
      account_id: account_id,
      conversation_session_id: id,
      **payload
    )
  end

  def emit_identity_promotion(payload, user_id: nil)
    return if payload.blank?

    PilotUsageLog.log(
      "identity_promotion",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: id,
      **payload
    )
  end

  def pin_document_ids(entities)
    return [] unless entities.is_a?(Hash)

    entities.filter_map { |_key, meta| meta["kb_document_id"] if meta.is_a?(Hash) && meta["kb_document_id"].present? }
  end

  def photo_marker(raw)
    photo = raw.is_a?(Hash) ? raw["active_photo"] : nil
    return nil unless photo.is_a?(Hash)

    photo["field_photo_id"]
  end

  def raw_episode_id(raw)
    return nil unless raw.is_a?(Hash)

    raw["episode_id"].presence
  end

  def stored_episode_invalid?(raw, now)
    Rag::ActiveEpisode.parse(raw, now: now).reason == "invalid_state"
  end

  def stored_episode_expired?(raw, now)
    Rag::ActiveEpisode.parse(raw, now: now).reason == "expired"
  end

  # No caller after F1. The case no longer filters pins. F9 deletes this cluster.
  def pins_after_expiry(entities, stored_episode)
    cutoff = expiry_pin_cutoff(stored_episode)
    entities.each_with_object({}) do |(key, meta), kept|
      added = parse_history_ts(meta.is_a?(Hash) ? meta["added_at"] : nil)
      next if added.nil? || cutoff.nil? || added <= cutoff

      kept[key] = meta
    end
  end

  def expiry_pin_cutoff(stored_episode)
    data = stored_episode.is_a?(Hash) ? stored_episode : {}
    updated = parse_history_ts(data["updated_at"])
    return nil if updated.nil?

    updated + EPISODE_WINDOW
  end

  def pins_after_manufacturer_correction(entities, stored_episode, new_state)
    old_value = manufacturer_fact_value(stored_episode)
    new_value = manufacturer_fact_value(new_state)
    return nil if old_value.blank? || new_value.blank?

    old_label = Rag::FollowupQueryRewriter.normalize_label(old_value)
    new_label = Rag::FollowupQueryRewriter.normalize_label(new_value)
    return nil if old_label.blank? || new_label.blank? || old_label == new_label

    removed = false
    kept = entities.each_with_object({}) do |(key, meta), acc|
      if incompatible_manufacturer_pin?(key, meta, old_label, new_label)
        removed = true
        next
      end

      acc[key] = meta
    end
    removed ? kept : nil
  end

  def manufacturer_fact_value(raw)
    data = raw.is_a?(Hash) ? raw : {}
    facts = data["facts"]
    return nil unless facts.is_a?(Hash)

    fact = facts["manufacturer"]
    return nil unless fact.is_a?(Hash)

    fact["value"].presence
  end

  def incompatible_manufacturer_pin?(key, meta, old_label, new_label)
    meta = meta.is_a?(Hash) ? meta : {}
    labels = [ key, meta["canonical_name"], *Array(meta["aliases"]) ]
    old_hit = labels.any? { |label| label_contains_word?(label, old_label) }
    new_hit = labels.any? { |label| label_contains_word?(label, new_label) }
    old_hit && !new_hit
  end

  def label_contains_word?(label, word)
    normalized = Rag::FollowupQueryRewriter.normalize_label(label)
    return false if normalized.blank? || word.blank?

    normalized.match?(/\b#{Regexp.escape(word)}\b/)
  end

  def write_focus!(kb_doc, s3_uri)
    if uses_document_focus?
      write_document_focus!(kb_doc, s3_uri)
    else
      write_pinned_document!(kb_doc, s3_uri)
    end
  end

  def write_document_focus!(kb_doc, s3_uri)
    entries = document_focus_entries
    added_at = Time.current.iso8601
    entry = {
      "kb_document_id" => kb_doc.id,
      "source_uri" => s3_uri,
      "display_name" => kb_doc.display_name.presence || File.basename(kb_doc.s3_key.to_s, ".*"),
      "added_at" => added_at
    }
    index = entries.index { |existing| existing["kb_document_id"] == kb_doc.id }
    if index
      entries[index] = entry
    else
      entries << entry
      evict_oldest_focus!(entries)
    end

    update!(document_focus: entries)
    true
  end

  def remove_document_focus_id!(kb_document_id)
    entries = document_focus_entries
    kept = entries.reject { |entry| entry["kb_document_id"] == kb_document_id.to_i }
    return false if kept.size == entries.size

    update!(document_focus: kept)
    true
  end

  def remove_document_focus_uri!(uri)
    entries = document_focus_entries
    kept = entries.reject { |entry| entry["source_uri"] == uri.to_s }
    return false if kept.size == entries.size

    update!(document_focus: kept)
    true
  end

  def evict_oldest_focus!(entries)
    return unless entries.size > MAX_ENTITIES

    oldest = entries.min_by { |entry| entry["added_at"].to_s }
    entries.delete(oldest)
  end

  def coerce_focus_entry(item)
    return nil unless item.is_a?(Hash)

    data = item.stringify_keys
    id = data["kb_document_id"]
    uri = data["source_uri"]
    return nil if id.blank? || uri.blank?

    {
      "kb_document_id" => id.to_i,
      "source_uri" => uri.to_s,
      "display_name" => data["display_name"].to_s,
      "added_at" => data["added_at"].to_s
    }
  end

  def write_pinned_document!(kb_doc, s3_uri)
    entities = active_entities.dup
    existing_key = find_entity_by_source_uri(s3_uri)
    if existing_key.nil? && kb_doc.id.present?
      existing_key = entities.find { |_, meta| meta.is_a?(Hash) && meta["kb_document_id"].to_s == kb_doc.id.to_s }&.first
    end
    canonical = kb_doc.display_name.presence || File.basename(kb_doc.s3_key.to_s, ".*")
    entity_type = pinned_entity_type(kb_doc)
    added_at = Time.current.iso8601

    if existing_key
      existing = entities[existing_key].dup
      merged_aliases = sanitize_aliases(
        (Array(existing["aliases"]) + Array(kb_doc.aliases)).map(&:to_s)
      )
      entities[existing_key] = existing.merge(
        "kb_document_id" => kb_doc.id,
        "source_uri"     => s3_uri,
        "wa_filename"    => File.basename(kb_doc.s3_key.to_s),
        "entity_type"    => entity_type,
        "source"         => "user_pin",
        "aliases"        => merged_aliases,
        "added_at"       => added_at
      )
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
        "added_at"          => added_at
      }
      evict_oldest!(entities)
    end

    update!(active_entities: entities)
    true
  end

  def delete_pinned_key!(key)
    entities = active_entities.dup
    entities.delete(key)
    update!(active_entities: entities)
    true
  end

  def parse_history_ts(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

  def history_message(role, content, user_id:, correlation_id:, focus_ids: nil)
    message = {
      "role" => role,
      "content" => Rag::TurnText.truncate(content),
      "ts" => Time.current.iso8601
    }
    message["user_id"] = user_id if user_id.present?
    message["correlation_id"] = correlation_id if correlation_id.present?
    message["focus_ids"] = Array(focus_ids).map(&:to_i).uniq.sort unless focus_ids.nil?
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
    return if photo_identity_blocked?(readings)

    written = []
    written << "manufacturer" if apply_photo_fact!(episode, "manufacturer", readings["manufacturer"], correlation_id)
    written << "model" if apply_photo_fact!(episode, "model", readings["model_visible"] || readings["model"], correlation_id)
    close_photo_pending!(episode, written) if Rag::HaikuQueryAnalysisFlag.owner?
  end

  # The first observation write promotes equipment identity only when Vision
  # marked the photo relevant. nil and uncertain stay on the photo until a
  # later reuse confirms them. unrelated never becomes a fact.
  def photo_identity_blocked?(readings)
    readings["relevance_to_goal"] != "relevant"
  end

  # A reuse turn already decided, through PhotoRetrievalSnapshot, that this
  # observation contributes identity. Persist only those photo rows for this
  # correlation. apply_photo_fact! keeps the user-versus-photo conflict rule.
  def promote_reused_photo_identity!(correlation_id:, question:, accepted_observation:)
    episode = Rag::ActiveEpisode.parse(active_episode, now: Time.current)
    return nil if episode.blank?

    observation = accepted_observation.to_h.stringify_keys
    candidate = visual_identity_candidate?(observation)
    before_compact = compact_known_identity(episode)
    preview = Rag::PhotoRetrievalSnapshot.capture(
      episode: episode,
      question: question,
      observation: accepted_observation,
      correlation_id: correlation_id
    )
    identity = preview.equipment_identity
    if identity.nil?
      return traced_identity_promotion(
        candidate,
        result: "blocked",
        outcome_reason: "snapshot_excluded",
        relevance_to_goal: observation["relevance_to_goal"],
        identity_before: before_compact,
        identity_after: before_compact,
        correlation_id: correlation_id,
        episode_id: episode.episode_id
      )
    end

    before = episode.to_h.deep_dup
    conflict_count = episode.conflicts.size
    written = []
    Array(identity.facts).each do |fact|
      next unless fact["source"] == "photo"
      next unless fact["correlation_id"].to_s == correlation_id.to_s
      next unless Rag::PhotoRetrievalSnapshot::IDENTITY_SLOTS.include?(fact["slot"])

      written << fact["slot"] if apply_photo_fact!(episode, fact["slot"], fact["value"], correlation_id)
    end
    close_photo_pending!(episode, written) if Rag::HaikuQueryAnalysisFlag.owner? && written.any?
    if episode.to_h == before
      return traced_identity_promotion(
        candidate,
        result: "unchanged",
        outcome_reason: "already_known",
        relevance_to_goal: observation["relevance_to_goal"],
        identity_before: before_compact,
        identity_after: before_compact,
        correlation_id: correlation_id,
        episode_id: episode.episode_id
      )
    end

    episode.touch!(Time.current)
    update!(active_episode: episode.to_h)
    conflicts_grew = episode.conflicts.size > conflict_count
    if written.empty?
      return traced_identity_promotion(
        candidate,
        result: "conflict",
        outcome_reason: "user_photo_conflict",
        identity_conflict: true,
        relevance_to_goal: observation["relevance_to_goal"],
        identity_before: before_compact,
        identity_after: compact_known_identity(episode),
        correlation_id: correlation_id,
        episode_id: episode.episode_id
      )
    end

    traced_identity_promotion(
      candidate,
      result: "promoted",
      outcome_reason: "explicit_reuse",
      identity_conflict: conflicts_grew,
      relevance_to_goal: observation["relevance_to_goal"],
      identity_before: before_compact,
      identity_after: compact_known_identity(episode),
      correlation_id: correlation_id,
      episode_id: episode.episode_id
    )
  end

  def first_photo_identity_promotion(before_episode, after_episode, photo_value, correlation_id)
    return nil if before_episode.blank? || after_episode.blank?

    readings = photo_value.to_h.stringify_keys
    return nil unless visual_identity_candidate?(readings)

    before_compact = compact_known_identity(before_episode)
    fields = {
      correlation_id: correlation_id,
      episode_id: after_episode.episode_id,
      relevance_to_goal: readings["relevance_to_goal"],
      identity_before: before_compact
    }
    if photo_identity_blocked?(readings)
      return fields.merge(result: "blocked", outcome_reason: "relevance_blocked", identity_after: before_compact)
    end

    conflicts_grew = after_episode.conflicts.size > before_episode.conflicts.size
    slots_changed = %w[manufacturer model].any? { |slot| before_episode.fact(slot) != after_episode.fact(slot) }
    after_compact = compact_known_identity(after_episode)
    if slots_changed
      fields.merge(
        result: "promoted",
        outcome_reason: "relevant_observation",
        identity_conflict: conflicts_grew,
        identity_after: after_compact
      )
    elsif conflicts_grew
      fields.merge(
        result: "conflict",
        outcome_reason: "user_photo_conflict",
        identity_conflict: true,
        identity_after: after_compact
      )
    else
      fields.merge(result: "unchanged", outcome_reason: "already_known", identity_after: before_compact)
    end
  end

  def traced_identity_promotion(candidate, **fields)
    return nil unless candidate

    identity_promotion_fields(**fields)
  end

  def visual_identity_candidate?(readings)
    %w[manufacturer model model_visible].any? { |key| usable_identity_value?(readings[key]) }
  end

  def usable_identity_value?(raw)
    text = raw.to_s.squish
    text.present? && !text.casecmp?("unknown")
  end

  def identity_promotion_fields(result:, outcome_reason:, identity_before:, identity_after:, correlation_id:, episode_id:, relevance_to_goal: nil, identity_conflict: false)
    {
      result: result,
      outcome_reason: outcome_reason,
      identity_before: identity_before,
      identity_after: identity_after,
      correlation_id: correlation_id,
      episode_id: episode_id,
      relevance_to_goal: relevance_to_goal,
      identity_conflict: identity_conflict
    }
  end

  def compact_known_identity(episode)
    return "none" if episode.blank?

    parts = %w[manufacturer model].filter_map do |slot|
      fact = episode.fact(slot)
      next unless fact.is_a?(Hash) && fact["status"] == "known" && fact["value"].present?

      "#{slot}:#{fact['value']}:#{fact['source']}"
    end
    parts.presence&.join("|") || "none"
  end

  def apply_photo_fact!(episode, key, raw, correlation_id)
    text = raw.to_s.squish
    return false if text.blank? || text.casecmp?("unknown")

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
      true
    elsif existing["status"] == "known" && existing["source"] == "user" && !same
      episode.add_conflict!(fact: key, user: existing["value"], photo: text, correlation_id: correlation_id)
      false
    else
      false
    end
  end

  def close_photo_pending!(episode, written)
    question_type = episode.pending_question&.dig("type").to_s
    return if Rag::PendingQuestion::CONVERSATIONAL_TYPES.include?(question_type)

    fact_subject = episode.pending_fact&.dig("subject").to_s
    slot = if Rag::PendingQuestion::FACT_TYPES.include?(question_type)
      question_type
    elsif Rag::PendingQuestion::FACT_TYPES.include?(fact_subject)
      fact_subject
    end
    return unless PHOTO_PENDING_SLOTS.include?(slot) && written.include?(slot)

    fact = episode.fact(slot)
    return unless fact.is_a?(Hash) && fact["status"] == "known" && fact["source"] == "photo"

    episode.clear_pending!
  end

  # original_sha256 is the technician turn. effective_sha256 is the retrieval
  # query actually used. An assistant reply is not a query, so those digests
  # stay off that event. The reply hash remains TURN_EVIDENCE.answer_sha256.
  def log_field_companion_turn(result, content, correlation_id:, user_id:)
    causal = turn_causal.is_a?(Hash) ? turn_causal : {}
    self.turn_causal = nil
    fields = {
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: id,
      correlation_id: correlation_id,
      route: "field_companion",
      result: result.decision.to_s,
      outcome_reason: result.reason,
      episode_id: result.state.is_a?(Hash) ? result.state["episode_id"] : nil,
      episode_decision: result.decision.to_s,
      episode_fields_changed: result.fields_changed,
      pending_question_type: result.state.is_a?(Hash) ? result.state.dig("pending_question", "type") : nil,
      composed_chars: result.composed&.length,
      state_before_sha256: causal[:before],
      state_after_sha256: causal[:after]
    }
    unless result.decision.to_s == "assistant"
      raw = content.to_s
      fields[:original_sha256] = Digest::SHA256.hexdigest(raw)
      fields[:effective_sha256] = Digest::SHA256.hexdigest(effective_retrieval_text(result, raw))
      fields[:query_components] = causal[:components] if causal[:components]
    end
    PilotUsageLog.log("field_companion_turn", **fields)
  rescue StandardError => error
    Rails.logger.warn("field_companion_turn telemetry failed #{error.class}")
  end

  def interpreter_assertion_tokens(interpreted, result)
    Rag::CausalTrace.assertion_tokens(
      interpreted.perception,
      result&.understanding,
      fallback: interpreted.fallback || result&.understanding&.fallback || false
    )
  rescue StandardError => error
    Rails.logger.warn("interpreter assertion trace failed #{error.class}")
    nil
  end

  def remember_turn_causal!(before, after, components: nil)
    self.turn_causal = {
      before: episode_digest(before),
      after: episode_digest(after),
      components: components
    }
  rescue StandardError => error
    Rails.logger.warn("turn causal trace failed #{error.class}")
    self.turn_causal = nil
  end

  def episode_digest(episode)
    source = episode.is_a?(Rag::ActiveEpisode) ? episode.fork : episode
    parsed = source.is_a?(Rag::ActiveEpisode) ? source : Rag::ActiveEpisode.parse(source)
    parsed = Rag::ActiveEpisode.new if parsed.nil?
    Digest::SHA256.hexdigest(JSON.generate(canonicalize_episode(parsed.to_h)))
  end

  def effective_retrieval_text(result, raw)
    decision = result.understanding&.decision.to_s
    return "" if %w[meta clarify_first].include?(decision)

    composed = result.composed
    return composed if composed.present?

    raw.to_s
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
