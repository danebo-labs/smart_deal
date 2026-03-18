# frozen_string_literal: true

namespace :kb do
  desc 'Trigger Knowledge Base ingestion sync'
  task sync: :environment do
    result = KbSyncService.new.sync!
    if result && result[:job_id]
      puts "✓ Ingestion job started: #{result[:job_id]} (data source: #{result[:data_source_id]})"
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

  desc 'Show the embedding model ARN configured for the Knowledge Base (from AWS)'
  task embedding_model: :environment do
    require 'aws-sdk-bedrockagent'

    kb_id = ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
            Rails.application.credentials.dig(:bedrock, :knowledge_base_id)

    unless kb_id
      puts '✗ Knowledge Base ID not configured'
      exit 1
    end

    region = ENV['AWS_REGION'].presence ||
             Rails.application.credentials.dig(:aws, :region) ||
             'us-east-1'

    begin
      client = Aws::BedrockAgent::Client.new(region: region)
      response = client.get_knowledge_base(knowledge_base_id: kb_id)

      vkb = response.knowledge_base&.knowledge_base_configuration&.vector_knowledge_base_configuration
      arn = vkb&.embedding_model_arn

      puts "\nKnowledge Base: #{kb_id}"
      puts "Region: #{region}"
      if arn.present?
        puts "Embedding Model ARN: #{arn}"
      else
        puts "Embedding Model ARN: (not found - KB may not be vector type)"
      end
      puts ""
    rescue StandardError => e
      puts "✗ Failed to get Knowledge Base config: #{e.message}"
      exit 1
    end
  end
end
