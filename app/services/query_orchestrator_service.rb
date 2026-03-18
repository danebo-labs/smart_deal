# frozen_string_literal: true

# app/services/query_orchestrator_service.rb
#
# This service acts as an intelligent router. It first determines the user's intent
# using a fast, cheap LLM call and then delegates the query to the appropriate
# specialized service. This "orchestration first" approach avoids expensive
# operations (RAG retrieval, DB queries) until we know which tool is needed.
#
# Supports three routing modes:
#   - DATABASE_QUERY: business data from the client's database
#   - KNOWLEDGE_BASE_QUERY: documents/policies from the AWS Knowledge Base
#   - HYBRID_QUERY: both sources queried in parallel, results merged
#
# Images are never sent to the LLM directly. They are always uploaded to S3 and
# indexed into the Knowledge Base in a background thread, just like documents.
# The frontend (rag_chat_controller.js) listens for the ActionCable "indexed"
# event and re-sends the original text query once indexing completes.
class QueryOrchestratorService
  TOOLS = {
    DATABASE_QUERY: 'DATABASE_QUERY',
    KNOWLEDGE_BASE_QUERY: 'KNOWLEDGE_BASE_QUERY',
    HYBRID_QUERY: 'HYBRID_QUERY'
  }.freeze

  # @param query [String] The user's question
  # @param images [Array<Hash>] Optional array of { data: base64, media_type: "image/png" }
  # @param documents [Array<Hash>] Optional array of { data: base64, media_type: "text/plain", filename: "x.txt" }
  # @param tenant [Tenant, nil] Optional tenant for multi-tenant data source selection
  def initialize(query, images: [], documents: [], tenant: nil)
    @query = query
    @images = images || []
    @documents = documents || []
    @tenant = tenant
    @ai_provider = AiProvider.new
  end

  # Main entry point. Routing logic:
  #
  # 1. Documents only: respond immediately with an "indexing" message and run
  #    S3 upload + KB ingestion in a background thread.
  #
  # 2. Images (with or without documents): same as documents — respond immediately
  #    with an "indexing" message and run S3 upload + KB ingestion in background.
  #    The frontend stores the original query and re-sends it as a text-only
  #    request after the ActionCable "indexed" event arrives.
  #    Images are NEVER sent to the LLM; all generation uses Haiku 4.5 (text).
  #
  # 3. Text-only query: classify intent and delegate to the appropriate service.
  def execute
    if @documents.any? && @images.empty?
      filenames = @documents.map { |d| File.basename((d[:filename] || d['filename']).presence || 'doc.txt') }
      Thread.new do
        upload_and_sync_attachments
      rescue StandardError => e
        Rails.logger.error("QueryOrchestrator - S3 upload/KB sync failed: #{e.message}")
      end
      return {
        answer: I18n.t('rag.document_indexing_message'),
        citations: [],
        session_id: nil,
        documents_uploaded: filenames
      }
    end

    if @images.any?
      filenames = @images.each_with_index.map do |img, idx|
        name = (img[:filename] || img['filename']).presence
        name ? File.basename(name) : "image_#{idx + 1}"
      end
      Thread.new do
        upload_and_sync_attachments
      rescue StandardError => e
        Rails.logger.error("QueryOrchestrator - S3 upload/KB sync failed: #{e.message}")
      end
      return {
        answer: I18n.t('rag.image_indexing_message'),
        citations: [],
        session_id: nil,
        images_uploaded: filenames
      }
    end

    tool_to_use = classify_query_intent

    case tool_to_use
    when TOOLS[:DATABASE_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to DATABASE_QUERY for: '#{@query}'")
      SqlGenerationService.new(@query).execute
    when TOOLS[:KNOWLEDGE_BASE_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to KNOWLEDGE_BASE_QUERY for: '#{@query}'")
      BedrockRagService.new(tenant: @tenant || current_tenant).query(@query)
    when TOOLS[:HYBRID_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to HYBRID_QUERY for: '#{@query}'")
      execute_hybrid_query
    else
      Rails.logger.warn(
        "QueryOrchestrator: Could not clearly classify intent for: '#{@query}'. " \
        "LLM returned: '#{tool_to_use}'. Defaulting to KNOWLEDGE_BASE_QUERY."
      )
      BedrockRagService.new(tenant: @tenant || current_tenant).query(@query)
    end
  end

  private

  # Uploads all pending images and documents to S3, then starts a Bedrock KB
  # ingestion job via KbSyncService. BedrockIngestionJob polls for completion
  # and broadcasts the result via ActionCable.
  # @return [Array<String>] filenames that were successfully uploaded to S3
  def upload_and_sync_attachments
    s3 = S3DocumentsService.new
    uploaded_filenames = []

    @images.each_with_index do |img, idx|
      ext = img[:media_type]&.split('/')&.last || 'png'
      filename = (img[:filename] || img['filename']).presence
      filename = File.basename(filename) if filename.present?
      filename = "chat_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.#{ext}" if filename.blank?
      binary_data = Base64.decode64(img[:data] || img['data'])
      key = s3.upload_file(filename, binary_data, img[:media_type] || img['media_type'])
      uploaded_filenames << filename if key.present?
    end

    @documents.each_with_index do |doc, idx|
      filename = doc[:filename].presence || "doc_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.txt"
      filename = File.basename(filename)
      binary_data = Base64.decode64(doc[:data] || doc['data'])
      media_type = doc[:media_type] || doc['media_type'] || 'text/plain'
      key = s3.upload_file(filename, binary_data, media_type)
      uploaded_filenames << filename if key.present?
    end

    return [] unless uploaded_filenames.any?

    result = KbSyncService.new(tenant: @tenant || current_tenant).sync!(uploaded_filenames: uploaded_filenames)
    if result.present?
      BedrockIngestionJob.perform_later(
        result[:job_id],
        uploaded_filenames,
        kb_id: result[:kb_id],
        data_source_id: result[:data_source_id]
      )
    end
    uploaded_filenames
  end

  # Executes both DATABASE_QUERY and KNOWLEDGE_BASE_QUERY in parallel using threads,
  # then merges the results into a single coherent answer via an LLM synthesis step.
  def execute_hybrid_query
    db_result = nil
    kb_result = nil

    # Run both queries in parallel to minimize total latency.
    # Instead of ~DB_time + ~KB_time, we pay only ~max(DB_time, KB_time).
    db_thread = Thread.new do
      db_result = SqlGenerationService.new(@query).execute
    rescue StandardError => e
      Rails.logger.error("QueryOrchestrator HYBRID - DB thread failed: #{e.message}")
      db_result = { answer: nil, citations: [], session_id: nil }
    end

    kb_thread = Thread.new do
      kb_result = BedrockRagService.new(tenant: @tenant || current_tenant).query(@query)
    rescue StandardError => e
      Rails.logger.error("QueryOrchestrator HYBRID - KB thread failed: #{e.message}")
      kb_result = { answer: nil, citations: [], session_id: nil }
    end

    # Wait for both threads to complete
    db_thread.join
    kb_thread.join

    Rails.logger.info("QueryOrchestrator HYBRID - DB answer present: #{db_result[:answer].present?}")
    Rails.logger.info("QueryOrchestrator HYBRID - KB answer present: #{kb_result[:answer].present?}")

    # If one source failed, return the other directly
    return kb_result if db_result[:answer].blank?
    return db_result if kb_result[:answer].blank?

    # Both sources returned data -- merge them with an LLM synthesis
    merged_answer = synthesize_hybrid_answer(db_result[:answer], kb_result[:answer])

    {
      answer: merged_answer,
      citations: kb_result[:citations] || [],
      session_id: kb_result[:session_id]
    }
  end

  # Uses the LLM to merge answers from both sources into a single coherent response.
  def synthesize_hybrid_answer(db_answer, kb_answer)
    synthesis_prompt = <<~PROMPT
      You have two answers to the same user question, each from a different source.
      Combine them into a single, coherent, well-structured response. Do not mention the sources explicitly (don't say "according to the database" or "according to the knowledge base"). Just present the information naturally as one unified answer.

      If information overlaps, avoid repetition. If information is complementary, organize it logically.

      User question: "#{@query}"

      Source 1 - Business data:
      #{db_answer}

      Source 2 - Documentation/Knowledge base:
      #{kb_answer}

      Write the unified answer:
    PROMPT

    @ai_provider.query(synthesis_prompt).to_s.strip
  end

  # This is the cheap, fast, first step. It uses an LLM to classify the task.
  # The prompt is designed to return ONLY the tool name, minimizing output tokens.
  def classify_query_intent
    classification_prompt = <<~PROMPT
      You are a task classification agent. Your only job is to determine the correct tool for a user's question based on these definitions:

      - Use DATABASE_QUERY for questions about specific business metrics, numbers, counts, or lists of data that would be in a database (e.g., sales, customers, revenue, dates, inventory, orders).
      - Use KNOWLEDGE_BASE_QUERY for questions about procedures, policies, explanations, "how-to" information, or general knowledge found in documents.
      - Use HYBRID_QUERY when the question clearly requires BOTH database records AND document knowledge to fully answer (e.g., "what records do we have about X and explain its details", or questions asking for data AND explanations).

      User question: "#{@query}"

      Based on the user's question, which is the correct tool? Respond with ONLY the tool name (DATABASE_QUERY, KNOWLEDGE_BASE_QUERY, or HYBRID_QUERY). Do not include any other text.
    PROMPT

    response = @ai_provider.query(classification_prompt).to_s.strip

    # Extract the tool name even if the LLM adds extra text around it.
    # Check HYBRID_QUERY first since it contains "DATABASE_QUERY" as a substring concept.
    if response.include?('HYBRID_QUERY')
      TOOLS[:HYBRID_QUERY]
    elsif response.include?('DATABASE_QUERY')
      TOOLS[:DATABASE_QUERY]
    elsif response.include?('KNOWLEDGE_BASE_QUERY')
      TOOLS[:KNOWLEDGE_BASE_QUERY]
    else
      response
    end
  end

  def current_tenant
    Object.const_defined?("Current") && Current.respond_to?(:tenant) ? Current.tenant : nil
  end
end
