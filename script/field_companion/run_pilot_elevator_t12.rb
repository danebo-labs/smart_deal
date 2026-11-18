# frozen_string_literal: true

# One real T12 on a local copy of case 20, with its captured photo reading.
# Run via bin/rails runner after the offline test. The receipt is persistent
# across processes and reserves all three calls before the first one is sent.
require "fileutils"
require Rails.root.join("test/support/pilot_elevator_closure")

module PilotElevatorT12
  KB = "Y7RZWMFJSR"
  CALLS = 3
  OUTPUT = Rails.root.join("tmp/field_companion/pilot_elevator_t12")
  MODEL = "claude-haiku-5-5-direct"

  class QueryHost
    include RagQueryConcern
    attr_reader :current_account, :current_user

    def initialize(current_account, current_user)
      @current_account, @current_user = current_account, current_user
    end

    def call(question, **options)
      execute_rag_query(question, **options)
    end
  end

  # Anthropic attempts already use LocalPassLedger. Join AWS Retrieve to the
  # same ledger at the SDK boundary and reject every alternative KB operation.
  module ReadOnlyKb
    def retrieve(params, options = {})
      vector = params.fetch(:retrieval_configuration).fetch(:vector_search_configuration)
      leaves = vector.fetch(:filter).fetch(:or_all).map { |leaf| leaf.fetch(:equals) }
      expected = %w[original_source_uri x-amz-bedrock-kb-source-uri]
      unless params[:knowledge_base_id] == KB && config.retry_mode == "standard" && config.max_attempts == 1 &&
          vector[:reranking_configuration].blank? && leaves.pluck(:key).sort == expected &&
          leaves.pluck(:value).uniq == [ PilotElevatorT12.pin_uri ]
        raise Rag::LocalPassLedger::Stop, "capture_kb_scope_or_transport_changed"
      end

      Rag::LocalPassLedger.protect!(operation: "retrieve", model_id: "read-only-kb", input_tokens: 0, output_tokens: 0) do
        super
      end
    end

    def rerank(...)
      raise Rag::LocalPassLedger::Stop, "rerank_would_exceed_three_call_plan"
    end

    def retrieve_and_generate(...)
      raise Rag::LocalPassLedger::Stop, "bedrock_generation_outside_plan"
    end

    def retrieve_and_generate_stream(...)
      raise Rag::LocalPassLedger::Stop, "bedrock_generation_outside_plan"
    end
  end

  # The SDK retry flag does not control the application's Aurora retry.
  # This runner has exactly one Retrieve slot.
  module SingleRetrieve
    def with_retry(error_classes:, on_retry: nil)
      yield
    end
  end

  module_function

  def pin_uri
    @capture.fetch("pin_uri")
  end

  def arm!
    raise "development local database required" unless Rails.env.development? && Rag::LocalPassLedger.local_process?
    raise "shared session is enabled" if SharedSession::ENABLED
    raise "existing assignment guard applies to a different run" if ENV["RAG_ASSIGNMENT_SPEND_PATH"].present?
    raise "Anthropic credential missing" if ENV["ANTHROPIC_API_KEY"].blank? && Rails.application.credentials.dig(:anthropic, :api_key).blank?

    env = {
      "AWS_MAX_ATTEMPTS" => "1", "AWS_RETRY_MODE" => "standard", "AWS_EC2_METADATA_DISABLED" => "true",
      "RAG_TRANSIENT_ATTEMPT_LIMIT" => "1", "BEDROCK_INFERENCE" => "blocked", "BEDROCK_KNOWLEDGE_BASE_ID" => KB,
      "RAG_COMPANION_GENERATION" => "direct", "COMPANION_DIRECT_PROVIDER" => "anthropic",
      "COMPANION_DIRECT_MODEL_ID" => "claude-haiku-5-5", "COMPANION_DIRECT_MAX_TOKENS" => "4000",
      "RAG_LOCAL_PASS_GUARD" => "1", "RAG_LOCAL_PASS_CALL_CAP" => CALLS.to_s,
      "RAG_LOCAL_PASS_ALLOWED_CALLS" => "converse@#{MODEL},retrieve@read-only-kb,converse_message@#{MODEL}",
      "HAIKU_QUERY_ANALYSIS_MODE" => "owner", "RAG_COMPANION_TURN" => "1",
      "FIELD_COMPANION_TURN_ENABLED" => "true", "DOCUMENT_IDENTITY_SCOPE_ENABLED" => "true"
    }
    env.each { |key, value| ENV[key] = value }
    # Same price table and conservative character-as-token reserve as live runners.
    interpreter = Rag::LocalPassLedger.price(MODEL, Rag::TurnInterpreter::PROMPT.length + 8_000, Rag::TurnInterpreter::MAX_TOKENS)
    generator = Rag::LocalPassLedger.price(MODEL, Rag::CompanionDirectAnswer::SYSTEM_PROMPT.length + 48_000, 4_000)
    ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = (interpreter + generator).to_s("F")
    raise "runner budget is unarmed" unless Rag::LocalPassLedger.armed?
    configured_kb = @account.try(:bedrock_config)&.knowledge_base_id
    raise "production KB override differs" if configured_kb.present? && configured_kb != KB

    Aws::BedrockAgentRuntime::Client.prepend(ReadOnlyKb)
    Bedrock::AuroraColdStartRetry.singleton_class.prepend(SingleRetrieve)
  end

  def restore!(history, document, user)
    state = history.last.fetch("checkpoint").deep_dup
    first = history.first
    attachment = first.fetch("attachment")
    visual = FieldPhotoObservation.sanitize(first.fetch("visual_context"))
    raise "captured photo observation invalid" unless visual && attachment["sha256"] == state.dig("active_photo", "sha256")

    FieldCase.transaction do
      photo = FieldPhoto.find_or_create_by!(
        account: @account, sha256: attachment.fetch("sha256"), storage_scope: "pilot-elevator-t12"
      ) do |row|
        row.assign_attributes(
          user_id: user.id, s3_key_original: "capture-fixture/#{attachment.fetch('sha256')}",
          content_type: attachment.fetch("content_type"), byte_size: attachment.fetch("byte_size"), visual_observation: visual
        )
      end
      raise "local photo observation differs from capture" unless FieldPhotoObservation.sanitize(photo.visual_observation) == visual

      state["active_photo"]["field_photo_id"] = photo.id
      case_evidence = history.reduce({}) do |ledger, turn|
        next ledger if turn["kind"] == "photo"

        chunks = PilotElevatorClosure.numbered_chunks(turn, key: "cited_sources", pin_uri: pin_uri, full: true)
        Rag::CompanionCaseRecord.record(
          state: ledger, episode_id: state.fetch("episode_id"), chunks: chunks,
          published_text: turn.fetch("prompt_reply"), correlation_id: turn.fetch("correlation_id"),
          outcome: "published", quotes: turn.fetch("quotes")
        ).state
      end
      observed = case_evidence.fetch("sources").pluck("n").sort
      expected = @capture.fetch("turns").last.fetch("ledger_numbers").sort
      raise "T11 ledger differs from capture (#{observed} vs #{expected})" unless observed == expected

      pin = { "kb_document_id" => document.id, "document_uid" => document.document_uid }
      restored = FieldCase.create!(
        account: @account, user: user, episode_id: state.fetch("episode_id"),
        opened_at: state.fetch("opened_at"), last_activity_at: state.fetch("updated_at"),
        document_focus: [ pin ], last_sequence: history.size, state_revision: history.size,
        technical_state: state.merge("case_evidence" => case_evidence)
      )
      history.each do |turn|
        cid = turn.fetch("correlation_id")
        admitted = Time.iso8601(turn.fetch("admitted_at"))
        rendered = turn.fetch("published_text")
        restored.field_turns.create!(
          sequence: turn.fetch("sequence"), kind: turn.fetch("kind"), correlation_id: cid,
          field_photo: (photo if turn["kind"] == "photo"),
          client_submission_id: "restore-#{turn.fetch('sequence')}",
          input_digest: FieldCases::Payload.digest(message: turn.fetch("message"), attachment_sha256: turn.dig("attachment", "sha256")),
          execution_token: SecureRandom.uuid, attempt: 1,
          base_state_revision: turn.fetch("sequence") - 1, result_state_revision: turn.fetch("sequence"),
          locale: "es", message: turn.fetch("message"), status: "completed", phase: "published",
          admitted_at: admitted, completed_at: admitted,
          attachment: turn.fetch("attachment", {}).except("href"),
          response: { "published_text" => rendered }, prompt_reply: turn.fetch("prompt_reply")
        )
      end
      restored
    end
  end

  def one_turn(kase, user, question, directory)
    focus = FieldCases::Pins.resolve(kase.document_focus, account: @account)
    raise "T11 pin not restored" unless focus

    restored = FieldCases::TurnContext.build(kase, focus: focus)
    raise "T11 pin, history, or photo not restored" unless kase.field_turns.where(status: "completed").count == 11 &&
      restored.conversation_history.size == 2 * ConversationSession::EPISODE_MAX_USER_MESSAGES &&
      SessionContextBuilder.entity_s3_uris(restored) == [ pin_uri ] && restored.case_photo_context.loaded?

    pending = Rag::AnswerContract.open_parts(Rag::ActiveEpisode.parse(restored.active_episode))
    raise "T11 pending check not restored" unless pending.one? && pending.first["id"] == "p9"

    cid = "query:#{SecureRandom.uuid}"
    admission = FieldCases::AdmitTurn.call(
      account: @account, user: user, field_case_id: kase.id, client_submission_id: SecureRandom.uuid,
      message: question, correlation_id: cid, locale: "es"
    )
    raise "T12 admission failed: #{admission.status}" unless admission.status == :ok && admission.turn.sequence == 12

    turn = FieldCases::TextTurn.new(admission, account: @account, user: user)
    context = turn.context
    events = nil
    result = nil
    outcome = nil
    File.open(directory.join("reserved"), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.puts CALLS }
    Rag::ValidationCapture.capture do |bucket|
      events = bucket
      Rag::ValidationCapture.bind(run_id: "pilot-elevator-t12", correlation_root: cid)
      episode_turn = context.record_user_turn!(question, user_id: user.id, correlation_id: cid, locale: :es)
      expected_episode_id = context.live_episode_id
      result = QueryHost.new(@account, user).call(
        question, session_context: SessionContextBuilder.build(context), conv_session: context,
        entity_s3_uris: SessionContextBuilder.entity_s3_uris(context), account: @account, user_id: user.id,
        correlation_id: cid, episode_turn: episode_turn, output_channel: :web, apply_photo_continuity: false
      )
      raise "turn returned #{result.error_type}" unless result.success?

      context.stamp_user_retrieval_query!(cid, result.effective_question || question)
      context.capture_pending!(result)
      written = Rag::CompanionCaseWrite.persist!(
        context, result, user_id: user.id, expected_episode_id: expected_episode_id, focus_ids: context.focus_document_ids
      )
      raise "case write conflict" if Rag::CompanionCaseWrite.conflict?(written)

      citations = Bedrock::CitationProcessor.new.transport_references(result.citations)
      outcome = turn.complete({ answer: result.answer, citations: citations,
        provenance_segments: Rag::ProvenanceSegmenter.call(answer: result.answer, citations: citations) },
        context, prompt_reply: result.history_answer)
      raise "case close failed: #{outcome.status}" unless outcome.status == :ok
    end
  rescue Rag::LocalPassLedger::Stop, StandardError
    turn&.fail("replay_interrupted", "La ejecución local se interrumpió antes de concluir.")
    raise
  ensure
    if events
      document = Rag::ValidationCapture.export_capture(events, directory, run_id: "pilot-elevator-t12")
      File.write(directory.join("capture.json"), JSON.pretty_generate(document))
      persisted = FieldTurn.find_by(correlation_id: cid)
      episode = Rag::ActiveEpisode.parse(kase.reload.technical_state.except("case_evidence"))
      published = persisted&.response&.dig("published_text")
      summary = {
        "correlation_id" => cid, "field_case_id" => kase.id, "episode_id" => episode.episode_id,
        "answer" => published, "turn_status" => persisted&.status, "route_outcome" => result&.route_outcome,
        "functional_check" => Rag::AnswerContract.part_state(episode, pending.first.fetch("id")),
        "open_parts" => Rag::AnswerContract.open_parts(episode),
        "missing_closure_facts" => PilotElevatorClosure.missing_closure_facts(published),
        "budget" => Rag::LocalPassLedger.snapshot,
        "error" => ($!.message if $!)
      }
      File.write(directory.join("summary.json"), JSON.pretty_generate(summary))
      puts JSON.pretty_generate(summary)
      return summary unless $!
    end
  end

  def run
    @capture = PilotElevatorClosure.load_capture
    history = @capture.fetch("turns").first(11)
    question = @capture.fetch("turns").last.fetch("message")
    FileUtils.mkdir_p(OUTPUT, mode: 0o700)
    raise "three-call reservation already used" if OUTPUT.join("reserved").exist?
    raise "development local database required" unless Rails.env.development? && Rag::LocalPassLedger.local_process?

    @account = Account.find_by!(id: 3, slug: "danebo-pilot-elevator")
    arm!
    key = pin_uri.delete_prefix("s3://#{KbDocument::KB_BUCKET}/")
    matching = KbDocument.where(s3_key: [ key, pin_uri ]).to_a
    raise "local manual catalog is ambiguous" if matching.many?

    # Seed only the local catalog registration when the production pin has
    # no local row. The canonical object continues to be read from the KB.
    document = matching.first || KbDocument.create!(
      account: @account, s3_key: key, display_name: File.basename(key, ".pdf")
    )
    raise "local document differs from capture" unless document.canonical_uri == pin_uri &&
      Rag::KnowledgeScopePolicy.authorized?(document, viewer_account: @account)

    user = User.find_by(id: 7, account: @account) ||
      User.find_or_create_by!(account: @account, email: "pilot-t12-replay@example.invalid") do |local|
        local.password = SecureRandom.hex(24)
      end
    kase = FieldCase.find_by(account: @account, user: user, episode_id: @capture.fetch("episode_id"))
    if kase
      expected = history.map { |row| row.values_at("correlation_id", "message") }
      unless kase.last_sequence == 11 && kase.field_turns.order(:sequence).pluck(:correlation_id, :message) == expected
        raise "local replay case no longer matches T11"
      end
    else
      kase = restore!(history, document, user)
    end
    summary = one_turn(kase, user, question, OUTPUT)
    summary && summary["functional_check"] == "complete" && summary["open_parts"].empty? &&
      summary["route_outcome"].to_s == "answered" && summary["missing_closure_facts"].empty? ? 0 : 2
  rescue Rag::LocalPassLedger::Stop, StandardError => error
    warn "#{error.class}: #{error.message}"
    2
  end
end

exit PilotElevatorT12.run
