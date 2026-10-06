# frozen_string_literal: true

# Deterministic longitudinal baseline. Drives the web turn path and stubs
# Bedrock at the F1 seams. It does not change product behavior, and it does
# not score stubbed assistant text as usefulness.
require "digest"
require "fileutils"
require "json"
require "yaml"
require "stringio"
require "ostruct"

module FieldCompanion
  module LongitudinalJourneys
    class LiveRefused < StandardError; end

    FIXTURE = Rails.root.join("test/fixtures/files/field_companion/longitudinal_journeys.yml")
    CHUNK_PATH = Rails.root.join("test/fixtures/files/elemont/chunk_p1_2_current.txt")
    STUB_ANSWER = "STUB_ANSWER"
    FLAGS = {
      "HAIKU_QUERY_ANALYSIS_MODE" => "owner",
      "RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED" => "true",
      "FIELD_COMPANION_EPISODE_ENABLED" => "true",
      "FIELD_COMPANION_TURN_ENABLED" => "true",
      "DOCUMENT_IDENTITY_SCOPE_ENABLED" => "true",
      "SHARED_SESSION_ENABLED" => "false",
      "PHOTO_QUESTION_RAG_ENABLED" => "true",
      "BEDROCK_KNOWLEDGE_BASE_ID" => "mvp-journey-stub",
      "BEDROCK_MODEL_ID" => "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    }.freeze
    UNSET_FLAGS = %w[RAG_EPISODE_SCOPE_ENABLED RAG_THREAD_MENU_ENABLED].freeze
    PRIOR_CASE = [ "puerta 1 no termina de cerrar", "imán no magnetiza", "código 18", "guía de la puerta", "código 8" ].freeze

    class << self
      def run!(account:, user:, out_dir: Rails.root.join("tmp/mvp_continuity/f1"))
        refuse_live!
        Runner.new(account: account, user: user, out_dir: out_dir).run
      end

      def evaluate(turns, l3: [])
        Score.evaluate(turns, l3: l3)
      end

      def refuse_live!
        return unless ENV["MVP_JOURNEY_LIVE"] == "1"

        cap = ENV["MVP_JOURNEY_SPEND_CAP"].to_s.strip
        ledger = ENV["MVP_JOURNEY_LEDGER"].to_s.strip
        if cap.empty? || ledger.empty?
          raise LiveRefused, "refusing live mode without MVP_JOURNEY_SPEND_CAP and a ledger path"
        end

        raise LiveRefused, "F1 does not execute live mode"
      end
    end

    # Scores recorded turns. A specific absence cause is emitted only when
    # the snapshots show the evidence for it.
    module Score
      module_function

      def evaluate(turns, l3: [])
        rows = Array(turns)
        absences = []
        faults = structural_faults(rows)
        rows.each_with_index do |turn, index|
          Array(turn["expect"]).each do |item|
            miss = item_miss(rows, index, item)
            next if miss.nil?

            faults << miss["fault"]
            absences << miss.merge("id" => turn["id"], "journey" => turn["journey"], "checkpoint" => turn["checkpoint"], "fact" => item["id"])
          end
          contract = contract_miss(turn)
          if contract
            faults << contract["fault"]
            absences << contract.merge("id" => turn["id"], "journey" => turn["journey"], "checkpoint" => turn["checkpoint"], "fact" => "contract")
          end
          ellipse = elliptical_miss(turn)
          if ellipse
            faults << ellipse["fault"]
            absences << ellipse.merge("id" => turn["id"], "journey" => turn["journey"], "checkpoint" => turn["checkpoint"], "fact" => "elliptical")
          end
        end
        {
          "faults" => faults.uniq,
          "absences" => absences,
          "L1" => level_verdict(rows, absences, faults, "L1"),
          "L2" => level_verdict(rows, absences, faults, "L2"),
          "L3" => l3_verdict(l3)
        }
      end

      def structural_faults(turns)
        faults = []
        turns.group_by { |turn| turn["journey"] }.each_value do |rows|
          scoped = rows.select { |turn| %w[L1 L2].include?(turn["checkpoint"]) }
          ids = scoped.filter_map { |turn| turn["episode_id"] }
          faults << "wrong_episode_id" if ids.uniq.size > 1
          scoped.each do |turn|
            faults << "episode_opened_at_turn_count" if turn["n"] == 11 && turn["episode_changed"]
            faults << "episode_opened_at_history_eviction" if turn["first_eviction"] && turn["episode_changed"]
            faults << "repeated_critical_request" if turn["repeated_critical_request"]
            faults << "foreign_applicability" if turn["foreign_applicability"]
            faults << "stale_write" if turn["stale_mutated"]
          end
        end
        faults
      end

      def item_miss(turns, index, item)
        check(turns, index, item)["miss"]
      end

      # state_and_generation is the historical contract. state_only checks the
      # episode and reports generator as n/a. It does not count as a generator pass.
      def check(turns, index, item)
        turn = turns[index]
        in_state = state_has?(turn["state"], item)
        if item["expectation_scope"].to_s == "state_only"
          return { "state" => in_state, "generator" => "n/a", "miss" => state_only_miss(turns, index, item, in_state) }
        end

        in_gen = generator_has?(turn, item)
        { "state" => in_state, "generator" => in_gen, "miss" => generation_miss(turns, index, item, in_state, in_gen) }
      end

      def state_only_miss(turns, index, item, in_state)
        if item["polarity"] == "absent"
          return nil unless in_state

          prior = index.positive? && !state_has?(turns[index - 1]["state"], item)
          return {
            "fault" => (prior ? "superseded_fact_resurfaced" : "superseded_fact_current"),
            "cause" => "corrected or replaced",
            "state" => true,
            "generator" => "n/a",
            "weight" => item["weight"]
          }
        end
        return nil if in_state

        {
          "fault" => (item["weight"] == "diagnostic" ? "diagnostic_lost" : "lost_fact"),
          "cause" => classify(turns, index, item, false),
          "state" => false,
          "generator" => "n/a",
          "weight" => item["weight"]
        }
      end

      def generation_miss(turns, index, item, in_state, in_gen)
        if item["polarity"] == "absent"
          return nil unless in_state || in_gen

          prior = index.positive? && !state_has?(turns[index - 1]["state"], item)
          return {
            "fault" => (prior ? "superseded_fact_resurfaced" : "superseded_fact_current"),
            "cause" => "corrected or replaced",
            "state" => in_state,
            "generator" => in_gen,
            "weight" => item["weight"]
          }
        end
        return nil if in_state && in_gen

        {
          "fault" => (item["weight"] == "diagnostic" ? "diagnostic_lost" : "lost_fact"),
          "cause" => classify(turns, index, item, in_state),
          "state" => in_state,
          "generator" => in_gen,
          "weight" => item["weight"]
        }
      end

      def contract_miss(turn)
        contract = turn["expectation_contract"]
        return nil unless contract.is_a?(Hash)

        mismatches = []
        %w[generation_mode route].each do |key|
          next unless contract.key?(key)

          mismatches << key if turn[key].to_s != contract[key].to_s
        end
        mismatches << "model_invoked" if contract.key?("model_invoked") && turn["model_invoked"] != contract["model_invoked"]
        return nil if mismatches.empty?

        {
          "fault" => "contract_mismatch",
          "cause" => mismatches.join(","),
          "state" => true,
          "generator" => "n/a",
          "weight" => "critical"
        }
      end

      def elliptical_miss(turn)
        spec = turn["elliptical"]
        return nil unless spec.is_a?(Hash)

        query = turn["retrieval_query"].to_s
        raw = turn["text"].to_s.squish.downcase
        isolated = query.squish.downcase == raw || query.blank?
        referents = Array(spec["referents"])
        return nil if !isolated && referents.any? { |token| text_hit?(query, token.to_s) }

        { "fault" => "isolated_elliptical", "cause" => "composition or reducer loss", "weight" => "critical", "state" => false, "generator" => false }
      end

      def classify(turns, index, item, in_state)
        text = marker_text(item)
        unless in_state
          return "observation FIFO eviction" if fifo?(turns, index, text)
          return "conversation-history rollover" if rollover?(turns, index, text)
          return "corrected or replaced" if replaced?(turns[index], item)
          return "composition or reducer loss" if never_in_state?(turns, index, item)

          return "UNCLASSIFIED"
        end
        return "400-character problem projection" if turns[index]["context_truncated"]

        recent = Array(turns[index]["recent_user"]).join("\n")
        goal = turns[index].dig("state", "goal").to_s
        return "outside the recent-message window" if text.present? && !text_hit?(recent, text) && !text_hit?(goal, text)

        "composition or reducer loss"
      end

      def fifo?(turns, index, text)
        return false if text.blank?

        current = Array(turns[index].dig("state", "observations"))
        return false unless current.size >= Rag::ActiveEpisode::MAX_OBSERVATIONS
        return false if current.any? { |line| text_hit?(line, text) }

        turns[0...index].any? { |turn| Array(turn.dig("state", "observations")).any? { |line| text_hit?(line, text) } }
      end

      def rollover?(turns, index, text)
        turn = turns[index]
        return false unless turn["rollover"]
        return false if text.blank?

        Array(turn["evicted"]).any? { |message| text_hit?(message["content"].to_s, text) } && !state_has_text?(turn["state"], text)
      end

      def replaced?(turn, item)
        value = item["value"].presence || marker_text(item)
        Array(turn.dig("state", "rejected")).any? { |row|
          row.is_a?(Hash) && (row["value"].to_s == value.to_s || text_hit?(row["value"].to_s, value.to_s))
        }
      end

      def never_in_state?(turns, index, item)
        turns[0...index].none? { |turn| state_has?(turn["state"], item) }
      end

      def state_has?(state, item)
        return false unless state.is_a?(Hash)

        case item["kind"]
        when "fact"
          fact = (state["facts"] || {})[item["slot"].to_s]
          return false unless fact.is_a?(Hash)
          return fact["status"].to_s == item["status"].to_s if item["status"].present?

          fact["status"].to_s == "known" && fact["value"].to_s == item["value"].to_s
        when "identity"
          values = known_values(state)
          if item["known"]
            Array(item["values"]).all? { |value| values.any? { |known| text_hit?(known, value.to_s) } || Array(state["identifiers"]).any? { |ident| text_hit?(ident, value.to_s) } }
          else
            values.empty?
          end
        when "visible_text"
          Array(state.dig("active_photo", "visible_text")).any? { |line| text_hit?(line.to_s, item["text"].to_s) }
        else
          state_has_text?(state, item["text"].to_s)
        end
      end

      def state_has_text?(state, text)
        blob = [
          state["goal"],
          *Array(state["observations"]),
          *Array(state["identifiers"]),
          *(state["facts"] || {}).values.filter_map { |fact| fact.is_a?(Hash) ? fact["value"] : nil }
        ].join("\n")
        text_hit?(blob, text)
      end

      def known_values(state)
        (state["facts"] || {}).filter_map { |slot, fact|
          next unless %w[manufacturer model].include?(slot.to_s)
          next unless fact.is_a?(Hash) && fact["value"].present?
          next unless fact["status"].to_s == "known"
          next unless %w[user photo catalog].include?(fact["source"].to_s)

          fact["value"].to_s
        }
      end

      def generator_has?(turn, item)
        scope = item["polarity"] == "absent" ? (item["generator"].presence || "current") : "full"
        blob = generator_blob(turn, scope)
        case item["kind"]
        when "fact"
          return false if item["status"].present?

          text_hit?(blob, "fault #{item['value']}") || text_hit?(blob, "código #{item['value']}") || text_hit?(blob, "codigo #{item['value']}") ||
            (item["value"].present? && blob.match?(/fault_code[^.\n]{0,40}#{Regexp.escape(item['value'].to_s)}(?!\d)/))
        when "identity"
          if item["known"]
            Array(item["values"]).all? { |value| text_hit?(blob, value.to_s) }
          else
            !blob.match?(/Orona|PBCM-V3/)
          end
        else
          text_hit?(blob, marker_text(item))
        end
      end

      def generator_blob(turn, scope)
        prompt = turn["generator_input"].to_s
        query = turn["retrieval_query"].to_s
        body = scope == "full" ? prompt : prompt.gsub(/## Recent Conversation.*?(?=## |\z)/m, "")
        current_turn = turn["text"].to_s
        if scope != "full" && current_turn.present?
          body = body.gsub(current_turn, "")
          query = query.gsub(current_turn, "")
        end
        "#{body}\n#{query}"
      end

      def marker_text(item)
        return "código #{item['value']}" if item["kind"] == "fact" && item["text"].blank? && item["value"].present?

        item["text"].to_s
      end

      def text_hit?(blob, text)
        return false if blob.blank? || text.blank?
        return blob.match?(/#{Regexp.escape(text)}(?![A-Za-z0-9+])/i) if text.match?(/\A[A-Za-z0-9+\-]{2,}\z/)

        blob.downcase.include?(text.downcase)
      end

      def level_verdict(turns, absences, faults, level)
        journeys = turns.select { |turn| turn["checkpoint"] == level }.pluck("journey").uniq
        journeys = [ "A" ] if level == "L2" && journeys.empty?
        journeys.each_with_object({}) do |journey, verdict|
          mine = absences.select { |row| row["checkpoint"] == level && row["journey"] == journey }
          structural = faults & structural_for(level)
          critical = mine.select { |row| row["weight"] != "diagnostic" }
          diagnostic = mine.select { |row| row["weight"] == "diagnostic" }
          verdict[journey] = if level == "L1"
            critical.empty? && structural.empty? ? "PASS" : "FAIL"
          elsif critical.any? || structural.any?
            "FAIL"
          elsif diagnostic.any? { |row| row["cause"].to_s == "UNCLASSIFIED" }
            "FAIL"
          elsif diagnostic.any?
            "DEGRADED"
          else
            "PASS"
          end
        end
      end

      def structural_for(level)
        shared = %w[wrong_episode_id repeated_critical_request foreign_applicability stale_write]
        return shared if level == "L1"

        shared + %w[episode_opened_at_turn_count episode_opened_at_history_eviction]
      end

      def l3_verdict(records)
        Array(records).each_with_object({}) do |record, verdict|
          reasons = []
          reasons << "episode_id_unchanged" unless record["episode_changed"]
          reasons << "follow_up_left_episode" unless record["follow_same_episode"]
          reasons << "prior_case_in_query" if Array(record["prior_in_query"]).any?
          reasons << "prior_case_in_prompt" if Array(record["prior_in_prompt"]).any?
          reasons << "isolated_follow_up" unless record["new_referent"]
          reasons << "resolver_joined_prior" if record["resolver_joined_prior"]
          reasons << "prompt_history_crossed_opened_at" if record["prompt_history_crossed_opened_at"]
          reasons << "stale_write" if record["stale_mutated"] || !record["stale_assistant_dropped"] || !record["stale_photo_dropped"]
          reasons << "stale_event_missing" unless record["stale_event"]
          verdict[record["variant"]] = reasons.empty? ? "PASS" : "FAIL"
          verdict["#{record['variant']}_reasons"] = reasons
        end
      end
    end

    class QueryHost
      include RagQueryConcern

      def initialize(account)
        @current_account = account
      end

      attr_reader :current_account

      def execute(question, **)
        execute_rag_query(question, **)
      end
    end

    class ScriptedClient
      def initialize(payload)
        @payload = payload
      end

      def converse(_params)
        tool = Struct.new(:name, :input).new("turn_perception", @payload)
        block = Struct.new(:tool_use).new(tool)
        message = Struct.new(:content).new([ block ])
        output = Struct.new(:message).new(message)
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(output, usage)
      end
    end

    module Seams
      class << self
        def install!(chunk)
          return if @on

          @chunk = chunk
          BedrockRagService.class_eval do
            alias_method :__mvp_retrieve, :retrieve_with_retry
            alias_method :__mvp_rag, :retrieve_and_generate_with_retry
            define_method(:retrieve_with_retry) { |params| Seams.retrieve(params) }
            define_method(:retrieve_and_generate_with_retry) { |*| raise LiveRefused, "F1 refuses retrieve_and_generate" }
          end
          AiProvider.class_eval do
            alias_method :__mvp_query, :query
            alias_method :__mvp_converse, :converse
            define_method(:query) { |prompt, **| Seams.query(prompt) }
            define_method(:converse) { |params| Seams.converse(params) }
          end
          BedrockClient.class_eval do
            alias_method :__mvp_bq, :query
            alias_method :__mvp_bc, :converse_message
            define_method(:query) { |*| raise LiveRefused, "F1 refuses BedrockClient#query" }
            define_method(:converse_message) { |*| raise LiveRefused, "F1 refuses BedrockClient#converse_message" }
          end
          @vision = FieldPhotoAnalysisService.method(:new)
          FieldPhotoAnalysisService.define_singleton_method(:new) { |**| raise LiveRefused, "F1 refuses a vision call" }
          @on = true
        end

        def restore!
          return unless @on

          BedrockRagService.class_eval do
            alias_method :retrieve_with_retry, :__mvp_retrieve
            alias_method :retrieve_and_generate_with_retry, :__mvp_rag
          end
          AiProvider.class_eval do
            alias_method :query, :__mvp_query
            alias_method :converse, :__mvp_converse
          end
          BedrockClient.class_eval do
            alias_method :query, :__mvp_bq
            alias_method :converse_message, :__mvp_bc
          end
          vision = @vision
          FieldPhotoAnalysisService.define_singleton_method(:new) { |**kwargs| vision.call(**kwargs) }
          @on = false
        end

        def retrieve(params)
          Array(Thread.current[:mvp_retrieve]) << params
          metadata = {
            "account_id" => Thread.current[:mvp_account_id].to_s,
            "canonical_name" => Thread.current[:mvp_chunk_name].presence || "Elemont Montacargas Hidraulico Modelo MH",
            "page_number" => "1",
            "original_source_uri" => Thread.current[:mvp_chunk_uri].presence || "s3://mvp-journey-stub/elemont/chunk_p1_2_current.txt",
            "section_identity" => Thread.current[:mvp_chunk_name].presence || "Borneras"
          }
          hit = OpenStruct.new(
            content: OpenStruct.new(text: Thread.current[:mvp_chunk_text].presence || @chunk.to_s),
            score: 0.42,
            location: OpenStruct.new(s3_location: OpenStruct.new(uri: metadata["original_source_uri"])),
            metadata: metadata
          )
          OpenStruct.new(retrieval_results: [ hit ])
        end

        def query(prompt)
          Array(Thread.current[:mvp_prompts]) << { "kind" => "known-path prompt", "text" => prompt.to_s }
          STUB_ANSWER
        end

        def converse(params)
          text = Array(params[:messages] || params["messages"]).flat_map { |message|
            Array(message[:content] || message["content"]).filter_map { |block| block[:text] || block["text"] || block.respond_to?(:text) && block.text }
          }.join("\n")
          tool = params.dig(:tool_config, :tools, 0, :tool_spec, :name) || params.dig("tool_config", "tools", 0, "tool_spec", "name")
          kind = tool.to_s.include?("unknown") ? "contract prompt" : "converse prompt"
          Array(Thread.current[:mvp_prompts]) << { "kind" => kind, "text" => text }
          content = [ OpenStruct.new(text: "not a tool") ]
          OpenStruct.new(output: OpenStruct.new(message: OpenStruct.new(content: content)), usage: OpenStruct.new(input_tokens: 0, output_tokens: 0))
        end
      end
    end

    class Runner
      include ActiveSupport::Testing::TimeHelpers

      def initialize(account:, user:, out_dir:)
        @account = account
        @user = user
        @out_dir = Pathname(out_dir)
        @spec = YAML.safe_load(FIXTURE.read, permitted_classes: [], aliases: false)
        @chunk = CHUNK_PATH.read
        @base = Time.zone.parse(@spec.fetch("fixed_time"))
        @turns = []
        @l3 = []
        @known_sections = []
        @first_eviction = {}
      end

      def run
        with_flags do
          Seams.install!(@chunk)
          Thread.current[:mvp_account_id] = @account.id
          document = travel_to(@base) { ensure_elemont_document! }
          run_journey("A", "A_no_focus", document, focus: false)
          run_journey("A", "A_selected_elemont", document, focus: true)
          run_journey("B", "B", document, focus: false)
          travel_to(@base) { capture_known_controls }
        end
        write_packet
      ensure
        Seams.restore!
        Thread.current[:mvp_account_id] = nil
        Thread.current[:mvp_prompts] = nil
      end

      private

      def with_flags
        previous = (FLAGS.keys + UNSET_FLAGS).index_with { |key| ENV[key] }
        FLAGS.each { |key, value| ENV[key] = value }
        UNSET_FLAGS.each { |key| ENV.delete(key) }
        yield
      ensure
        previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end

      # The calibration runner passes this PIN with force_entity_filter.
      # KnowledgeScopePolicy denies the set unless one owned row matches it,
      # which happens before the stubbed Retrieve. The row lets that same
      # call reach generation. It is not a different route contract.
      def ensure_known_control_document!(pin)
        found = KbDocument.find_by(account: @account, s3_key: pin)
        return found if found

        KbDocument.create!(
          account: @account,
          document_uid: "f1c18c19-c020-4000-8000-c18c19c20a11",
          s3_key: pin,
          display_name: "F1 calibration pin",
          aliases: [],
          knowledge_scope: "tenant_private"
        )
      end

      def ensure_elemont_document!
        spec = @spec.fetch("elemont_document")
        found = KbDocument.find_by(document_uid: spec["document_uid"]) || KbDocument.find_by(s3_key: spec["s3_key"])
        return found if found

        KbDocument.create!(
          account: @account,
          document_uid: spec["document_uid"],
          s3_key: spec["s3_key"],
          display_name: spec["display_name"],
          aliases: [],
          knowledge_scope: "tenant_private"
        )
      end

      def run_journey(key, journey, document, focus:)
        session = fresh_session(journey)
        pin_document(session, document) if focus
        @clock = 0
        @rollover = false
        @eviction_marked = false
        @previous_episode_id = nil
        @spec.dig("journeys", key, "turns").each do |row|
          @turns << play_turn(session, journey, row)
        end
        return unless key == "A"

        @l3 << play_l3(session, journey, document, focus: focus)
      end

      def fresh_session(journey)
        identifier = "#{@user.id}:mvp:#{journey}"
        session = ConversationSession.find_or_initialize_by(account: @account, identifier: identifier, channel: "web")
        session.user = @user
        session.expires_at = 30.days.from_now
        session.conversation_history = []
        session.active_episode = {}
        session.document_focus = []
        session.current_procedure = {}
        session.save!
        session
      end

      def pin_document(session, document)
        session.update!(document_focus: [ {
          "kb_document_id" => document.id,
          "source_uri" => document.display_s3_uri(KbDocument::KB_BUCKET),
          "display_name" => document.display_name,
          "added_at" => @base.iso8601
        } ])
      end

      def play_turn(session, journey, row)
        row = row.deep_stringify_keys
        before_id = @previous_episode_id
        history_before = session.reload.conversation_history.deep_dup
        prompts = []
        result = nil
        error = nil
        photo = nil
        travel_to(@base + @clock.minutes) do
          turn = session.record_user_turn!(
            row["text"],
            user_id: @user.id,
            correlation_id: "mvp:#{journey}:t#{format('%02d', row['n'])}:user",
            interpreter_client: ScriptedClient.new(perception_payload(row["perception"])),
            now: Time.current
          )
          photo = write_photo(session, journey, row) if row["photo"]
          prompts, result, error = execute_query(session, journey, row, turn)
          record_answer(session, journey, row, result) unless error
        end
        @clock += 1
        finish_turn(session, journey, row, before_id, history_before, prompts, result, error, photo)
      end

      def finish_turn(session, journey, row, before_id, history_before, prompts, result, error, photo)
        session.reload
        evicted = evicted_messages(history_before, session.conversation_history)
        @rollover ||= evicted.any?
        first = false
        if evicted.any? && !@eviction_marked
          @eviction_marked = true
          first = true
          @first_eviction[journey] = {
            "turn" => turn_id(journey, row),
            "role" => evicted.first["role"],
            "content" => evicted.first["content"].to_s
          }
        end
        state = snapshot(session, photo)
        episode_id = state["episode_id"].presence || session.active_episode["episode_id"]
        changed = before_id.present? && episode_id != before_id
        @previous_episode_id = episode_id
        prompt = prompts.pluck("text").join("\n\n")
        mode = result.respond_to?(:generation_mode) ? result.generation_mode.to_s : ""
        kind = prompts.last&.dig("kind")
        answer = result.respond_to?(:answer) ? result.answer.to_s : ""
        if prompt.blank?
          prompt = result&.generation_context.to_s
          if prompt.blank? && answer.present?
            prompt = answer
            kind = "deterministic"
          end
        end
        {
          "id" => turn_id(journey, row),
          "n" => row["n"],
          "journey" => journey,
          "checkpoint" => row["checkpoint"],
          "type" => row["type"],
          "text" => row["text"],
          "episode_id" => episode_id,
          "episode_changed" => changed,
          "history_length" => session.conversation_history.size,
          "rollover" => @rollover,
          "oldest" => oldest_message(session),
          "evicted" => evicted.map { |message| { "role" => message["role"], "content" => message["content"].to_s } },
          "first_eviction" => first,
          "state" => state,
          "generator_input" => prompt,
          "generator_kind" => kind || (mode.present? ? "deterministic" : "none"),
          "retrieval_query" => result.respond_to?(:effective_question) ? result.effective_question.to_s : "",
          "context_truncated" => result.respond_to?(:context_truncated) && result.context_truncated == true,
          "route" => route_label(mode, prompt, kind),
          "generation_mode" => mode,
          "route_outcome" => result.respond_to?(:route_outcome) ? result.route_outcome.to_s : "",
          "identity_status" => result.respond_to?(:equipment_identity_status) ? result.equipment_identity_status.to_s : "",
          "model_invoked" => result.respond_to?(:model_invoked) ? result.model_invoked : nil,
          "expectation_contract" => row["contract"].is_a?(Hash) ? row["contract"] : nil,
          "answer_excerpt" => answer.first(240),
          "answer_is_stub" => answer == STUB_ANSWER,
          "unknown_prompt_includes_chunk_body" => prompt.include?("identity_unknown_reference") && prompt.include?("SEGURIDAD IN"),
          "error" => error&.message,
          "interpreter_move" => session.active_episode.dig("goal", "text").present? ? row.dig("perception", "move") : row.dig("perception", "move"),
          "repeated_critical_request" => repeated_request?(result, state),
          "foreign_applicability" => foreign_procedure?(result, state, prompt),
          "stale_mutated" => false,
          "recent_user" => session.conversation_history.select { |message| message["role"] == "user" }.last(2).map { |message| message["content"].to_s },
          "elliptical" => row["elliptical"],
          "expect" => expectations(row)
        }
      end

      def play_l3(session, journey, document, focus:)
        previous = session.reload.active_episode["episode_id"]
        boundary = {
          "n" => 15, "checkpoint" => "L3", "type" => "new_work", "text" => @spec.dig("l3", "boundary"),
          "perception" => @spec.dig("l3", "boundary_perception")
        }
        follow = {
          "n" => 16, "checkpoint" => "L3", "type" => "follow_up", "text" => @spec.dig("l3", "follow_up"),
          "perception" => @spec.dig("l3", "follow_perception"),
          "elliptical" => { "referents" => @spec.dig("l3", "new_referents") }
        }
        boundary_turn = play_turn(session, journey, boundary)
        follow_turn = play_turn(session, journey, follow)
        follow_at = @base + (@clock - 1).minutes
        probe = travel_to(follow_at) { resolver_probe(session, follow["text"]) }
        stale = travel_to(follow_at) { stale_probes(session, previous) }
        crossed = travel_to(follow_at) { session.reload.episode_user_messages.any? { |text| prior_case?(text) } }
        prompt = follow_turn["generator_input"].to_s
        focus_name = document.display_name.to_s
        outside = outside_session_focus(prompt, focus_name)
        prior_prompt = prior_hits(strip_session_focus(prompt))
        prior_query = prior_hits(follow_turn["retrieval_query"].to_s)
        opened = session.active_episode["opened_at"].to_s
        {
          "variant" => (focus ? "selected_elemont" : "no_focus"),
          "episode_changed" => boundary_turn["episode_id"].present? && boundary_turn["episode_id"] != previous,
          "follow_same_episode" => follow_turn["episode_id"] == boundary_turn["episode_id"],
          "boundary_episode_id" => boundary_turn["episode_id"],
          "follow_episode_id" => follow_turn["episode_id"],
          "previous_episode_id" => previous,
          "prior_in_query" => prior_query,
          "prior_in_prompt" => prior_prompt,
          "new_referent" => Array(@spec.dig("l3", "new_referents")).any? { |token| Score.text_hit?(follow_turn["retrieval_query"].to_s, token) },
          "resolver_joined_prior" => probe["joined_prior"],
          "resolver" => probe,
          "replaced_rows_in_window" => probe["replaced_rows"],
          "prompt_history_crossed_opened_at" => crossed,
          "opened_at" => opened,
          "focus_retained" => Array(session.document_focus).any?,
          "elemont_outside_session_focus" => outside,
          "focus_blocker" => focus && focus_blocker?(prompt, follow_turn),
          "route" => follow_turn["route"],
          "generation_mode" => follow_turn["generation_mode"],
          "route_outcome" => follow_turn["route_outcome"],
          "retrieval_query" => follow_turn["retrieval_query"],
          "stale_assistant_dropped" => stale["assistant_dropped"],
          "stale_photo_dropped" => stale["photo_dropped"],
          "stale_mutated" => stale["mutated"],
          "stale_event" => stale["event"]
        }
      end

      def resolver_probe(session, question)
        now = Time.current
        result = Rag::EpisodeThreadResolver.call(
          question: question, conversation_session: session, correlation_id: "mvp:l3:resolver", locale: :es, now: now
        )
        rows = Rag::EpisodeThreadResolver.new(
          question: question, conversation_session: session, correlation_id: "mvp:l3:rows", locale: :es, now: now
        ).send(:episode_rows)
        opened = parse_opened_at(session.active_episode["opened_at"])
        replaced = rows.select { |row| replaced_episode_row?(row, opened) }
        marker_rows = replaced.select { |row| prior_case?(row["content"].to_s) }
        composed = result.composed.to_s
        {
          "outcome" => result.outcome.to_s,
          "reason" => result.reason.to_s,
          "composed" => composed.first(240),
          "joined_prior" => result.outcome.to_sym == :join && prior_case?(composed),
          "replaced_rows" => replaced.size,
          "prior_marker_rows" => marker_rows.size,
          "reads_replaced_episode" => replaced.any?,
          "replaced_user_excerpts" => replaced.map { |row| row["content"].to_s.first(120) }
        }
      end

      def parse_opened_at(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def replaced_episode_row?(row, opened)
        return false unless row["role"] == "user" && opened.present?

        ts = row["ts"]
        ts = Time.zone.parse(ts.to_s) unless ts.is_a?(Time) || ts.is_a?(ActiveSupport::TimeWithZone)
        ts.present? && ts < opened
      rescue ArgumentError, TypeError
        false
      end

      def stale_probes(session, old_id)
        before_history = session.reload.conversation_history.deep_dup
        before_state = session.active_episode.deep_dup
        logs = capture_logs do
          session.record_assistant_turn!(
            "stale assistant",
            user_id: @user.id,
            correlation_id: "mvp:l3:stale-assistant",
            expected_episode_id: old_id
          )
          session.record_photo_observation!(
            photo_value: { "manufacturer" => "Elemont", "model_visible" => "MH", "relevance_to_goal" => "relevant" },
            field_photo_id: 0,
            sha256: "stale",
            correlation_id: "mvp:l3:stale-photo",
            expected_episode_id: old_id
          )
        end
        session.reload
        unchanged = session.conversation_history == before_history && session.active_episode == before_state
        {
          "assistant_dropped" => unchanged,
          "photo_dropped" => unchanged,
          "mutated" => !unchanged,
          "event" => logs.include?("stale_case_write_dropped")
        }
      end

      def execute_query(session, journey, row, turn)
        prompts = []
        result = nil
        error = nil
        Thread.current[:mvp_prompts] = []
        host = QueryHost.new(@account)
        result = host.execute(
          row["text"],
          conv_session: session,
          account: @account,
          user_id: @user.id,
          correlation_id: "mvp:#{journey}:t#{format('%02d', row['n'])}:query",
          conversation_session_id: session.id,
          episode_turn: turn,
          response_locale: :es,
          output_channel: :web,
          raw_question: row["text"]
        )
        prompts = Array(Thread.current[:mvp_prompts])
        remember_known_prompt(journey, row, prompts) if journey == "A_no_focus" && row["n"].to_i <= 14
        [ prompts, result, error ]
      rescue StandardError => raised
        [ Array(Thread.current[:mvp_prompts]), result, raised ]
      end

      def record_answer(session, journey, row, result)
        return if result.nil? || (result.respond_to?(:success?) && result.success? == false)

        answer = result.respond_to?(:answer) ? result.answer.to_s : ""
        answer = STUB_ANSWER if answer.blank?
        session.record_assistant_turn!(
          answer,
          user_id: @user.id,
          correlation_id: "mvp:#{journey}:t#{format('%02d', row['n'])}:assistant",
          expected_episode_id: session.reload.live_episode_id,
          pending_question: result.respond_to?(:pending_question) ? result.pending_question : nil
        )
      end

      def write_photo(session, journey, row)
        spec = row["photo"]
        sha = Digest::SHA256.hexdigest("mvp-#{journey}-#{row['n']}")
        photo = FieldPhoto.find_or_create_by!(account: @account, sha256: sha) do |row|
          row.user_id = @user.id
          row.conversation_session_id = session.id
          row.s3_key_original = "field_photos/#{@account.id}/#{sha}/original.jpg"
          row.content_type = "image/jpeg"
          row.byte_size = 128
        end
        acceptance = FieldPhotoObservation.accept!(
          photo: photo,
          parsed: {
            "canonical_component" => "placa",
            "manufacturer" => spec["manufacturer"],
            "model" => spec["model"],
            "subsystem" => "CONTROLLER_LOGIC",
            "condition" => "UNKNOWN",
            "visible_text" => [ spec["visible_text"] ]
          },
          model_id: "hand-written-projection",
          target_visible: true,
          relevance_to_goal: spec["relevance_to_goal"]
        )
        episode_id = session.reload.live_episode_id
        session.record_photo_observation!(
          photo_value: {
            "manufacturer" => spec["manufacturer"],
            "model_visible" => spec["model"],
            "relevance_to_goal" => spec["relevance_to_goal"],
            "visible_text" => [ spec["visible_text"] ]
          },
          field_photo_id: photo.id,
          sha256: sha,
          correlation_id: "mvp:#{journey}:t#{format('%02d', row['n'])}:photo",
          expected_episode_id: episode_id
        )
        visible = acceptance.observation&.dig("visible_text")&.join(", ")
        session.record_photo_assistant_context!(
          "#{spec['manufacturer']} #{spec['model']}. Visible text: #{visible}",
          user_id: @user.id,
          correlation_id: "mvp:#{journey}:t#{format('%02d', row['n'])}:photo-context",
          expected_episode_id: episode_id,
          accepted_observation: acceptance.observation
        )
        photo.reload
      end

      def capture_known_controls
        require Rails.root.join("script/field_companion/f1_calibration_corpus")
        corpus = FieldCompanion::F1CalibrationCorpus
        ensure_known_control_document!(corpus::PIN)
        corpus.cases.select { |row| corpus::KNOWN.include?(row[:id]) }.each do |row|
          label = "#{row[:id]} #{row[:lane]}"
          text = capture_control(row)
          @known_sections << "## #{label}\n#{text.presence || 'EMPTY'}"
        end
      end

      def capture_control(row)
        corpus = FieldCompanion::F1CalibrationCorpus
        Thread.current[:mvp_prompts] = []
        Thread.current[:mvp_chunk_text] = corpus.fixture_body(row[:manual])
        Thread.current[:mvp_chunk_name] = corpus.fixture_name(row[:manual])
        Thread.current[:mvp_chunk_uri] = corpus::PIN
        identity = known_identity(row)
        if row[:lane] == :managed
          BedrockRagService.new(account: @account).query(
            row[:question],
            response_locale: row[:locale],
            output_channel: :web,
            equipment_identity: identity,
            correlation_id: "mvp:known:#{row[:id]}:#{row[:lane]}"
          )
        else
          # Corpus rows label every case manual :zephyr, including ORBITA c20.
          # A ZEPHYR stub is other equipment, so the structured route closes
          # before generation and captures nothing. The structured lane uses
          # the frozen fixture for that known identity.
          if row[:identity] == "orbita"
            Thread.current[:mvp_chunk_text] = corpus.fixture_body(:orbita)
            Thread.current[:mvp_chunk_name] = corpus.fixture_name(:orbita)
          end
          Rag::StructuredEvidenceRoute.new(
            question: row[:question],
            account: @account,
            entity_s3_uris: [ corpus::PIN ],
            entity_sources: [ "document" ],
            force_entity_filter: true,
            response_locale: row[:locale],
            equipment_identity: identity,
            correlation_id: "mvp:known:#{row[:id]}:#{row[:lane]}"
          ).execute
        end
        Array(Thread.current[:mvp_prompts]).pluck("text").join("\n\n")
      rescue StandardError => error
        "ERROR #{error.class}: #{error.message}"
      ensure
        Thread.current[:mvp_chunk_text] = nil
        Thread.current[:mvp_chunk_name] = nil
        Thread.current[:mvp_chunk_uri] = nil
      end

      def known_identity(row)
        return nil if row[:known_manufacturer].blank?

        Rag::EquipmentIdentity.new(
          manufacturer: row[:known_manufacturer],
          needles: [ row[:known_manufacturer], row[:known_model] ],
          facts: [
            { "slot" => "manufacturer", "value" => row[:known_manufacturer], "source" => "user", "correlation_id" => "mvp:#{row[:known_model]}" },
            { "slot" => "model", "value" => row[:known_model], "source" => "user", "correlation_id" => "mvp:#{row[:known_model]}" }
          ]
        )
      end

      def remember_known_prompt(journey, row, prompts)
        return unless journey == "A_no_focus"

        body = prompts.pluck("text").join("\n\n")
        @known_sections << "## #{turn_id(journey, row)}\n#{body.presence || 'EMPTY'}"
      end

      def expectations(row)
        markers = @spec.fetch("markers")
        state_only = Array(row["state_only"]).map(&:to_s)
        items = []
        Array(row["present"]).each { |id| items << expectation_item(markers, id, "present", "critical", state_only) }
        Array(row["absent"]).each { |id| items << expectation_item(markers, id, "absent", "critical", state_only) }
        Array(row["diagnostic"]).each { |id| items << expectation_item(markers, id, "present", "diagnostic", state_only) }
        items
      end

      def expectation_item(markers, id, polarity, weight, state_only)
        markers.fetch(id).merge(
          "id" => id,
          "polarity" => polarity,
          "weight" => weight,
          "expectation_scope" => state_only.include?(id.to_s) ? "state_only" : "state_and_generation"
        )
      end

      def perception_payload(raw)
        raw = raw.to_h.deep_stringify_keys
        {
          "move" => raw["move"],
          "assertions" => Array(raw["assertions"]).map { |item|
            item = item.stringify_keys
            payload = { "span" => item["span"].to_s, "act" => item["act"].to_s }
            payload["slot_hint"] = item["slot_hint"] if item["slot_hint"].present?
            payload
          },
          "observations" => Array(raw["observations"]).map(&:to_s),
          "pending_resolution" => raw["pending_resolution"],
          "clarification_target" => raw["clarification_target"]
        }
      end

      def snapshot(session, photo)
        episode = session.active_episode.is_a?(Hash) ? session.active_episode : {}
        facts = episode["facts"].is_a?(Hash) ? episode["facts"] : {}
        photo ||= FieldPhoto.find_by(id: episode.dig("active_photo", "field_photo_id"))
        visible = Array(photo&.visual_observation&.dig("visible_text"))
        active = episode["active_photo"].is_a?(Hash) ? episode["active_photo"].dup : {}
        active["visible_text"] = visible if visible.any?
        {
          "episode_id" => episode["episode_id"],
          "facts" => facts,
          "goal" => episode.dig("goal", "text").to_s,
          "observations" => Array(episode["observations"]).map { |item| item.is_a?(Hash) ? item["text"].to_s : item.to_s },
          "identifiers" => Array(episode["identifiers"]).map { |item| item.is_a?(Hash) ? item["value"].to_s : item.to_s },
          "rejected" => Array(episode["rejected"]),
          "pending" => episode["pending_question"],
          "active_photo" => active,
          "conflicts" => Array(episode["conflicts"])
        }
      end

      def evicted_messages(before, after)
        keys = after.map { |message| message_key(message) }
        before.reject { |message| keys.include?(message_key(message)) }
      end

      def message_key(message)
        [ message["role"], message["content"], message["correlation_id"] ]
      end

      def oldest_message(session)
        message = session.conversation_history.first
        return nil unless message

        { "role" => message["role"], "content" => message["content"].to_s.first(180) }
      end

      def route_label(mode, prompt = "", kind = nil)
        text = mode.to_s
        return "deterministic" if %w[meta clarify_first].include?(text)
        return "structured" if text.include?("structured")
        return "context-evidence" if text.include?("context_evidence") || text.include?("context-evidence")
        return "ambiguous-model responder" if text.include?("ambiguous")
        return "managed" if text.present? || kind.to_s.include?("prompt") || prompt.to_s.include?("identity_unknown_reference") || prompt.to_s.include?("FIELD COMPANION")

        "deterministic"
      end

      def repeated_request?(result, state)
        return false unless result.respond_to?(:answer)

        answer = result.answer.to_s
        return false if answer.blank? || answer == STUB_ANSWER

        blob = Score.state_has_text?(state, "guía de la puerta")
        blob && answer.match?(/gu[ií]a de la puerta/i) && answer.match?(/revis|comprob|verifica/i)
      end

      def foreign_procedure?(result, state, prompt)
        status = result.respond_to?(:equipment_identity_status) ? result.equipment_identity_status.to_s : ""
        return false unless %w[compatible known].include?(status)
        return false if Score.known_values(state).any? { |value| value.match?(/elemont/i) }

        prompt.to_s.include?("SEGURIDAD IN")
      end

      def prior_case?(text)
        PRIOR_CASE.any? { |marker| text.to_s.downcase.include?(marker.downcase) }
      end

      def prior_hits(text)
        PRIOR_CASE.select { |marker| text.to_s.downcase.include?(marker.downcase) }
      end

      def strip_session_focus(prompt)
        prompt.to_s.sub(/## Session Focus.*?(?=## |\z)/m, "")
      end

      def outside_session_focus(prompt, name)
        return false if name.blank?

        strip_session_focus(prompt).include?(name)
      end

      def focus_blocker?(prompt, turn)
        outcome = turn["route_outcome"].to_s
        mode = turn["generation_mode"].to_s
        return true if outcome.match?(/abstain/i) || mode.match?(/abstain/i)

        chunk = prompt.include?("SEGURIDAD IN")
        labeled = prompt.match?(/unconfirmed|reference-only|identity_unknown_reference|no confirm/i)
        chunk && !labeled
      end

      def capture_logs
        io = StringIO.new
        logger = ActiveSupport::Logger.new(io)
        Rails.logger.broadcast_to(logger)
        yield
        io.string
      ensure
        Rails.logger.stop_broadcasting_to(logger) if logger
      end

      def turn_id(journey, row)
        prefix = journey.to_s.start_with?("B") ? "B" : "A"
        "#{prefix}#{row['n']}"
      end

      def write_packet
        FileUtils.mkdir_p(@out_dir)
        verdict = Score.evaluate(@turns, l3: @l3)
        known = @known_sections.join("\n\n")
        known_path = @out_dir.join("known_prompts.txt")
        known_path.write(known)
        fixture_hash = Digest::SHA256.hexdigest(FIXTURE.read)
        known_hash = Digest::SHA256.hexdigest(known)
        packet = {
          "interpreter_mode" => "owner",
          "fixed_time" => @spec.fetch("fixed_time"),
          "expectation_scope_revision" => @spec["expectation_scope_revision"],
          "fixture_sha256" => fixture_hash,
          "known_prompt_sha256" => known_hash,
          "chunk_source" => @spec.fetch("chunk_source"),
          "chunk_sha256" => Digest::SHA256.hexdigest(@chunk),
          "usefulness_score" => nil,
          "first_eviction" => @first_eviction,
          "verdict" => verdict,
          "turns" => @turns,
          "l3" => @l3
        }
        @out_dir.join("ledger.json").write(JSON.generate(packet))
        summary = packet.except("turns")
        summary["routes"] = @turns.map { |turn| { "id" => turn["id"], "journey" => turn["journey"], "route" => turn["route"], "generation_mode" => turn["generation_mode"], "error" => turn["error"] } }
        summary["absences"] = verdict["absences"]
        @out_dir.join("summary.json").write(JSON.pretty_generate(summary))
        packet
      end
    end
  end
end
