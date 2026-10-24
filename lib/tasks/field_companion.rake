# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../config/environment" unless defined?(::ApplicationRecord)

# Local debug clean start for one web workspace. Dry-run unless APPLY=true.
# Selects the runtime row (account, channel web, identifier = user id as text).
# Inside the row lock, writes a sanitized copy first. Only after that copy is
# on disk, opens a new episode and clears the working context. Page reload
# does not call this task. Does not call a model.
class FieldCompanionCleanStart
  class Refused < StandardError; end

  # Queue database, not the primary connection. A failed lookup must not abort
  # the workspace transaction.
  class QueueRecord < ::ApplicationRecord
    self.abstract_class = true
    connects_to database: { writing: :queue }
  end

  class QueueJob < QueueRecord
    self.table_name = "solid_queue_jobs"
  end

  COPY_DIR_ENV = "FIELD_COMPANION_CLEAN_START_COPY_DIR"
  TRIAL_COPY_DIR_ENV = "FIELD_COMPANION_WEB_TRIAL_COPY_DIR"
  CONFIRM_ENV = "FIELD_COMPANION_WEB_TRIAL_CONFIRM"
  # Shown references only. Existence uses the full exact-id count.
  REFERENCE_LIMIT = 20
  # Keyword names ActiveJob writes into solid_queue_jobs.arguments.
  SESSION_ARGUMENT_KEYS = %w[conversation_session_id conv_session_id].freeze
  MARKER_UI = "ui_reload: reload the workspace before the next question. " \
    "Stimulus keeps pendingFile, pendingFieldPhotoId and pendingPhotoCorrelationId until reload. " \
    "A discarded late write does not clear a reply already painted in an open tab. " \
    "Reloading the page does not open another case."

  def self.call(account_slug:, user_email:, apply:, io: $stdout, clock: nil)
    new(io: io, clock: clock).call(account_slug: account_slug, user_email: user_email, apply: apply)
  end

  def self.rows_for(account, user)
    ConversationSession.where(
      account_id: account.id,
      channel: "web",
      identifier: user.id.to_s
    ).order(:id).to_a
  end

  def initialize(io:, clock:)
    @io = io
    @clock = clock || -> { Time.current }
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
      say("DRY RUN no_comprobado. Re-run with APPLY=true to open a new episode and clear conversation_history, document_focus, active_entities, and current_procedure.")
      return :dry_run
    end

    refuse!("ABORT exclusion_configuration incomplete #{flag_text}") unless exclusion_configuration_complete?
    refuse!("ABORT row_expired session_id=#{session.id}") if session.expired?

    apply_clean_start!(session, account, user)
    :applied
  end

  # Production-capable isolation of one web workspace. start_clean_case keeps
  # its production refusal. This entry requires the confirmation env to equal
  # the email argument before it writes. It does not destroy the session row.
  def isolate_web_trial(account_slug:, user_email:, apply:, confirm:)
    slug = account_slug.to_s.strip
    email = user_email.to_s.strip.downcase
    refuse!("usage: FIELD_COMPANION_WEB_TRIAL_CONFIRM=user@example.com APPLY=true bin/rails \"field_companion:isolate_web_trial[account-slug,user@example.com]\"") if slug.blank? || email.blank?

    say("operation=isolate_web_trial rails_env=#{Rails.env} git=#{git_sha} production_guard=not_consulted")
    say(flag_text)
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
    say(FieldCompanionCleanStart::MARKER_UI)
    say("scope=conversation_history document_focus active_entities current_procedure active_episode")
    say("kept=session_row photos bedrock_queries pilot_events manuals")

    unless apply
      say("DRY RUN no_comprobado. Re-run with APPLY=true and #{CONFIRM_ENV} equal to the user email.")
      return :dry_run
    end

    confirmed = confirm.to_s.strip.downcase
    refuse!("ABORT confirm_mismatch") unless confirmed == email
    refuse!("ABORT row_expired session_id=#{session.id}") if session.expired?

    apply_clean_start!(session, account, user, directory: trial_copy_directory, reason: "web_trial")
    :applied
  end

  private

  def apply_clean_start!(session, account, user, directory: nil, reason: "clean_start")
    copy_path = nil
    begin
      session.with_lock do
        session.reload
        opened = @clock.call
        snapshot = snapshot_for(session, account, user, opened)
        copy_path = write_snapshot!(snapshot, directory: directory)
        session.start_new_case!(now: opened, reason: reason, correlation_id: "#{reason}:#{SecureRandom.uuid}")
        session.update!(
          conversation_history: [],
          document_focus: [],
          active_entities: {},
          current_procedure: {}
        )
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
    say("conversation_history=#{session.conversation_history.size}")
    say("active_entities=#{session.active_entities.inspect}")
    say("current_procedure=#{session.current_procedure.inspect}")
    say("facts=#{session.active_episode['facts'].inspect}")
    say("active_photo=#{session.active_episode['active_photo'].inspect}")
    say("session_status=#{session.session_status} kept")
    say("pending_work=#{pending[:label]}")
    say("pending_work_reading=puntual no_impide_trabajo_posterior")
    say("cleanliness=#{cleanliness_for(pending)}")
    say("cleanliness_scope=fila_y_lectura_de_cola navegador_no_recorrido otros_procesos_no_inspeccionados no_impide_trabajo_posterior")
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
        "conversation_history" => history_copy(session),
        "document_focus" => session.document_focus,
        "active_entities" => session.active_entities,
        "current_procedure" => session.current_procedure
      },
      "kept" => {
        "id" => session.id,
        "account_id" => session.account_id,
        "user_id" => session.user_id,
        "identifier" => session.identifier,
        "channel" => session.channel,
        "expires_at" => session.expires_at.iso8601,
        "created_at" => session.created_at.iso8601,
        "session_status" => session.session_status
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

  # Solid Queue stores ActiveJob#serialize as JSON text. A keyword id is a
  # JSON number, for example "conversation_session_id":12. The next character
  # has to be a non-digit so 120 does not count as 12. REFERENCE_LIMIT caps
  # the copy; count does not.
  def pending_work(session)
    id = Integer(session.id)
    scope = unfinished_session_jobs(id)
    count = scope.count
    refs = scope.order(:id).limit(REFERENCE_LIMIT).pluck(:id, :class_name).map { |job_id, class_name|
      { "id" => job_id, "class_name" => class_name }
    }
    {
      "status" => "read",
      "count" => count,
      "jobs" => refs,
      "reading" => "point_in_time"
    }
  rescue StandardError => error
    { "status" => "unreadable", "error_class" => error.class.name, "count" => nil, "jobs" => [], "reading" => "point_in_time" }
  end

  def unfinished_session_jobs(id)
    QueueJob.where(finished_at: nil).where(
      SESSION_ARGUMENT_KEYS.map { "arguments ~ ?" }.join(" OR "),
      *SESSION_ARGUMENT_KEYS.map { |key| session_argument_pattern(key, id) }
    )
  end

  def session_argument_pattern(key, id)
    %("#{key}"[[:space:]]*:[[:space:]]*#{id}([^0-9]|$))
  end

  def write_snapshot!(snapshot, directory: nil)
    directory = Pathname(directory || ENV.fetch(COPY_DIR_ENV, Rails.root.join("tmp/field_companion/clean_starts").to_s))
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
    status = pending["status"].to_s
    count = pending["count"]
    readable = status == "read" && count.is_a?(Integer)
    {
      label: readable ? count.to_s : "unreadable",
      count: readable ? count : nil,
      status: status
    }
  rescue StandardError
    { label: "unreadable", count: nil, status: "unreadable" }
  end

  def cleanliness_for(pending)
    return "incompleto" unless pending[:status] == "read" && pending[:count] == 0

    "limpio"
  end

  def print_preflight
    say("operation=start_clean_case rails_env=#{Rails.env} git=#{git_sha}")
    say("kb=#{ENV['BEDROCK_KNOWLEDGE_BASE_ID']} model=#{BedrockClient::QUERY_MODEL_ID}")
    say(flag_text)
    say("flags_scope=este_proceso web_y_workers_no_inspeccionados")
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

  def trial_copy_directory
    ENV.fetch(TRIAL_COPY_DIR_ENV, Rails.root.join("tmp/field_companion/web_trials").to_s)
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

  desc "Isolate one production web workspace (APPLY plus email confirmation)"
  task :isolate_web_trial, %i[account_slug user_email] => :environment do |_task, args|
    FieldCompanionCleanStart.new(io: $stdout, clock: nil).isolate_web_trial(
      account_slug: args[:account_slug],
      user_email: args[:user_email],
      apply: ENV["APPLY"] == "true",
      confirm: ENV[FieldCompanionCleanStart::CONFIRM_ENV]
    )
  rescue FieldCompanionCleanStart::Refused => error
    abort error.message
  end
end
