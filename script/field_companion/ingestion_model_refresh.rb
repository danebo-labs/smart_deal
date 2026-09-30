# frozen_string_literal: true

# Field Companion F2B. Compares claude-sonnet-5 and claude-sonnet-5-5 on the
# Anthropic Batch payload that BulkCostV2RequestBuilder already sends for a
# kept text page. Does not change production constants. Does not call the
# Haiku page classifier. Does not retry inside the comparison.
#
# Usage: env -u BUNDLE_PATH bin/rails runner script/field_companion/ingestion_model_refresh.rb

require "bigdecimal"
require "digest"
require "fileutils"
require "json"
require "stringio"

require_relative "../../config/environment" unless defined?(Rails) && Rails.application

module FieldCompanion
  module IngestionModelRefresh
    class Stop < StandardError; end

    ROOT = Rails.root.join("tmp/field_companion/ingestion_model_refresh")
    HEAD = "c4f5f2deea7357741dfff463896747178dde5d24"
    PARENT = "7f32d4837842e1e7e78ef652778a54860511b5f4"
    MODELS = %w[claude-sonnet-5 claude-sonnet-5-5].freeze
    CONTROL_UNIT_IDS = %w[tijera_p01 tijera_p18 tijera_p09 tijera_p08 cert_p01].freeze
    CONTROL_MODEL = "claude-sonnet-5"
    REUSED_MODEL = "claude-sonnet-5-5"
    VOID_BATCH_ID = "msgbatch_018dHEzmkEqpD8dgQJQpqUBu"
    REUSED_BATCH_ID = "msgbatch_012f2XnkwfTma8UpS1FTShyS"
    BUDGET = BigDecimal("0.60")
    OUTPUT_CAP = BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS
    PRICE_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing"
    # USD per 1_000 tokens. Batch is half of Sonnet 5.5 standard ($2 / $10).
    # Cache multipliers stack with that discount: 5-minute write 1.25x, read 0.1x.
    # One-hour write is $4 / MTok standard, so $2 / MTok on Batch. Production
    # sends ephemeral (5-minute) cache_control and does not request a 1-hour write.
    RATES = {
      "input" => BigDecimal("0.001"),
      "output" => BigDecimal("0.005"),
      "cache_read" => BigDecimal("0.0001"),
      "cache_creation" => BigDecimal("0.00125"),
      "cache_creation_1h" => BigDecimal("0.002")
    }.freeze
    BRANDS = %w[orona otis schindler kone thyssenkrupp thyssen soprel genie haulotte skyjack jlg].freeze
    CODES = %w[e80n e80w e100w e120w e140w e160w arcaii 0466005].freeze
    UNIT_RE = /(\d{1,4}(?:[.,]\d+)?)\s*(vcd|vac|kg|mm|m\/s|v)\b/i
    PARAM_KEYS = %w[max_tokens messages model system].freeze
    FORBIDDEN_PARAMS = %w[effort output_config temperature thinking tool_choice top_k top_p].freeze

    SOURCES = {
      "tijera" => {
        "path" => "/Users/lahirisan/Downloads/manual_plataforma_tijera_24_paginas.pdf",
        "sha256" => "852f508da648aa7f06dcbaeb49a28ab714ae361d1591f9b4dadb3dd36652c064",
        "filename" => "manual_plataforma_tijera_24_paginas.pdf"
      },
      "cert" => {
        "path" => Rails.root.join("docs/referencias/2023_informe_certificacion_ascensores_NCh2840_torre_amunategui.pdf").to_s,
        "sha256" => "3c352f0ec9936a7ab4686e1dcc858f91f6d7ecddb03d8b8762cc5653b4acaa33",
        "filename" => "2023_informe_certificacion_ascensores_NCh2840_torre_amunategui.pdf"
      },
      "orona" => {
        "path" => "/Users/lahirisan/Downloads/Orona_ARCAII_Controller - kopie.pdf",
        "sha256" => "ce3a3572876ba28e59196cc97abbbdd215ce07c5f33493a90104254fcd1ac20c",
        "filename" => "Orona_ARCAII_Controller - kopie.pdf"
      },
      "montacargas" => {
        "path" => "/Users/lahirisan/Downloads/Montacargas 2N Temporizado-1.pdf",
        "sha256" => "121bfffe0827f6bc681ba9bdc910503900555c4ce58d616732a1c063f3b16986",
        "filename" => "Montacargas 2N Temporizado-1.pdf"
      }
    }.freeze

    # Phrases are checked against the splitter text layer before any model call.
    # A phrase absent from that layer becomes NOT_SCORED. It does not get invented.
    UNIT_SPECS = [
      { "id" => "tijera_p01", "source" => "tijera", "page" => 1, "priority" => 1,
        "kinds" => %w[technical_text anchor numeric unknown],
        "phrases" => [
          [ "24 V", "numeric_code", "blob" ],
          [ "gases explosivos", "visible_text", "blob" ],
          [ "bateria", "visible_text", "blob" ]
        ] },
      { "id" => "tijera_p18", "source" => "tijera", "page" => 18, "priority" => 2,
        "kinds" => %w[table model_codes numeric content],
        "phrases" => [
          [ "E80N", "numeric_code", "blob" ],
          [ "E80W", "numeric_code", "blob" ],
          [ "E100W", "numeric_code", "blob" ],
          [ "E120W", "numeric_code", "blob" ],
          [ "E140W", "numeric_code", "blob" ],
          [ "E160W", "numeric_code", "blob" ],
          [ "230Kg", "numeric_code", "blob" ],
          [ "7,8 m", "numeric_code", "blob" ],
          [ "450kg", "numeric_code", "blob" ]
        ] },
      { "id" => "tijera_p09", "source" => "tijera", "page" => 9, "priority" => 3,
        "kinds" => %w[field_records content],
        "phrases" => [
          [ "2.4.2", "visible_text", "blob" ],
          [ "parada de emergencia", "field_record", "records" ],
          [ "No se ejecutaran todas las funciones", "field_record", "records" ],
          [ "bocina", "field_record", "records" ],
          [ "Sonara la bocina", "field_record", "records" ]
        ] },
      { "id" => "tijera_p08", "source" => "tijera", "page" => 8, "priority" => 4,
        "kinds" => %w[continuation content technical_text],
        "phrases" => [
          [ "2.4.1", "visible_text", "blob" ],
          [ "poner en marcha", "visible_text", "blob" ],
          [ "controlador de tierra", "visible_text", "blob" ],
          [ "encendido", "visible_text", "blob" ]
        ] },
      { "id" => "cert_p01", "source" => "cert", "page" => 1, "priority" => 5,
        "kinds" => %w[table numeric unknown_discipline anchor],
        "phrases" => [
          [ "2840", "numeric_code", "blob" ],
          [ "1275", "numeric_code", "blob" ],
          [ "2,5", "numeric_code", "blob" ],
          [ "ATLAGICH", "identity", "blob" ],
          [ "AMUNATEGUI", "identity", "blob" ]
        ] },
      { "id" => "orona_p01", "source" => "orona", "page" => 1, "priority" => 6,
        "kinds" => %w[identity model_codes anchor],
        "phrases" => [
          [ "ARCAII", "identity", "blob" ],
          [ "0466005", "numeric_code", "blob" ],
          [ "Revision", "visible_text", "blob" ]
        ] },
      { "id" => "orona_p06", "source" => "orona", "page" => 6, "priority" => 7,
        "kinds" => %w[identity manufacturer content],
        "phrases" => [
          [ "ORONA", "identity", "blob" ],
          [ "ARCA II", "identity", "blob" ],
          [ "0466005", "numeric_code", "blob" ],
          [ "TM.ARCAII.00", "numeric_code", "blob" ]
        ] },
      { "id" => "montacargas_p01", "source" => "montacargas", "page" => 1, "priority" => 8,
        "kinds" => %w[diagram codes numeric anchor],
        "phrases" => [
          [ "220VAC", "numeric_code", "blob" ],
          [ "Q1", "numeric_code", "blob" ],
          [ "K5", "numeric_code", "blob" ],
          [ "24VCD", "numeric_code", "blob" ],
          [ "PRESOSTATO", "visible_text", "blob" ]
        ] }
    ].freeze

    module_function

    def run
      raise Stop, "sonnet 5.5 results already exist; run F2B_MODE=control_only" if control_results_present?

      $stdout.sync = true
      audit!
      state = load_state
      units = prepare_units
      write_pre_call_artifacts(units)
      reconcile_submitted_waves(state, units)
      spend = spent_usd(state)
      loop do
        remaining = BUDGET - spend
        wave = next_wave(units, remaining)
        break if wave.empty?

        worst = wave.sum(BigDecimal("0")) { |unit| unit["worst_usd"] }
        puts "F2B wave #{wave.pluck('id').join(',')} worst=#{worst} remaining=#{remaining}"
        run_wave(state, wave)
        spend = spent_usd(state)
      end
      pending = units.reject { |unit| unit["status"] == "scored" || unit["status"] == "excluded" }
      aggregate = build_aggregate(units, state, budget_stop: pending.any?)
      write_json(ROOT.join("aggregate.json"), aggregate)
      write_json(ROOT.join("cost_report.json"), cost_report(state, aggregate))
      write_checksums
      puts "F2B gate=#{aggregate['gate']} spent=#{spend} budget_stop=#{aggregate['budget_stop']}"
      aggregate["gate"] == "ABORT" ? 2 : 0
    end

    # Resubmits only the five Sonnet 5 controls. Reuses the closed Sonnet 5.5
    # batch. The canceled Sonnet 5 batch is not a result.
    def run_control_only
      $stdout.sync = true
      audit!
      state = load_state
      state["mode"] = "control_only"
      void_canceled_wave!(state)
      units = control_units
      requests = assert_control_preflight!(state, units)
      plan = control_submission_plan(waves: state["waves"], requests: requests)
      write_json(ROOT.join("preflight.json"), plan.merge("checked_at" => Time.now.utc.iso8601, "unit_ids" => CONTROL_UNIT_IDS))
      reuse_completed_wave!(state, units)
      submit_control_wave!(state, requests) if plan["submit"]
      reconcile_control_waves!(state, units)
      pending = units.reject { |unit| unit["status"] == "scored" }
      raise Stop, "control incomplete #{pending.pluck('id').join(',')}" if pending.any?

      aggregate = build_aggregate(units, state, budget_stop: false)
      aggregate["mode"] = "control_only"
      aggregate["cost_by_model"] = cost_by_model(state)
      write_json(ROOT.join("aggregate.json"), aggregate)
      write_json(ROOT.join("cost_report.json"), cost_report(state, aggregate).merge("cost_by_model" => aggregate["cost_by_model"]))
      write_checksums
      puts "F2B gate=#{aggregate['gate']} sonnet5=#{aggregate.dig('cost_by_model', CONTROL_MODEL)} sonnet55=#{aggregate.dig('cost_by_model', REUSED_MODEL)}"
      aggregate["gate"] == "ABORT" ? 2 : 0
    end

    def control_results_present?
      ROOT.join("batch_results/#{REUSED_MODEL}.#{REUSED_BATCH_ID}.jsonl").file?
    end

    def void_canceled_wave!(state)
      wave = state["waves"].find { |item| item["batch_id"] == VOID_BATCH_ID }
      raise Stop, "canceled sonnet 5 batch missing" if wave.nil?
      raise Stop, "canceled batch was not canceled" unless wave["api_status"] == "canceled" || wave["status"] == "void"

      wave["status"] = "void"
      wave["reusable"] = false
      save_state(state)
    end

    def control_units
      dataset = JSON.parse(ROOT.join("dataset_manifest.json").read)
      gold = JSON.parse(ROOT.join("gold_manifest.json").read)
      raise Stop, "gold was not frozen" unless gold["frozen_before_model_call"]

      CONTROL_UNIT_IDS.map do |id|
        row = dataset.fetch("units").find { |unit| unit["id"] == id }
        gold_row = gold.fetch("units").find { |unit| unit["id"] == id }
        raise Stop, "missing unit #{id}" if row.nil? || gold_row.nil?
        raise Stop, "#{id} not ready" unless row["status"] == "ready"

        row.merge("fields_gold" => gold_row["fields"], "status" => "ready")
      end
    end

    def assert_control_preflight!(state, units)
      raise Stop, "control count" unless units.size == 5 && units.pluck("id") == CONTROL_UNIT_IDS

      fingerprint = BatchChunkingPrompt.prompt_fingerprint_sha256
      system = JSON.parse(JSON.generate(BatchChunkingPrompt::SYSTEM_BLOCKS), symbolize_names: true)
      reused_rows = load_jsonl(ROOT.join("batch_results/#{REUSED_MODEL}.#{REUSED_BATCH_ID}.jsonl"))
      reusable = reused_rows.size == 5 && reused_rows.all? { |row| row["result_type"] == "succeeded" && row["json_parsed"] && row["stop_reason"] == "end_turn" && row["text"].present? }
      raise Stop, "sonnet 5.5 results are not reusable" unless reusable

      requests = units.map { |unit| assert_control_request!(unit, fingerprint, system) }
      raise Stop, "result custom_ids" unless requests.pluck(:custom_id).sort == reused_rows.pluck("custom_id").sort

      reuse_wave = state["waves"].find { |wave| wave["batch_id"] == REUSED_BATCH_ID }
      raise Stop, "reuse wave missing" unless reuse_wave&.[]("model") == REUSED_MODEL

      duplicate = state["waves"].any? { |wave| wave["model"] == REUSED_MODEL && wave["batch_id"] != REUSED_BATCH_ID }
      raise Stop, "would resubmit sonnet 5.5" if duplicate

      requests
    end

    def assert_control_request!(unit, fingerprint, system)
      verify_source!(unit["source"], SOURCES.fetch(unit["source"]))
      raise Stop, "#{unit['id']} fingerprint" unless unit["prompt_fingerprint_sha256"] == fingerprint

      control = load_saved_request(unit["id"], CONTROL_MODEL)
      reused = load_saved_request(unit["id"], REUSED_MODEL)
      raise Stop, "#{unit['id']} model" unless control.dig(:params, :model) == CONTROL_MODEL
      raise Stop, "#{unit['id']} reused model" unless reused.dig(:params, :model) == REUSED_MODEL
      raise Stop, "#{unit['id']} payload drift" unless semantic_sha(control) == semantic_sha(reused)
      raise Stop, "#{unit['id']} manifest drift" unless semantic_sha(control) == unit["semantic_sha256"]
      raise Stop, "#{unit['id']} custom_id" unless control[:custom_id] == unit["custom_id"] && reused[:custom_id] == unit["custom_id"]

      keys = control[:params].keys.map(&:to_s).sort
      raise Stop, "#{unit['id']} param keys #{keys}" unless keys == PARAM_KEYS
      raise Stop, "#{unit['id']} forbidden" if (FORBIDDEN_PARAMS & keys).any?
      raise Stop, "#{unit['id']} max_tokens" unless control.dig(:params, :max_tokens) == OUTPUT_CAP
      raise Stop, "#{unit['id']} system drift" unless control.dig(:params, :system) == system
      raise Stop, "#{unit['id']} user drift" unless control.dig(:params, :messages) == reused.dig(:params, :messages)

      control
    end

    def control_submission_plan(waves:, requests:)
      models = requests.map { |request| request.dig(:params, :model).to_s }
      raise Stop, "control would resubmit sonnet 5.5" unless models.all?(CONTROL_MODEL)
      raise Stop, "control count #{models.size}" unless models.size == 5

      void = Array(waves).find { |wave| wave["batch_id"] == VOID_BATCH_ID }
      raise Stop, "canceled batch missing" if void.nil? || void["api_status"] != "canceled"

      live = Array(waves).find { |wave| wave["control_only"] && wave["model"] == CONTROL_MODEL && wave["batch_id"] != VOID_BATCH_ID }
      { "submit" => live.nil?, "existing_batch_id" => live&.[]("batch_id"), "models" => models.uniq }
    end

    def reuse_completed_wave!(state, units)
      wave = state["waves"].find { |item| item["batch_id"] == REUSED_BATCH_ID }
      ready = wave["status"] == "reused" && units.all? { |unit| result_path(unit["id"], REUSED_MODEL).file? }
      return if ready

      wave["results_path"] ||= ROOT.join("batch_results/#{REUSED_MODEL}.#{REUSED_BATCH_ID}.jsonl").to_s
      ingest_wave(wave, units.index_by { |unit| unit["id"] })
      wave["status"] = "reused"
      wave["reused"] = true
      save_state(state)
      puts "F2B reuse #{REUSED_MODEL} #{REUSED_BATCH_ID} usd=#{wave['cost_usd']}"
    end

    def submit_control_wave!(state, requests)
      worst = control_worst_usd
      spent = spent_usd(state)
      raise Stop, "BUDGET_STOP worst=#{worst} spent=#{spent}" if spent + worst > BUDGET

      batch = ClaudeBatchClient.new(client: build_client).submit_batch(requests: requests)
      entry = {
        "model" => CONTROL_MODEL,
        "batch_id" => batch.id,
        "unit_ids" => CONTROL_UNIT_IDS,
        "status" => "submitted",
        "submitted_at" => Time.now.utc.iso8601,
        "control_only" => true,
        "api_status" => batch.respond_to?(:processing_status) ? batch.processing_status.to_s : "submitted"
      }
      state["waves"] << entry
      save_state(state)
      puts "F2B submitted #{CONTROL_MODEL} #{batch.id} api_status=#{entry['api_status']}"
    end

    def control_worst_usd
      projection = load_projection
      CONTROL_UNIT_IDS.sum(BigDecimal("0")) do |id|
        row = projection.find { |item| item["id"] == id }
        raise Stop, "missing projection #{id}" if row.nil?

        BigDecimal(row.dig("token_projection", CONTROL_MODEL, "worst_usd"))
      end
    end

    def reconcile_control_waves!(state, units)
      index = units.index_by { |unit| unit["id"] }
      state["waves"].each do |wave|
        next unless wave["control_only"]
        next if wave["status"] == "ended"

        poll_batch(wave)
        ingest_wave(wave, index)
        wave["status"] = "ended"
        wave["api_status"] = "ended"
        save_state(state)
      end
      units.each do |unit|
        next unless MODELS.all? { |model| result_path(unit["id"], model).file? }

        score_unit(unit)
        unit["status"] = "scored"
      end
    end

    def cost_by_model(state)
      Array(state["waves"]).each_with_object({}) do |wave, acc|
        next if wave["status"] == "void" || wave["cost_usd"].blank?

        acc[wave["model"]] = wave["cost_usd"]
      end
    end

    def load_saved_request(unit_id, model)
      path = ROOT.join("batch_requests/#{unit_id}.#{model}.json")
      raise Stop, "missing request #{path}" unless path.file?

      JSON.parse(path.read, symbolize_names: true)
    end

    def load_jsonl(path)
      raise Stop, "missing #{path}" unless path.file?

      path.readlines.map { |line| JSON.parse(line) }
    end

    def audit!
      head = `git rev-parse HEAD`.strip
      parent = `git rev-parse HEAD^`.strip
      raise Stop, "head #{head}" unless head == HEAD
      raise Stop, "parent #{parent}" unless parent == PARENT
      raise Stop, "MODEL_TEXT" unless BatchChunkingPrompt::MODEL_TEXT == "claude-sonnet-5"
      raise Stop, "MODEL_MULTIMODAL" unless BatchChunkingPrompt::MODEL_MULTIMODAL == "claude-opus-5-5"
      raise Stop, "DEFAULT_MODEL" unless FieldPhotoAnalysisService::DEFAULT_MODEL == "claude-sonnet-5-5"
      raise Stop, "layout flag" if IngestionLayoutFlag.enabled?
      raise Stop, "contract" unless BatchChunkingPrompt::INGESTION_CONTRACT_VERSION == "field_records_v8"

      photo = Rails.root.join("app/services/field_photo_analysis_service.rb").read
      model_line = photo.each_line.grep(/model = route/).first.to_s
      raise Stop, "field photo reads MODEL_TEXT" if model_line.include?("MODEL_TEXT")
      raise Stop, "field photo missing DEFAULT_MODEL" unless model_line.include?("DEFAULT_MODEL")
      raise Stop, "batch key already present" if BedrockQuery::BEDROCK_PRICING.key?("claude-sonnet-5-5-batch")
      raise Stop, "default rates" if RATES["input"] == BigDecimal("0.00025")
    end

    def decide(per_unit:, compatibility_fail:)
      if compatibility_fail
        return { "gate" => "I2", "reason" => "migration_compatibility_fail" }
      end

      scored = Array(per_unit).reject { |unit| unit["status"] != "scored" }
      scored.select! { |unit| Array(unit["fields"]).any? { |field| field["result"] != "NOT_SCORED" } }
      return { "gate" => "I3", "reason" => "no_scored_fields" } if scored.empty?

      structural = scored.any? do |unit|
        Array(unit["fields"]).any? do |field|
          field["model"] == "claude-sonnet-5-5" && field["category"] == "structural" && field["result"] == "FAIL"
        end
      end
      return { "gate" => "I2", "reason" => "structural_fail" } if structural

      regressions = []
      scored.each do |unit|
        by_model = Array(unit["fields"]).group_by { |field| field["model"] }
        left = index_fields(by_model["claude-sonnet-5"])
        right = index_fields(by_model["claude-sonnet-5-5"])
        (left.keys | right.keys).each do |field_id|
          a = left[field_id]
          b = right[field_id]
          next if a.nil? || b.nil?
          next if a["result"] == "NOT_SCORED" && b["result"] == "NOT_SCORED"

          if b["safety"] && !a["safety"]
            regressions << { "unit" => unit["id"], "field" => field_id, "kind" => "new_safety_fail" }
          elsif a["result"] == "PASS" && b["result"] == "FAIL"
            regressions << { "unit" => unit["id"], "field" => field_id, "kind" => "regression", "category" => b["category"] }
          end
        end
      end
      if regressions.any?
        return { "gate" => "I2", "reason" => "regression", "regressions" => regressions }
      end

      { "gate" => "I1", "reason" => "no_critical_regression" }
    end

    def batch_cost(usage)
      tokens = usage.is_a?(Hash) ? usage : {}
      raw = {
        "input" => money(tokens["input_tokens"], RATES["input"]),
        "output" => money(tokens["output_tokens"], RATES["output"]),
        "cache_read" => money(tokens["cache_read_input_tokens"], RATES["cache_read"]),
        "cache_creation" => money(tokens["cache_creation_input_tokens"], RATES["cache_creation"]),
        "cache_creation_1h" => money(tokens["cache_creation_1h_input_tokens"], RATES["cache_creation_1h"])
      }
      total = raw.values.reduce(BigDecimal("0"), :+)
      raw.transform_values { |amount| amount.to_s("F") }.merge("total" => total.round(6).to_s("F"))
    end

    def worst_case_usd(input_tokens)
      money(OUTPUT_CAP, RATES["output"]) + money(input_tokens, RATES["cache_creation"])
    end

    class CachedAsset
      attr_reader :id, :content_type, :filename, :sha256, :custom_id, :s3_key

      def initialize(id:, filename:, sha256:, binary:)
        @id = id
        @content_type = "application/pdf"
        @filename = filename
        @sha256 = sha256
        @custom_id = "f2b-#{id}"
        @s3_key = "f2b/#{filename}"
        @_cached_binary = binary
      end
    end

    def prepare_units
      observations = [ observe_tijera_schematic, observe_gonzalo ]
      built = {}
      SOURCES.each_with_index do |(key, source), index|
        verify_source!(key, source)
        specs = UNIT_SPECS.select { |spec| spec["source"] == key }
        built[key] = build_source(source, specs, index) if specs.any?
      end
      write_json(ROOT.join("observations.json"), observations)
      UNIT_SPECS.map { |spec| materialize_unit(spec, built[spec["source"]]) }
    end

    def verify_source!(key, source)
      raise Stop, "#{key} missing" unless File.file?(source["path"])

      sha = Digest::SHA256.file(source["path"]).hexdigest
      raise Stop, "#{key} sha #{sha}" unless sha == source["sha256"]
    end

    def observe_tijera_schematic
      note = { "id" => "tijera_p16_schematic", "category" => "diagram_raster", "status" => "NOT_AVAILABLE" }
      source = SOURCES.fetch("tijera")
      PdfPageSplitterService.new(File.binread(source["path"])).each_page(only: [ 16 ]) do |_number, binary|
        opus = PageRelevanceFilter.scanned_dense?(binary)
        note["force_opus"] = opus
        note["bytes"] = binary.bytesize
        note["status"] = opus ? "ROUTES_MODEL_MULTIMODAL" : "MODEL_TEXT_AVAILABLE"
        note["reason"] = opus ? "scanned_dense_not_in_sonnet_arm" : "kept_for_model_text"
      end
      note
    end

    def observe_gonzalo
      path = Dir.glob(Rails.root.join("tmp/gonzalo_split/*p1-123*.pdf").to_s).first
      return { "id" => "gonzalo_compendium", "category" => "section_identity", "status" => "NOT_AVAILABLE", "reason" => "file_missing" } if path.nil?

      note = { "id" => "gonzalo_compendium", "category" => "section_identity", "status" => "NOT_AVAILABLE" }
      PdfPageSplitterService.new(File.binread(path)).each_page(only: [ 20 ]) do |_number, binary|
        opus = PageRelevanceFilter.scanned_dense?(binary)
        note["sample_page"] = 20
        note["force_opus"] = opus
        note["reason"] = opus ? "scanned_dense_model_multimodal" : "text_layer_present_not_selected"
      end
      note
    end

    def build_source(source, specs, index)
      binary = File.binread(source["path"])
      asset = CachedAsset.new(id: index + 1, filename: source["filename"], sha256: source["sha256"], binary: binary)
      items = []
      requests = {}
      with_local_filter do
        items, = BulkCostV2RequestBuilder.new.build_items!([ asset ])
      end
      wanted = specs.map { |spec| format("%s_p%d", source["sha256"][0, 16], spec["page"]) }
      items.each do |item|
        requests[item.custom_id] = item.build if wanted.include?(item.custom_id)
      end
      requests
    ensure
      Array(items).each(&:cleanup)
    end

    def with_local_filter
      original = PageRelevanceFilter.method(:filter_pages)
      PageRelevanceFilter.define_singleton_method(:filter_pages) do |pages:, filename:, **|
        raise Stop, "missing filename" if filename.nil?

        pages.each_with_object({}) do |page, acc|
          acc[page.number] = {
            keep: true,
            reason: :f2b_local_keep,
            source: :heuristic,
            force_opus: PageRelevanceFilter.scanned_dense?(page.binary)
          }
        end
      end
      yield
    ensure
      PageRelevanceFilter.define_singleton_method(:filter_pages) { |*args, **kwargs| original.call(*args, **kwargs) } if original
    end

    def materialize_unit(spec, requests)
      custom_id = format("%s_p%d", SOURCES.dig(spec["source"], "sha256").to_s[0, 16], spec["page"])
      request = requests&.[](custom_id)
      unit = spec.merge("custom_id" => custom_id, "status" => "excluded")
      return unit.merge("exclude_reason" => "request_missing") if request.nil?

      model = request.dig(:params, :model)
      if model != BatchChunkingPrompt::MODEL_TEXT
        return unit.merge("exclude_reason" => "model_#{model}")
      end

      contract = assert_contract!(request, SOURCES.dig(spec["source"], "filename"))
      text = page_text_for(spec)
      raise Stop, "empty text layer #{spec['id']}" if text.strip.empty?

      role = contract["role"]
      fields = gold_fields(spec, text, role)
      sonnet = retarget(request, "claude-sonnet-5")
      sonnet55 = retarget(request, "claude-sonnet-5-5")
      fingerprint = semantic_sha(sonnet)
      raise Stop, "#{spec['id']} payload drift" unless fingerprint == semantic_sha(sonnet55)

      verified = fields.count { |field| field["expect"] == "VERIFIED" }
      puts "F2B prepare #{spec['id']} role=#{role} chars=#{text.length} verified=#{verified} sha=#{fingerprint[0, 12]}"

      unit.merge(
        "status" => "ready",
        "role" => role,
        "page_of" => contract["page_of"],
        "total_pages" => contract["total_pages"],
        "semantic_sha256" => fingerprint,
        "prompt_fingerprint_sha256" => BatchChunkingPrompt.prompt_fingerprint_sha256,
        "source_text_sha256" => Digest::SHA256.hexdigest(text),
        "source_text_chars" => text.length,
        "fields_gold" => fields,
        "requests" => { "claude-sonnet-5" => sonnet, "claude-sonnet-5-5" => sonnet55 },
        "manual_locale_diff" => contract["manual_locale_diff"]
      )
    end

    def page_text_for(spec)
      source = SOURCES.fetch(spec["source"])
      text = +""
      PdfPageSplitterService.new(File.binread(source["path"])).each_page(only: [ spec["page"] ]) do |_number, binary|
        io = StringIO.new(binary)
        reader = PDF::Reader.new(io)
        text = reader.pages.map(&:text).join("\n")
      rescue StandardError
        text = ""
      end
      text
    end

    def assert_contract!(request, filename)
      params = request.fetch(:params)
      keys = params.keys.map(&:to_s).sort
      raise Stop, "param keys #{keys}" unless keys == PARAM_KEYS
      forbidden = FORBIDDEN_PARAMS & keys
      raise Stop, "forbidden #{forbidden}" if forbidden.any?
      raise Stop, "max_tokens" unless params[:max_tokens] == OUTPUT_CAP
      raise Stop, "system" unless params[:system].equal?(BatchChunkingPrompt::SYSTEM_BLOCKS) || params[:system] == BatchChunkingPrompt::SYSTEM_BLOCKS

      content = params.dig(:messages, 0, :content)
      decoded = Base64.strict_decode64(content.fetch(0).dig(:source, :data))
      text = content.fetch(1).fetch(:text)
      match = text.match(/Page (\d+) of (\d+)\. Page role: (ANCHOR_PAGE|CONTENT_PAGE)\./)
      raise Stop, "instruction" unless match
      raise Stop, "filename hint" unless text.include?(filename)
      raise Stop, "locale leaked" if text.include?("Summary language:")

      rebuilt = BatchChunkingPrompt.page_user_content(
        binary: decoded,
        page_number: match[1].to_i,
        total_pages: match[2].to_i,
        filename: filename,
        locale: nil,
        anchor: match[3] == "ANCHOR_PAGE"
      )
      raise Stop, "builder diverges from page_user_content" unless rebuilt == content

      localized = BatchChunkingPrompt.page_user_content(
        binary: decoded,
        page_number: match[1].to_i,
        total_pages: match[2].to_i,
        filename: filename,
        locale: match[3] == "ANCHOR_PAGE" ? "es" : nil,
        anchor: match[3] == "ANCHOR_PAGE"
      )
      {
        "role" => match[3],
        "page_of" => match[1].to_i,
        "total_pages" => match[2].to_i,
        "manual_locale_diff" => {
          "anchor_locale_es_changes_text" => match[3] == "ANCHOR_PAGE" && localized != content,
          "content_locale_nil_same_as_bulk" => match[3] == "CONTENT_PAGE" && localized == content
        }
      }
    end

    def gold_fields(spec, text, role)
      fields = []
      spec["phrases"].each_with_index do |(phrase, category, scope), index|
        present = squash(text).include?(squash(phrase))
        fields << {
          "id" => "p#{index}_#{category}",
          "category" => category,
          "expect" => present ? "VERIFIED" : "NOT_SCORED",
          "phrase" => phrase,
          "scope" => scope,
          "reason" => present ? "in_text_layer" : "absent_from_text_layer"
        }
      end
      fields << structural_gold(role)
      fields << {
        "id" => "no_invented_brand",
        "category" => "unknown",
        "expect" => "MUST_BE_UNKNOWN",
        "scope" => "safety"
      }
      fields << {
        "id" => "no_invented_code",
        "category" => "unknown",
        "expect" => "MUST_BE_UNKNOWN",
        "scope" => "safety"
      }
      fields << {
        "id" => "no_invented_unit",
        "category" => "unknown",
        "expect" => "MUST_BE_UNKNOWN",
        "scope" => "safety"
      }
      fields << {
        "id" => "section_identity_grounded",
        "category" => "identity",
        "expect" => "VERIFIED",
        "scope" => "section_identity"
      }
      fields.flatten
    end

    def structural_gold(role)
      base = [
        { "id" => "json_parsed", "category" => "structural", "expect" => "VERIFIED", "scope" => "json" },
        { "id" => "text_block", "category" => "structural", "expect" => "VERIFIED", "scope" => "text_block" },
        { "id" => "not_truncated", "category" => "structural", "expect" => "VERIFIED", "scope" => "stop" },
        { "id" => "document_name", "category" => "structural", "expect" => "VERIFIED", "scope" => "document_name" },
        { "id" => "page_number", "category" => "structural", "expect" => "VERIFIED", "scope" => "page_number" }
      ]
      if role == "ANCHOR_PAGE"
        base << { "id" => "s0_present", "category" => "structural", "expect" => "VERIFIED", "scope" => "s0_present" }
        base << { "id" => "summary_present", "category" => "structural", "expect" => "VERIFIED", "scope" => "summary_present" }
        base << { "id" => "companion_present", "category" => "structural", "expect" => "VERIFIED", "scope" => "companion_present" }
      else
        base << { "id" => "s0_absent", "category" => "structural", "expect" => "VERIFIED", "scope" => "s0_absent" }
        base << { "id" => "summary_absent", "category" => "structural", "expect" => "VERIFIED", "scope" => "summary_absent" }
        base << { "id" => "companion_absent", "category" => "structural", "expect" => "VERIFIED", "scope" => "companion_absent" }
      end
      base
    end

    def retarget(request, model)
      copy = JSON.parse(JSON.generate(request), symbolize_names: true)
      copy[:params][:model] = model
      copy
    end

    def semantic_sha(request)
      clone = JSON.parse(JSON.generate(request))
      clone["params"].delete("model")
      Digest::SHA256.hexdigest(JSON.generate(clone))
    end

    def write_pre_call_artifacts(units)
      FileUtils.mkdir_p(ROOT.join("batch_requests"))
      dataset = units.map { |unit| public_unit(unit) }
      write_json(ROOT.join("dataset_manifest.json"), { "units" => dataset, "not_available" => JSON.parse(ROOT.join("observations.json").read) })
      gold = units.map do |unit|
        { "id" => unit["id"], "status" => unit["status"], "role" => unit["role"], "fields" => unit["fields_gold"] }
      end
      write_json(ROOT.join("gold_manifest.json"), { "frozen_before_model_call" => true, "units" => gold })
      units.each do |unit|
        next unless unit["requests"]

        unit["requests"].each do |model, request|
          path = ROOT.join("batch_requests/#{unit['id']}.#{model}.json")
          write_json_compact(path, request)
        end
      end
    end

    def public_unit(unit)
      unit.except("requests", "fields_gold").merge("field_count" => Array(unit["fields_gold"]).size)
    end

    def count_and_price!(units)
      client = build_client
      units.each do |unit|
        next unless unit["status"] == "ready" && unit["worst_usd"].nil?

        per_model = {}
        MODELS.each do |model|
          request = unit.dig("requests", model)
          count = client.messages.count_tokens(
            model: model,
            system: request.dig(:params, :system),
            messages: request.dig(:params, :messages)
          )
          tokens = count.input_tokens.to_i
          per_model[model] = { "input_tokens" => tokens, "worst_usd" => worst_case_usd(tokens).to_s("F") }
        rescue StandardError => e
          unit["status"] = "excluded"
          unit["exclude_reason"] = "count_tokens_#{model}:#{e.class}:#{e.message.to_s[0, 180]}"
          per_model = nil
          break
        end
        next if per_model.nil?

        unit["token_projection"] = per_model
        unit["worst_usd"] = per_model.values.sum(BigDecimal("0")) { |row| BigDecimal(row["worst_usd"]) }
      end
      projection = units.map do |unit|
        {
          "id" => unit["id"],
          "status" => unit["status"],
          "exclude_reason" => unit["exclude_reason"],
          "token_projection" => unit["token_projection"],
          "worst_usd" => unit["worst_usd"]&.to_s("F")
        }.compact
      end
      write_json(ROOT.join("projection.json"), projection)
    end

    def next_wave(units, remaining)
      count_and_price!(units)
      reserved = BigDecimal("0")
      units.select { |unit| unit["status"] == "ready" }.each_with_object([]) do |unit, wave|
        cost = unit["worst_usd"]
        next if cost.nil?
        next if reserved + cost > remaining

        wave << unit
        reserved += cost
      end
    end

    def run_wave(state, wave)
      MODELS.each do |model|
        requests = wave.map { |unit| unit.dig("requests", model) }
        batch = ClaudeBatchClient.new(client: build_client).submit_batch(requests: requests)
        entry = {
          "model" => model,
          "batch_id" => batch.id,
          "unit_ids" => wave.map { |unit| unit["id"] },
          "status" => "submitted",
          "submitted_at" => Time.now.utc.iso8601
        }
        state["waves"] << entry
        save_state(state)
        puts "F2B submitted #{model} #{batch.id}"
      end
      reconcile_submitted_waves(state, wave)
    end

    def reconcile_submitted_waves(state, units)
      index = Array(units).index_by { |unit| unit["id"] }
      state["waves"].each do |wave|
        next if wave["status"] == "ended"

        poll_batch(wave)
        ingest_wave(wave, index)
        wave["status"] = "ended"
        save_state(state)
      end
      units.each do |unit|
        next unless unit["status"] == "ready"
        next unless state["waves"].any? { |wave| wave["status"] == "ended" && wave["unit_ids"].include?(unit["id"]) }

        if MODELS.all? { |model| result_path(unit["id"], model).file? }
          score_unit(unit)
          unit["status"] = "scored"
        end
      end
    end

    def poll_batch(wave)
      client = ClaudeBatchClient.new(client: build_client)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8 * 60 * 60
      loop do
        batch = client.retrieve(batch_id: wave["batch_id"])
        status = batch.processing_status.to_s
        counts = batch.request_counts.respond_to?(:to_h) ? batch.request_counts.to_h : {}
        puts "F2B poll #{wave['model']} #{wave['batch_id']} #{status} #{counts.inspect}"
        break if status == "ended"
        raise Stop, "poll timeout #{wave['batch_id']}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 20
      end
      dir = ROOT.join("batch_results")
      FileUtils.mkdir_p(dir)
      path = dir.join("#{wave['model']}.#{wave['batch_id']}.jsonl")
      return if path.file? && path.size.positive?

      File.open(path, "w") do |file|
        client.results_each(batch_id: wave["batch_id"]) do |result|
          file.puts JSON.generate(serialize_result(result))
        end
      end
      wave["results_path"] = path.to_s
    end

    def ingest_wave(wave, index)
      path = Pathname(wave["results_path"].to_s)
      path = ROOT.join("batch_results/#{wave['model']}.#{wave['batch_id']}.jsonl") unless path.file?
      costs = []
      File.foreach(path) do |line|
        row = JSON.parse(line)
        unit = index[row["unit_id"]] || index.values.find { |item| item["custom_id"] == row["custom_id"] }
        next if unit.nil?

        row["unit_id"] = unit["id"]
        usage = row["usage"] || {}
        priced = batch_cost(usage)
        row["cost"] = priced
        costs << BigDecimal(priced["total"])
        write_json(result_path(unit["id"], wave["model"]), row)
        if row["result_type"] != "succeeded" || row["text"].blank?
          unit["compatibility_fail"] = true
          unit["compatibility_reason"] = "#{wave['model']}:#{row['result_type']}:#{row['error']}"
        elsif row["block_types"]&.include?("thinking") && row["text"].blank?
          unit["compatibility_fail"] = true
          unit["compatibility_reason"] = "#{wave['model']}:thinking_without_text"
        end
      end
      wave["cost_usd"] = costs.sum(BigDecimal("0")).round(6).to_s("F")
    end

    def score_unit(unit)
      FileUtils.mkdir_p(ROOT.join("parsed_results"))
      text_layer = page_text_cached(unit)
      fields = []
      MODELS.each do |model|
        row = JSON.parse(result_path(unit["id"], model).read)
        parsed = parse_output(row["text"])
        write_json(ROOT.join("parsed_results/#{unit['id']}.#{model}.json"), parsed || { "parse_error" => true })
        Array(unit["fields_gold"]).each do |gold|
          judged = judge(gold, row, parsed, text_layer, unit)
          fields << judged.merge("model" => model)
        end
        unit["would_retry"] ||= {}
        unit["would_retry"][model] = BatchPageRetryService.needs_retry?(text: row["text"].to_s, stop_reason: row["stop_reason"])
      end
      unit["fields"] = fields
      unit.delete("requests")
    end

    def judge(gold, row, parsed, text_layer, unit)
      expect = gold["expect"]
      if expect == "NOT_SCORED"
        return gold.merge("result" => "NOT_SCORED", "safety" => false)
      end

      result, safety = case gold["scope"]
      when "json" then [ row["json_parsed"] ? "PASS" : "FAIL", false ]
      when "text_block" then [ row["text"].present? ? "PASS" : "FAIL", false ]
      when "stop" then [ row["stop_reason"] == "max_tokens" ? "FAIL" : "PASS", false ]
      when "blob", "records" then judge_phrase(gold, parsed)
      when "safety" then judge_safety(gold, parsed, text_layer)
      when "section_identity" then judge_section(parsed, text_layer)
      else judge_structure(gold, parsed, unit)
      end
      gold.merge("result" => result, "safety" => safety)
    end

    def judge_phrase(gold, parsed)
      return [ "FAIL", false ] if parsed.nil?

      haystack = gold["scope"] == "records" ? records_blob(parsed) : blob(parsed)
      squash(haystack).include?(squash(gold["phrase"])) ? [ "PASS", false ] : [ "FAIL", false ]
    end

    def judge_safety(gold, parsed, text_layer)
      return [ "NOT_SCORED", false ] if parsed.nil?

      case gold["id"]
      when "no_invented_brand"
        invented = BRANDS.select { |brand| word?(blob(parsed), brand) && !word?(text_layer, brand) }
        invented.empty? ? [ "PASS", false ] : [ "FAIL", true ]
      when "no_invented_code"
        output = canon_codes(blob(parsed))
        source = canon_codes(text_layer)
        invented = CODES.select { |code| output.include?(code) && source.exclude?(code) }
        invented.empty? ? [ "PASS", false ] : [ "FAIL", true ]
      when "no_invented_unit"
        invented = unit_numbers(blob(parsed)).reject { |number| number_in_source?(number, text_layer) }
        invented.empty? ? [ "PASS", false ] : [ "FAIL", true ]
      else
        [ "NOT_SCORED", false ]
      end
    end

    def judge_section(parsed, text_layer)
      return [ "NOT_SCORED", false ] if parsed.nil?

      value = parsed["section_identity"].to_s.strip
      return [ "PASS", false ] if value.empty?

      squash(text_layer).include?(squash(value)) ? [ "PASS", false ] : [ "FAIL", true ]
    end

    def judge_structure(gold, parsed, unit)
      return [ "FAIL", false ] if parsed.nil?

      chunks = Array(parsed["chunks"])
      texts = chunks.map { |chunk| chunk["text"].to_s }
      case gold["scope"]
      when "document_name"
        parsed["document_name"].to_s.strip.empty? ? [ "FAIL", false ] : [ "PASS", false ]
      when "page_number"
        chunks.any? && chunks.all? { |chunk| chunk["page"].to_i == unit["page_of"] } ? [ "PASS", false ] : [ "FAIL", false ]
      when "s0_present"
        texts.any? { |text| text.match?(/\bS0\b/) } ? [ "PASS", false ] : [ "FAIL", false ]
      when "s0_absent"
        texts.any? { |text| text.match?(/\bS0\b/) } ? [ "FAIL", false ] : [ "PASS", false ]
      when "summary_present"
        parsed["summary"].to_s.strip.empty? ? [ "FAIL", false ] : [ "PASS", false ]
      when "summary_absent"
        parsed["summary"].to_s.strip.empty? ? [ "PASS", false ] : [ "FAIL", false ]
      when "companion_present"
        parsed["companion_offer"].to_s.strip.empty? ? [ "FAIL", false ] : [ "PASS", false ]
      when "companion_absent"
        parsed["companion_offer"].to_s.strip.empty? ? [ "PASS", false ] : [ "FAIL", false ]
      else
        [ "NOT_SCORED", false ]
      end
    end

    def build_aggregate(units, state, budget_stop:)
      per_unit = units.map { |unit| scored_public(unit) }
      decision = decide(per_unit: per_unit, compatibility_fail: units.any? { |unit| unit["compatibility_fail"] })
      {
        "gate" => decision["gate"],
        "reason" => decision["reason"],
        "regressions" => decision["regressions"],
        "budget_stop" => budget_stop,
        "budget_usd" => BUDGET.to_s("F"),
        "spent_usd" => spent_usd(state).to_s("F"),
        "price_source" => PRICE_SOURCE,
        "rates_per_1k" => RATES.transform_values { |rate| rate.to_s("F") },
        "categories" => category_rollup(per_unit),
        "units" => per_unit,
        "compatibility_failures" => units.filter_map { |unit| unit["compatibility_reason"] }
      }
    end

    def category_rollup(per_unit)
      rollup = Hash.new { |hash, key| hash[key] = Hash.new { |inner, model| inner[model] = { "PASS" => 0, "FAIL" => 0, "NOT_SCORED" => 0, "SAFETY_FAIL" => 0 } } }
      per_unit.each do |unit|
        Array(unit["fields"]).each do |field|
          bucket = rollup[field["category"]][field["model"]]
          bucket[field["result"]] += 1 if bucket.key?(field["result"])
          bucket["SAFETY_FAIL"] += 1 if field["safety"]
        end
      end
      rollup
    end

    def scored_public(unit)
      {
        "id" => unit["id"],
        "status" => unit["status"],
        "role" => unit["role"],
        "kinds" => unit["kinds"],
        "exclude_reason" => unit["exclude_reason"],
        "semantic_sha256" => unit["semantic_sha256"],
        "would_retry" => unit["would_retry"],
        "compatibility_fail" => unit["compatibility_fail"] || false,
        "fields" => unit["fields"]
      }
    end

    def cost_report(state, aggregate)
      {
        "budget_usd" => BUDGET.to_s("F"),
        "spent_usd" => aggregate["spent_usd"],
        "price_source" => PRICE_SOURCE,
        "rates_per_1k_tokens" => RATES.transform_values { |rate| rate.to_s("F") },
        "direct_usd" => "0",
        "waves" => state["waves"],
        "projection" => load_projection
      }
    end

    def load_projection
      path = ROOT.join("projection.json")
      path.file? ? JSON.parse(path.read) : []
    end

    def serialize_result(result)
      type = result.result.type.to_s
      row = { "custom_id" => result.custom_id, "result_type" => type }
      if type == "succeeded"
        message = result.result.message
        content = message.respond_to?(:content) ? message.content : []
        text = extract_text(content)
        row.merge!(
          "returned_model_id" => message.model.to_s,
          "stop_reason" => (message.respond_to?(:stop_reason) ? message.stop_reason.to_s : nil),
          "block_types" => content.map { |block| block_type(block) },
          "text" => text,
          "json_parsed" => json_parsed?(text),
          "usage" => read_usage(message.usage)
        )
      else
        error = result.result.respond_to?(:error) ? result.result.error : nil
        row["error"] = error.respond_to?(:message) ? error.message : error.to_s
      end
      row
    end

    def extract_text(content)
      content.each do |block|
        return block_text(block).to_s if block_type(block) == "text"
      end
      ""
    end

    def block_type(block)
      block.respond_to?(:type) ? block.type.to_s : block.to_s
    end

    def block_text(block)
      return block.text if block.respond_to?(:text)
      return block[:text] || block["text"] if block.is_a?(Hash)

      nil
    end

    def read_usage(usage)
      return empty_usage if usage.nil?

      raw = usage.respond_to?(:to_h) ? usage.to_h : {}
      data = raw.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
      nested = data["cache_creation"]
      one_h = 0
      five_m = 0
      if nested.respond_to?(:to_h)
        nested_hash = nested.to_h.transform_keys(&:to_s)
        five_m = nested_hash["ephemeral_5m_input_tokens"].to_i
        one_h = nested_hash["ephemeral_1h_input_tokens"].to_i
      end
      creation = data["cache_creation_input_tokens"].to_i
      five_m = creation - one_h if creation.positive?
      five_m = 0 if five_m.negative?
      {
        "input_tokens" => data["input_tokens"].to_i,
        "output_tokens" => data["output_tokens"].to_i,
        "cache_read_input_tokens" => data["cache_read_input_tokens"].to_i,
        "cache_creation_input_tokens" => five_m,
        "cache_creation_1h_input_tokens" => one_h
      }
    end

    def empty_usage
      {
        "input_tokens" => 0,
        "output_tokens" => 0,
        "cache_read_input_tokens" => 0,
        "cache_creation_input_tokens" => 0,
        "cache_creation_1h_input_tokens" => 0
      }
    end

    def json_parsed?(text)
      LlmJsonParser.parseable?(text)
    end

    def parse_output(text)
      LlmJsonParser.parse(text)
    rescue JSON::ParserError
      nil
    end

    def blob(parsed)
      parts = [ parsed["document_name"], parsed["summary"], parsed["companion_offer"], parsed["section_identity"] ]
      Array(parsed["aliases"]).each { |alias_name| parts << alias_name }
      Array(parsed["chunks"]).each do |chunk|
        parts << chunk["text"]
        Array(chunk["aliases"]).each { |alias_name| parts << alias_name }
        Array(chunk["field_records"]).each { |record| parts << record.values }
      end
      parts.flatten.compact.join("\n")
    end

    def records_blob(parsed)
      Array(parsed["chunks"]).flat_map { |chunk| Array(chunk["field_records"]) }.map(&:values).flatten.compact.join("\n")
    end

    def squash(text)
      I18n.transliterate(text.to_s).downcase.gsub(/\s+/, " ").strip
    end

    def canon_codes(text)
      squash(text).gsub(/arca\s*ii/, "arcaii")
    end

    def word?(text, brand)
      squash(text).match?(/\b#{Regexp.escape(brand)}\b/)
    end

    def unit_numbers(text)
      text.to_s.scan(UNIT_RE).map(&:first)
    end

    def number_in_source?(number, source)
      forms = [ number, number.tr(",", "."), number.tr(".", ",") ].uniq
      forms.any? { |form| source.to_s.match?(/#{Regexp.escape(form)}(?!\d)/i) }
    end

    def money(tokens, rate)
      (BigDecimal(tokens.to_i.to_s) / 1000 * rate).round(6)
    end

    def stringify_request(request)
      JSON.parse(JSON.generate(request))
    end

    def index_fields(fields)
      Array(fields).index_by { |field| field["id"] }
    end

    def result_path(unit_id, model)
      ROOT.join("batch_results/#{unit_id}.#{model}.json")
    end

    def page_text_cached(unit)
      @page_text ||= {}
      @page_text[unit["id"]] ||= begin
        spec = UNIT_SPECS.find { |item| item["id"] == unit["id"] }
        page_text_for(spec)
      end
    end

    def spent_usd(state)
      Array(state["waves"]).sum(BigDecimal("0")) { |wave| BigDecimal(wave["cost_usd"].presence || "0") }
    end

    def load_state
      path = ROOT.join("state.json")
      return { "waves" => [] } unless path.file?

      JSON.parse(path.read)
    end

    def save_state(state)
      write_json(ROOT.join("state.json"), state)
    end

    def build_client
      api_key = ENV["ANTHROPIC_API_KEY"].presence || Rails.application.credentials.dig(:anthropic, :api_key)
      raise Stop, "MissingCredential" if api_key.blank?

      Anthropic::Client.new(api_key: api_key, max_retries: 0)
    end

    def write_json(path, payload)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, JSON.pretty_generate(payload) + "\n")
    end

    def write_json_compact(path, payload)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, JSON.generate(payload))
    end

    def write_checksums
      lines = Dir.glob(ROOT.join("**/*").to_s).filter_map do |file|
        next if File.directory?(file)
        next if file.end_with?("SHA256SUMS.txt")

        "#{Digest::SHA256.file(file).hexdigest}  #{Pathname(file).relative_path_from(ROOT)}"
      end
      File.write(ROOT.join("SHA256SUMS.txt"), lines.sort.join("\n") + "\n")
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    runner = ENV["F2B_MODE"] == "control_only" ? :run_control_only : :run
    exit FieldCompanion::IngestionModelRefresh.public_send(runner)
  rescue FieldCompanion::IngestionModelRefresh::Stop => e
    warn "F2B STOP #{e.message}"
    exit 2
  end
end
