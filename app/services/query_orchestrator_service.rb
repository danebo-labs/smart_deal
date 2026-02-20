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
class QueryOrchestratorService
  TOOLS = {
    DATABASE_QUERY: 'DATABASE_QUERY',
    KNOWLEDGE_BASE_QUERY: 'KNOWLEDGE_BASE_QUERY',
    HYBRID_QUERY: 'HYBRID_QUERY'
  }.freeze

  DEFAULT_IMAGE_PROMPT = <<~PROMPT.freeze
    Describe esta imagen en detalle. Identifica toda la información relevante.
    Responde siempre en español.
  PROMPT

  # @param query [String] The user's question
  # @param images [Array<Hash>] Optional array of { data: base64, media_type: "image/png" }
  def initialize(query, images: [])
    @query = query
    @images = images || []
    @ai_provider = AiProvider.new
  end

  # Main entry point. When images are present, always runs a multimodal
  # analysis in parallel with a KB lookup, then merges results.
  # Without images, uses the standard intent classification flow.
  def execute
    return execute_multimodal_query if @images.any?

    tool_to_use = classify_query_intent

    case tool_to_use
    when TOOLS[:DATABASE_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to DATABASE_QUERY for: '#{@query}'")
      SqlGenerationService.new(@query).execute
    when TOOLS[:KNOWLEDGE_BASE_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to KNOWLEDGE_BASE_QUERY for: '#{@query}'")
      BedrockRagService.new.query(@query)
    when TOOLS[:HYBRID_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to HYBRID_QUERY for: '#{@query}'")
      execute_hybrid_query
    else
      Rails.logger.warn(
        "QueryOrchestrator: Could not clearly classify intent for: '#{@query}'. " \
        "LLM returned: '#{tool_to_use}'. Defaulting to KNOWLEDGE_BASE_QUERY."
      )
      BedrockRagService.new.query(@query)
    end
  end

  private

  # Multimodal flow: analyzes the image directly via invoke_model (Sonnet).
  # The image is also uploaded to S3 in background for future KB queries.
  # No KB query or merge step — keeps response time under Twilio's 15s timeout.
  def execute_multimodal_query
    Rails.logger.info("QueryOrchestrator: MULTIMODAL query with #{@images.size} image(s) for: '#{@query}'")

    prompt = @query.presence || DEFAULT_IMAGE_PROMPT
    image_result = @ai_provider.query(prompt, images: @images, max_tokens: 3000)

    Thread.new do
      upload_and_sync_images
    rescue StandardError => e
      Rails.logger.error("QueryOrchestrator MULTIMODAL - S3 upload/sync failed: #{e.message}")
    end

    image_answer = image_result.to_s.strip.presence

    Rails.logger.info("QueryOrchestrator MULTIMODAL - Image answer present: #{image_answer.present?}")

    if image_answer.present?
      { answer: image_answer, citations: [], session_id: nil }
    else
      { answer: "No pude analizar la imagen. Por favor, intenta de nuevo.", citations: [], session_id: nil }
    end
  end

  def upload_and_sync_images
    s3 = S3DocumentsService.new

    @images.each_with_index do |img, idx|
      ext = img[:media_type]&.split('/')&.last || 'png'
      filename = "whatsapp_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.#{ext}"
      binary_data = Base64.decode64(img[:data] || img['data'])
      s3.upload_file(filename, binary_data, img[:media_type] || img['media_type'])
    end

    KbSyncService.new.sync!
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
      kb_result = BedrockRagService.new.query(@query)
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
end
