# frozen_string_literal: true

# Operator writer for knowledge_scope. APPLY=true is the execution switch.
# actor is a label recorded in the audit row. It is not an authentication check.
# Access to this task is the production control.
namespace :knowledge_scope do
  desc "Set accounts.danebo_controlled. SLUG= VALUE=true|false APPLY=true. Does not change documents."
  task mark_account: :environment do
    slug = ENV["SLUG"].to_s.strip
    value = ENV["VALUE"].to_s.strip
    abort "usage: SLUG=account-slug VALUE=true|false APPLY=true bin/rails knowledge_scope:mark_account" if slug.blank?
    abort "VALUE must be true or false" unless %w[true false].include?(value)

    account = Account.find_by(slug: slug) or abort "no Account with slug #{slug}"
    flag = value == "true"
    puts "#{slug}: danebo_controlled #{account.danebo_controlled} → #{flag}"
    puts "No document scope changes."
    unless ENV["APPLY"] == "true"
      puts "DRY RUN: no data changed."
      next
    end

    account.update!(danebo_controlled: flag)
    puts "UPDATED #{slug} danebo_controlled=#{account.danebo_controlled}"
  end

  desc "Change one KbDocument scope. ID= TO=tenant_private|danebo_general ACTOR= REASON= APPLY=true"
  task apply: :environment do
    id = ENV["ID"].to_s.strip
    to_scope = ENV["TO"].to_s.strip
    actor = ENV["ACTOR"].to_s.strip
    reason = ENV["REASON"].to_s.strip
    if id.blank? || to_scope.blank? || actor.blank? || reason.blank?
      abort "usage: ID= TO=tenant_private|danebo_general ACTOR= REASON= APPLY=true bin/rails knowledge_scope:apply"
    end

    document = KbDocument.find_by(id: id) or abort "no KbDocument #{id}"
    puts "kb_document=#{document.id} account=#{document.account&.slug} scope=#{document.knowledge_scope} → #{to_scope}"
    if to_scope == KbDocument::KNOWLEDGE_SCOPE_GENERAL
      blocked = KnowledgeScopeEligibility.blocking_reasons(document)
      puts(blocked.empty? ? "eligible" : "blocked: #{blocked.join(', ')}")
    else
      puts "revoke does not consult eligibility"
    end
    unless ENV["APPLY"] == "true"
      puts "DRY RUN: no data changed."
      next
    end

    KnowledgeScopeChange.apply!(kb_document: document, to_scope: to_scope, actor: actor, reason: reason)
    puts "UPDATED kb_document=#{document.id} knowledge_scope=#{document.knowledge_scope}"
  end
end
