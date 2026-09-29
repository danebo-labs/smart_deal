# frozen_string_literal: true

# Field Companion F1 evidence extension.
# Same two model ids, same request contract as F1, fifteen images, one call
# each. Does not change production, routing, resolution, preprocessing, or
# FieldPhotoPrompt. Anthropic::Client only. No job enqueue.
#
# Usage: env -u BUNDLE_PATH bin/rails runner script/field_companion/visual_benchmark_extended.rb

require "bigdecimal"
require "digest"
require "fileutils"
require "json"

require_relative "../../config/environment" unless defined?(Rails) && Rails.application
require_relative "visual_benchmark"

module FieldCompanion
  module VisualBenchmarkExtended
    class Stop < StandardError; end
    class Blocked < StandardError; end

    Bench = VisualBenchmark
    DATASET_DIR = Rails.root.join("tmp/field_companion/images/f1_extended")
    ROOT = Rails.root.join("tmp/field_companion/f1_extended")
    MODELS = Bench::MODELS
    MAX_TOKENS = Bench::MAX_TOKENS
    FINGERPRINT = Bench::FINGERPRINT
    SPRING_CASE = Bench::SPRING_CASE
    SPRING_SHA = "202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd"
    BUDGET_CAP = BigDecimal("1.00")
    # Pre-call output ceiling. Raised to the largest output already observed.
    # Not a price. The billed cost uses the API usage block.
    OUTPUT_TOKEN_CEILING = 2_500
    ESTIMATE_MARGIN = BigDecimal("1.25")
    USER_TEXT_SLACK = 400
    CACHE_TOKEN_SLACK = 1_800
    PRICE_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing"
    # USD per 1_000 tokens. Claude Sonnet 5.5 and Claude Opus 5.5 rows:
    # input, 5-minute cache write, cache hit, output. 1-hour write is priced
    # only when the usage split reports it. Ephemeral cache_control is 5 minutes.
    RATES = {
      "claude-sonnet-5-5" => {
        input: BigDecimal("0.002"),
        output: BigDecimal("0.01"),
        cache_read: BigDecimal("0.0002"),
        cache_creation_5m: BigDecimal("0.0025"),
        cache_creation_1h: BigDecimal("0.004")
      },
      "claude-opus-5-5" => {
        input: BigDecimal("0.004"),
        output: BigDecimal("0.02"),
        cache_read: BigDecimal("0.0002"),
        cache_creation_5m: BigDecimal("0.005"),
        cache_creation_1h: BigDecimal("0.008")
      }
    }.freeze
    OTHER_BRANDS = %w[otis kone schindler thyssen fuji mitsubishi orona].freeze
    WEAK_PASS_RATE = BigDecimal("0.5")
    OPUS_WIN_FLOOR = 2
    MATERIAL_GAP = BigDecimal("0.10")
    TIE_MARGIN = BigDecimal("0.05")

    module_function

    def run(client: nil, dataset_dir: DATASET_DIR, root: ROOT, io: $stdout, budget_cap: BUDGET_CAP)
      ensure_fingerprint!
      rows = load_dataset!(dataset_dir)
      http = client || build_client
      result = execute_rows(rows, client: http, root: root, budget_cap: budget_cap, io: io)
      write_artifacts!(root, result, rows)
      print_summary(io, result)
      result["status"] == "BLOCKED" ? 2 : 0
    rescue Blocked => e
      io.puts "F1_EXTENDED_STATUS=BLOCKED"
      io.puts e.message
      2
    rescue Stop, Bench::Stop => e
      io.puts "F1_EXTENDED_STATUS=STOP"
      io.puts e.message
      3
    end

    def ensure_fingerprint!
      actual = FieldPhotoPrompt.prompt_fingerprint_sha256
      raise Stop, "prompt fingerprint mismatch" unless actual == FINGERPRINT
    end

    def load_dataset!(dir)
      raise Blocked, "dataset missing" unless dir.directory?

      sums = read_sums(dir.join("SHA256SUMS.txt"))
      names = dir.children.select { |path| path.file? && image_name?(path.basename.to_s) }.map { |path| path.basename.to_s }
      expected = CASES.pluck("filename")
      raise Blocked, "dataset is not the 15 frozen images" unless names.sort == expected.sort

      CASES.map { |row| load_row(dir, row, sums) }
    end

    def load_row(dir, row, sums)
      path = dir.join(row["filename"])
      binary = File.binread(path)
      sha = Digest::SHA256.hexdigest(binary)
      registered = sums&.[](row["filename"])
      raise Blocked, "registered sha256 mismatch #{row["filename"]}" if registered && registered != sha
      raise Blocked, "spring image sha256 mismatch" if row["case_id"] == SPRING_CASE && sha != SPRING_SHA

      media_type = media_type_for(binary, row["filename"])
      width, height = image_size(binary, media_type)
      row.merge(
        "path" => path.to_s,
        "bytes" => binary.bytesize,
        "sha256" => sha,
        "media_type" => media_type,
        "width" => width,
        "height" => height
      )
    end

    def execute_rows(rows, client:, root:, budget_cap:, output_token_ceiling: OUTPUT_TOKEN_CEILING, io: nil)
      scored = []
      accumulated = BigDecimal(0)
      ceiling = output_token_ceiling
      stop_reason = nil
      rows.each do |row|
        break if stop_reason

        case_result, accumulated, ceiling, stop_reason = execute_case(
          row,
          client: client,
          root: root,
          accumulated: accumulated,
          budget_cap: budget_cap,
          output_token_ceiling: ceiling,
          io: io
        )
        scored << case_result if case_result["models"].any?
      end
      result = build_result(
        scored,
        accumulated: accumulated,
        budget_cap: budget_cap,
        stop_reason: stop_reason,
        ceiling: ceiling
      )
      result["pending_case_ids"] = rows.pluck("case_id") - scored.pluck("case_id")
      result["partial_case_ids"] = scored.select { |row| row["models"].size < MODELS.size }.pluck("case_id")
      result
    end

    def execute_case(row, client:, root:, accumulated:, budget_cap:, output_token_ceiling:, io: nil)
      binary = File.binread(row["path"])
      sha = Digest::SHA256.hexdigest(binary)
      raise Blocked, "image sha256 mismatch" unless sha == row["sha256"]

      models = {}
      seen = nil
      stop_reason = nil
      MODELS.each do |model_id|
        params = Bench.request_params(
          model_id: model_id,
          binary: binary,
          media_type: row.fetch("media_type"),
          filename: row.fetch("filename")
        )
        request_sha = Bench.request_sha256(params)
        bytes_sha = Bench.bytes_sha_from_params(params)
        seen = Bench.remember_pair!(seen, bytes_sha: bytes_sha, request_sha: request_sha, file_sha: sha)
        stored = read_stored_call(root, row["case_id"], model_id)
        if final_call?(stored, model_id: model_id, bytes_sha: bytes_sha, request_sha: request_sha)
          call = stored.merge("reused" => true)
        else
          estimate = estimate_cost(model_id, width: row["width"], height: row["height"], output_tokens: output_token_ceiling)
          if exceeds_cap?(accumulated, estimate, budget_cap)
            stop_reason = "budget"
            break
          end
          call = perform_call(
            model_id: model_id,
            params: params,
            bytes_sha: bytes_sha,
            request_sha: request_sha,
            client: client,
            estimate: estimate
          )
          write_json(call_path(root, row["case_id"], model_id), call)
        end
        refresh_sidecars(root, row["case_id"], model_id, call)
        priced = price_call(call)
        accumulated = add_cost(accumulated, priced)
        output_token_ceiling = [ output_token_ceiling, call["output_tokens"].to_i ].max if call["success"]
        models[model_id] = score_call(row, call, priced)
        io&.puts [
          row["case_id"],
          model_id,
          "success=#{call["success"]}",
          "cost=#{priced["estimated_cost"]}",
          "accumulated=#{format_money(accumulated)}"
        ].join(" ")
        if priced["estimated_cost"] == "UNKNOWN" && call["success"]
          stop_reason = "unknown_cost"
          break
        end
      end
      case_result = {
        "case_id" => row["case_id"],
        "filename" => row["filename"],
        "media_type" => row["media_type"],
        "bytes" => binary.bytesize,
        "sha256" => sha,
        "width" => row["width"],
        "height" => row["height"],
        "subject" => row["subject"],
        "models" => models
      }
      [ case_result, accumulated, output_token_ceiling, stop_reason ]
    end

    def perform_call(model_id:, params:, bytes_sha:, request_sha:, client:, estimate:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      message = client.messages.create(params)
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      text = Bench.message_text(message)
      cache = cache_parts(message)
      {
        "requested_model_id" => model_id,
        "returned_model_id" => Bench.message_model(message),
        "bytes_sha256" => bytes_sha,
        "request_sha256" => request_sha,
        "system_prompt_fingerprint_sha256" => FINGERPRINT,
        "max_tokens" => MAX_TOKENS,
        "success" => true,
        "error_class" => nil,
        "error_message" => nil,
        "output_text" => text,
        "input_tokens" => Bench.usage_integer(message, :input_tokens),
        "output_tokens" => Bench.usage_integer(message, :output_tokens),
        "cache_read_tokens" => cache["cache_read_tokens"],
        "cache_creation_tokens" => cache["cache_creation_tokens"],
        "cache_creation_5m_tokens" => cache["cache_creation_5m_tokens"],
        "cache_creation_1h_tokens" => cache["cache_creation_1h_tokens"],
        "latency_ms" => latency_ms,
        "client_max_retries" => 0,
        "retry_count" => 0,
        "reused" => false,
        "pre_call_estimate" => format_money(estimate),
        "timestamp" => Time.now.utc.iso8601
      }
    rescue Bench::Stop
      raise
    rescue StandardError => e
      {
        "requested_model_id" => model_id,
        "returned_model_id" => "",
        "bytes_sha256" => bytes_sha,
        "request_sha256" => request_sha,
        "system_prompt_fingerprint_sha256" => FINGERPRINT,
        "max_tokens" => MAX_TOKENS,
        "success" => false,
        "error_class" => e.class.name,
        "error_message" => redact(e.message),
        "output_text" => "",
        "input_tokens" => nil,
        "output_tokens" => nil,
        "cache_read_tokens" => nil,
        "cache_creation_tokens" => nil,
        "cache_creation_5m_tokens" => nil,
        "cache_creation_1h_tokens" => nil,
        "latency_ms" => nil,
        "client_max_retries" => 0,
        "retry_count" => 0,
        "reused" => false,
        "pre_call_estimate" => format_money(estimate),
        "timestamp" => Time.now.utc.iso8601
      }
    end

    def score_call(row, call, priced)
      parsed = call["success"] ? parse_json(call["output_text"]) : nil
      fields = call["success"] ? Bench.ordered_fields(Bench.score_gold(row.fetch("gold"), parsed)) : {}
      safety = call["success"] ? safety_failures(row, parsed, fields) : []
      call.merge(
        "parsed" => parsed,
        "fields" => fields,
        "safety_fail" => safety.any?,
        "safety_reasons" => safety
      ).merge(priced).except("output_text")
    end

    def safety_failures(row, parsed, fields)
      reasons = []
      %w[manufacturer model visible_text].each do |name|
        field = fields[name]
        next unless field && field["status"] == "MUST_BE_UNKNOWN" && field["result"] == "FAIL"

        reasons << "invented_#{name}"
      end
      if row["subject"] == "document" && fields.dig("component", "result") == "FAIL"
        reasons << "document_as_physical"
      end
      reasons << "undocumented_function_as_fact" if row["functions_must_be_empty"] && functions_present?(parsed)
      reasons << "incompatible_identity" if incompatible_identity?(row, fields)
      reasons
    end

    def functions_present?(parsed)
      return false unless parsed.is_a?(Hash)

      Array(parsed["documented_functions"]).any?
    end

    def incompatible_identity?(row, fields)
      spec = row.dig("gold", "manufacturer")
      return false unless spec && spec["status"] == "VERIFIED"

      text = fields.dig("manufacturer", "normalized_text").to_s
      Array(spec["fail_if"]).any? { |fragment| Bench.substring?(text, fragment) }
    end

    def evidence_class(metrics)
      return nil if metrics["complete_pairs"].to_i < 1

      sonnet_rate = decimal_or_nil(metrics["sonnet_pass_rate"])
      opus_rate = decimal_or_nil(metrics["opus_pass_rate"])
      return "E3" if sonnet_rate.nil? || opus_rate.nil?

      shared_fails = metrics["shared_fails"].to_i
      opus_wins = metrics["opus_only_wins"].to_i
      sonnet_wins = metrics["sonnet_only_wins"].to_i
      sonnet_safety = metrics.dig("safety_fail_count", MODELS[0]).to_i
      opus_safety = metrics.dig("safety_fail_count", MODELS[1]).to_i
      if sonnet_rate < WEAK_PASS_RATE && opus_rate < WEAK_PASS_RATE &&
          shared_fails.positive? && shared_fails >= opus_wins && shared_fails >= sonnet_wins
        return "E4"
      end
      if opus_wins >= OPUS_WIN_FLOOR && opus_wins > sonnet_wins &&
          (opus_rate - sonnet_rate) >= MATERIAL_GAP && opus_safety <= sonnet_safety
        return "E2"
      end
      if (sonnet_rate + TIE_MARGIN) >= opus_rate && sonnet_safety <= opus_safety && opus_wins < OPUS_WIN_FLOOR
        return "E1"
      end

      "E3"
    end

    def price_call(call)
      rates = rates_for(call["requested_model_id"], call["returned_model_id"])
      blank = {
        "input_cost" => "UNKNOWN",
        "output_cost" => "UNKNOWN",
        "cache_read_cost" => "UNKNOWN",
        "cache_creation_cost" => "UNKNOWN",
        "cache_creation_5m_cost" => "UNKNOWN",
        "cache_creation_1h_cost" => "UNKNOWN",
        "input_output_cost" => "UNKNOWN",
        "estimated_cost" => "UNKNOWN",
        "price_source" => nil
      }
      return blank unless call["success"] && rates
      return blank if call["input_tokens"].nil? || call["output_tokens"].nil?
      return blank if call["cache_read_tokens"].nil? || call["cache_creation_5m_tokens"].nil?

      input_cost = money(call["input_tokens"], rates[:input])
      output_cost = money(call["output_tokens"], rates[:output])
      read_cost = money(call["cache_read_tokens"], rates[:cache_read])
      create_5m = money(call["cache_creation_5m_tokens"], rates[:cache_creation_5m])
      create_1h = money(call["cache_creation_1h_tokens"].to_i, rates[:cache_creation_1h])
      create_cost = create_5m + create_1h
      input_output = input_cost + output_cost
      {
        "input_cost" => format_money(input_cost),
        "output_cost" => format_money(output_cost),
        "cache_read_cost" => format_money(read_cost),
        "cache_creation_cost" => format_money(create_cost),
        "cache_creation_5m_cost" => format_money(create_5m),
        "cache_creation_1h_cost" => format_money(create_1h),
        "input_output_cost" => format_money(input_output),
        "estimated_cost" => format_money(input_output + read_cost + create_cost),
        "price_source" => PRICE_SOURCE
      }
    end

    def estimate_cost(model_id, width:, height:, output_tokens:)
      rates = RATES.fetch(model_id)
      input_tokens = estimate_image_tokens(width, height) + USER_TEXT_SLACK
      raw = money(input_tokens, rates[:input]) +
        money(output_tokens, rates[:output]) +
        money(CACHE_TOKEN_SLACK, rates[:cache_creation_5m])
      (raw * ESTIMATE_MARGIN).round(6)
    end

    def estimate_image_tokens(width, height)
      return 4_000 if width.to_i <= 0 || height.to_i <= 0

      w = width.to_f
      h = height.to_f
      long = [ w, h ].max
      if long > 1_568
        scale = 1_568.0 / long
        w = (w * scale).ceil
        h = (h * scale).ceil
      end
      pixels = w * h
      if pixels > 1_150_000
        scale = Math.sqrt(1_150_000.0 / pixels)
        w = (w * scale).ceil
        h = (h * scale).ceil
      end
      [ (w * h / 750.0).ceil, 1 ].max
    end

    def exceeds_cap?(accumulated, estimate, cap)
      accumulated + estimate > cap
    end

    def aggregate_metrics(cases)
      complete = cases.select { |row| MODELS.all? { |model| row.dig("models", model, "success") } }
      outcomes = complete.map { |row| pair_outcome(row) }
      by_model = MODELS.index_with { |model| model_metrics(cases, model) }
      metrics = {
        "complete_pairs" => complete.size,
        "sonnet_only_wins" => outcomes.count("sonnet_only"),
        "opus_only_wins" => outcomes.count("opus_only"),
        "shared_passes" => outcomes.count("shared_pass"),
        "shared_fails" => outcomes.count("shared_fail"),
        "shared_safety_fails" => complete.count { |row|
          MODELS.all? { |model| row.dig("models", model, "safety_fail") }
        },
        "sonnet_pass_rate" => by_model.dig(MODELS[0], "pass_rate"),
        "opus_pass_rate" => by_model.dig(MODELS[1], "pass_rate"),
        "safety_fail_count" => MODELS.index_with { |model| by_model.dig(model, "safety_fail_count") },
        "by_model" => by_model
      }
      metrics["evidence_class"] = evidence_class(metrics)
      metrics
    end

    def model_metrics(cases, model)
      entries = cases.filter_map { |row| row.dig("models", model) }
      successes = entries.select { |item| item["success"] }
      scored = successes.flat_map { |item| scored_fields(item["fields"]) }
      passes = scored.count { |field| field["result"] == "PASS" }
      fails = scored.count { |field| field["result"] == "FAIL" }
      latencies = successes.filter_map { |item| item["latency_ms"] }
      {
        "component_accuracy" => field_accuracy(successes, "component", "VERIFIED"),
        "manufacturer_accuracy" => field_accuracy(successes, "manufacturer", "VERIFIED"),
        "model_accuracy" => field_accuracy(successes, "model", "VERIFIED"),
        "visible_text_accuracy" => field_accuracy(successes, "visible_text", "VERIFIED"),
        "must_be_unknown_compliance" => unknown_compliance(successes),
        "safety_fail_count" => successes.count { |item| item["safety_fail"] },
        "scored_fields" => scored.size,
        "pass" => passes,
        "fail" => fails,
        "pass_rate" => scored.empty? ? nil : format_rate(passes, scored.size),
        "latency_ms_total" => latencies.sum,
        "latency_ms_p50" => percentile(latencies, 50),
        "latency_ms_p95" => percentile(latencies, 95),
        "input_tokens" => successes.sum { |item| item["input_tokens"].to_i },
        "output_tokens" => successes.sum { |item| item["output_tokens"].to_i },
        "cache_creation_tokens" => successes.sum { |item| item["cache_creation_tokens"].to_i },
        "cache_read_tokens" => successes.sum { |item| item["cache_read_tokens"].to_i },
        "estimated_cost" => sum_money(successes)
      }
    end

    def field_accuracy(entries, name, status)
      fields = entries.filter_map { |item| item.dig("fields", name) }
        .select { |field| field["status"] == status && field["result"] }
      return nil if fields.empty?

      passes = fields.count { |field| field["result"] == "PASS" }
      { "pass" => passes, "scored" => fields.size, "accuracy" => format_rate(passes, fields.size) }
    end

    def unknown_compliance(entries)
      fields = entries.flat_map { |item| Array(item["fields"]&.values) }
        .select { |field| field["status"] == "MUST_BE_UNKNOWN" && field["result"] }
      return nil if fields.empty?

      passes = fields.count { |field| field["result"] == "PASS" }
      { "pass" => passes, "scored" => fields.size, "compliance" => format_rate(passes, fields.size) }
    end

    def pair_outcome(row)
      sonnet = row.dig("models", MODELS[0], "fields")
      opus = row.dig("models", MODELS[1], "fields")
      return nil if scored_fields(sonnet).empty? || scored_fields(opus).empty?

      sonnet_pass = all_pass?(sonnet)
      opus_pass = all_pass?(opus)
      sonnet_fail = any_fail?(sonnet)
      opus_fail = any_fail?(opus)
      return "sonnet_only" if sonnet_pass && opus_fail
      return "opus_only" if opus_pass && sonnet_fail
      return "shared_pass" if sonnet_pass && opus_pass
      return "shared_fail" if sonnet_fail && opus_fail

      nil
    end

    def percentile(values, percentile_value)
      sorted = values.compact.sort
      return nil if sorted.empty?
      return sorted.first if sorted.size == 1

      rank = (BigDecimal(percentile_value.to_s) / 100) * (sorted.size - 1)
      low = sorted[rank.floor]
      high = sorted[rank.ceil]
      (low + ((high - low) * (rank - rank.floor))).round
    end

    def build_result(cases, accumulated:, budget_cap:, stop_reason:, ceiling:)
      metrics = aggregate_metrics(cases)
      status = if stop_reason == "budget"
        "BUDGET_STOP"
      elsif stop_reason == "unknown_cost"
        "UNKNOWN_COST_STOP"
      else
        "COMPLETE"
      end
      {
        "phase" => "F1_EXTENDED",
        "status" => status,
        "stop_reason" => stop_reason,
        "budget_cap" => format_money(budget_cap),
        "accumulated_estimated_cost" => format_money(accumulated),
        "remaining_budget_estimate" => format_money(budget_cap - accumulated),
        "output_token_ceiling" => ceiling,
        "system_prompt_fingerprint_sha256" => FINGERPRINT,
        "locale" => "es",
        "photo_intent" => "",
        "max_tokens" => MAX_TOKENS,
        "reads_model_text" => false,
        "uses_density_gate" => false,
        "client_max_retries" => 0,
        "calls" => cases.sum { |row| row["models"].size },
        "cases" => cases,
        "metrics" => metrics,
        "safety_failures" => safety_list(cases),
        "spring" => spring_summary(cases)
      }
    end

    def safety_list(cases)
      cases.flat_map { |row|
        MODELS.filter_map { |model|
          reasons = row.dig("models", model, "safety_reasons")
          next if reasons.blank?

          { "case_id" => row["case_id"], "model" => model, "reasons" => reasons }
        }
      }
    end

    def spring_summary(cases)
      row = cases.find { |item| item["case_id"] == SPRING_CASE }
      return nil unless row

      MODELS.to_h { |model|
        entry = row.dig("models", model) || {}
        [
          model,
          {
            "result" => entry.dig("fields", "component", "result"),
            "normalized_text" => entry.dig("fields", "component", "normalized_text"),
            "success" => entry["success"],
            "estimated_cost" => entry["estimated_cost"]
          }
        ]
      }
    end

    def write_artifacts!(root, result, rows)
      FileUtils.mkdir_p(root)
      manifest = {
        "dataset_dir" => "tmp/field_companion/images/f1_extended",
        "images" => rows.map { |row|
          row.slice("case_id", "filename", "media_type", "bytes", "sha256", "width", "height")
        }
      }
      write_frozen(root.join("gold_manifest.json"), gold_manifest)
      write_json(root.join("manifest.json"), manifest)
      public_cases = result["cases"].map { |row| public_case(row) }
      aggregate = result.merge("cases" => public_cases)
      write_json(root.join("aggregate.json"), aggregate)
      write_json(root.join("cost_report.json"), cost_report(result))
      write_sums(root)
    end

    def public_case(row)
      models = row["models"].transform_values { |entry|
        entry.except("parsed").merge("parsed_sha256" => sha_text(JSON.generate(entry["parsed"])))
      }
      row.merge("models" => models)
    end

    def cost_report(result)
      {
        "budget_cap" => result["budget_cap"],
        "accumulated_estimated_cost" => result["accumulated_estimated_cost"],
        "remaining_budget_estimate" => result["remaining_budget_estimate"],
        "price_source" => PRICE_SOURCE,
        "cache_priced_separately" => true,
        "output_token_ceiling" => result["output_token_ceiling"],
        "estimate_margin" => ESTIMATE_MARGIN.to_s("F"),
        "by_model" => MODELS.to_h { |model|
          metrics = result.dig("metrics", "by_model", model) || {}
          [ model, {
            "estimated_cost" => metrics["estimated_cost"],
            "input_tokens" => metrics["input_tokens"],
            "output_tokens" => metrics["output_tokens"],
            "cache_creation_tokens" => metrics["cache_creation_tokens"],
            "cache_read_tokens" => metrics["cache_read_tokens"]
          } ]
        }
      }
    end

    def gold_manifest
      {
        "frozen_before_model_output" => true,
        "spring_sha256" => SPRING_SHA,
        "cases" => CASES.map { |row|
          row.slice("case_id", "filename", "subject", "functions_must_be_empty", "gold_basis", "gold")
        }
      }
    end

    def write_frozen(path, payload)
      body = JSON.pretty_generate(payload) + "\n"
      if path.file? && File.read(path) != body
        raise Stop, "gold manifest changed after it was frozen"
      end

      write_raw(path, body) unless path.file?
    end

    def write_sums(root)
      lines = root.glob("**/*").select(&:file?).reject { |path| path.basename.to_s == "SHA256SUMS.txt" }.sort.map { |path|
        "#{Digest::SHA256.file(path).hexdigest}  #{path.relative_path_from(root)}"
      }
      write_raw(root.join("SHA256SUMS.txt"), lines.join("\n") + "\n")
    end

    def refresh_sidecars(root, case_id, model_id, call)
      output = root.join("outputs/#{case_id}.#{model_id}.txt")
      parsed_path = root.join("parsed/#{case_id}.#{model_id}.json")
      write_raw(output, call["output_text"].to_s)
      parsed = call["success"] ? parse_json(call["output_text"]) : nil
      write_json(parsed_path, parsed)
    end

    def cache_parts(message)
      usage = message.respond_to?(:usage) ? message.usage : message[:usage]
      total = usage_value(usage, :cache_creation_input_tokens)
      read = usage_value(usage, :cache_read_input_tokens)
      split = usage_value(usage, :cache_creation)
      five, one = cache_split(split, total)
      {
        "cache_read_tokens" => integer_or_nil(read),
        "cache_creation_tokens" => integer_or_nil(total) || ((five && one) ? five + one : nil),
        "cache_creation_5m_tokens" => five,
        "cache_creation_1h_tokens" => one
      }
    end

    def cache_split(split, total)
      five = usage_value(split, :ephemeral_5m_input_tokens)
      one = usage_value(split, :ephemeral_1h_input_tokens)
      return [ five.to_i, one.to_i ] if !five.nil? || !one.nil?
      return [ nil, nil ] if total.nil?

      [ total.to_i, 0 ]
    end

    def rates_for(requested, returned)
      return nil unless MODELS.include?(requested) && returned.to_s.start_with?(requested)

      RATES[requested]
    end

    def final_call?(stored, model_id:, bytes_sha:, request_sha:)
      return false unless stored.is_a?(Hash)
      return false unless stored["requested_model_id"] == model_id
      return false unless stored["bytes_sha256"] == bytes_sha
      return false unless stored["request_sha256"] == request_sha
      return false unless stored["system_prompt_fingerprint_sha256"] == FINGERPRINT
      return false unless stored["max_tokens"] == MAX_TOKENS

      stored["success"] == false || (stored["success"] == true && stored["output_text"].present?)
    end

    def read_stored_call(root, case_id, model_id)
      path = call_path(root, case_id, model_id)
      return nil unless path.file?

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def call_path(root, case_id, model_id)
      root.join("calls/#{case_id}.#{model_id}.json")
    end

    def read_sums(path)
      return nil unless path.file?

      path.each_line.filter_map { |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        hash, name = stripped.split(/\s+/, 2)
        [ File.basename(name.to_s.delete_prefix("*")), hash ]
      }.to_h
    end

    def media_type_for(binary, filename)
      detected = if binary.start_with?("\x89PNG\r\n\x1a\n".b)
        "image/png"
      elsif binary.start_with?("\xFF\xD8\xFF".b)
        "image/jpeg"
      else
        raise Blocked, "unsupported image #{filename}"
      end
      expected = { ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg" }[File.extname(filename).downcase]
      raise Blocked, "mime/extension mismatch #{filename}" unless expected == detected

      detected
    end

    def image_size(binary, media_type)
      if media_type == "image/png"
        return binary[16, 8].unpack("NN") if binary.bytesize >= 24
      elsif media_type == "image/jpeg"
        return jpeg_size(binary)
      end
      [ nil, nil ]
    end

    def jpeg_size(binary)
      index = 2
      while index < binary.bytesize - 8
        break unless binary.getbyte(index) == 0xFF

        marker = binary.getbyte(index + 1)
        index += 2
        next if marker == 0xD8 || marker == 0xD9

        length = binary[index, 2].unpack1("n")
        if [ 0xC0, 0xC1, 0xC2 ].include?(marker)
          height, width = binary[index + 3, 4].unpack("nn")
          return [ width, height ]
        end

        index += length
      end
      [ nil, nil ]
    end

    def image_name?(name)
      File.extname(name).downcase.match?(/\A\.(png|jpe?g)\z/)
    end

    def parse_json(text)
      LlmJsonParser.parse(text)
    rescue JSON::ParserError
      nil
    end

    def scored_fields(fields)
      Array(fields&.values).select { |field| %w[VERIFIED MUST_BE_UNKNOWN].include?(field["status"]) }
    end

    def all_pass?(fields)
      scored = scored_fields(fields)
      scored.any? && scored.all? { |field| field["result"] == "PASS" }
    end

    def any_fail?(fields)
      scored_fields(fields).any? { |field| field["result"] == "FAIL" }
    end

    def add_cost(accumulated, priced)
      return accumulated if priced["estimated_cost"] == "UNKNOWN"

      accumulated + BigDecimal(priced["estimated_cost"])
    end

    def sum_money(entries)
      amounts = entries.filter_map { |item|
        cost = item["estimated_cost"]
        BigDecimal(cost) unless cost.nil? || cost == "UNKNOWN"
      }
      return "UNKNOWN" if amounts.empty? && entries.any?

      format_money(amounts.sum { |amount| amount })
    end

    def money(tokens, rate)
      (BigDecimal(tokens.to_i) / 1_000) * rate
    end

    def format_money(amount)
      format("%.6f", BigDecimal(amount.to_s))
    end

    def format_rate(pass_count, total)
      format("%.6f", BigDecimal(pass_count) / BigDecimal(total))
    end

    def decimal_or_nil(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    end

    def usage_value(usage, name)
      return nil if usage.nil?

      if usage.respond_to?(name)
        usage.public_send(name)
      elsif usage.is_a?(Hash)
        usage[name] || usage[name.to_s]
      end
    end

    def integer_or_nil(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      value.to_i if value.is_a?(Numeric) || value.is_a?(String)
    end

    def redact(message)
      message.to_s.gsub(/sk-ant-[A-Za-z0-9_-]+/, "[redacted]").byteslice(0, 300)
    end

    def build_client
      api_key = ENV["ANTHROPIC_API_KEY"].presence || Rails.application.credentials.dig(:anthropic, :api_key)
      raise Stop, "MissingCredential" if api_key.blank?

      Anthropic::Client.new(api_key: api_key, max_retries: 0)
    end

    def write_json(path, payload)
      write_raw(path, JSON.pretty_generate(payload) + "\n")
    end

    def write_raw(path, body)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, body)
    end

    def sha_text(text)
      Digest::SHA256.hexdigest(text.to_s)
    end

    def print_summary(io, result)
      io.puts "F1_EXTENDED_STATUS=#{result["status"]}"
      io.puts "calls=#{result["calls"]}"
      io.puts "accumulated=#{result["accumulated_estimated_cost"]}"
      io.puts "remaining=#{result["remaining_budget_estimate"]}"
      io.puts "evidence_class=#{result.dig("metrics", "evidence_class")}"
      io.puts "opus_only_wins=#{result.dig("metrics", "opus_only_wins")}"
      io.puts "sonnet_only_wins=#{result.dig("metrics", "sonnet_only_wins")}"
      io.puts "shared_passes=#{result.dig("metrics", "shared_passes")}"
      io.puts "shared_fails=#{result.dig("metrics", "shared_fails")}"
      io.puts "shared_safety_fails=#{result.dig("metrics", "shared_safety_fails")}"
    end

    def verified(allowed, fail_if: [])
      { "status" => "VERIFIED", "allowed" => Array(allowed), "fail_if" => Array(fail_if) }
    end

    def unknown
      { "status" => "MUST_BE_UNKNOWN" }
    end

    def unscored
      { "status" => "NOT_SCORED" }
    end

    def brands_except(brand)
      OTHER_BRANDS - [ brand ]
    end

    def case_row(case_id, filename, subject:, functions_must_be_empty:, gold_basis:, gold:)
      {
        "case_id" => case_id,
        "filename" => filename,
        "subject" => subject,
        "functions_must_be_empty" => functions_must_be_empty,
        "gold_basis" => gold_basis,
        "gold" => gold
      }
    end

    CASES = [
      case_row(
        SPRING_CASE,
        "spring_assembly_misread.png",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "Frozen F1 gold. Plate text is not transcribed.",
        gold: {
          "manufacturer" => unscored,
          "model" => unscored,
          "component" => verified(%w[resorte resortes muelle muelles], fail_if: %w[resistenc bobinad]),
          "visible_text" => unscored
        }
      ),
      case_row(
        "field_dense_control_panel",
        "field_dense_control_panel.jpeg",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "Orona and PBCM are printed on the board.",
        gold: {
          "component" => verified(%w[placa controlador tablero]),
          "manufacturer" => verified("orona", fail_if: brands_except("orona")),
          "model" => verified(%w[pbcm pbcm-v3]),
          "visible_text" => verified(%w[orona pbcm danger])
        }
      ),
      case_row(
        "field_dense_controller",
        "field_dense_controller.png",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "KONE is printed on the panel. The small model code is not frozen.",
        gold: {
          "component" => verified(%w[controlador placa tablero]),
          "manufacturer" => verified("kone", fail_if: brands_except("kone")),
          "model" => unscored,
          "visible_text" => verified("kone")
        }
      ),
      case_row(
        "field_controller_display_keypad",
        "field_controller_display_keypad.png",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "Key labels MODULE, FUNCTION and ENTER are printed. No brand or model.",
        gold: {
          "component" => verified(%w[teclado keypad consola programador controlador]),
          "manufacturer" => unknown,
          "model" => unknown,
          "visible_text" => verified(%w[module function enter])
        }
      ),
      case_row(
        "field_controller_nameplate",
        "field_controller_nameplate.png",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "Controller board. No readable brand or model. Display digits are not frozen.",
        gold: {
          "component" => verified(%w[controlador placa display tablero]),
          "manufacturer" => unknown,
          "model" => unknown,
          "visible_text" => unscored
        }
      ),
      case_row(
        "field_controller_text_display",
        "field_controller_text_display.png",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "LCD on a board. The small LCD string is not frozen. No brand or model.",
        gold: {
          "component" => verified(%w[display pantalla controlador placa]),
          "manufacturer" => unknown,
          "model" => unknown,
          "visible_text" => unscored
        }
      ),
      case_row(
        "field_degraded_control_board",
        "field_degraded_control_board.png",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "NORMAL, RESCUE and LEARN are printed. No brand. The part code is not frozen.",
        gold: {
          "component" => verified(%w[controlador placa tablero]),
          "manufacturer" => unknown,
          "model" => unscored,
          "visible_text" => verified(%w[normal rescue learn])
        }
      ),
      case_row(
        "field_degraded_error_display",
        "field_degraded_error_display.png",
        subject: "physical",
        functions_must_be_empty: true,
        gold_basis: "Large display reads EE.36. No brand, model, or worded function legend.",
        gold: {
          "component" => verified(%w[display controlador placa]),
          "manufacturer" => unknown,
          "model" => unknown,
          "visible_text" => verified("ee.36")
        }
      ),
      case_row(
        "field_cabin_panel_with_diagram",
        "field_cabin_panel_with_diagram.png",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "Car panel. The placard prints MODEL 3020. No equipment brand.",
        gold: {
          "component" => verified(%w[botonera panel cabina pulsador pulsadores]),
          "manufacturer" => unknown,
          "model" => verified("3020"),
          "visible_text" => verified(%w[3020 warning smoking])
        }
      ),
      case_row(
        "field_shaft_mechanical_context",
        "field_shaft_mechanical_context.png",
        subject: "physical",
        functions_must_be_empty: true,
        gold_basis: "Hoistway structure. No readable brand, model, text, or function legend.",
        gold: {
          "component" => verified(%w[hueco cabina estructura guia guias andamio montacargas ascensor puerta]),
          "manufacturer" => unknown,
          "model" => unknown,
          "visible_text" => unknown
        }
      ),
      case_row(
        "document_hydraulic_diagram",
        "document_hydraulic_diagram.png",
        subject: "document",
        functions_must_be_empty: false,
        gold_basis: "Printed page titled esquema hidraulico. No brand or model on the page.",
        gold: {
          "component" => verified(%w[esquema diagrama plano documento]),
          "manufacturer" => unknown,
          "model" => unknown,
          "visible_text" => verified(%w[esquema hidraulico])
        }
      ),
      case_row(
        "field_floor_indicator",
        "field_floor_indicator.jpeg",
        subject: "physical",
        functions_must_be_empty: true,
        gold_basis: "Floor indicator. The separate letter F is visible. No brand, model, or worded legend.",
        gold: {
          "component" => verified(%w[indicador display]),
          "manufacturer" => unknown,
          "model" => unknown,
          "visible_text" => verified("f")
        }
      ),
      case_row(
        "field_elevator_indicator_context",
        "field_elevator_indicator_context.png",
        subject: "physical",
        functions_must_be_empty: true,
        gold_basis: "Landing doors with a display reading 15. No elevator brand or model.",
        gold: {
          "component" => verified(%w[indicador cabina puerta display]),
          "manufacturer" => unknown,
          "model" => unknown,
          "visible_text" => verified("15")
        }
      ),
      case_row(
        "field_branded_indicator",
        "field_branded_indicator.png",
        subject: "physical",
        functions_must_be_empty: true,
        gold_basis: "Floor indicator showing E. The corner logo is not treated as equipment identity.",
        gold: {
          "component" => verified(%w[indicador display]),
          "manufacturer" => unscored,
          "model" => unknown,
          "visible_text" => verified("e")
        }
      ),
      case_row(
        "field_kone_controller",
        "field_kone_controller.png",
        subject: "physical",
        functions_must_be_empty: false,
        gold_basis: "Controller cabinet. The KONE graphic is an overlay, so manufacturer is not scored. No model code.",
        gold: {
          "component" => verified(%w[controlador armario tablero placa]),
          "manufacturer" => unscored,
          "model" => unknown,
          "visible_text" => unscored
        }
      )
    ].freeze
  end
end

if __FILE__ == $PROGRAM_NAME
  exit FieldCompanion::VisualBenchmarkExtended.run
end
