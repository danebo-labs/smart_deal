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
  # @param session_id [String, nil] Bedrock multi-turn session (e.g. WhatsApp thread)
  # @param response_locale [Symbol, nil] :en / :es to force generation language; nil = infer from query text
  # @param conv_session [ConversationSession, nil] Web/API session — passed to ingestion job for entity registration
  # @param entity_s3_uris [Array<String>] S3 URIs of active session documents for retrieval scoping
  # @param force_entity_filter [Boolean] When true, BedrockRagService bypasses its
  #   "query names a different document" heuristic and always scopes retrieval to
  #   entity_s3_uris. Use when the caller has explicitly bound the query to a
  #   specific document (e.g. WhatsApp post-reset picker selection).
  def initialize(query, images: [], documents: [], tenant: nil, session_id: nil, response_locale: nil, session_context: nil,
                 conv_session: nil, entity_s3_uris: [], output_channel: nil, force_entity_filter: false)
    @query = query
    @images = images || []
    @documents = documents || []
    @tenant = tenant
    @session_id = session_id
    @response_locale = response_locale
    @session_context = session_context
    @conv_session = conv_session
    @entity_s3_uris = Array(entity_s3_uris)
    @output_channel = output_channel
    @force_entity_filter = force_entity_filter
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
    if @documents.any? || @images.any?
      has_images = @images.any?
      filenames = if has_images
        @images.each_with_index.map do |img, idx|
          name = (img[:filename] || img['filename']).presence
          name ? File.basename(name) : "image_#{idx + 1}"
        end
      else
        @documents.map { |d| File.basename((d[:filename] || d['filename']).presence || 'doc.txt') }
      end

      # Off-request via Solid Queue lane (NOT Thread.new). The previous
      # Thread.new pattern leaked AR connections during Puma graceful
      # shutdowns and had no retry / observability. The job rebuilds the
      # orchestrator in the worker process and calls the same private
      # method, so behavior is preserved.
      UploadAndSyncAttachmentsJob.perform_later(
        images_payload:    UploadAndSyncAttachmentsJob.prepare_images_for_async(@images),
        documents_payload: @documents,
        conv_session_id:   @conv_session&.id,
        tenant_id:         @tenant&.id
      )

      if @query.blank?
        key = has_images ? :images_uploaded : :documents_uploaded
        msg = has_images ? I18n.t('rag.image_indexing_message') : I18n.t('rag.document_indexing_message')
        return { answer: msg, citations: [], session_id: nil }.merge(key => filenames)
      end
    end

    # QUERY_ROUTING_ENABLED (ENV) gates the classification call globally.
    # Default: false — skips the extra invoke_model round-trip and always uses RAG (KB).
    # Set to true when multi-tenant DB routing is needed.
    tool_to_use = skip_routing? ? TOOLS[:KNOWLEDGE_BASE_QUERY] : classify_query_intent

    case tool_to_use
    when TOOLS[:DATABASE_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to DATABASE_QUERY for: '#{@query}'")
      SqlGenerationService.new(@query).execute
    when TOOLS[:KNOWLEDGE_BASE_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to KNOWLEDGE_BASE_QUERY for: '#{@query}'")
      BedrockRagService.new(tenant: @tenant || current_tenant).query(
        @query,
        session_id: @session_id,
        response_locale: @response_locale,
        session_context: @session_context,
        entity_s3_uris: @entity_s3_uris,
        output_channel: @output_channel,
        force_entity_filter: @force_entity_filter
      )
    when TOOLS[:HYBRID_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to HYBRID_QUERY for: '#{@query}'")
      execute_hybrid_query
    else
      Rails.logger.warn(
        "QueryOrchestrator: Could not clearly classify intent for: '#{@query}'. " \
        "LLM returned: '#{tool_to_use}'. Defaulting to KNOWLEDGE_BASE_QUERY."
      )
      BedrockRagService.new(tenant: @tenant || current_tenant).query(
        @query,
        session_id: @session_id,
        response_locale: @response_locale,
        session_context: @session_context,
        entity_s3_uris: @entity_s3_uris,
        output_channel: @output_channel,
        force_entity_filter: @force_entity_filter
      )
    end
  end

  private

  # Uploads all pending images and documents to S3, creates KbDocument + thumbnail
  # synchronously in this thread (same process, data in memory), then enqueues
  # BedrockIngestionJob with explicit kb_document_ids for enrichment-only work.
  # @return [Array<String>] filenames that were successfully uploaded to S3
  def upload_and_sync_attachments
    s3 = S3DocumentsService.new
    uploaded_filenames = []
    kb_document_ids    = []

    @images.each_with_index do |img, idx|
      ext = img[:media_type]&.split('/')&.last || 'jpeg'
      filename = (img[:filename] || img['filename']).presence
      filename = File.basename(filename) if filename.present?
      filename = "chat_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.#{ext}" if filename.blank?
      binary_data = img[:binary] || img['binary'] || Base64.decode64(img[:data] || img['data'])
      key = s3.upload_file(filename, binary_data, img[:media_type] || img['media_type'])
      next if key.blank?

      uploaded_filenames << filename
      kb_doc = ensure_kb_document_for(key)
      persist_thumbnail_for(kb_doc, img)
      kb_document_ids << kb_doc.id
    end

    @documents.each_with_index do |doc, idx|
      filename = doc[:filename].presence || "doc_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.txt"
      filename = File.basename(filename)
      binary_data = Base64.decode64(doc[:data] || doc['data'])
      media_type = doc[:media_type] || doc['media_type'] || 'text/plain'
      key = s3.upload_file(filename, binary_data, media_type)
      next if key.blank?

      uploaded_filenames << filename
      kb_doc = ensure_kb_document_for(key)
      kb_document_ids << kb_doc.id
    end

    return [] if uploaded_filenames.empty?

    result = KbSyncService.new(tenant: @tenant || current_tenant).sync!(uploaded_filenames: uploaded_filenames)
    if result.present?
      BedrockIngestionJob.perform_later(
        result[:job_id],
        uploaded_filenames,
        kb_id:           result[:kb_id],
        data_source_id:  result[:data_source_id],
        conv_session_id: @conv_session&.id,
        kb_document_ids: kb_document_ids
      )
    end
    uploaded_filenames
  end

  # Idempotent: uses s3_key as unique key. Recovers from a race-condition
  # RecordNotUnique by re-finding the row the winner thread created.
  def ensure_kb_document_for(s3_key)
    KbDocument.find_or_create_by!(s3_key: s3_key) do |d|
      d.display_name = File.basename(s3_key, ".*").tr("_-", " ").strip.presence
      d.aliases      = []
    end
  rescue ActiveRecord::RecordNotUnique
    KbDocument.find_by!(s3_key: s3_key)
  end

  def persist_thumbnail_for(kb_doc, img)
    thumb_binary = img[:thumbnail_binary] || img['thumbnail_binary']
    return if thumb_binary.blank?
    return if kb_doc.thumbnail.present?

    kb_doc.create_thumbnail!(
      data:         thumb_binary,
      content_type: img[:thumbnail_content_type] || img['thumbnail_content_type'] || "image/jpeg",
      width:        img[:thumbnail_width]  || img['thumbnail_width'],
      height:       img[:thumbnail_height] || img['thumbnail_height'],
      byte_size:    thumb_binary.bytesize
    )
  rescue StandardError => e
    Rails.logger.warn("QueryOrchestrator: thumbnail persist failed for kb_doc=#{kb_doc.id} — #{e.message}")
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
      kb_result = BedrockRagService.new(tenant: @tenant || current_tenant).query(
        @query,
        session_id: @session_id,
        response_locale: @response_locale,
        session_context: @session_context,
        entity_s3_uris: @entity_s3_uris,
        output_channel: @output_channel,
        force_entity_filter: @force_entity_filter
      )
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
      retrieved_citations: kb_result[:retrieved_citations],
      doc_refs: kb_result[:doc_refs],
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

  def skip_routing?
    !self.class.query_routing_enabled? || rag_only_tenant?
  end

  def self.query_routing_enabled?
    ENV.fetch('QUERY_ROUTING_ENABLED', 'false').casecmp?('true')
  end

  def rag_only_tenant?
    @tenant.nil? || Array(@tenant.try(:data_sources)).exclude?("db")
  end

  def current_tenant
    Object.const_defined?("Current") && Current.respond_to?(:tenant) ? Current.tenant : nil
  end
end
