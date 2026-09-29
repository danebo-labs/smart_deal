# frozen_string_literal: true

# Field Companion F1 visual benchmark.
# Forces two model ids, sends each the same bytes and the same request
# parameters, scores the frozen manifest, and does not change production.
# Anthropic::Client only. No job enqueue. A successful response is stored
# before scoring so a later process does not pay for that model again.
#
# Usage: env -u BUNDLE_PATH bin/rails runner script/field_companion/visual_benchmark.rb

require "bigdecimal"
require "digest"
require "fileutils"
require "json"

require_relative "../../config/environment" unless defined?(Rails) && Rails.application

module FieldCompanion
  module VisualBenchmark
    class Stop < StandardError; end
    class Blocked < StandardError; end

    ROOT = Rails.root.join("tmp/field_companion")
    MANIFEST_PATH = ROOT.join("visual_manifest.json")
    IMAGE_RELATIVE = "tmp/field_companion/images/spring_assembly_misread.png"
    SPRING_SOURCE = Pathname.new("/Users/lahirisan/Desktop/resortes.png")
    MODELS = %w[claude-sonnet-5-5 claude-opus-5-5].freeze
    MAX_TOKENS = 8_000
    LOCALE = "es"
    PHOTO_INTENT = ""
    MAX_IMAGES = 16
    CALL_CEILING = 32
    FINGERPRINT = "4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1"
    MANIFEST_SHA = "7a17aad222d0be44bf961b7119226fef54632a3789aa11e4cd985b95431a05f1"
    SPRING_SHA = "202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd"
    SPRING_BYTES = 1_430_913
    SPRING_CASE = "spring_assembly_misread"
    FIELD_ORDER = %w[component manufacturer model visible_text].freeze
    # USD per 1_000 tokens from the Claude Sonnet 5.5 row ($2 / $10 per MTok).
    # Input and output only. Not loaded from the pricing hash.
    SONNET_INPUT_PER_1K = BigDecimal("0.002")
    SONNET_OUTPUT_PER_1K = BigDecimal("0.01")
    SONNET_PRICE_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing"
    OPUS_PRICE_KEY = "claude-opus-5-5-direct"
    OPUS_PRICE_SOURCE = "app/models/bedrock_query.rb#BEDROCK_PRICING[claude-opus-5-5-direct]"

    module_function

    def run(client: nil, root: ROOT, manifest_path: MANIFEST_PATH, image_path: Rails.root.join(IMAGE_RELATIVE), io: $stdout)
      ensure_fingerprint!
      manifest_sha = ensure_manifest!(manifest_path)
      manifest = JSON.parse(File.read(manifest_path))
      ensure_spring_image!(image_path)
      rows = eligible_cases(manifest)
      raise Blocked, "no eligible cases" if rows.empty?

      ensure_budget!(rows)
      rows.each { |row| assert_spring_contract!(row) }
      http = client || build_client
      scored = rows.map { |row| execute_case(row, http, root: root, image_path: image_path) }
      artifact = build_artifact(manifest_sha, scored)
      path = root.join("f1_visual.json")
      write_json(path, artifact)
      digest = Digest::SHA256.file(path).hexdigest
      status = pass?(artifact) ? "PASS" : "BLOCKED"
      io.puts "F1_STATUS=#{status}"
      io.puts "f1_visual.json #{digest}"
      io.puts "calls=#{artifact["calls"]}"
      io.puts "spring_split=#{artifact.dig("counters", "spring_split").inspect}"
      io.puts "opus_only_wins=#{artifact.dig("counters", "opus_only_wins")}"
      io.puts "shared_component_fail=#{artifact.dig("counters", "shared_component_fail")}"
      io.puts "shared_identity_fail=#{artifact.dig("counters", "shared_identity_fail")}"
      MODELS.each do |model|
        entry = artifact.dig("cases", 0, "models", model) || {}
        component = entry.dig("fields", "component") || {}
        io.puts [
          model,
          "result=#{component["result"]}",
          "normalized=#{component["normalized_text"].inspect}",
          "returned=#{entry["returned_model_id"]}",
          "input=#{entry["input_tokens"]}",
          "output=#{entry["output_tokens"]}",
          "cache_read=#{entry["cache_read_tokens"]}",
          "cache_creation=#{entry["cache_creation_tokens"]}",
          "latency_ms=#{entry["latency_ms"]}",
          "cost=#{entry["cost"]}",
          "bytes_sha256=#{entry["bytes_sha256"]}",
          "output_sha256=#{entry["output_sha256"]}"
        ].join(" ")
      end
      status == "PASS" ? 0 : 2
    rescue Blocked => e
      io.puts "F1_STATUS=BLOCKED"
      io.puts e.message
      2
    rescue Stop => e
      io.puts "F1_STATUS=STOP"
      io.puts e.message
      3
    end

    def ensure_fingerprint!
      actual = FieldPhotoPrompt.prompt_fingerprint_sha256
      raise Stop, "prompt fingerprint mismatch" unless actual == FINGERPRINT
    end

    def ensure_manifest!(path)
      raise Blocked, "manifest missing" unless path.file?

      sha = Digest::SHA256.file(path).hexdigest
      raise Blocked, "manifest sha256 mismatch" unless sha == MANIFEST_SHA

      sha
    end

    def ensure_spring_image!(path)
      return if image_ok?(path)

      raise Blocked, "spring image sha256 mismatch" unless SPRING_SOURCE.file?

      bytes = File.binread(SPRING_SOURCE)
      source_ok = Digest::SHA256.hexdigest(bytes) == SPRING_SHA && bytes.bytesize == SPRING_BYTES
      raise Blocked, "spring image sha256 mismatch" unless source_ok

      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, bytes)
      raise Blocked, "spring image sha256 mismatch" unless image_ok?(path)
    end

    def image_ok?(path)
      path.file? && path.size == SPRING_BYTES && Digest::SHA256.file(path).hexdigest == SPRING_SHA
    end

    def eligible_cases(manifest)
      Array(manifest["cases"]).select { |row| row["eligible"] == true && scoreable_gold?(row["gold"]) }
    end

    def scoreable_gold?(gold)
      Array(gold&.values).any? { |field| %w[VERIFIED MUST_BE_UNKNOWN].include?(field["status"]) }
    end

    def ensure_budget!(rows)
      raise Stop, "image ceiling exceeded" if rows.size > MAX_IMAGES
      raise Stop, "call ceiling exceeded" if rows.size * MODELS.size > CALL_CEILING
    end

    def assert_spring_contract!(row)
      return unless row["case_id"] == SPRING_CASE

      ok = row["filename"] == "spring_assembly_misread.png" &&
        row["media_type"] == "image/png" &&
        row["bytes"] == SPRING_BYTES &&
        row["sha256"] == SPRING_SHA
      raise Blocked, "spring row does not match the frozen contract" unless ok
    end

    def execute_case(row, client, root:, image_path:)
      binary = File.binread(image_path)
      sha = Digest::SHA256.hexdigest(binary)
      raise Blocked, "image sha256 mismatch" unless sha == row["sha256"] && sha == Digest::SHA256.file(image_path).hexdigest

      models = {}
      seen = nil
      MODELS.each do |model_id|
        params = request_params(
          model_id: model_id,
          binary: binary,
          media_type: row.fetch("media_type"),
          filename: row.fetch("filename")
        )
        request_sha = request_sha256(params)
        bytes_sha = bytes_sha_from_params(params)
        seen = remember_pair!(seen, bytes_sha: bytes_sha, request_sha: request_sha, file_sha: sha)
        call = fetch_call(
          model_id: model_id,
          params: params,
          bytes_sha: bytes_sha,
          request_sha: request_sha,
          client: client,
          case_id: row.fetch("case_id"),
          root: root
        )
        parsed = call["success"] ? parse_observation(call["output_text"]) : nil
        fields = ordered_fields(score_gold(row.fetch("gold"), parsed))
        cost, source = cost_for(
          requested_model_id: model_id,
          returned_model_id: call["returned_model_id"],
          input_tokens: call["input_tokens"],
          output_tokens: call["output_tokens"]
        )
        models[model_id] = model_entry(call, fields, cost, source)
      end

      {
        "case_id" => row["case_id"],
        "filename" => row["filename"],
        "media_type" => row["media_type"],
        "bytes" => binary.bytesize,
        "sha256" => sha,
        "models" => models
      }
    end

    def remember_pair!(previous, bytes_sha:, request_sha:, file_sha:)
      current = { bytes_sha: bytes_sha, request_sha: request_sha }
      return current if previous.nil?

      same = previous[:bytes_sha] == bytes_sha && previous[:request_sha] == request_sha && bytes_sha == file_sha
      raise Stop, "bytes sha256 diverged; row aborted without another call" unless same

      current
    end

    def request_params(model_id:, binary:, media_type:, filename:)
      {
        model: model_id,
        max_tokens: MAX_TOKENS,
        system: FieldPhotoPrompt::SYSTEM_BLOCKS,
        messages: [
          {
            role: "user",
            content: FieldPhotoPrompt.user_content(
              binary: binary,
              content_type: media_type,
              filename: filename,
              locale: LOCALE,
              photo_intent: nil
            )
          }
        ]
      }
    end

    def request_sha256(params)
      content = params[:messages][0][:content]
      image = content[0]
      texts = content.drop(1).map { |block| block[:text].to_s }
      system_text = Array(params[:system]).map { |block| block[:text].to_s }.join("\n")
      Digest::SHA256.hexdigest([
        params[:max_tokens].to_s,
        system_text,
        image.dig(:source, :media_type).to_s,
        image.dig(:source, :data).to_s,
        texts.join("\n")
      ].join("\0"))
    end

    def bytes_sha_from_params(params)
      data = params[:messages][0][:content][0].dig(:source, :data)
      Digest::SHA256.hexdigest(Base64.strict_decode64(data))
    end

    def fetch_call(model_id:, params:, bytes_sha:, request_sha:, client:, case_id:, root:)
      stored = read_call(root, model_id)
      if reusable_call?(stored, model_id: model_id, bytes_sha: bytes_sha, request_sha: request_sha)
        return refresh_output(stored, case_id: case_id, model_id: model_id, root: root)
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      message = client.messages.create(params)
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      text = message_text(message)
      output_path, output_sha = write_output(root, case_id, model_id, text)
      record = {
        "requested_model_id" => model_id,
        "returned_model_id" => message_model(message),
        "bytes_sha256" => bytes_sha,
        "request_sha256" => request_sha,
        "system_prompt_fingerprint_sha256" => FINGERPRINT,
        "max_tokens" => MAX_TOKENS,
        "success" => true,
        "error_class" => nil,
        "output_text" => text,
        "output_path" => relative_output(case_id, model_id),
        "output_sha256" => output_sha,
        "input_tokens" => usage_integer(message, :input_tokens),
        "output_tokens" => usage_integer(message, :output_tokens),
        "cache_read_tokens" => usage_integer(message, :cache_read_input_tokens),
        "cache_creation_tokens" => usage_integer(message, :cache_creation_input_tokens),
        "latency_ms" => latency_ms,
        "timestamp" => Time.now.utc.iso8601
      }
      write_json(call_path(root, model_id), record)
      record
    rescue Stop
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
        "output_text" => "",
        "output_path" => nil,
        "output_sha256" => nil,
        "input_tokens" => nil,
        "output_tokens" => nil,
        "cache_read_tokens" => nil,
        "cache_creation_tokens" => nil,
        "latency_ms" => nil,
        "timestamp" => Time.now.utc.iso8601
      }
    end

    def reusable_call?(stored, model_id:, bytes_sha:, request_sha:)
      stored.is_a?(Hash) &&
        stored["success"] == true &&
        stored["requested_model_id"] == model_id &&
        stored["bytes_sha256"] == bytes_sha &&
        stored["request_sha256"] == request_sha &&
        stored["system_prompt_fingerprint_sha256"] == FINGERPRINT &&
        stored["max_tokens"] == MAX_TOKENS &&
        stored["output_text"].present?
    end

    def refresh_output(stored, case_id:, model_id:, root:)
      _path, output_sha = write_output(root, case_id, model_id, stored["output_text"])
      stored.merge(
        "output_path" => relative_output(case_id, model_id),
        "output_sha256" => output_sha
      )
    end

    def write_output(root, case_id, model_id, text)
      path = root.join("outputs", "#{case_id}.#{model_id}.txt")
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, text.to_s)
      [ path, Digest::SHA256.file(path).hexdigest ]
    end

    def relative_output(case_id, model_id)
      "tmp/field_companion/outputs/#{case_id}.#{model_id}.txt"
    end

    def call_path(root, model_id)
      root.join("f1_calls", "#{model_id}.json")
    end

    def read_call(root, model_id)
      path = call_path(root, model_id)
      return nil unless path.file?

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def message_text(message)
      content = message.respond_to?(:content) ? message.content : message[:content]
      block = Array(content).find { |item| item_type(item) == "text" }
      raise IOError, "no text block" unless block

      if block.respond_to?(:text)
        block.text.to_s
      else
        (block[:text] || block["text"]).to_s
      end
    end

    def item_type(item)
      value = if item.respond_to?(:type)
        item.type
      else
        item[:type] || item["type"]
      end
      value.to_s
    end

    def message_model(message)
      value = message.respond_to?(:model) ? message.model : message[:model]
      value.to_s
    end

    def usage_integer(message, name)
      usage = message.respond_to?(:usage) ? message.usage : message[:usage]
      return nil if usage.nil?

      value = if usage.respond_to?(name)
        usage.public_send(name)
      elsif usage.is_a?(Hash)
        usage[name] || usage[name.to_s]
      end
      value.nil? ? nil : value.to_i
    end

    def parse_observation(text)
      LlmJsonParser.parse(text)
    rescue JSON::ParserError
      nil
    end

    def score_gold(gold, parsed)
      gold.each_with_object({}) do |(name, spec), fields|
        fields[name] = score_field(name, spec, parsed)
      end
    end

    def score_field(name, spec, parsed)
      case spec["status"]
      when "NOT_SCORED"
        { "status" => "NOT_SCORED" }
      when "VERIFIED"
        score_verified(field_text(parsed, name), allowed: spec["allowed"], fail_if: spec["fail_if"])
      when "MUST_BE_UNKNOWN"
        score_unknown(field_text(parsed, name))
      else
        raise Stop, "unknown gold status"
      end
    end

    def field_text(parsed, name)
      return "" unless parsed.is_a?(Hash)

      if name == "visible_text"
        Array(parsed["visible_text"]).map(&:to_s).join(" ")
      elsif name == "component"
        parsed["canonical_component"].to_s
      else
        parsed[name].to_s
      end
    end

    def ordered_fields(fields)
      ordered = {}
      FIELD_ORDER.each { |key| ordered[key] = fields[key] if fields.key?(key) }
      fields.each { |key, value| ordered[key] = value unless ordered.key?(key) }
      ordered
    end

    def score_verified(text, allowed:, fail_if:)
      normalized = normalize(text)
      forbidden = Array(fail_if).any? { |fragment| substring?(normalized, fragment) }
      matched = Array(allowed).any? { |token| whole_word?(normalized, token) }
      {
        "status" => "VERIFIED",
        "result" => (!forbidden && matched) ? "PASS" : "FAIL",
        "normalized_text" => normalized
      }
    end

    def score_unknown(text)
      normalized = normalize(text)
      {
        "status" => "MUST_BE_UNKNOWN",
        "result" => (normalized.empty? || normalized == "unknown") ? "PASS" : "FAIL",
        "normalized_text" => normalized
      }
    end

    def normalize(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/\s+/, " ").strip
    end

    def whole_word?(normalized, token)
      needle = normalize(token)
      return false if needle.empty?

      /(?<![[:alnum:]])#{Regexp.escape(needle)}(?![[:alnum:]])/.match?(normalized)
    end

    def substring?(normalized, fragment)
      needle = normalize(fragment)
      return false if needle.empty?

      normalized.include?(needle)
    end

    def cost_for(requested_model_id:, returned_model_id:, input_tokens:, output_tokens:)
      return [ "UNKNOWN", nil ] if input_tokens.nil? || output_tokens.nil?

      rates, source = rates_for(requested_model_id, returned_model_id)
      return [ "UNKNOWN", nil ] unless rates

      amount = (BigDecimal(input_tokens.to_i) / 1000 * rates[:input]) +
        (BigDecimal(output_tokens.to_i) / 1000 * rates[:output])
      [ format("%.6f", amount), source ]
    end

    def rates_for(requested_model_id, returned_model_id)
      returned = returned_model_id.to_s
      if requested_model_id == MODELS[0] && returned.start_with?(MODELS[0])
        return [ { input: SONNET_INPUT_PER_1K, output: SONNET_OUTPUT_PER_1K }, SONNET_PRICE_SOURCE ]
      end
      if requested_model_id == MODELS[1] && returned.start_with?(MODELS[1])
        row = BedrockQuery::BEDROCK_PRICING.fetch(OPUS_PRICE_KEY)
        rates = {
          input: BigDecimal(row.fetch(:input).to_s),
          output: BigDecimal(row.fetch(:output).to_s)
        }
        return [ rates, OPUS_PRICE_SOURCE ]
      end

      [ nil, nil ]
    end

    def model_entry(call, fields, cost, source)
      {
        "requested_model_id" => call["requested_model_id"],
        "returned_model_id" => call["returned_model_id"].to_s,
        "bytes_sha256" => call["bytes_sha256"],
        "request_sha256" => call["request_sha256"],
        "success" => call["success"],
        "error_class" => call["error_class"],
        "fields" => fields,
        "input_tokens" => call["input_tokens"],
        "output_tokens" => call["output_tokens"],
        "cache_read_tokens" => call["cache_read_tokens"],
        "cache_creation_tokens" => call["cache_creation_tokens"],
        "latency_ms" => call["latency_ms"],
        "cost" => cost,
        "price_source" => source,
        "output_path" => call["output_path"],
        "output_sha256" => call["output_sha256"],
        "timestamp" => call["timestamp"]
      }
    end

    def build_artifact(manifest_sha, cases)
      {
        "phase" => "F1",
        "manifest_path" => "tmp/field_companion/visual_manifest.json",
        "manifest_sha256" => manifest_sha,
        "system_prompt_fingerprint_sha256" => FINGERPRINT,
        "locale" => LOCALE,
        "photo_intent" => PHOTO_INTENT,
        "max_tokens" => MAX_TOKENS,
        "reads_model_text" => false,
        "uses_density_gate" => false,
        "calls" => cases.sum { |row| row["models"].size },
        "call_ceiling" => CALL_CEILING,
        "cases" => cases,
        "by_model" => by_model(cases),
        "counters" => counters(cases)
      }
    end

    def by_model(cases)
      MODELS.to_h do |model|
        invention = 0
        component_fails = 0
        cases.each do |row|
          fields = row.dig("models", model, "fields") || {}
          invention += fields.count { |_name, field| field["status"] == "MUST_BE_UNKNOWN" && field["result"] == "FAIL" }
          component_fails += 1 if component_fail?(fields)
        end
        [ model, { "identity_invention_count" => invention, "component_fail_count" => component_fails } ]
      end
    end

    def counters(cases)
      {
        "spring_split" => spring_split(cases),
        "opus_only_wins" => opus_only_wins(cases),
        "shared_component_fail" => shared_component_fail(cases),
        "shared_identity_fail" => shared_identity_fail(cases)
      }
    end

    def spring_split(cases)
      row = cases.find { |item| item["case_id"] == SPRING_CASE }
      return nil unless row

      sonnet = row.dig("models", MODELS[0], "fields", "component", "result")
      opus = row.dig("models", MODELS[1], "fields", "component", "result")
      return nil unless sonnet && opus
      return "opus_pass_sonnet_fail" if opus == "PASS" && sonnet == "FAIL"
      return "sonnet_pass_opus_fail" if sonnet == "PASS" && opus == "FAIL"

      nil
    end

    def opus_only_wins(cases)
      cases.count { |row|
        opus = row.dig("models", MODELS[1], "fields")
        sonnet = row.dig("models", MODELS[0], "fields")
        all_scored_pass?(opus) && any_scored_fail?(sonnet)
      }
    end

    def shared_component_fail(cases)
      cases.count { |row|
        component_fail?(row.dig("models", MODELS[0], "fields")) &&
          component_fail?(row.dig("models", MODELS[1], "fields"))
      }
    end

    def shared_identity_fail(cases)
      cases.count { |row|
        sonnet = row.dig("models", MODELS[0], "fields") || {}
        opus = row.dig("models", MODELS[1], "fields") || {}
        next false if component_fail?(sonnet) && component_fail?(opus)

        sonnet.any? { |name, field|
          field["status"] == "MUST_BE_UNKNOWN" && field["result"] == "FAIL" &&
            opus.dig(name, "status") == "MUST_BE_UNKNOWN" && opus.dig(name, "result") == "FAIL"
        }
      }
    end

    def component_fail?(fields)
      field = fields&.dig("component")
      field && field["status"] == "VERIFIED" && field["result"] == "FAIL"
    end

    def scored_fields(fields)
      Array(fields&.values).select { |field| %w[VERIFIED MUST_BE_UNKNOWN].include?(field["status"]) }
    end

    def all_scored_pass?(fields)
      scored = scored_fields(fields)
      scored.any? && scored.all? { |field| field["result"] == "PASS" }
    end

    def any_scored_fail?(fields)
      scored_fields(fields).any? { |field| field["result"] == "FAIL" }
    end

    def pass?(artifact)
      return false unless artifact["calls"] == MODELS.size
      return false unless artifact["system_prompt_fingerprint_sha256"] == FINGERPRINT

      row = artifact["cases"]&.first
      return false unless row && row["case_id"] == SPRING_CASE && row["sha256"] == SPRING_SHA

      models = row["models"]
      return false unless models.keys == MODELS

      bytes = models.values.pluck("bytes_sha256")
      requests = models.values.pluck("request_sha256")
      bytes.uniq == [ SPRING_SHA ] && requests.uniq.size == 1 && models.values.all? { |item| item["success"] == true }
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
  end
end

if __FILE__ == $PROGRAM_NAME
  exit FieldCompanion::VisualBenchmark.run
end
