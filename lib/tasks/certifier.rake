# frozen_string_literal: true

# Onboarding of the certifier module (Fase 1A).
#
# Assigning who owns a company's issuer configuration is an explicit operation,
# never an implicit one: Danebo does not promote the first visitor, the first
# user of the account, or an admin flag that does not exist in this schema. It
# is one command, run deliberately, with both arguments named.
#
#   bin/rails "certifier:settings_owner[danebo-legacy,alguien@empresa.cl]"
#   bin/rails "certifier:settings_owner:show[danebo-legacy]"
#   bin/rails "certifier:settings_owner:clear[danebo-legacy]"
#
# Locally add DB_USERNAME=lahirisan, like the rest of the module's commands.
namespace :certifier do
  desc "Assign the user allowed to edit a company's certifier settings"
  task :settings_owner, %i[account_slug user_email] => :environment do |_task, args|
    slug  = args[:account_slug].to_s
    email = args[:user_email].to_s
    if slug.blank? || email.blank?
      abort "usage: bin/rails \"certifier:settings_owner[account-slug,user@example.com]\""
    end

    account = Account.find_by(slug: slug) or abort "no Account with slug #{slug}"
    user    = User.find_by(email: email)  or abort "no User with email #{email}"

    # The model validates this too; failing here says which pair was wrong.
    if user.account_id != account.id
      abort "#{email} belongs to account #{user.account_id}, not to #{slug} (#{account.id})"
    end

    account.update!(certifier_settings_user: user)
    puts "#{slug}: certifier settings owner is now #{email} (user #{user.id})"
  end

  namespace :settings_owner do
    desc "Show the current certifier settings owner of a company"
    task :show, %i[account_slug] => :environment do |_task, args|
      account = Account.find_by(slug: args[:account_slug].to_s) or
        abort "usage: bin/rails \"certifier:settings_owner:show[account-slug]\""

      owner = account.certifier_settings_user
      puts "account:    #{account.slug} (#{account.id})"
      puts "owner:      #{owner ? "#{owner.email} (user #{owner.id})" : "none — settings are read-only"}"
      puts "name:       #{account.certifier_name.presence || "(blank)"}"
      puts "MINVU role: #{account.certifier_minvu_role.presence || "(blank)"}"
      puts "logo:       #{account.certifier_logo_s3_key.presence || "(none)"}"
    end

    desc "Clear the certifier settings owner, leaving the configuration read-only"
    task :clear, %i[account_slug] => :environment do |_task, args|
      account = Account.find_by(slug: args[:account_slug].to_s) or
        abort "usage: bin/rails \"certifier:settings_owner:clear[account-slug]\""

      account.update!(certifier_settings_user: nil)
      puts "#{account.slug}: certifier settings are now read-only for every user"
    end
  end
end
