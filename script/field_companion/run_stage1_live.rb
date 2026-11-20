# frozen_string_literal: true

# Bounded stage 1 live check for Thyssen T11/T12 and Otis T5/T6, or (with
# STAGE1_FULL=otis) the whole Otis case 29, T1 to T6, from a new case: no
# restored checkpoint, each turn starts from the state the previous one left,
# and T1/T3 go through the photo pipeline with the supplied images.
# Restores earlier turns from the 19 Nov fixture, sends the target turn
# through AdmitTurn and RagQueryConcern#execute_rag_query, then reloads the
# case. Retrieve and rerank may reach the production knowledge base. Every
# other Bedrock generation call stops. One attempt per turn: a failed
# acceptance or a raised error writes the directory and does not continue.
#
# Requires STAGE1_LIVE_CONFIRM=1, FIELD_CHECK_OUTCOME=true and
# SHARED_SESSION_ENABLED=false in the process environment. The flag is not
# written to the application default. Local database: STAGE1_DATABASE
# (default smart_deal_stage1_live).

require "fileutils"
require "json"
require_relative "otis_rubric"
require_relative "photo_prep"

module Stage1Live
  KB = "Y7RZWMFJSR"
  # The HTTP runner sets this before Puma boots. KbDocument::KB_BUCKET is
  # frozen from KNOWLEDGE_BASE_S3_BUCKET at load. .env says smart-deal-dev-kb,
  # and a relative catalog key then becomes that bucket in the retrieve filter.
  PRODUCTION_BUCKET = "multimodal-source-destination"
  THYSSEN_UID = "02ae6128-077b-4c00-8029-f0cf80e0f6c4"
  THYSSEN_KEY = "bulk_uploads/3/2026-08-20/THYSSEN (Manual de Maniobra Universal con MCINV4).pdf"
  THYSSEN_URI = "s3://#{PRODUCTION_BUCKET}/#{THYSSEN_KEY}".freeze
  DATABASE = ENV.fetch("STAGE1_DATABASE", "smart_deal_stage1_live")
  ROOT = Rails.root.join("tmp/field_companion/stage1_live")
  FIXTURE = Rails.root.join("test/fixtures/files/field_companion/pilot_2026_11_19.json")
  MODEL = "claude-haiku-5-5-direct"
  RERANK = "cohere.rerank-v3-5:0"
  CALLS_PER_TURN = 12
  # The blocked T11 priced the rerank payload at 118_383 characters. The
  # reservation uses the Haiku 4.5 fallback rate because Cohere is not in
  # BEDROCK_PRICING. 500_000 characters leaves room for the longer Otis pages.
  RERANK_CHARS = 500_000
  RERANK_USD = BigDecimal("0.002")
  OTIS = [
    [ "9437fc07-4430-4c61-80cb-3dd7b6bc69ae",
      "bulk_uploads/3/2026-08-24/MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p1-123).pdf" ],
    [ "8ef7b20c-b73a-4da9-a920-bdc34fb60747",
      "bulk_uploads/3/2026-08-24/MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p124-245).pdf" ]
  ].freeze
  DEPENDS_ON = { "Thyssen T12" => "Thyssen T11", "Otis T6" => "Otis T5" }.freeze
  PINS = {
    "28" => [ "bulk_uploads/3/2026-08-20/THYSSEN (Manual de Maniobra Universal con MCINV4).pdf" ],
    "29" => [
      "bulk_uploads/3/2026-08-24/MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p1-123).pdf",
      "bulk_uploads/3/2026-08-24/MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p124-245).pdf"
    ]
  }.freeze

  class Halt < StandardError
    attr_reader :details

    def initialize(message, details = {})
      super(message)
      @details = details
    end
  end

  class QueryHost
    include RagQueryConcern
    attr_reader :current_account, :current_user

    def initialize(current_account, current_user)
      @current_account = current_account
      @current_user = current_user
    end

    def call(question, **options)
      execute_rag_query(question, **options)
    end
  end

  # Retrieve stays on the production KB. Rerank is the companion reorder.
  # Generation through the knowledge base is refused before the SDK.
  module ReadOnlyKb
    def retrieve(params, options = {})
      kb = params[:knowledge_base_id] || params["knowledge_base_id"]
      vector = params.fetch(:retrieval_configuration).fetch(:vector_search_configuration)
      values = Stage1Live.filter_values(vector[:filter]).uniq.sort
      expected = Array(Stage1Live.pin_uris.presence || Stage1Live.pin_uri).map(&:to_s).uniq.sort
      unless kb == Stage1Live::KB && values == expected
        raise Rag::LocalPassLedger::Stop, "pin_uri_differs expected=#{expected.inspect} observed=#{values.inspect} kb=#{kb}"
      end

      Rag::LocalPassLedger.protect!(
        operation: "retrieve", model_id: "read-only-kb", input_tokens: 0, output_tokens: 0
      ) { super }
    end

    def rerank(params, options = {})
      body = params.to_s
      raise Rag::LocalPassLedger::Stop, "rerank_model" unless body.include?(Stage1Live::RERANK)

      Rag::LocalPassLedger.protect!(
        operation: "rerank", model_id: Stage1Live::RERANK,
        input_tokens: Rag::LocalPassLedger.text_chars(params), output_tokens: 0
      ) { super }
    end

    def retrieve_and_generate(...)
      raise Rag::LocalPassLedger::Stop, "retrieve_and_generate_blocked"
    end

    def retrieve_and_generate_stream(...)
      raise Rag::LocalPassLedger::Stop, "retrieve_and_generate_blocked"
    end
  end

  # The SDK attempt flag does not stop AuroraColdStartRetry. The previous
  # T12 runner keeps one physical Retrieve.
  module SingleRetrieve
    def with_retry(error_classes:, on_retry: nil)
      yield
    end
  end

  module TokenTap
    def settle_usage!(response, model_id:)
      Stage1Live.remember_usage(model_id, response)
      super
    end
  end

  class << self
    attr_reader :usage
    attr_accessor :pin_uri, :pin_uris

    def run
      raise Halt, "STAGE1_LIVE_CONFIRM=1 is required" unless ENV["STAGE1_LIVE_CONFIRM"] == "1"
      raise Halt, "FIELD_CHECK_OUTCOME must be true for this process" unless Rag::CheckOutcomeFlag.enabled?
      raise Halt, "shared session is enabled" if SharedSession::ENABLED
      raise Halt, "development boot required" unless Rails.env.development?

      use_database!
      raise Halt, "not a local database" unless Rag::LocalPassLedger.local_process?
      raise Halt, "Anthropic credential missing" if anthropic_key.blank?

      @armed = false
      @usage = []
      @cases = JSON.parse(FIXTURE.read).fetch("cases")
      @account = Account.find_by!(id: 3, slug: "danebo-pilot-elevator")
      @user = replay_user
      @run_dir = ROOT.join(Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
      FileUtils.mkdir_p(@run_dir)
      File.write(@run_dir.join("candidate.json"), JSON.pretty_generate(candidate))
      guard_production_bucket!
      arm!
      return run_full_otis if full_mode?

      probe = probe_thyssen_filter!
      File.write(@run_dir.join("probe.json"), JSON.pretty_generate(probe))
      puts JSON.generate(probe.except("filter"))
      raise Halt.new("thyssen retrieve probe failed", probe) unless probe["accepted"]

      @results = []
      @abandoned_usage = []
      failed = {}
      otis_probe = nil
      selected_turns.each do |case_id, number, label|
        dependency = DEPENDS_ON[label]
        if dependency && failed[dependency]
          summary = {
            "label" => label, "accepted" => false, "reason" => "depends_on_failed_turn",
            "depends_on" => dependency,
            "first_divergence" => "#{label} was not sent because #{dependency} failed"
          }
          write_turn(@run_dir.join(label.downcase.tr(" ", "-")), summary)
          @results << summary
          next
        end
        if case_id == "29" && otis_probe.nil?
          otis_probe = probe_documents!(identity_documents(OTIS), @cases.fetch("29").fetch("turns").fetch(4).fetch("message"))
          File.write(@run_dir.join("otis_probe.json"), JSON.pretty_generate(otis_probe))
          puts JSON.generate(otis_probe.except("filter"))
        end
        summary = run_turn(case_id, number, label)
        failed[label] = true unless summary["accepted"]
        @results << summary
      end
      record_spend
      @results.all? { |row| row["accepted"] } ? 0 : 2
    rescue Halt, Rag::LocalPassLedger::Stop, StandardError => error
      write_failure(error)
      warn "#{error.class}: #{error.message}"
      2
    end

    def remember_usage(model_id, response)
      usage_value = if response.is_a?(Hash)
        response["usage"] || response[:usage]
      elsif response.respond_to?(:usage)
        response.usage
      end
      return unless usage_value

      read = ->(name) {
        if usage_value.is_a?(Hash)
          usage_value[name] || usage_value[name.to_s]
        elsif usage_value.respond_to?(name)
          usage_value.public_send(name)
        end
      }
      @usage << {
        "model_id" => model_id.to_s,
        "input_tokens" => read.call(:input_tokens).to_i,
        "output_tokens" => read.call(:output_tokens).to_i,
        "cache_read_input_tokens" => read.call(:cache_read_input_tokens).to_i,
        "cache_creation_input_tokens" => read.call(:cache_creation_input_tokens).to_i
      }
    end

    private

    def one(case_id, number, label)
      directory = @run_dir.join(label.downcase.tr(" ", "-"))
      FileUtils.mkdir_p(directory)
      Rag::LocalPassLedger.reset!
      @usage = []
      kase = case_for(case_id, number).reload
      opened = Rag::ActiveEpisode.parse(kase.technical_state.except("case_evidence"))
      question = @cases.fetch(case_id).fetch("turns").fetch(number - 1).fetch("message")
      capture_turn(label, directory, opened) { send_turn(kase, question, label, directory) }
    end

    # One captured turn: the capture, the usage and ledger totals, the verdict
    # and the written evidence. An error is a failed turn, not a crash.
    def capture_turn(label, directory, opened)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      summary = nil
      events = nil
      begin
        Rag::ValidationCapture.capture do |bucket|
          events = bucket
          summary = yield
        end
      ensure
        if events
          document = Rag::ValidationCapture.export_capture(events, directory, run_id: "stage1-#{label}")
          File.write(directory.join("capture.json"), JSON.generate(document))
          File.write(directory.join("stages.json"), JSON.pretty_generate(Array(events).map { |event|
            event.slice("sequence", "kind", "operation", "result", "error_class")
          }))
        end
      end
      summary["pending_before"] = opened&.pending_question
      summary["latency_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      summary["input_tokens"] = @usage.sum { |row| row["input_tokens"] }
      summary["output_tokens"] = @usage.sum { |row| row["output_tokens"] }
      summary["usage"] = @usage
      summary["ledger"] = Rag::LocalPassLedger.snapshot
      summary["stages"] = Array(events).map { |event| event.values_at("sequence", "kind", "operation", "result").compact }
      summary["generator_sources"] = generator_sources(events)
      verdict = judge(label, opened, summary)
      summary.merge!(verdict)
      write_turn(directory, summary)
      summary
    rescue StandardError => raised
      summary ||= { "label" => label, "accepted" => false }
      summary["error"] = "#{raised.class}: #{raised.message}"
      summary["accepted"] = false
      summary["reason"] = "execution_error"
      summary["first_divergence"] = app_frame(raised)
      write_turn(directory, summary) if directory
      summary
    end

    def run_turn(case_id, number, label)
      4.times do |attempt|
        begin
          return one(case_id, number, label)
        rescue Rag::LocalPassLedger::Stop => error
          directory = @run_dir.join(label.downcase.tr(" ", "-"))
          blocked = budget_blocked?(directory)
          @abandoned_usage.concat(Array(@usage))
          archive_attempt!(directory, attempt + 1)
          if blocked && attempt < 3
            raise_budget!(blocked)
            next
          end
          summary = {
            "label" => label, "accepted" => false, "reason" => "execution_error",
            "error" => "#{error.class}: #{error.message}", "first_divergence" => app_frame(error)
          }
          write_turn(directory, summary)
          return summary
        end
      end
    end

    def send_turn(kase, question, label, directory)
      bind_pins!(kase)
      focus = FieldCases::Pins.resolve(kase.document_focus, account: @account)
      raise Halt, "pins did not resolve" unless focus

      context = FieldCases::TurnContext.build(kase, focus: focus)
      raise Halt, "turn context missing" unless context

      admission = FieldCases::AdmitTurn.call(
        account: @account, user: @user, field_case_id: kase.id,
        client_submission_id: SecureRandom.uuid, message: question, locale: "es"
      )
      raise Halt, "admission #{admission.status}: #{admission.error}" unless admission.status == :ok

      turn = FieldCases::TextTurn.new(admission, account: @account, user: @user)
      cid = admission.turn.correlation_id
      Rag::ValidationCapture.bind(run_id: "stage1-live", correlation_root: cid, field_case_id: kase.id, field_turn_id: admission.turn.id)
      Rag::ValidationCapture.correlation = cid
      episode_turn = context.record_user_turn!(question, user_id: @user.id, correlation_id: cid, locale: :es)
      result = QueryHost.new(@account, @user).call(
        question,
        session_context: SessionContextBuilder.build(context),
        conv_session: context,
        entity_s3_uris: SessionContextBuilder.entity_s3_uris(context),
        account: @account, user_id: @user.id, correlation_id: cid,
        episode_turn: episode_turn, output_channel: :web, apply_photo_continuity: false
      )
      raise Halt, "query failed: #{result.error_type}" unless result.success?

      context.stamp_user_retrieval_query!(cid, result.effective_question || question)
      context.capture_pending!(result)
      written = Rag::CompanionCaseWrite.persist!(
        context, result, user_id: @user.id, expected_episode_id: context.live_episode_id,
        focus_ids: context.focus_document_ids
      )
      raise Halt, "case write conflict" if Rag::CompanionCaseWrite.conflict?(written)

      citations = Bedrock::CitationProcessor.new.transport_references(result.citations)
      closed = turn.complete(
        { answer: result.answer, citations: citations,
          provenance_segments: Rag::ProvenanceSegmenter.call(answer: result.answer, citations: citations) },
        context, prompt_reply: result.history_answer
      )
      raise Halt, "close #{closed.status}: #{closed.error}" unless closed.status == :ok

      summarize(kase, cid, focus, directory, label)
    end

    # The numbered sources the generator received, by citation number.
    def generator_sources(events)
      row = Array(events).reverse.find { |event| event["kind"] == "generator_evidence" }
      Array(row && row["rows"]).to_h { |item| [ item["n"].to_s, item["text"].to_s ] }
    end

    # The state after reload and the turn as it was stored: what the rubric
    # and the evidence read. Photo and text turns end the same way.
    def summarize(kase, cid, focus, directory, label)
      reloaded = kase.reload
      episode = Rag::ActiveEpisode.parse(reloaded.technical_state.except("case_evidence"))
      session = FieldCases::TurnContext.build(reloaded, focus: focus)
      outcome = Rag::CheckOutcome.current(episode: episode, session: session, correlation_id: cid)
      persisted = FieldTurn.find_by!(correlation_id: cid)
      published = persisted.response.to_h.fetch("published_text", "")
      File.write(directory.join("published.txt"), published)
      File.write(directory.join("reloaded_state.json"), JSON.pretty_generate(episode.to_h))
      citations = Array(persisted.response.to_h["citations"]).map { |item| item.to_h.deep_stringify_keys }
      photo_turns = reloaded.field_turns.where(kind: "photo").order(:sequence).includes(:field_photo).map { |turn|
        { "sequence" => turn.sequence, "correlation_id" => turn.correlation_id, "sha256" => turn.field_photo&.sha256,
          "visual_observation" => turn.field_photo&.visual_observation }
      }
      active = photo_turns.last
      {
        "label" => label, "field_case_id" => reloaded.id, "correlation_id" => cid,
        "published" => published, "turn_status" => persisted.status, "failure" => persisted.failure_code,
        "pending" => episode.pending_question, "part_states" => part_states(episode),
        "checks" => episode.checks, "replies" => episode.replies,
        "asked_again" => asked_question(published),
        "citations" => citations,
        "identifiers" => episode.identifiers,
        "photo_turns" => photo_turns.map { |row| row.slice("sequence", "correlation_id", "sha256") },
        "visible_text" => Array(active && active.dig("visual_observation", "visible_text")),
        "observations" => episode_texts(episode.observations, cid, same: true),
        "earlier_observations" => episode_texts(episode.observations, cid, same: false),
        "all_observations" => Array(episode.observations).map { |row| row["text"].to_s },
        "earlier_checks" => Array(episode.checks).reject { |row| row["correlation_id"] == cid },
        "outcome" => outcome.to_trace, "outcome_lines" => outcome.lines,
        "photo" => session.case_photo_context.status
      }
    end

    def judge(label, opened, summary)
      # The first turn of a new case has no episode before it.
      pending = opened&.pending_question.is_a?(Hash) ? opened.pending_question : {}
      part = Array(pending["parts"]).find { |item| item.is_a?(Hash) && item["role"] != "declared" }
      part_id = part&.fetch("id", nil)
      question = pending["question"].to_s
      state = summary.dig("part_states", part_id)
      asked = summary["asked_again"].to_s
      same = asked.present? && same_question?(asked, question)
      blank_key = blank_document_key?(summary["pending"])
      expected, observed, ok = case label
      when "Thyssen T11"
        [
          "p8 complete, a new pending question, and no repeat of ¿Sigue marcando EA?",
          "p8=#{summary.dig('part_states', 'p8')} pending=#{summary.dig('pending', 'question')} asked=#{asked}",
          summary.dig("part_states", "p8") == "complete" && summary.dig("pending", "question").present? &&
            !same_question?(summary.dig("pending", "question"), "¿Sigue marcando EA?") && !same && !blank_key
        ]
      when "Thyssen T12"
        [
          "#{pending['id']}.#{part_id} complete and the published question is not that check",
          "#{part_id}=#{state} asked=#{asked}",
          part_id.present? && state == "complete" && !same && !blank_key
        ]
      when "Otis T1", "Otis T2", "Otis T3", "Otis T4"
        names = OTIS.map { |_uid, key| File.basename(key, ".pdf") }
        rubric = OtisRubric.public_send(label.split.last.downcase, summary, allowed_documents: names)
        summary["rubric"] = rubric
        [ "#{label} rubric (document, Al recargar)", "failed=#{rubric['failed'].inspect} asked=#{asked.inspect}", rubric["ok"] && summary["turn_status"] == "completed" ]
      when "Otis T5", "Otis T6"
        summary["opened_pending"] = pending.presence
        summary["repeats_open_question"] = same
        names = OTIS.map { |_uid, key| File.basename(key, ".pdf") }
        rubric = label == "Otis T5" ? OtisRubric.t5(summary, allowed_documents: names) : OtisRubric.t6(summary, allowed_documents: names)
        summary["rubric"] = rubric
        [
          label == "Otis T5" ? "T5 rubric: unverified DCL/DFC kept, result limited to the test, residue named as likely, citations and pending source preserved" :
                               "T6 rubric: DFC reading recorded and linked, DCL recorded unverified and not asked, state kept after reload",
          "failed=#{rubric['failed'].inspect} pending=#{summary['pending'].to_json} asked=#{asked.inspect} blank_key=#{blank_key}",
          rubric["ok"]
        ]
      else
        [ label, label, false ]
      end
      {
        "accepted" => ok, "expected" => expected, "observed" => observed,
        "reason" => (ok ? "accepted" : "acceptance"),
        "first_divergence" => (ok ? nil : "#{label}: expected #{expected}. observed #{observed}")
      }
    end

    def case_for(case_id, number)
      return @live_case if @live_case && @live_label == case_id && number > @live_number

      turns = @cases.fetch(case_id).fetch("turns")
      state = turns.fetch(number - 1).fetch("before").deep_dup
      prior = turns.first(number - 1)
      raise Halt, "fixture checkpoint missing" if state.blank?

      photos = restore_photos(prior)
      state = rewrite_photos(state, photos)
      stale = FieldCase.find_by(account: @account, user: @user, episode_id: state.fetch("episode_id"))
      if stale&.field_turns&.exists?(status: "pending")
        preserve_pending_case!(stale)
      elsif stale
        stale.field_turns.delete_all
        stale.destroy!
      end

      documents = documents_for(case_id)
      focus = documents.map { |document| { "kb_document_id" => document.id, "document_uid" => document.document_uid } }
      kase = FieldCase.create!(
        account: @account, user: @user, episode_id: state.fetch("episode_id"),
        opened_at: state.fetch("opened_at"), last_activity_at: state.fetch("updated_at"),
        document_focus: focus, last_sequence: prior.size, state_revision: prior.size,
        technical_state: state
      )
      prior.each_with_index do |turn, index|
        photo_id = photos[turn.dig("attachment", "field_photo_id")]
        published = turn.fetch("published")
        kase.field_turns.create!(
          sequence: index + 1,
          kind: (turn.fetch("correlation_id").start_with?("photo:") ? "photo" : "text"),
          correlation_id: turn.fetch("correlation_id"),
          field_photo_id: photo_id,
          client_submission_id: "restore-#{index + 1}",
          input_digest: FieldCases::Payload.digest(message: turn.fetch("message"), attachment_sha256: turn.dig("attachment", "sha256")),
          execution_token: SecureRandom.uuid, attempt: 1,
          base_state_revision: index, result_state_revision: index + 1,
          locale: "es", message: turn.fetch("message"), status: "completed", phase: "published",
          admitted_at: Time.iso8601(turn.fetch("at")), completed_at: Time.iso8601(turn.fetch("at")),
          attachment: (turn["attachment"] || {}).except("href", "field_photo_id"),
          response: { "published_text" => published },
          prompt_reply: published.first(FieldCases::Payload::PROMPT_REPLY_MAX),
          checkpoint: { "v" => 1, "source" => "pilot_2026_11_19", "correlation_id" => turn.fetch("correlation_id") }
        )
      end
      @live_case = kase
      @live_label = case_id
      @live_number = number
      kase
    end

    def restore_photos(turns)
      map = {}
      turns.each do |turn|
        next unless turn.fetch("correlation_id").start_with?("photo:")

        sha = turn.dig("attachment", "sha256")
        raise Halt, "photo attachment missing" if sha.blank?

        observation = FieldPhotoObservation.sanitize(turn["vision"])
        photo = FieldPhoto.find_or_create_by!(account: @account, sha256: sha, storage_scope: "stage1-live") do |row|
          row.user_id = @user.id
          row.s3_key_original = "stage1-live/#{sha}"
          row.content_type = turn.dig("attachment", "content_type").presence || "image/jpeg"
          row.byte_size = turn.dig("attachment", "byte_size").to_i.nonzero? || 1
          row.visual_observation = observation if observation
        end
        map[turn.dig("attachment", "field_photo_id")] = photo.id
      end
      map
    end

    def rewrite_photos(value, map)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          copy[key] = key == "field_photo_id" && map[item] ? map[item] : rewrite_photos(item, map)
        end
      when Array
        value.map { |item| rewrite_photos(item, map) }
      else
        value
      end
    end

    def selected_turns
      catalog = {
        "thyssen-t11" => [ "28", 11, "Thyssen T11" ],
        "thyssen-t12" => [ "28", 12, "Thyssen T12" ],
        "otis-t5" => [ "29", 5, "Otis T5" ],
        "otis-t6" => [ "29", 6, "Otis T6" ]
      }
      ENV.fetch("STAGE1_TURNS", catalog.keys.join(",")).split(",").map { |name| catalog.fetch(name.strip) }
    end

    def guard_production_bucket!
      return if KbDocument::KB_BUCKET == PRODUCTION_BUCKET

      raise Halt.new("knowledge base bucket differs", {
        "accepted" => false,
        "reason" => "bucket",
        "expected_bucket" => PRODUCTION_BUCKET,
        "observed_bucket" => KbDocument::KB_BUCKET,
        "env_bucket" => ENV["KNOWLEDGE_BASE_S3_BUCKET"],
        "difference" => "KbDocument::KB_BUCKET is frozen when the process boots. .env sets smart-deal-dev-kb. " \
          "run_haiku55_http.rb assigns KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination before Puma boots. " \
          "run_stage1_live.rb did not, so the relative Thyssen key was retrieved as s3://smart-deal-dev-kb/..."
      })
    end

    def probe_thyssen_filter!
      document = KbDocument.find_by!(account: @account, document_uid: THYSSEN_UID)
      uri = document.canonical_uri
      self.pin_uri = THYSSEN_URI
      self.pin_uris = [ THYSSEN_URI ]
      report = {
        "expected_uri" => THYSSEN_URI, "observed_uri" => uri,
        "document_uid" => document.document_uid, "s3_key" => document.s3_key,
        "bucket" => KbDocument::KB_BUCKET
      }
      return report.merge("accepted" => false, "reason" => "catalog_uri") if uri != THYSSEN_URI

      rows = thyssen_catalog_rows
      report["catalog_rows"] = rows.map { |row| { "id" => row.id, "document_uid" => row.document_uid, "s3_key" => row.s3_key } }
      unless rows.one? && rows.first.document_uid == THYSSEN_UID
        return report.merge("accepted" => false, "reason" => "catalog_ambiguous")
      end

      message = @cases.fetch("28").fetch("turns").fetch(10).fetch("message")
      service = BedrockRagService.new(account: @account)
      vector = service.build_vector_search_configuration(
        question: message, entity_s3_uris: [ uri ], entity_sources: [],
        number_of_results: 16, reranking: false, apply_page_filter: true
      )
      filter = vector[:filter] || vector["filter"]
      values = filter_values(filter)
      report["filter_uris"] = values.uniq
      return report.merge("accepted" => false, "reason" => "filter") unless values.uniq == [ THYSSEN_URI ]

      response = retrieve_once(service, message, vector)
      rows = Array(response.retrieval_results)
      returned = rows.map { |row|
        metadata = row.metadata.is_a?(Hash) ? row.metadata : {}
        {
          "original_source_uri" => metadata["original_source_uri"].to_s,
          "source_uri" => metadata["x-amz-bedrock-kb-source-uri"].to_s,
          "location_uri" => row.location&.s3_location&.uri.to_s,
          "chars" => row.content&.text.to_s.length
        }
      }
      matched = returned.select { |row| row.values.any? { |value| value.to_s.include?(THYSSEN_KEY) } }
      report.merge(
        "accepted" => matched.any? && matched.all? { |row| row["chars"].positive? },
        "reason" => (matched.any? ? "passages" : "no_passages"),
        "returned" => returned.size,
        "matched" => matched.size,
        "returned_uris" => returned.flat_map { |row| row.values_at("original_source_uri", "source_uri", "location_uri") }.uniq.compact_blank
      )
    rescue Rag::LocalPassLedger::Stop => error
      { "accepted" => false, "reason" => "retrieve_stopped", "difference" => error.message, "expected_uri" => THYSSEN_URI }
    end

    def retrieve_once(service, question, vector)
      Bedrock::AuroraColdStartRetry.with_retry(error_classes: [ Aws::BedrockAgentRuntime::Errors::ServiceError ]) do
        service.instance_variable_get(:@client).retrieve(
          knowledge_base_id: KB,
          retrieval_query: { text: question },
          retrieval_configuration: { vector_search_configuration: vector }
        )
      end
    end

    def filter_values(node, found = [])
      case node
      when Hash
        equals = node[:equals] || node["equals"]
        found << (equals[:value] || equals["value"]).to_s if equals.is_a?(Hash)
        listed = node[:in] || node["in"]
        Array(listed[:value] || listed["value"]).each { |value| found << value.to_s } if listed.is_a?(Hash)
        node.each_value { |value| filter_values(value, found) }
      when Array
        node.each { |value| filter_values(value, found) }
      end
      found
    end
    public :filter_values

    def thyssen_catalog_rows
      KbDocument.where(account: @account, s3_key: [ THYSSEN_KEY, THYSSEN_URI ]).to_a
        .select { |row| row.canonical_uri == THYSSEN_URI }
    end

    def documents_for(case_id)
      if case_id == "28"
        rows = thyssen_catalog_rows
        document = rows.one? ? rows.first : nil
        raise Halt, "thyssen catalog is not the unique fixture pin" unless document&.document_uid == THYSSEN_UID &&
          document.canonical_uri == THYSSEN_URI

        [ document ]
      elsif case_id == "29"
        identity_documents(OTIS)
      else
        PINS.fetch(case_id).map { |key| catalog_document(key) }
      end
    end

    def identity_documents(rows)
      rows.map { |uid, key| identity_document(uid, key) }
    end

    def identity_document(uid, key)
      expected = "s3://#{PRODUCTION_BUCKET}/#{key}"
      document = KbDocument.find_by(account: @account, document_uid: uid) ||
        KbDocument.find_by(account: @account, s3_key: key)
      if document.nil?
        document = KbDocument.create!(
          account: @account, s3_key: key, display_name: File.basename(key, ".pdf"),
          document_uid: uid, knowledge_scope: "tenant_private"
        )
      end
      matches = KbDocument.where(account: @account, s3_key: [ key, expected ]).to_a
        .select { |row| row.canonical_uri == expected }
      raise Halt, "catalog uid #{document.document_uid} is not #{uid}" unless document.document_uid == uid &&
        document.canonical_uri == expected && matches.one? && matches.first.id == document.id

      document
    end

    def probe_documents!(documents, question)
      uris = documents.map(&:canonical_uri)
      self.pin_uris = uris
      self.pin_uri = uris.first
      keys = documents.map { |document| document.s3_key.delete_prefix("s3://#{PRODUCTION_BUCKET}/") }
      service = BedrockRagService.new(account: @account)
      vector = service.build_vector_search_configuration(
        question: question, entity_s3_uris: uris, entity_sources: [],
        number_of_results: 16, reranking: false, apply_page_filter: true
      )
      values = filter_values(vector[:filter]).uniq.sort
      report = { "expected_uris" => uris.sort, "filter_uris" => values, "documents" => documents.map { |document|
        { "id" => document.id, "document_uid" => document.document_uid, "s3_key" => document.s3_key }
      } }
      return report.merge("accepted" => false, "reason" => "filter") unless values == uris.sort

      response = retrieve_once(service, question, vector)
      returned = Array(response.retrieval_results).map { |row|
        metadata = row.metadata.is_a?(Hash) ? row.metadata : {}
        {
          "original_source_uri" => metadata["original_source_uri"].to_s,
          "source_uri" => metadata["x-amz-bedrock-kb-source-uri"].to_s,
          "location_uri" => row.location&.s3_location&.uri.to_s,
          "chars" => row.content&.text.to_s.length
        }
      }
      matched = returned.select { |row| keys.any? { |key| row.values.any? { |value| value.to_s.include?(key) } } }
      report.merge(
        "accepted" => matched.any? && matched.all? { |row| row["chars"].positive? },
        "reason" => (matched.any? ? "passages" : "no_passages"),
        "returned" => returned.size, "matched" => matched.size,
        "returned_uris" => returned.flat_map { |row| row.values_at("original_source_uri", "source_uri", "location_uri") }.uniq.compact_blank
      )
    rescue Rag::LocalPassLedger::Stop => error
      { "accepted" => false, "reason" => "retrieve_stopped", "difference" => error.message, "expected_uris" => uris }
    end

    def catalog_document(key)
      found = KbDocument.find_by(account: @account, s3_key: key)
      return found if found

      KbDocument.create!(
        account: @account, s3_key: key, display_name: File.basename(key, ".pdf"),
        document_uid: SecureRandom.uuid, knowledge_scope: "tenant_private"
      )
    end

    def replay_user
      User.find_or_create_by!(account: @account, email: "stage1-live@danebo.local") do |user|
        user.password = SecureRandom.hex(24)
      end
    end

    def use_database!
      config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(database: DATABASE)
      ActiveRecord::Base.establish_connection(config)
      raise Halt, "field_cases is not in #{DATABASE}" unless ActiveRecord::Base.connection.data_source_exists?("field_cases")
    end

    def arm!
      return if @armed

      ENV["AWS_MAX_ATTEMPTS"] = "1"
      ENV["AWS_RETRY_MODE"] = "standard"
      ENV["AWS_EC2_METADATA_DISABLED"] = "true"
      ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = "1"
      ENV["BEDROCK_INFERENCE"] = "blocked"
      ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = KB
      ENV["RAG_COMPANION_GENERATION"] = "direct"
      ENV["COMPANION_DIRECT_PROVIDER"] = "anthropic"
      ENV["COMPANION_DIRECT_MODEL_ID"] = "claude-haiku-5-5"
      ENV["COMPANION_DIRECT_MAX_TOKENS"] = "4000"
      ENV["RAG_LOCAL_PASS_GUARD"] = "1"
      ENV["RAG_LOCAL_PASS_CALL_CAP"] = CALLS_PER_TURN.to_s
      ENV["RAG_LOCAL_PASS_ALLOWED_CALLS"] = [
        "converse@#{MODEL}", "converse_message@#{MODEL}", "retrieve@read-only-kb", "rerank@#{RERANK}"
      ].join(",")
      ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
      ENV["RAG_COMPANION_TURN"] = "1"
      ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
      if full_mode?
        ENV["PHOTO_QUESTION_RAG_ENABLED"] = "true"
        ENV["RAG_PHOTO_LOCAL_STORE"] = ROOT.join("local_field_photos").to_s
        ENV["RAG_LOCAL_PASS_ALLOWED_CALLS"] += ",#{Rag::GuardedPhotoVision::OPERATION}@#{Rag::GuardedPhotoVision::TRACKING_MODEL}"
      end
      interpreter = Rag::LocalPassLedger.price(MODEL, Rag::TurnInterpreter::PROMPT.length + 8_000, Rag::TurnInterpreter::MAX_TOKENS)
      generator = Rag::LocalPassLedger.price(MODEL, Rag::CompanionDirectAnswer::SYSTEM_PROMPT.length + 48_000, 4_000)
      rerank = Rag::LocalPassLedger.price(RERANK, RERANK_CHARS, 0)
      ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = ((interpreter + generator + rerank) * 2).to_s("F")
      Rag::LocalPassLedger.reset!
      Rag::LocalPassLedger.reset_local_process!
      raise Halt, "ledger not armed: #{Rag::LocalPassLedger.missing_requirements.join(',')}" unless Rag::LocalPassLedger.armed?

      Aws::BedrockAgentRuntime::Client.prepend(ReadOnlyKb)
      Rag::LocalPassLedger.singleton_class.prepend(TokenTap)
      @armed = true
    end

    def anthropic_key
      ENV["ANTHROPIC_API_KEY"].presence || Rails.application.credentials.dig(:anthropic, :api_key)
    end

    def candidate
      root = Rails.root.to_s
      diff = IO.popen([ "git", "-C", root, "diff", "HEAD", "--", "app", "test", "docs" ], &:read)
      untracked = IO.popen([ "git", "-C", root, "ls-files", "--others", "--exclude-standard", "--", "app", "test" ], &:read)
      {
        "base" => IO.popen([ "git", "-C", root, "rev-parse", "HEAD" ], &:read).strip,
        "commit" => nil,
        "diff_sha256" => Digest::SHA256.hexdigest(diff.to_s + untracked.to_s),
        "note" => "No commit. The candidate is the uncommitted working tree on the base commit."
      }
    end

    def full_mode?
      ENV["STAGE1_FULL"] == "otis"
    end

    PHOTO_SOURCES = PhotoPrep::SOURCES.transform_values { |row| row.fetch("file") }.freeze

    # T1 to T6 of case 29 on a new case. Every turn is sent through the real
    # admission and reads the case the previous turn closed. A turn that did
    # not complete stops the run: the next one would not start from its state.
    def run_full_otis
      documents = identity_documents(OTIS)
      turns = @cases.fetch("29").fetch("turns")
      probe = probe_documents!(documents, turns.fetch(4).fetch("message"))
      File.write(@run_dir.join("otis_probe.json"), JSON.pretty_generate(probe))
      puts JSON.generate(probe.except("filter"))
      raise Halt.new("otis retrieve probe failed", probe) unless probe["accepted"]

      ActiveJob::Base.queue_adapter = :inline
      @results = []
      @abandoned_usage = []
      @vision_files = []
      @full_case = nil
      File.write(@run_dir.join("photos.json"), JSON.pretty_generate(prepare_photos))
      (1..6).each do |number|
        label = "Otis T#{number}"
        summary = full_turn(number, label, turns.fetch(number - 1).fetch("message"), documents)
        @results << summary
        break unless summary["turn_status"] == "completed"
      end
      record_spend
      @results.size == 6 && @results.all? { |row| row["accepted"] } ? 0 : 2
    end

    def full_turn(number, label, message, documents)
      directory = @run_dir.join(label.downcase.tr(" ", "-"))
      FileUtils.mkdir_p(directory)
      Rag::LocalPassLedger.reset!
      @usage = []
      opened = @full_case && Rag::ActiveEpisode.parse(@full_case.reload.technical_state.except("case_evidence"))
      capture_turn(label, directory, opened) do
        if PHOTO_SOURCES.key?(number)
          send_photo_turn(number, label, message, directory, documents)
        else
          send_turn(@full_case.reload, message, label, directory)
        end
      end
    end

    # The supplied images (kept in test/fixtures/files/field_companion/otis_case29),
    # prepared by PhotoPrep. STAGE1_PHOTO_T1 / STAGE1_PHOTO_T3 replace a source
    # and are recorded as an override with that file's own hash.
    def prepare_photos
      FileUtils.mkdir_p(@run_dir.join("photos"))
      @prepared = {}
      PHOTO_SOURCES.each_with_object({}) do |(number, fixture), report|
        override = ENV["STAGE1_PHOTO_T#{number}"]
        source = override.presence || fixture
        raise Halt, "photo T#{number} missing: #{source}" unless File.file?(source)

        path = @run_dir.join("photos", "otis-t#{number}.jpg")
        done = PhotoPrep.prepare(source, path, expected_sha256: (override ? nil : PhotoPrep::SOURCES.fetch(number).fetch("sha256")))
        @prepared[number] = path
        expected = PhotoPrep::PREPARED_SHA256.fetch(number)
        report["T#{number}"] = done.merge(
          "override" => override.present?, "matches_run_20261120T012019Z" => done["prepared_sha256"] == expected,
          "recorded_prepared_sha256" => expected
        )
      end.merge("preparation" => PhotoPrep.parameters)
    end

    def send_photo_turn(number, label, message, directory, documents)
      path = @prepared.fetch(number)
      spend = @run_dir.join("vision-spend-t#{number}.json")
      Rag::GuardedPhotoVision.assignment(spend).admit_execution!(
        id: Rag::GuardedPhotoVision::GRANT_ID, calls: 1, cost_usd: Rag::GuardedPhotoVision.ceiling
      )
      ENV[Rag::GuardedPhotoVision::PATH_ENV] = spend.to_s
      @vision_files << spend
      Rag::ValidationCapture.bind(run_id: "stage1-live")
      image = { binary: File.binread(path), media_type: "image/jpeg", filename: path.basename.to_s }
      arguments = { account: @account, user: @user, submission_id: SecureRandom.uuid, message: message, image: image, locale: "es" }
      admission = if @full_case
        bind_pins!(@full_case)
        FieldCases::PhotoTurn.submit(**arguments, field_case_id: @full_case.id, creation_key: nil)
      else
        FieldCases::PhotoTurn.submit(**arguments, field_case_id: nil, creation_key: SecureRandom.uuid, document_ids: documents.map(&:id))
      end
      raise Halt, "photo admission #{admission.status}: #{admission.error}" unless admission.respond_to?(:turn) && admission.turn

      @full_case = admission.field_case.reload
      focus = FieldCases::Pins.resolve(@full_case.document_focus, account: @account)
      raise Halt, "pins did not resolve" unless focus

      summarize(@full_case, admission.turn.correlation_id, focus, directory, label)
    end

    def episode_texts(rows, cid, same:)
      Array(rows).select { |row| (row["correlation_id"] == cid) == same }.map { |row| row["text"].to_s }
    end

    def part_states(episode)
      ids = Array(episode.replies).filter_map { |reply| reply["p"] }.uniq
      ids.index_with { |part_id| Rag::AnswerContract.part_state(episode, part_id) }
    end

    def asked_question(text)
      Rag::PendingQuestion.question_in(text.to_s, locale: :es)
    end

    def same_question?(left, right)
      normalize(left) == normalize(right) && normalize(left).present?
    end

    def normalize(text)
      text.to_s.downcase.gsub(/[¿?¡!.,:;]/, " ").gsub(/\s+/, " ").strip
    end

    def blank_document_key?(pending)
      Array(pending.is_a?(Hash) ? pending["targets"] : nil).any? { |target| target.is_a?(Hash) && target["document_key"] == "" }
    end

    def write_turn(directory, summary)
      FileUtils.mkdir_p(directory)
      File.write(directory.join("summary.json"), JSON.pretty_generate(summary))
      unless summary["accepted"]
        File.write(directory.join("divergence.json"), JSON.pretty_generate(summary.slice(
          "label", "accepted", "reason", "expected", "observed", "first_divergence",
          "correlation_id", "error", "depends_on"
        )))
      end
      puts JSON.generate(summary.except("published", "checks", "replies", "outcome_lines", "outcome"))
    end

    def bind_pins!(kase)
      ids = Array(kase.document_focus).filter_map { |row| row["kb_document_id"] }
      uris = KbDocument.where(id: ids).map(&:canonical_uri)
      self.pin_uris = uris
      self.pin_uri = uris.first
      uris
    end

    def preserve_pending_case!(kase)
      owner = User.find_or_create_by!(account: @account, email: "stage1-pending-#{kase.id}@danebo.local") do |user|
        user.password = SecureRandom.hex(24)
      end
      kase.field_turns.where.not(status: "pending").find_each do |turn|
        kind = turn.correlation_id.split(":", 2).first
        checkpoint = (turn.checkpoint || {}).merge("evidence_correlation_id" => turn.correlation_id)
        turn.update!(correlation_id: "#{kind}:#{SecureRandom.uuid}", checkpoint: checkpoint)
      end
      kase.update!(user: owner)
    end

    def budget_blocked?(directory)
      capture = directory.join("capture.json")
      return nil unless capture.exist?

      event = JSON.parse(capture.read).fetch("events", []).reverse.find { |row| row["result"] == "blocked" }
      event && event["ceiling_usd"]
    end

    def archive_attempt!(directory, attempt)
      return unless directory.exist?

      FileUtils.mv(directory, directory.dirname.join("#{directory.basename}-blocked-#{attempt}"))
    end

    def raise_budget!(ceiling)
      current = BigDecimal(ENV.fetch("RAG_LOCAL_PASS_COST_CAP_USD"))
      needed = BigDecimal(ceiling.to_s) * 2
      ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = [ current, needed ].max.to_s("F")
      ENV["RAG_LOCAL_PASS_CALL_CAP"] = (Rag::LocalPassLedger.call_cap.to_i + 4).to_s
    end

    def record_spend
      rows = Array(@results)
      priced = (rows.flat_map { |row| Array(row["usage"]) } + Array(@abandoned_usage)).map { |usage|
        pricing = BedrockQuery.new(model_id: usage["model_id"], input_tokens: 1, output_tokens: 0).pricing_for(usage["model_id"])
        usd = (usage["input_tokens"].to_i / 1000.0) * pricing[:input].to_f +
          (usage["output_tokens"].to_i / 1000.0) * pricing[:output].to_f +
          (usage["cache_read_input_tokens"].to_i / 1000.0) * pricing.fetch(:cache_read, 0).to_f +
          (usage["cache_creation_input_tokens"].to_i / 1000.0) * pricing.fetch(:cache_creation, 0).to_f
        usage.merge("usd" => BigDecimal(usd.round(6).to_s).to_s("F"))
      }
      vision = Array(@vision_files).sum(BigDecimal("0")) { |file|
        file.exist? ? BigDecimal(JSON.parse(file.read).fetch("committed", "0").to_s) : BigDecimal("0")
      }
      reranks = rows.sum { |row| Array(row["stages"]).count { |stage| stage[1] == "local_pass_ledger" && stage[2] == "rerank" && stage[3] == "admitted" } }
      spend = {
        "input_tokens" => priced.sum { |row| row["input_tokens"].to_i },
        "output_tokens" => priced.sum { |row| row["output_tokens"].to_i },
        "generation_usd" => priced.sum { |row| BigDecimal(row["usd"]) }.to_s("F"),
        "rerank_calls" => reranks,
        "rerank_usd" => (RERANK_USD * reranks).to_s("F"),
        "vision_usd" => vision.to_s("F"),
        "total_usd" => (priced.sum { |row| BigDecimal(row["usd"]) } + (RERANK_USD * reranks) + vision).to_s("F"),
        "cost_cap_usd" => ENV["RAG_LOCAL_PASS_COST_CAP_USD"],
        "calls" => priced,
        "turns" => rows.map { |row| row.slice("label", "accepted", "reason", "correlation_id", "input_tokens", "output_tokens", "latency_ms", "depends_on") }
      }
      File.write(@run_dir.join("spend.json"), JSON.pretty_generate(spend))
      puts JSON.generate(spend.except("calls"))
    end

    def write_failure(error)
      return unless @run_dir

      details = error.is_a?(Halt) ? error.details : { "error" => "#{error.class}: #{error.message}", "first_divergence" => app_frame(error) }
      File.write(@run_dir.join("failure.json"), JSON.pretty_generate(details.merge("reproduce" => reproduce)))
    end

    def app_frame(error)
      frame = Array(error.backtrace).find { |line| line.include?("/smart_deal/") }
      "#{error.class}: #{error.message} at #{frame}"
    end

    def reproduce
      "KNOWLEDGE_BASE_S3_BUCKET=#{PRODUCTION_BUCKET} SHARED_SESSION_ENABLED=false FIELD_CHECK_OUTCOME=true STAGE1_LIVE_CONFIRM=1 STAGE1_TURNS=thyssen-t11 STAGE1_DATABASE=#{DATABASE} bin/rails runner script/field_companion/run_stage1_live.rb"
    end
  end
end

# A test loads the file for its pure methods with Stage1Live::NO_RUN defined.
exit Stage1Live.run unless defined?(Stage1Live::NO_RUN)
