# frozen_string_literal: true

require "json"
require "open3"

# Local clean start for one web workspace. Dry-run unless APPLY=true.
# Selects the runtime row (account, channel web, identifier = user id as text).
# Writes a sanitized copy inside the row lock before start_new_case! and an
# empty document_focus commit together. Does not call a model.
class FieldCompanionCleanStart
  class Refused < StandardError; end

  # Queue database, not the primary connection. A failed lookup must not abort
  # the workspace transaction.
  class QueueRecord < ApplicationRecord
    self.abstract_class = true
    connects_to database: { writing: :queue }
  end

  class QueueJob < QueueRecord
    self.table_name = "solid_queue_jobs"
  end

  COPY_DIR_ENV = "FIELD_COMPANION_CLEAN_START_COPY_DIR"
  MARKER_UI = "ui_reload: reload the workspace before the next question. " \
    "Stimulus keeps pendingFile, pendingFieldPhotoId and pendingPhotoCorrelationId until reload. " \
    "A discarded late write does not clear a reply already painted in an open tab."

  def self.call(account_slug:, user_email:, apply:, io: $stdout, clock: nil, sleeper: nil)
    new(io: io, clock: clock, sleeper: sleeper).call(account_slug: account_slug, user_email: user_email, apply: apply)
  end

  def self.rows_for(account, user)
    ConversationSession.where(
      account_id: account.id,
      channel: "web",
      identifier: user.id.to_s
    ).order(:id).to_a
  end

  def initialize(io:, clock:, sleeper:)
    @io = io
    @clock = clock || -> { Time.current }
    @sleeper = sleeper || ->(seconds) { sleep(seconds) }
  end

  def call(account_slug:, user_email:, apply:)
    slug = account_slug.to_s.strip
    email = user_email.to_s.strip.downcase
    refuse!("usage: APPLY=true bin/rails \"field_companion:start_clean_case[account-slug,user@example.com]\"") if slug.blank? || email.blank?

    print_preflight
    refuse!("ABORT production") if production_target?

    account = Account.find_by(slug: slug) or refuse!("ABORT no Account with slug #{slug}")
    user = account.users.find_by(email: email) or refuse!("ABORT no User with email #{email} in account #{slug}")
    key = selection_key(account, user)
    say(key)
    refuse!("ABORT shared_session #{key}") if SharedSession::ENABLED

    rows = self.class.rows_for(account, user)
    if rows.empty?
      refuse!("ABORT no_row #{key}")
    elsif rows.size > 1
      refuse!("ABORT ambiguous count=#{rows.size} ids=#{rows.map(&:id).join(',')} #{key}")
    end

    session = rows.first
    say("session_id=#{session.id} user_id=#{session.user_id.inspect} expires_at=#{session.expires_at.iso8601}")
    say(attribution_line(session, user))
    say("exclusion_configuration=#{exclusion_configuration_complete? ? 'complete' : 'incomplete'}")
    say(MARKER_UI)

    unless apply
      say("DRY RUN no_comprobado. Re-run with APPLY=true to open a new episode and clear document_focus.")
      return :dry_run
    end

    refuse!("ABORT exclusion_configuration incomplete #{flag_text}") unless exclusion_configuration_complete?
    refuse!("ABORT row_expired session_id=#{session.id}") if session.expired?

    apply_clean_start!(session, account, user)
    :applied
  end

  private

  def apply_clean_start!(session, account, user)
    copy_path = nil
    begin
      session.with_lock do
        session.reload
        opened = exclusive_opened_at(session)
        snapshot = snapshot_for(session, account, user, opened)
        copy_path = write_snapshot!(snapshot)
        session.start_new_case!(now: opened, reason: "clean_start", correlation_id: "clean_start:#{SecureRandom.uuid}")
        session.update!(document_focus: [])
      end
    rescue Refused
      raise
    rescue StandardError
      say("transition_failed row_unchanged copy=#{copy_path || 'unwritten'}")
      raise
    end
    session.reload
    pending = snapshot_pending(copy_path)
    say("APPLIED copy=#{copy_path}")
    say("episode_id=#{session.active_episode['episode_id']} opened_at=#{session.active_episode['opened_at']}")
    say("document_focus=#{session.document_focus.inspect}")
    say("history_rows_kept=#{session.conversation_history.size}")
    say("pending_work=#{pending[:label]}")
    say("cleanliness=#{cleanliness_for(pending)}")
  end

  def exclusive_opened_at(session)
    latest = latest_history_second(session)
    now = @clock.call
    return now if latest.nil?

    now_second = second_floor(now)
    return now if latest < now_second

    boundary = latest + 1.second
    delay = boundary - now
    refuse!("ABORT history timestamp is more than 2 seconds ahead of the clock") if delay > 2
    @sleeper.call(delay) if delay.positive?
    opened = @clock.call
    if second_floor(opened) <= latest
      refuse!("ABORT opened_at would share a stored history second")
    end
    opened
  end

  def latest_history_second(session)
    Array(session.conversation_history).filter_map { |message|
      raw = message.is_a?(Hash) ? (message["ts"] || message[:ts]) : nil
      parsed = parse_time(raw)
      second_floor(parsed) if parsed
    }.max
  end

  def second_floor(time)
    return nil if time.nil?

    parse_time(time.iso8601) || time.change(usec: 0)
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def snapshot_for(session, account, user, opened)
    Rag::ValidationCapture.sanitize(
      "kind" => "field_companion_clean_start_copy",
      "written_at" => @clock.call.iso8601,
      "opened_at" => opened.iso8601,
      "workspace" => {
        "account_id" => account.id,
        "account_slug" => account.slug,
        "resolved_user_id" => user.id,
        "resolved_user_email" => user.email,
        "session_user_id" => session.user_id,
        "identifier" => session.identifier,
        "channel" => session.channel,
        "conversation_session_id" => session.id,
        "attribution_consistent" => session.user_id == user.id
      },
      "flags" => flag_row,
      "connections" => connection_rows,
      "kb" => ENV["BEDROCK_KNOWLEDGE_BASE_ID"].to_s,
      "model" => BedrockClient::QUERY_MODEL_ID,
      "replaced" => {
        "active_episode" => session.active_episode,
        "document_focus" => session.document_focus,
        "current_procedure" => session.current_procedure
      },
      "conversation_history" => history_copy(session),
      "preserved" => {
        "active_entities" => session.active_entities,
        "expires_at" => session.expires_at.iso8601,
        "history_kept" => true
      },
      "photos" => photo_references(session),
      "pending_work" => pending_work(session)
    )
  end

  def history_copy(session)
    Array(session.conversation_history).each_with_index.map { |message, index|
      row = message.is_a?(Hash) ? message.deep_dup : { "content" => message.to_s }
      row["index"] = index
      row
    }
  end

  def photo_references(session)
    ids = []
    photo = session.active_episode.is_a?(Hash) ? session.active_episode["active_photo"] : nil
    ids << photo["field_photo_id"] if photo.is_a?(Hash) && photo["field_photo_id"].present?
    scope = FieldPhoto.where(account_id: session.account_id, conversation_session_id: session.id)
    scope = scope.or(FieldPhoto.where(account_id: session.account_id, id: ids)) if ids.any?
    scope.order(:id).pluck(:id, :sha256, :content_type, :byte_size, :s3_key_original).map { |id, sha, type, bytes, key|
      {
        "id" => id,
        "sha256" => sha,
        "content_type" => type,
        "byte_size" => bytes,
        "s3_key_original" => key
      }
    }
  end

  def pending_work(session)
    id = session.id.to_i
    jobs = QueueJob.where(finished_at: nil).where(
      "arguments LIKE :conversation OR arguments LIKE :conversation_spaced OR arguments LIKE :legacy OR arguments LIKE :legacy_spaced",
      conversation: "%\"conversation_session_id\":#{id}%",
      conversation_spaced: "%\"conversation_session_id\": #{id}%",
      legacy: "%\"conv_session_id\":#{id}%",
      legacy_spaced: "%\"conv_session_id\": #{id}%"
    )
    refs = []
    jobs.limit(50).pluck(:id, :class_name, :arguments).each do |job_id, class_name, arguments|
      text = arguments.is_a?(String) ? arguments : JSON.generate(arguments)
      next unless text.match?(/"(?:conversation_session_id|conv_session_id)"\s*:\s*#{id}(?!\d)/)

      refs << { "id" => job_id, "class_name" => class_name }
      break if refs.size >= 20
    end
    { "status" => "read", "jobs" => refs }
  rescue StandardError => error
    { "status" => "unreadable", "error_class" => error.class.name, "jobs" => [] }
  end

  def write_snapshot!(snapshot)
    directory = Pathname(ENV.fetch(COPY_DIR_ENV, Rails.root.join("tmp/field_companion/clean_starts").to_s))
    directory.mkpath
    session_id = snapshot.dig("workspace", "conversation_session_id")
    path = directory.join("#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}_#{SecureRandom.hex(4)}_session_#{session_id}.json")
    temporary = path.sub_ext(".json.tmp")
    File.binwrite(temporary, "#{JSON.pretty_generate(snapshot)}\n")
    File.rename(temporary, path)
    path.to_s
  rescue StandardError
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    raise
  end

  def snapshot_pending(path)
    data = JSON.parse(File.read(path))
    pending = data["pending_work"] || {}
    jobs = Array(pending["jobs"])
    label = pending["status"] == "read" ? jobs.size.to_s : "unreadable"
    { label: label, count: jobs.size, status: pending["status"].to_s }
  rescue StandardError
    { label: "unreadable", count: 0, status: "unreadable" }
  end

  def cleanliness_for(pending)
    return "incompleto" unless pending[:status] == "read" && pending[:count].zero?

    "limpio"
  end

  def print_preflight
    say("operation=start_clean_case rails_env=#{Rails.env} git=#{git_sha}")
    say("kb=#{ENV['BEDROCK_KNOWLEDGE_BASE_ID']} model=#{BedrockClient::QUERY_MODEL_ID}")
    say(flag_text)
    connection_rows.each do |row|
      say("connection name=#{row['name']} adapter=#{row['adapter']} host=#{row['host']} database=#{row['database']} username=#{row['username']}")
    end
  end

  def connection_rows
    ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).map { |config|
      hash = config.configuration_hash
      {
        "name" => config.name.to_s,
        "adapter" => hash[:adapter].to_s,
        "host" => hash[:host].to_s,
        "database" => hash[:database].to_s,
        "username" => hash[:username].to_s
      }
    }
  end

  def production_target?
    return true if Rails.env.production?

    connection_rows.any? { |row| row["database"].include?("production") }
  end

  def flag_row
    {
      "FIELD_COMPANION_EPISODE_ENABLED" => Rag::FieldCompanionEpisodeFlag.enabled?,
      "FIELD_COMPANION_TURN_ENABLED" => Rag::FieldCompanionTurnFlag.enabled?,
      "RAG_EPISODE_SCOPE_ENABLED" => Rag::EpisodeScopeFlag.enabled?,
      "RAG_THREAD_MENU_ENABLED" => Rag::ThreadMenuFlag.enabled?,
      "HAIKU_QUERY_ANALYSIS_MODE" => Rag::HaikuQueryAnalysisFlag.mode,
      "SHARED_SESSION_ENABLED" => SharedSession::ENABLED
    }
  end

  def flag_text
    flag_row.map { |key, value| "#{key}=#{value}" }.join(" ")
  end

  def exclusion_configuration_complete?
    Rag::FieldCompanionEpisodeFlag.enabled? &&
      Rag::FieldCompanionTurnFlag.enabled? &&
      Rag::EpisodeScopeFlag.enabled? &&
      Rag::HaikuQueryAnalysisFlag.owner? &&
      !SharedSession::ENABLED
  end

  def selection_key(account, user)
    "key account_id=#{account.id} user_id=#{user.id} identifier=#{user.id} channel=web"
  end

  def attribution_line(session, user)
    return "attribution=consistent" if session.user_id == user.id

    "attribution=mismatch session_user_id=#{session.user_id.inspect} resolved_user_id=#{user.id} not_rewritten"
  end

  def git_sha
    out, status = Open3.capture2("git", "-C", Rails.root.to_s, "rev-parse", "HEAD")
    status.success? ? out.strip : "unavailable"
  rescue StandardError
    "unavailable"
  end

  def say(line)
    @io.puts(line)
  end

  def refuse!(message)
    say(message)
    raise Refused, message
  end
end

namespace :field_companion do
  desc "Reset active episodes for one account user (dry-run unless APPLY=true)"
  task :reset_active_episode, %i[account_slug user_email] => :environment do |_task, args|
    slug = args[:account_slug].to_s.strip
    email = args[:user_email].to_s.strip.downcase
    if slug.blank? || email.blank?
      abort 'usage: APPLY=true bin/rails "field_companion:reset_active_episode[account-slug,user@example.com]"'
    end

    account = Account.find_by(slug: slug) or abort "no Account with slug #{slug}"
    user = account.users.find_by(email: email) or
      abort "no User with email #{email} in account #{slug}"

    sessions = ConversationSession.where(account: account, user: user, channel: "web").order(:id)
    active = sessions.where.not(active_episode: {})
    ids = active.pluck(:id)

    puts "#{slug}: #{sessions.count} web session(s); #{ids.size} active episode(s)#{ids.any? ? " in session(s) #{ids.join(', ')}" : ''}"
    unless ENV["APPLY"] == "true"
      puts 'DRY RUN: no data changed. Re-run with APPLY=true to clear only active_episode.'
      next
    end

    reset_count = 0
    active.find_each do |session|
      session.with_lock do
        next if session.active_episode.blank?

        # Preserve transcript, pins, TTL and timestamps; this operation changes
        # only the JSONB state that the task names.
        session.update_columns(active_episode: {}) # rubocop:disable Rails/SkipsModelValidations
        reset_count += 1
      end
    end
    puts "RESET: cleared active_episode in #{reset_count} session(s); all other columns were preserved."
  end

  desc "Open a clean web case for the runtime workspace (dry-run unless APPLY=true)"
  task :start_clean_case, %i[account_slug user_email] => :environment do |_task, args|
    FieldCompanionCleanStart.call(
      account_slug: args[:account_slug],
      user_email: args[:user_email],
      apply: ENV["APPLY"] == "true"
    )
  rescue FieldCompanionCleanStart::Refused => error
    abort error.message
  end
end
