# frozen_string_literal: true

namespace :kb do
  desc 'Trigger Knowledge Base ingestion sync'
  task sync: :environment do
    job_id = KbSyncService.new.sync!
    if job_id
      puts "✓ Ingestion job started: #{job_id}"
    else
      puts '✗ Failed to start ingestion job. Check logs and AWS configuration.'
    end
  end
end
