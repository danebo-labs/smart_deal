# frozen_string_literal: true

namespace :kb do
  desc 'Show complete RAG configuration (KB, data sources, S3, parsing, Lambda, embedding, storage, app prompts)'
  task config: :environment do
    require 'aws-sdk-bedrockagent'
    require 'json'
    # TO execute KB_CONFIG_JSON=1 bin/rails kb:config

    kb_id = ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
            Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
    preferred_ds_id = ENV['BEDROCK_DATA_SOURCE_ID'].presence ||
                      Rails.application.credentials.dig(:bedrock, :data_source_id)
    region = ENV['AWS_REGION'].presence ||
             Rails.application.credentials.dig(:aws, :region) ||
             'us-east-1'
    format_json = ENV['KB_CONFIG_JSON'] == '1'

    unless kb_id
      puts '✗ Knowledge Base ID not configured'
      exit 1
    end

    client = Aws::BedrockAgent::Client.new(region: region)
    report = KbConfigHelpers.build_full_rag_config(client, kb_id, preferred_ds_id, region, format_json)

    if format_json
      puts JSON.pretty_generate(report)
    else
      KbConfigHelpers.print_human_report(report)
    end
  rescue StandardError => e
    puts "✗ Failed to build RAG config: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    exit 1
  end
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

# Helpers for kb:config — keep in same file for rake visibility
module KbConfigHelpers
  class << self
    def build_full_rag_config(client, kb_id, preferred_ds_id, region, _format_json)
      kb = client.get_knowledge_base(knowledge_base_id: kb_id).knowledge_base
      ds_summaries = client.list_data_sources(knowledge_base_id: kb_id).data_source_summaries

      data_sources = ds_summaries.map do |ds|
        full_ds = client.get_data_source(
          knowledge_base_id: kb_id,
          data_source_id: ds.data_source_id
        ).data_source
        serialize_data_source(full_ds, ds.data_source_id == preferred_ds_id)
      end

      app_config = build_app_config(region)

      {
        knowledge_base: serialize_knowledge_base(kb),
        data_sources: data_sources,
        app_config: app_config
      }
    end

    def serialize_knowledge_base(kb)
      return {} if kb.nil?

      kbc = kb.knowledge_base_configuration
      vkb = kbc&.vector_knowledge_base_configuration
      emb_cfg = vkb&.embedding_model_configuration&.bedrock_embedding_model_configuration
      storage = kb.storage_configuration
      supplemental = vkb&.supplemental_data_storage_configuration

      {
        knowledge_base_id: kb.knowledge_base_id,
        name: kb.name,
        description: kb.description,
        role_arn: kb.role_arn,
        created_at: kb.created_at&.to_s,
        updated_at: kb.updated_at&.to_s,
        embedding: {
          model_arn: vkb&.embedding_model_arn,
          dimensions: emb_cfg&.dimensions,
          embedding_data_type: emb_cfg&.embedding_data_type
        },
        storage: serialize_storage(storage),
        supplemental_data_storage: serialize_supplemental_storage(supplemental)
      }.compact
    end

    def serialize_supplemental_storage(supplemental)
      return nil if supplemental.nil? || supplemental.storage_locations.blank?

      uris = supplemental.storage_locations.filter_map do |loc|
        loc.s3_location&.uri
      end
      return nil if uris.empty?

      { multimodal_storage_s3_uris: uris }
    end

    def serialize_storage(storage)
      return {} if storage.nil?

      base = { type: storage.type }
      case storage.type
      when 'OPENSEARCH_SERVERLESS'
        oss = storage.opensearch_serverless_configuration
        if oss
          fm = oss.field_mapping
          base.merge!(
            collection_arn: oss.collection_arn,
            vector_index_name: oss.vector_index_name,
            field_mapping: fm.respond_to?(:to_h) ? fm.to_h : { vector_field: fm&.vector_field, text_field: fm&.text_field, metadata_field: fm&.metadata_field }.compact
          )
        end
      when 'OPENSEARCH_MANAGED_CLUSTER'
        osm = storage.opensearch_managed_cluster_configuration
        if osm
          fm = osm.field_mapping
          base.merge!(
            domain_endpoint: osm.domain_endpoint,
            domain_arn: osm.domain_arn,
            vector_index_name: osm.vector_index_name,
            field_mapping: fm.respond_to?(:to_h) ? fm.to_h : { vector_field: fm&.vector_field, text_field: fm&.text_field, metadata_field: fm&.metadata_field }.compact
          )
        end
      when 'S3_VECTORS'
        s3 = storage.s3_vectors_configuration
        if s3
          fm = s3.field_mapping
          base.merge!(
            bucket_arn: s3.bucket_arn,
            vector_index_name: s3.vector_index_name,
            field_mapping: fm.respond_to?(:to_h) ? fm.to_h : { vector_field: fm&.vector_field, text_field: fm&.text_field, metadata_field: fm&.metadata_field }.compact
          )
        end
      when 'RDS'
        rds = storage.rds_configuration
        if rds
          fm = rds.field_mapping
          fm_hash = fm.respond_to?(:to_h) ? fm.to_h : {
            primary_key_field: fm&.primary_key_field,
            vector_field: fm&.vector_field,
            text_field: fm&.text_field,
            metadata_field: fm&.metadata_field,
            custom_metadata_field: fm&.custom_metadata_field
          }.compact
          base.merge!(
            vector_store_type: 'Amazon Aurora',
            resource_arn: rds.resource_arn,
            credentials_secret_arn: rds.credentials_secret_arn,
            database_name: rds.database_name,
            table_name: rds.table_name,
            field_mapping: fm_hash
          )
        end
      end
      base.compact
    end

    def serialize_data_source(ds, preferred)
      return {} if ds.nil?

      ds_cfg = ds.data_source_configuration
      s3 = ds_cfg&.s3_configuration
      vic = ds.vector_ingestion_configuration
      chunk = vic&.chunking_configuration
      parse_cfg = vic&.parsing_configuration
      bfm = parse_cfg&.bedrock_foundation_model_configuration
      custom = vic&.custom_transformation_configuration

      {
        data_source_id: ds.data_source_id,
        name: ds.name,
        status: ds.status,
        preferred: preferred,
        created_at: ds.created_at&.to_s,
        updated_at: ds.updated_at&.to_s,
        data_source_config: {
          type: ds_cfg&.type,
          s3: s3 ? {
            bucket_arn: s3.bucket_arn,
            inclusion_prefixes: s3.inclusion_prefixes,
            bucket_owner_account_id: s3.bucket_owner_account_id
          }.compact : nil
        }.compact,
        chunking: serialize_chunking(chunk),
        parsing: serialize_parsing(parse_cfg, bfm),
        custom_transformation: serialize_custom_transformation(custom)
      }.compact
    end

    def serialize_chunking(chunk)
      return nil if chunk.nil?

      base = { strategy: chunk.chunking_strategy }
      case chunk.chunking_strategy
      when 'HIERARCHICAL'
        hc = chunk.hierarchical_chunking_configuration
        base[:hierarchical] = {
          level_configurations: hc&.level_configurations&.map { |l| { max_tokens: l.max_tokens } },
          overlap_tokens: hc&.overlap_tokens
        }.compact if hc
      when 'FIXED_SIZE'
        fc = chunk.fixed_size_chunking_configuration
        base[:fixed_size] = {
          max_tokens: fc&.max_tokens,
          overlap_percentage: fc&.overlap_percentage
        }.compact if fc
      when 'SEMANTIC'
        sc = chunk.semantic_chunking_configuration
        base[:semantic] = {
          max_tokens: sc&.max_tokens,
          buffer_size: sc&.buffer_size,
          breakpoint_percentile_threshold: sc&.breakpoint_percentile_threshold
        }.compact if sc
      end
      base
    end

    def serialize_parsing(parse_cfg, bfm)
      return nil if parse_cfg.nil?

      base = { strategy: parse_cfg.parsing_strategy }
      return base if bfm.nil?

      prompt_text = bfm.parsing_prompt&.parsing_prompt_text
      model_arn = bfm.model_arn
      model_short = extract_model_short_name(model_arn)
      base.merge!(
        model_arn: model_arn,
        model_short_name: model_short,
        parsing_modality: bfm.parsing_modality,
        parsing_prompt: prompt_text,
        parsing_prompt_length: prompt_text&.length
      )
      base.compact
    end

    def extract_model_short_name(arn)
      return nil if arn.blank?
      # arn:aws:bedrock:us-east-1:935142957735:inference-profile/global.anthropic.claude-opus-4-6-v1
      # -> anthropic.claude-opus-4-6-v1
      arn.split(%r{/|:}).last
    end

    def serialize_custom_transformation(custom)
      return nil if custom.nil?

      storage = custom.intermediate_storage&.s3_location
      transforms = custom.transformations || []
      lambdas = transforms.map do |t|
        fn = t.transformation_function
        lc = fn&.transformation_lambda_configuration
        {
          lambda_arn: lc&.lambda_arn,
          step_to_apply: t.step_to_apply
        }.compact
      end

      {
        intermediate_storage_s3_uri: storage&.uri,
        transformations: lambdas
      }.compact
    end

    def build_app_config(region)
      gen_path = Rails.root.join('app/prompts/bedrock/generation.txt')
      orch_path = Rails.root.join('app/prompts/bedrock/orchestration.txt')

      {
        env: {
          knowledge_base_id: ENV['BEDROCK_KNOWLEDGE_BASE_ID'].presence || '(from credentials)',
          data_source_id: ENV['BEDROCK_DATA_SOURCE_ID'].presence || '(from credentials)',
          model_id: ENV['BEDROCK_MODEL_ID'].presence || '(from credentials)',
          region: region
        },
        rag_params: {
          number_of_results: ENV['BEDROCK_RAG_NUMBER_OF_RESULTS'].presence || '15',
          search_type: ENV['BEDROCK_RAG_SEARCH_TYPE'].presence || 'HYBRID',
          generation_temperature: ENV['BEDROCK_RAG_GENERATION_TEMPERATURE'].presence || '0.0',
          generation_max_tokens: ENV['BEDROCK_RAG_GENERATION_MAX_TOKENS'].presence || '3000',
          orchestration_temperature: ENV['BEDROCK_RAG_ORCHESTRATION_TEMPERATURE'].presence || '0.0',
          orchestration_max_tokens: ENV['BEDROCK_RAG_ORCHESTRATION_MAX_TOKENS'].presence || '2048'
        },
        prompts: {
          generation: gen_path.exist? ? gen_path.to_s : nil,
          orchestration: orch_path.exist? ? orch_path.to_s : nil,
          generation_size_bytes: gen_path.exist? ? File.size(gen_path) : nil,
          orchestration_size_bytes: orch_path.exist? ? File.size(orch_path) : nil
        }.compact
      }
    end

    def print_human_report(report)
      puts "\n" + "=" * 70
      puts "  RAG CONFIGURATION — Complete"
      puts "=" * 70

      kb = report[:knowledge_base] || {}
      puts "\n📚 KNOWLEDGE BASE"
      puts "  ID: #{kb[:knowledge_base_id]}"
      puts "  Name: #{kb[:name]}"
      puts "  Description: #{kb[:description]}" if kb[:description].present?
      puts "  Role ARN: #{kb[:role_arn]}"
      if (emb = kb[:embedding])
        puts "  Embedding Model: #{emb[:model_arn]}"
        puts "  Dimensions: #{emb[:dimensions]}" if emb[:dimensions]
        puts "  Data Type: #{emb[:embedding_data_type]}" if emb[:embedding_data_type]
      end
      if (st = kb[:storage]).present?
        puts "\n  📍 VECTOR STORE"
        puts "  Vector store type: #{st[:vector_store_type] || st[:type]}"
        puts "  Aurora DB Cluster ARN: #{st[:resource_arn]}" if st[:resource_arn]
        puts "  Database name: #{st[:database_name]}" if st[:database_name]
        puts "  Table name: #{st[:table_name]}" if st[:table_name]
        puts "  Credential Secret ARN: #{st[:credentials_secret_arn]}" if st[:credentials_secret_arn]
        if (fm = st[:field_mapping]).present?
          puts "  Vector field name: #{fm[:vector_field]}" if fm[:vector_field]
          puts "  Text field name: #{fm[:text_field]}" if fm[:text_field]
          puts "  Metadata field name: #{fm[:metadata_field]}" if fm[:metadata_field]
          puts "  Custom metadata: #{fm[:custom_metadata_field]}" if fm[:custom_metadata_field]
          puts "  Primary key: #{fm[:primary_key_field]}" if fm[:primary_key_field]
        end
        puts "  Collection ARN: #{st[:collection_arn]}" if st[:collection_arn]
        puts "  Vector Index: #{st[:vector_index_name]}" if st[:vector_index_name]
      end
      if (sup = kb[:supplemental_data_storage]).present? && sup[:multimodal_storage_s3_uris]&.any?
        puts "\n  📍 MULTIMODAL STORAGE DESTINATION"
        sup[:multimodal_storage_s3_uris].each { |uri| puts "  S3 URI: #{uri}" }
      end

      puts "\n📦 DATA SOURCES"
      (report[:data_sources] || []).each do |ds|
        pref = ds[:preferred] ? " [PREFERRED]" : ""
        puts "\n  #{ds[:data_source_id]}#{pref}"
        puts "    Name: #{ds[:name]} | Status: #{ds[:status]}"
        ds_type = ds.dig(:data_source_config, :type)
        puts "    Data source type: #{ds_type}" if ds_type.present?
        if (s3 = ds.dig(:data_source_config, :s3))
          puts "    S3 Bucket: #{s3[:bucket_arn]}"
          puts "    Inclusion Prefixes: #{s3[:inclusion_prefixes]}" if s3[:inclusion_prefixes]&.any?
        end
        if (ch = ds[:chunking])
          puts "    Chunking: #{ch[:strategy]}"
          puts "      #{ch.except(:strategy).to_json}" if ch.keys.size > 1
        end
        if (pr = ds[:parsing])
          puts "    Parsing strategy: #{pr[:strategy]}"
          puts "      Model: #{pr[:model_short_name] || pr[:model_arn]} (Bedrock)"
          puts "      Model ARN: #{pr[:model_arn]}" if pr[:model_arn]
          puts "      Prompt length: #{pr[:parsing_prompt_length]} chars" if pr[:parsing_prompt_length]
          if (prompt = pr[:parsing_prompt]).present?
            puts "      Parsing prompt (full):"
            prompt.each_line { |line| puts "        #{line.chomp}" }
          end
        end
        if (ct = ds[:custom_transformation])
          puts "    Custom Transformation (Lambda):"
          puts "      Intermediate S3: #{ct[:intermediate_storage_s3_uri]}"
          (ct[:transformations] || []).each do |t|
            puts "      Lambda ARN: #{t[:lambda_arn]}"
            puts "      Step: #{t[:step_to_apply]}"
          end
        end
      end

      app = report[:app_config] || {}
      puts "\n⚙️  APP CONFIG (env/credentials)"
      puts "  KB ID: #{app.dig(:env, :knowledge_base_id)}"
      puts "  Data Source ID: #{app.dig(:env, :data_source_id)}"
      puts "  Model ID: #{app.dig(:env, :model_id)}"
      puts "  Region: #{app.dig(:env, :region)}"
      if (rag = app[:rag_params])
        puts "  RAG: number_of_results=#{rag[:number_of_results]}, search_type=#{rag[:search_type]}, temp=#{rag[:generation_temperature]}"
      end
      if (prompts = app[:prompts])
        puts "  Prompts: generation=#{prompts[:generation]}, orchestration=#{prompts[:orchestration]}"
      end

      puts "\n" + "=" * 70 + "\n"
    end
  end
end
