# frozen_string_literal: true

require "digest"

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
# Field photos are analyzed directly by Claude in a background job. The original
# bytes and a thumbnail are retained durably in field_photos/ (see
# FieldPhotoStore) for a bounded retention window so a technician can re-ask
# without re-uploading; they are never indexed into the Knowledge Base.
# Documents continue through the S3 + Knowledge Base ingestion path.
class QueryOrchestratorService
  TOOLS = {
    DATABASE_QUERY: 'DATABASE_QUERY',
    KNOWLEDGE_BASE_QUERY: 'KNOWLEDGE_BASE_QUERY',
    HYBRID_QUERY: 'HYBRID_QUERY'
  }.freeze

  # @param query [String] The user's question
  # @param images [Array<Hash>] Optional array of { data: base64, media_type: "image/png" }
  # @param documents [Array<Hash>] Optional array of { data: base64, media_type: "text/plain", filename: "x.txt" }
  # @param account [Account] Account for ingestion and retrieval scoping.
  # @param session_id [String, nil] Bedrock multi-turn session (e.g. WhatsApp thread)
  # @param response_locale [Symbol, nil] :en / :es to force generation language; nil = infer from query text
  # @param conv_session [ConversationSession, nil] Web/API session — passed to ingestion job for entity registration
  # @param entity_s3_uris [Array<String>] S3 URIs of active session documents for retrieval scoping
  # @param force_entity_filter [Boolean] When true, BedrockRagService bypasses its
  #   "query names a different document" heuristic and always scopes retrieval to
  #   entity_s3_uris. Use when the caller has explicitly bound the query to a
  #   specific document (e.g. WhatsApp post-reset picker selection).
  # @param auto_scope_filter [Boolean] When true, entity_s3_uris came from the
  #   resolver's specific match (not a pin) — passed only to BedrockRagService#query
  #   so it bypasses query_names_different_document? there. Deliberately NOT
  #   passed to the deterministic route builders below (StructuredEvidenceRoute,
  #   AmbiguousModelResponder, DeterministicRenderer), which assume force_entity_filter
  #   means an explicit pinned scope.
  # @param locale [String, nil] ISO 639-1 locale for image summary generation ("es", "en")
  def initialize(query, images: [], documents: [], document_uids: [], account: nil, session_id: nil, response_locale: nil, session_context: nil,
                 conv_session: nil, entity_s3_uris: [], output_channel: nil, force_entity_filter: false, auto_scope_filter: false, locale: nil,
                 user_id: nil, conversation_session_id: nil, correlation_id: nil, field_photo_id: nil, raw_question: nil,
                 context_truncated: nil, apply_photo_continuity: true, expected_episode_id: nil, equipment_identity: :omit)
    @query = query
    @raw_question = raw_question
    @context_truncated = context_truncated
    @images = images || []
    @documents = documents || []
    @document_uids = Array(document_uids)
    @account = account
    @session_id = session_id
    @response_locale = response_locale
    @session_context = session_context
    @conv_session = conv_session
    @entity_s3_uris = Array(entity_s3_uris)
    @output_channel = output_channel
    @force_entity_filter = force_entity_filter
    @auto_scope_filter = auto_scope_filter
    @locale = locale
    @user_id = user_id
    @conversation_session_id = conversation_session_id || (conv_session.id if conv_session.respond_to?(:id))
    @correlation_id = correlation_id
    @field_photo_id = field_photo_id
    @apply_photo_continuity = apply_photo_continuity
    @expected_episode_id = expected_episode_id
    @equipment_identity = equipment_identity
    @equipment_identity_supplied = equipment_identity != :omit
    @ai_provider = AiProvider.new
  end

  # Main entry point. Routing logic:
  #
  # 1. Images: analyze directly with Claude in a background job. No S3/KB writes.
  #
  # 2. Documents: respond immediately with an "indexing" message and run S3
  #    upload + KB ingestion in a background job.
  #
  # 3. Text-only query: classify intent and delegate to the appropriate service.
  def execute
    upload_context = {}

    # Image continuity. The first matching rule wins. New bytes stay on the
    # analysis path below and do not reuse a stored observation. The photo
    # question retrieve opts out: that call already has the observation and
    # must not start another visual turn.
    if @apply_photo_continuity
      decision = Rag::PhotoObservationContinuity.decide(
        question: @query,
        images: @images,
        field_photo_id: @field_photo_id,
        account: @account,
        session: @conv_session
      )
      log_photo_continuity(decision)
      case decision.action
      when :reread
        return enqueue_stored_field_photo(decision.photo, continuity: "reread")
      when :reuse
        if FieldPhotoObservation.sanitize(decision.photo.visual_observation)
          return enqueue_stored_field_photo(decision.photo, continuity: "reuse")
        end
      when :missing_photo
        return missing_field_photo_result
      end
    end

    if @images.any?
      image = @images.first
      filename = (image[:filename] || image["filename"]).presence
      filename = filename ? File.basename(filename) : "image_1"
      content_type = (image[:media_type] || image["media_type"]).presence || "image/jpeg"
      binary = image[:binary] || image["binary"] || Base64.strict_decode64(image[:data] || image["data"])
      image_sha256 = Digest::SHA256.hexdigest(binary)
      locale = (@response_locale || @locale || I18n.locale).to_s
      correlation_id = @correlation_id.presence || "photo:#{SecureRandom.uuid}"
      existing_photo_id = @account && FieldPhoto.where(account_id: @account.id, sha256: image_sha256).pick(:id)
      image_token = FieldPhotoPendingImageStore.write(
        binary: binary, content_type: content_type, filename: filename,
        account_id: @account&.id,
        thumbnail_binary: image[:thumbnail_binary] || image["thumbnail_binary"],
        thumbnail_content_type: image[:thumbnail_content_type] || image["thumbnail_content_type"],
        thumbnail_width: image[:thumbnail_width] || image["thumbnail_width"],
        thumbnail_height: image[:thumbnail_height] || image["thumbnail_height"]
      )

      # Aurora resumes while vision runs (9-18 s, no KB access). A question
      # starts RAG as soon as the reading returns, so the ping overlaps that wait.
      WarmBedrockKbJob.perform_later if @query.present?

      FieldPhotoAnalysisJob.perform_later(
        image_token: image_token,
        image_sha256: image_sha256,
        filename: filename,
        content_type: content_type,
        account_id: @account&.id,
        user_id: @user_id,
        conversation_session_id: @conversation_session_id,
        locale: locale,
        correlation_id: correlation_id,
        field_photo_id: existing_photo_id,
        question: @query.to_s,
        raw_question: @raw_question,
        expected_episode_id: photo_owner_episode_id(correlation_id)
      )

      PilotUsageLog.log(
        "photo_submitted",
        account_id: @account&.id,
        user_id: @user_id,
        conversation_session_id: @conversation_session_id,
        correlation_id: correlation_id,
        route: "visual_query",
        result: "accepted",
        image_digest_prefix: image_sha256.first(12)
      )

      return {
        answer: I18n.with_locale(locale) { I18n.t("rag.image_analyzing_message") },
        citations: [],
        session_id: nil,
        images_uploaded: [ filename ],
        correlation_id: correlation_id,
        response_locale: locale
      }
    end

    if @documents.any?
      filenames = @documents.map { |d| File.basename((d[:filename] || d["filename"]).presence || "doc.txt") }

      # Off-request via Solid Queue lane (NOT Thread.new). The previous
      # Thread.new pattern leaked AR connections during Puma graceful
      # shutdowns and had no retry / observability. The job rebuilds the
      # orchestrator in the worker process and calls the same private
      # method, so behavior is preserved.
      UploadAndSyncAttachmentsJob.perform_later(
        images_payload:    [],
        documents_payload: @documents,
        conv_session_id:   @conversation_session_id,
        account_id:        @account&.id,
        document_uid:      @document_uids.first,
        locale:            I18n.locale.to_s,
        query:             @query.to_s,
        expected_episode_id: upload_owner_episode_id
      )

      if @query.blank?
        return {
          answer: I18n.t("rag.document_indexing_message"),
          citations: [],
          session_id: nil,
          documents_uploaded: filenames
        }
      end

      upload_context[:documents_uploaded] = filenames
    end

    # QUERY_ROUTING_ENABLED (ENV) gates the classification call globally.
    # Default: false — skips the extra invoke_model round-trip and always uses RAG (KB).
    # Set to true when account-specific DB routing is needed.
    tool_to_use = skip_routing? ? TOOLS[:KNOWLEDGE_BASE_QUERY] : classify_query_intent

    case tool_to_use
    when TOOLS[:DATABASE_QUERY]
      Rails.logger.info("QueryOrchestrator: Routing to DATABASE_QUERY for: '#{@query}'")
      SqlGenerationService.new(@query).execute.merge(upload_context)
    when TOOLS[:HYBRID_QUERY]
      if equipment_identity_required?
        execute_knowledge_base_query.merge(upload_context)
      else
        Rails.logger.info("QueryOrchestrator: Routing to HYBRID_QUERY for: '#{@query}'")
        execute_hybrid_query.merge(upload_context)
      end
    else
      unless tool_to_use == TOOLS[:KNOWLEDGE_BASE_QUERY]
        Rails.logger.warn(
          "QueryOrchestrator: Could not clearly classify intent for: '#{@query}'. " \
          "LLM returned: '#{tool_to_use}'. Defaulting to KNOWLEDGE_BASE_QUERY."
        )
      end
      execute_knowledge_base_query.merge(upload_context)
    end
  end

  private

  def log_photo_continuity(decision)
    episode = photo_continuity_episode
    PilotUsageLog.log(
      "photo_continuity",
      account_id: @account&.id,
      user_id: @user_id,
      conversation_session_id: @conversation_session_id,
      correlation_id: photo_continuity_correlation_id(decision),
      episode_id: episode&.episode_id,
      continuity_action: decision.action.to_s,
      field_photo_id: decision.photo&.id || @field_photo_id.presence,
      active_photo_id: episode&.active_photo&.dig("field_photo_id")
    )
  end

  # Reuse, reread, fresh bytes, and a missing photo own the correlation of
  # the job that follows. Passthrough keeps the caller's id.
  def photo_continuity_correlation_id(decision)
    return @correlation_id if @correlation_id.present?
    return nil if decision.action == :passthrough

    @correlation_id = "photo:#{SecureRandom.uuid}"
  end

  def photo_continuity_episode
    return nil unless @conv_session.respond_to?(:active_episode)

    episode = Rag::ActiveEpisode.parse(@conv_session.active_episode, now: Time.current)
    episode.presence
  end

  def enqueue_stored_field_photo(photo, continuity:)
    locale = (@response_locale || @locale || I18n.locale).to_s
    correlation_id = @correlation_id.presence || "photo:#{SecureRandom.uuid}"
    filename = File.basename(photo.s3_key_original.to_s)

    FieldPhotoAnalysisJob.perform_later(
      image_token: nil,
      image_sha256: photo.sha256,
      filename: filename,
      content_type: photo.content_type,
      account_id: @account&.id,
      user_id: @user_id,
      conversation_session_id: @conversation_session_id,
      locale: locale,
      correlation_id: correlation_id,
      field_photo_id: photo.id,
      question: @query.to_s,
      raw_question: @raw_question,
      continuity: continuity,
      expected_episode_id: photo_owner_episode_id(correlation_id)
    )

    {
      answer: I18n.with_locale(locale) { I18n.t("rag.image_analyzing_message") },
      citations: [],
      session_id: nil,
      images_uploaded: [ filename ],
      correlation_id: correlation_id,
      response_locale: locale
    }
  end

  def missing_field_photo_result
    locale = (@response_locale || @locale || I18n.locale).to_s
    {
      answer: Rag::PhotoObservationContinuity::MISSING_PHOTO_MESSAGE,
      citations: [],
      session_id: nil,
      correlation_id: @correlation_id,
      response_locale: locale
    }
  end

  def execute_knowledge_base_query
    if (denied = denied_pin_set_result)
      return denied
    end

    unless equipment_identity_required?
      overview = Rag::DocumentOverviewResponder.build(
        question:        @query,
        account:         @account,
        conv_session:    @conv_session,
        response_locale: @response_locale
      )
      if overview && (rendered_overview = overview.execute)
        Rails.logger.info("QueryOrchestrator: Routing to deterministic_document_overview for: '#{@query}'")
        note_route_exit("document_overview", "deterministic_document_overview")
        return rendered_overview
      end
    end

    structured = Rag::StructuredEvidenceRoute.build(
      question: @query,
      account: @account,
      entity_s3_uris: @entity_s3_uris,
      entity_sources: entity_sources,
      force_entity_filter: @force_entity_filter,
      response_locale: @response_locale,
      output_channel: @output_channel,
      account_id: @account&.id,
      user_id: @user_id,
      conversation_session_id: @conversation_session_id,
      correlation_id: @correlation_id,
      episode: episode_for_scope,
      equipment_identity: resolved_equipment_identity,
      raw_question: @raw_question,
      session_context: @session_context
    )
    outcome = structured&.execute
    if outcome&.status == :answered || outcome&.status == :abstained
      Rails.logger.info("QueryOrchestrator: structured_evidence_route outcome=#{outcome.status}")
      note_route_exit("structured_evidence", outcome.status.to_s)
      return outcome.result
    end

    unless equipment_identity_required?
      disambiguation = Rag::AmbiguousModelResponder.build(
        question:            @query,
        account:             @account,
        entity_s3_uris:      @entity_s3_uris,
        entity_sources:      entity_sources,
        force_entity_filter: @force_entity_filter,
        response_locale:     @response_locale,
        # Carried so the turns this responder now answers through the structured
        # route keep the same attribution as the ones the route answers directly.
        user_id:                 @user_id,
        conversation_session_id: @conversation_session_id,
        correlation_id:          @correlation_id,
        raw_question:            @raw_question,
        session_context:         @session_context,
        episode:                 episode_for_scope,
        equipment_identity:      resolved_equipment_identity
      )
      if disambiguation && (disambiguated = disambiguation.execute)
        mode = disambiguated[:generation_mode].to_s
        exit_name = mode == "deterministic_model_disambiguation" ? "model_disambiguation" : mode
        Rails.logger.info("QueryOrchestrator: Routing to #{exit_name} for: '#{@query}'")
        note_route_exit(exit_name, mode)
        return disambiguated
      end

      deterministic = Rag::DeterministicRenderer.build(
        question:            @query,
        entity_s3_uris:      @entity_s3_uris,
        entity_sources:      entity_sources,
        force_entity_filter: @force_entity_filter,
        response_locale:     @response_locale,
        account:             @account
      )
      if deterministic
        Rails.logger.info("QueryOrchestrator: Routing to #{deterministic.generation_mode} for: '#{@query}'")
        note_route_exit("deterministic_renderer", deterministic.generation_mode.to_s)
        return deterministic.execute
      end
    end

    Rails.logger.info("QueryOrchestrator: Routing to KNOWLEDGE_BASE_QUERY for: '#{@query}'")
    if (context_result = context_evidence_result)
      note_route_exit("context_evidence", "context_evidence")
      return context_result
    end

    note_route_exit("knowledge_base", "delegate_query")
    BedrockRagService.new(account: @account).query(
      @query,
      session_id: @session_id,
      response_locale: @response_locale,
      session_context: @session_context,
      entity_s3_uris: @entity_s3_uris,
      entity_sources: entity_sources,
      output_channel: @output_channel,
      force_entity_filter: @force_entity_filter,
      auto_scope_filter: @auto_scope_filter,
      episode: episode_for_scope,
      equipment_identity: resolved_equipment_identity,
      raw_question: @raw_question,
      context_truncated: generation_context_truncated?,
      **rag_telemetry
    )
  end

  # Known equipment makes compatibility required. A supplied value that is
  # not an EquipmentIdentity is the same required state: Bedrock treats it
  # as malformed and stays closed. Terminals that do not apply
  # DocumentIdentityScope stay off that path: overview, model disambiguation,
  # deterministic renderers, and hybrid synthesis.
  def note_route_exit(exit_name, condition)
    return unless Rag::ValidationCapture.active?

    payload = { "stage" => "route", "result" => exit_name, "exit" => exit_name, "condition" => condition }
    payload["correlation_id"] = @correlation_id if @correlation_id.present?
    Rag::ValidationCapture.record("route_exit", payload)
  end

  def equipment_identity_required?
    identity = resolved_equipment_identity
    identity == :malformed || (identity.is_a?(Rag::EquipmentIdentity) && identity.known?)
  end

  def episode_for_scope
    return unless @conv_session.respond_to?(:active_episode)

    @conv_session.active_episode
  end

  # Explicit snapshot wins. Otherwise the text path derives one identity
  # from the live episode. Supplied nil stays unknown and does not re-read.
  # A non-nil value that is not an EquipmentIdentity stays malformed. The
  # episode is not used to repair that transport.
  def resolved_equipment_identity
    return @resolved_equipment_identity if defined?(@resolved_equipment_identity)

    @resolved_equipment_identity = if @equipment_identity_supplied
      if @equipment_identity.nil?
        nil
      elsif @equipment_identity.is_a?(Rag::EquipmentIdentity)
        @equipment_identity
      else
        :malformed
      end
    else
      Rag::EquipmentIdentity.from_episode(episode_for_scope)
    end
  end

  def denied_pin_set_result
    uris = Array(@entity_s3_uris).map(&:to_s).compact_blank.uniq
    return nil if uris.empty?

    decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set(uris, viewer_account: @account)
    return nil if decision.allowed?

    BedrockRagService.deny_retrieval_result(
      question: @query,
      session_id: @session_id,
      response_locale: @response_locale
    )
  end

  def context_evidence_result
    route = Rag::ContextEvidenceRoute.build(
      question: @query,
      account: @account,
      entity_s3_uris: @entity_s3_uris,
      entity_sources: entity_sources,
      response_locale: @response_locale,
      output_channel: @output_channel,
      account_id: @account&.id,
      user_id: @user_id,
      conversation_session_id: @conversation_session_id,
      correlation_id: @correlation_id,
      episode: episode_for_scope,
      equipment_identity: resolved_equipment_identity,
      session_context: @session_context,
      raw_question: @raw_question
    )
    outcome = route&.execute
    return nil unless outcome&.status == :answered || outcome&.status == :abstained

    Rails.logger.info("QueryOrchestrator: context_evidence_route outcome=#{outcome.status}")
    outcome.result
  end

  def generation_context_truncated?
    return true if @context_truncated == true

    @conv_session.respond_to?(:context_truncated) && @conv_session.context_truncated == true
  end

  def rag_telemetry
    {
      account_id: @account&.id,
      user_id: @user_id,
      conversation_session_id: @conversation_session_id,
      correlation_id: @correlation_id
    }
  end

  # Delegates all web/chat attachment uploads + chunking to CustomChunkingPipeline.
  # Short files parse via sync Messages; long PDFs route automatically to the
  # async manual Batch chain. Bulk/backoffice ZIP uploads still use /bulk_uploads.
  # @return [Array<String>] filenames successfully uploaded to S3
  def upload_and_sync_attachments
    CustomChunkingPipeline.new(
      images:       @images,
      documents:    @documents,
      conv_session: @conv_session,
      account_id:   @account&.id,
      document_uid: @document_uids.first || SecureRandom.uuid,
      locale:       @locale,
      urgent:       true,
      query:        @query,
      expected_episode_id: @expected_episode_id
    ).run!
  end

  # Captured on the request, before enqueue. A later case must not become the owner.
  def upload_owner_episode_id
    return @expected_episode_id if @expected_episode_id.present?
    return nil unless Rag::FieldCompanionEpisodeFlag.enabled?
    return nil unless @conv_session.respond_to?(:live_episode_id)

    @conv_session.live_episode_id
  end

  def photo_owner_episode_id(correlation_id)
    return nil unless @conv_session.respond_to?(:ensure_case_for_photo_submission!)

    @conv_session.ensure_case_for_photo_submission!(correlation_id: correlation_id)
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
      kb_result = BedrockRagService.new(account: @account).query(
        @query,
        session_id: @session_id,
        response_locale: @response_locale,
        session_context: @session_context,
        entity_s3_uris: @entity_s3_uris,
        entity_sources: entity_sources,
        output_channel: @output_channel,
        force_entity_filter: @force_entity_filter,
        auto_scope_filter: @auto_scope_filter,
        episode: episode_for_scope,
        equipment_identity: resolved_equipment_identity,
        **rag_telemetry
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
      retrieval_trace: kb_result[:retrieval_trace],
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
    !self.class.query_routing_enabled? || rag_only_account?
  end

  def self.query_routing_enabled?
    ENV.fetch('QUERY_ROUTING_ENABLED', 'false').casecmp?('true')
  end

  def rag_only_account?
    @account.nil? || Array(@account.try(:data_sources)).exclude?("db")
  end

  # Derives media types from pinned session entities for RagRetrievalProfile.
  # Legacy image_upload rows remain images; other legacy rows default to documents.
  def entity_sources
    return [] unless @conv_session

    if @conv_session.respond_to?(:uses_document_focus?) && @conv_session.uses_document_focus?
      return document_focus_entity_sources
    end
    return [] unless @conv_session.respond_to?(:active_entities)

    entities = @conv_session.active_entities.values
    if @entity_s3_uris.any?
      allowed_uris = @entity_s3_uris.to_set
      entities = entities.select { |meta| allowed_uris.include?(meta["source_uri"].to_s) }
    end

    entities.map do |meta|
      entity_type = meta["entity_type"].presence || meta["source"]
      entity_type == "image_upload" ? "image_upload" : "document"
    end
  end

  def document_focus_entity_sources
    entries = @conv_session.document_focus_entries
    if @entity_s3_uris.any?
      allowed_uris = @entity_s3_uris.to_set
      entries = entries.select { |entry| allowed_uris.include?(entry["source_uri"].to_s) }
    end
    documents = KbDocument.where(id: entries.pluck("kb_document_id")).index_by(&:id)
    entries.map { |entry|
      ConversationSession.media_type_for(documents[entry["kb_document_id"]] || entry["source_uri"])
    }
  end
end
