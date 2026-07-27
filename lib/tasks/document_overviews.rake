# frozen_string_literal: true

namespace :document_overviews do
  desc "Precompute ToC manifests for an account's documents. Usage: rake document_overviews:backfill[1]"
  task :backfill, [ :account_id ] => :environment do |_t, args|
    account = Account.find_by(id: args[:account_id])
    unless account
      puts "Account #{args[:account_id]} not found."
      next
    end

    built = 0
    skipped = 0

    account.kb_documents.find_each do |kb_document|
      label = kb_document.display_name.presence || kb_document.s3_key
      overview = Rag::DocumentOverviewBuilder.call(
        account: account, kb_document: kb_document, allow_cold_build: true
      )

      if overview
        puts "#{label}: #{overview[:sections].size} sections"
        built += 1
      else
        puts "#{label}: skipped"
        skipped += 1
      end
    rescue StandardError => e
      puts "#{label}: FAILED — #{e.message}"
      skipped += 1
    end

    puts "\nDone: #{built} built, #{skipped} skipped/failed."
  end
end
