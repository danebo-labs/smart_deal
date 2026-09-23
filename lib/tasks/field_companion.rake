# frozen_string_literal: true

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
end
