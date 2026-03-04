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

  desc 'List all data sources for the Knowledge Base'
  task status: :environment do
    require 'aws-sdk-bedrockagent'

    kb_id = ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
            Rails.application.credentials.dig(:bedrock, :knowledge_base_id)

    unless kb_id
      puts '✗ Knowledge Base ID not configured'
      exit 1
    end

    preferred_id = ENV['BEDROCK_DATA_SOURCE_ID'].presence ||
                   Rails.application.credentials.dig(:bedrock, :data_source_id)

    begin
      client = Aws::BedrockAgent::Client.new(region: ENV['AWS_REGION'] || 'us-east-1')
      ds_list = client.list_data_sources(knowledge_base_id: kb_id)

      puts "\n📊 Knowledge Base: #{kb_id}"
      puts "🎯 Preferred Data Source: #{preferred_id || '(none configured)'}"
      puts "\n📦 Available Data Sources:\n\n"

      if ds_list.data_source_summaries.empty?
        puts "  (no data sources found)"
      else
        ds_list.data_source_summaries.each do |ds|
          marker = ds.data_source_id == preferred_id ? '✓' : ' '
          puts "  [#{marker}] #{ds.data_source_id}"
          puts "      Name: #{ds.name}" if ds.name
          puts "      Status: #{ds.status}" if ds.status
          puts ""
        end
      end
    rescue StandardError => e
      puts "✗ Failed to list data sources: #{e.message}"
      exit 1
    end
  end
end
