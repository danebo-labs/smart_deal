# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "uri"

require Rails.root.join("test/support/companion_direct_capture_replay")

module Rag
  # Local Messages API adapter for the session 269 prompt comparison.
  # It is not a product path. Production stays on Bedrock Haiku 4.5.
  class CompanionHaiku55Compare
    MODEL_ID = "claude-haiku-5-5"
    EFFORT = "max"
    EFFORT_ORDER = %w[max xhigh high medium low].freeze
    THINKING = { "type" => "adaptive", "display" => "summarized" }.freeze
    ANTHROPIC_VERSION = "2026-10-21"
    FALLBACK_VERSION = "2023-06-01"
    ENDPOINT = "https://api.anthropic.com/v1/messages"
    PRIMARY_BUDGET = BigDecimal("0.15")
    AUTHORIZED_BUDGET = BigDecimal("0.30")
    ATTEMPTS_PER_TURN = 3
    RETRIES = 2
    GEO = BigDecimal("1.1")
    LONG_AT = 100_000
    MODEL_MAX_OUTPUT = 128_000
    CAPTURED_MAX_TOKENS = 700
    SHORT_INPUT = BigDecimal("0.10") / 1_000_000
    SHORT_OUTPUT = BigDecimal("0.50") / 1_000_000
    LONG_INPUT = BigDecimal("0.50") / 1_000_000
    LONG_OUTPUT = BigDecimal("2.50") / 1_000_000
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 300
    RETRY_AFTER_CAP = 60
    OUTPUT = Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare_haiku55")
    CANONICAL = Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare")
    SOURCES = {
      "model" => "https://platform.claude.com/docs/en/models/haiku-5-5/overview",
      "migration" => "https://platform.claude.com/docs/en/models/haiku-5-5/migration-guide",
      "effort" => "https://platform.claude.com/docs/en/build-with-claude/effort",
      "pricing" => "https://platform.claude.com/docs/en/about-claude/pricing"
    }.freeze
    CONSULTED_ON = "2026-11-05"

    Result = Struct.new(:http_status, :payload, :retry_after, :error_code, :error_message, :partial, keyword_init: true)

    class Ledger
      def initialize(path)
        @path = Pathname(path)
        @events = []
        load! if @path.file?
      end

      def events
        @events
      end

      def exposure
        spent + reserved_total
      end

      def spent
        totals[0]
      end

      def reserved_total
        totals[1]
      end

      def append(event)
        @events << event
        FileUtils.mkdir_p(@path.dirname)
        File.open(@path, "a") { |file| file.puts JSON.generate(event) }
      end

      def next_id
        @events.map { |event| event["id"].to_i }.max.to_i + 1
      end

      private

      def load!
        @events = @path.each_line.filter_map do |line|
          next if line.strip.empty?

          JSON.parse(line)
        end
      end

      def totals
        open = {}
        spent = BigDecimal("0")
        @events.each do |event|
          id = event["id"]
          case event["event"]
          when "reserved"
            open[id] = decimal(event["reserved_usd"])
          when "settled"
            open.delete(id)
            spent += decimal(event["actual_usd"])
          when "released"
            open.delete(id)
          when "kept"
            open[id] = decimal(event["reserved_usd"])
          end
        end
        [ spent, open.values.sum(BigDecimal("0")) ]
      end

      def decimal(value)
        BigDecimal(value.to_s)
      end
    end

    class Assembler
      def initialize
        @buffer = +""
        @blocks = {}
        @usage = {}
        @message = {}
        @event_name = nil
        @data = +""
        @stop_reason = nil
        @stop_sequence = nil
      end

      def <<(chunk)
        @buffer << chunk.to_s
        while (break_at = @buffer.index("\n"))
          line = @buffer.slice!(0..break_at)
          consume_line(line.delete_suffix!("\n").delete_suffix("\r"))
        end
        self
      end

      def finish
        unless @buffer.empty?
          consume_line(@buffer.delete_suffix("\n").delete_suffix("\r"))
          @buffer = +""
        end
        consume_line("") unless @data.empty?
        message
      end

      def message
        {
          "id" => @message["id"],
          "type" => "message",
          "role" => @message["role"] || "assistant",
          "model" => @message["model"],
          "stop_reason" => @stop_reason,
          "stop_sequence" => @stop_sequence,
          "content" => @blocks.keys.sort.map { |key| @blocks[key] },
          "usage" => @usage
        }
      end

      private

      def consume_line(line)
        if line.empty?
          dispatch
          return
        end
        return if line.start_with?(":")

        if line.start_with?("event:")
          @event_name = line.sub("event:", "").strip
        elsif line.start_with?("data:")
          @data << line.sub("data:", "").strip
        end
      end

      def dispatch
        raw = @data
        @data = +""
        @event_name = nil
        return if raw.empty?

        payload = JSON.parse(raw)
        apply(payload)
      rescue JSON::ParserError
        nil
      end

      def apply(payload)
        case payload["type"]
        when "message_start"
          @message = payload["message"].is_a?(Hash) ? payload["message"] : {}
          @usage = @message["usage"].is_a?(Hash) ? @message["usage"].dup : {}
        when "content_block_start"
          block = payload["content_block"].is_a?(Hash) ? payload["content_block"].dup : {}
          @blocks[payload["index"].to_i] = block
        when "content_block_delta"
          apply_delta(payload["index"].to_i, payload["delta"])
        when "message_delta"
          delta = payload["delta"].is_a?(Hash) ? payload["delta"] : {}
          @stop_reason = delta["stop_reason"] if delta.key?("stop_reason")
          @stop_sequence = delta["stop_sequence"] if delta.key?("stop_sequence")
          @usage.merge!(payload["usage"]) if payload["usage"].is_a?(Hash)
        end
      end

      def apply_delta(index, delta)
        return unless delta.is_a?(Hash)

        block = (@blocks[index] ||= { "type" => delta["type"].to_s.sub(/_delta\z/, "") })
        case delta["type"]
        when "thinking_delta"
          block["type"] = "thinking"
          block["thinking"] = block["thinking"].to_s + delta["thinking"].to_s
        when "signature_delta"
          block["type"] = "thinking"
          block["signature"] = block["signature"].to_s + delta["signature"].to_s
        when "text_delta"
          block["type"] = "text"
          block["text"] = block["text"].to_s + delta["text"].to_s
        when "input_json_delta"
          block["partial_json"] = block["partial_json"].to_s + delta["partial_json"].to_s
        end
      end
    end

    class Transport
      def initialize(http: Net::HTTP)
        @http = http
      end

      def post(body:, api_key:, version: ANTHROPIC_VERSION)
        assembler = Assembler.new
        uri = URI(ENDPOINT)
        http = @http.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.max_retries = 0
        request = Net::HTTP::Post.new(uri.request_uri)
        request["content-type"] = "application/json"
        request["anthropic-version"] = version
        request["x-api-key"] = api_key
        request.body = JSON.generate(body)
        status = nil
        retry_after = nil
        streamed = false
        http.request(request) do |response|
          status = response.code.to_i
          retry_after = response["retry-after"]
          streamed = response["content-type"].to_s.include?("text/event-stream")
          reader = streamed ? assembler : +""
          response.read_body { |chunk| streamed ? reader << chunk : reader << chunk }
          payload = streamed ? assembler.finish : parse_json(reader)
          return build_result(status, payload, retry_after)
        end
        build_result(status, nil, retry_after)
      rescue Net::OpenTimeout, Net::ReadTimeout
        Result.new(http_status: nil, payload: assembler.finish, retry_after: nil, error_code: "timeout", error_message: "timeout", partial: true)
      rescue StandardError => error
        Result.new(
          http_status: nil, payload: nil, retry_after: nil, error_code: "transport_error",
          error_message: InterpreterAnthropicAdapter.scrub_text(error.message.to_s).truncate(180), partial: false
        )
      end

      private

      def build_result(status, payload, retry_after)
        if status == 200 && payload.is_a?(Hash) && (payload["content"] || payload["stop_reason"])
          return Result.new(http_status: status, payload: payload, retry_after: retry_after, error_code: nil, error_message: nil, partial: false)
        end

        Result.new(
          http_status: status, payload: payload, retry_after: retry_after,
          error_code: "http_#{status}", error_message: error_text(payload), partial: false
        )
      end

      def parse_json(raw)
        return {} if raw.to_s.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        { "unparsed" => true }
      end

      def error_text(payload)
        return "http_error" unless payload.is_a?(Hash)

        err = payload["error"]
        text = err.is_a?(Hash) ? err["message"].to_s : "http_error"
        InterpreterAnthropicAdapter.scrub_text(text).truncate(180)
      end
    end

    def self.prepare(output_root: nil)
      new(output_root: output_root).prepare_report
    end

    def self.execute(live: false, transport: nil, credential: nil, sleeper: nil, output_root: nil, io: $stdout)
      new(live: live, transport: transport, credential: credential, sleeper: sleeper, output_root: output_root, io: io).execute
    end

    def self.translate(canonical, max_tokens:)
      new.translate(canonical, max_tokens: max_tokens)
    end

    def self.reservation_usd(input_tokens, max_tokens)
      long = input_tokens.to_i > LONG_AT
      input_rate = long ? LONG_INPUT : SHORT_INPUT
      output_rate = long ? LONG_OUTPUT : SHORT_OUTPUT
      (BigDecimal(input_tokens.to_i) * input_rate + BigDecimal(max_tokens.to_i) * output_rate) * GEO
    end

    def self.matrix_ceiling(input_tokens, max_tokens)
      Array(input_tokens).sum(BigDecimal("0")) { |tokens| ATTEMPTS_PER_TURN * reservation_usd(tokens, max_tokens) }
    end

    def self.affordable_max_tokens(input_tokens, budget)
      low = 0
      high = MODEL_MAX_OUTPUT
      best = 0
      while low <= high
        mid = (low + high) / 2
        if matrix_ceiling(input_tokens, mid) <= budget
          best = mid
          low = mid + 1
        else
          high = mid - 1
        end
      end
      best
    end

    def self.money(value)
      format("%.6f", value)
    end

    def self.marker_report(text, reasons:, quotes:)
      quoted = {}
      Array(quotes).each do |quote|
        source = quote["source"] || quote[:source]
        (quoted[source] ||= []) << (quote["text"] || quote[:text]).to_s
      end
      text.to_s.scan(/\[(\d+)\]/).flatten.map(&:to_i).tally.map do |number, count|
        rejected = Array(reasons).any? { |reason| reason["rule"] == "R1" && reason["detail"].to_s.end_with?(":#{number}") }
        {
          "marker" => "[#{number}]",
          "count" => count,
          "quotes" => quoted[number] || [],
          "gate_checked_source_exists" => !rejected,
          "claim_verified_by_quote" => quoted[number].present?,
          "accepted_without_quote_verification" => !rejected && quoted[number].blank?
        }
      end
    end

    def initialize(live: false, transport: nil, credential: nil, sleeper: nil, output_root: nil, io: $stdout, budget: nil)
      @live = live
      @transport = transport
      @credential = credential
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @output = Pathname(output_root || OUTPUT)
      @io = io
      @budget = budget || AUTHORIZED_BUDGET
      @plans = {}
    end

    def prepare_report
      plans = (1..3).map { |number| inspect_turn(number) }
      @plans = plans.index_by { |plan| plan["turn"] }
      inputs = plans.map { |plan| plan["input_tokens"].to_i }
      primary_limit = self.class.affordable_max_tokens(inputs, PRIMARY_BUDGET)
      authorized_limit = self.class.affordable_max_tokens(inputs, AUTHORIZED_BUDGET)
      max_tokens = authorized_limit
      ceiling = self.class.matrix_ceiling(inputs, max_tokens)
      primary_ceiling = self.class.matrix_ceiling(inputs, primary_limit)
      blockers = plans.flat_map { |plan| plan["mismatches"] }
      blockers << "max_tokens_not_above_captured" unless max_tokens > CAPTURED_MAX_TOKENS
      blockers << "ceiling_above_authorization" if ceiling > AUTHORIZED_BUDGET
      blockers << "sources_unjoined" if plans.any? { |plan| !plan["sources_joined"] }
      {
        "ok" => blockers.empty?,
        "blockers" => blockers,
        "stopped_before_model" => true,
        "prior_runs" => prior_runs,
        "prompt_sha256" => CompanionDirectCaptureReplay::PROMPT_SHA,
        "model_id" => MODEL_ID,
        "effort" => EFFORT,
        "thinking" => THINKING,
        "temperature" => "omitted",
        "max_tokens" => max_tokens,
        "captured_max_tokens" => CAPTURED_MAX_TOKENS,
        "primary_budget_usd" => self.class.money(PRIMARY_BUDGET),
        "authorized_budget_usd" => self.class.money(AUTHORIZED_BUDGET),
        "selected_budget_usd" => self.class.money(AUTHORIZED_BUDGET),
        "primary_max_tokens" => primary_limit,
        "primary_ceiling_usd" => self.class.money(primary_ceiling),
        "ceiling_usd" => self.class.money(ceiling),
        "ceiling_fits_primary" => ceiling <= PRIMARY_BUDGET,
        "input_tokens_estimate" => inputs,
        "input_estimate_method" => "one_token_per_character_times_us_geo_1_1",
        "attempts_per_turn" => ATTEMPTS_PER_TURN,
        "retries_per_call" => RETRIES,
        "http_max_retries" => 0,
        "history" => "session_269_fixed",
        "turns" => plans.map { |plan| plan.except("sources", "episode", "messages", "canonical") },
        "sources_consulted" => SOURCES,
        "consulted_on" => CONSULTED_ON,
        "budget_reason" => "El peor caso con effort max, thinking y dos reintentos por turno supera US$0,15. Lahiri autorizó US$0,30."
      }
    end

    def execute
      report = prepare_report
      FileUtils.mkdir_p(@output)
      write_json(@output.join("ceiling.json"), report.merge("written_before_call" => true))
      unless report["ok"]
        @io.puts JSON.generate(report.merge("status" => "refused", "paid_run" => "not_executed"))
        return 2
      end
      if @transport.nil? && !@live
        @io.puts JSON.generate(report.merge("status" => "refused", "reason" => "live_not_requested", "paid_run" => "not_executed"))
        return 2
      end

      key = @credential.nil? ? ENV["ANTHROPIC_API_KEY"].to_s : @credential.to_s
      if key.empty?
        refusal = report.merge("status" => "refused", "reason" => "credential_absent", "paid_run" => "not_executed")
        write_json(@output.join("preflight.json"), refusal)
        @io.puts JSON.generate(refusal)
        return 2
      end

      @ledger = Ledger.new(@output.join("attempts.jsonl"))
      @transport ||= Transport.new
      @max_tokens = report["max_tokens"]
      @version = ANTHROPIC_VERSION
      rows = []
      (1..3).each do |number|
        row = execute_turn(number, key)
        rows << row
        break if row["stop_run"]
      end
      payload = {
        "status" => rows.size == 3 && rows.all? { |row| row["status"] == "returned" } ? "executed" : "stopped",
        "model_id" => MODEL_ID,
        "effort" => EFFORT,
        "thinking" => THINKING,
        "max_tokens" => @max_tokens,
        "selected_budget_usd" => self.class.money(AUTHORIZED_BUDGET),
        "spent_usd" => self.class.money(@ledger.spent),
        "reserved_usd" => self.class.money(@ledger.reserved_total),
        "exposure_usd" => self.class.money(@ledger.exposure),
        "history" => "session_269_fixed",
        "continuity_with_new_answers" => "pending",
        "turns" => rows
      }
      write_json(@output.join("summary.json"), payload)
      @io.puts JSON.generate(payload)
      payload["status"] == "executed" ? 0 : 2
    end

    def translate(canonical, max_tokens:)
      messages = message_list(canonical)
      body = {
        "model" => MODEL_ID,
        "max_tokens" => max_tokens,
        "stream" => true,
        "thinking" => THINKING.dup,
        "output_config" => { "effort" => EFFORT },
        "system" => [ { "type" => "text", "text" => system_text(canonical) } ],
        "messages" => messages.map { |message|
          { "role" => message["role"], "content" => [ { "type" => "text", "text" => message["text"] } ] }
        }
      }
      {
        "provider" => "anthropic",
        "api" => "messages",
        "endpoint" => ENDPOINT,
        "anthropic_version" => @version || ANTHROPIC_VERSION,
        "headers" => { "content-type" => "application/json", "anthropic-version" => @version || ANTHROPIC_VERSION, "x-api-key" => { "present" => true } },
        "http_max_retries" => 0,
        "adjustments" => adjustments(max_tokens),
        "body" => body
      }
    end

    def publish_turn(number, text, stop_reason)
      plan = @plans[number] || inspect_turn(number)
      sources = plan["sources"]
      question = plan["question"]
      evidence = sources.map { |source| { content: source["content"] } }
      safety = AnswerSafetyProcessor.new(locale: :es).call(text.to_s, evidence: evidence, require_cited_evidence: true)
      attribution = CitationAttributionGuard.new(question: question, citations: evidence).call(safety)
      publication = CompanionTurnPublication.call(
        text: text.to_s,
        guarded_text: attribution.answer,
        sources: sources,
        stop_reason: stop_reason,
        technician_texts: CompanionDirectCaptureReplay.technician_texts(plan["episode"], question, plan["messages"]),
        manufacturer: CompanionDirectCaptureReplay.manufacturer(plan["episode"]),
        guards: [
          { "name" => "answer_safety", "before" => text.to_s, "after" => safety },
          { "name" => "citation_attribution", "before" => safety, "after" => attribution.answer }
        ],
        locale: :es
      )
      data = publication.to_h
      publishable = publication.accepted? ? attribution.answer.to_s : CompanionTurnPublication.abstain_message(:es)
      data.merge(
        "safety_text" => safety.to_s,
        "publishable" => publishable,
        "safety_unchanged" => safety.to_s == text.to_s,
        "attribution_unchanged" => attribution.answer.to_s == safety.to_s,
        "visible_markers" => self.class.marker_report(text.to_s, reasons: data["reasons"], quotes: data["quotes"])
      )
    end

    private

    def execute_turn(number, api_key)
      plan = @plans.fetch(number)
      if completed_same_config?(number)
        return { "turn" => number, "status" => "kept_prior", "stop_run" => false }
      end

      translated = translate(plan["canonical"], max_tokens: @max_tokens)
      turn_dir = @output.join(format("turn-%d", number))
      FileUtils.mkdir_p(turn_dir)
      write_json(turn_dir.join("request.json"), translated)
      outcome = call_with_retries(number, translated["body"], plan["input_tokens"], api_key, turn_dir)
      write_json(turn_dir.join("attempts.json"), outcome["attempts"])
      payload = outcome["payload"]
      if payload.is_a?(Hash)
        write_json(turn_dir.join("provider_response.json"), payload)
        composed = visible_response(payload)
        File.write(turn_dir.join("raw.txt"), composed["text"])
        File.write(turn_dir.join("thinking.txt"), thinking_text(payload))
        published = publish_safely(number, composed["text"], composed["stop_reason"])
        write_publication(turn_dir, published)
        usage = payload["usage"].is_a?(Hash) ? payload["usage"] : {}
        write_json(turn_dir.join("usage.json"), usage_document(outcome, composed, usage))
        {
          "turn" => number,
          "status" => outcome["status"],
          "stop_reason" => composed["stop_reason"],
          "stop_run" => outcome["stop_run"],
          "chars" => composed["text"].length,
          "truncated" => composed["stop_reason"].to_s == "max_tokens",
          "accepted" => published["accepted"]
        }
      else
        write_json(turn_dir.join("usage.json"), usage_document(outcome, {}, {}))
        { "turn" => number, "status" => outcome["status"], "stop_run" => outcome["stop_run"], "error" => outcome["error_code"] }
      end
    end

    def retries_allowed
      RETRIES
    end

    def call_with_retries(number, body, input_tokens, api_key, turn_dir)
      attempts = []
      current = body
        retries_left = retries_allowed
      blocked = false
      result = nil
      kind = nil
      loop do
        reservation = self.class.reservation_usd(input_tokens, current["max_tokens"])
        if @ledger.exposure + reservation > @budget
          return { "status" => "budget", "attempts" => attempts, "payload" => nil, "stop_run" => true, "error_code" => "budget" }
        end

        id = @ledger.next_id
        reserved = self.class.money(reservation)
        @ledger.append(attempt_event("reserved", id, number, attempts.size + 1, reserved, nil))
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = @transport.post(body: current, api_key: api_key, version: @version)
        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        kind = classify(result)
        record = {
          "id" => id, "turn" => number, "attempt" => attempts.size + 1, "kind" => kind.to_s,
          "http_status" => result.http_status, "error_code" => result.error_code,
          "retry_after" => result.retry_after, "latency_ms" => latency_ms, "partial" => result.partial
        }
        write_json(turn_dir.join(format("attempt-%d.json", attempts.size + 1)), scrub(result.payload))
        if kind == :ok
          finish_success(id, reserved, result, record)
          attempts << record
          say(number, record)
          return { "status" => "returned", "attempts" => attempts, "payload" => result.payload, "stop_run" => false }
        end

        finish_failure(id, reserved, result, kind, record)
        attempts << record
        say(number, record)
        break if kind == :auth
        break if retries_left <= 0

        if kind == :adapt
          corrected = correct(current, result.error_message)
          break unless corrected

          current = corrected
          @version = FALLBACK_VERSION if result.error_message.to_s.match?(/anthropic-version/i)
          retries_left -= 1
          next
        end
        break unless retryable?(kind)

        retries_left -= 1
        next_reservation = self.class.reservation_usd(input_tokens, current["max_tokens"])
        if @ledger.exposure + next_reservation > @budget
          blocked = true
          break
        end

        wait = delay_seconds(result, RETRIES - retries_left - 1)
        record["slept_seconds"] = wait
        @sleeper.call(wait)
      end
      {
        "status" => blocked ? "budget" : "failed",
        "attempts" => attempts,
        "payload" => result&.payload,
        "stop_run" => kind == :auth || blocked,
        "error_code" => blocked ? "budget" : result&.error_code
      }
    end

    def finish_success(id, reserved, result, record)
      priced = price_usage(result.payload["usage"])
      record["price"] = priced
      if priced["cost_status"] == "priced"
        @ledger.append(attempt_event("settled", id, record["turn"], record["attempt"], reserved, priced["cost_usd"]))
        record["ledger"] = "settled"
      else
        @ledger.append(attempt_event("kept", id, record["turn"], record["attempt"], reserved, nil))
        record["ledger"] = "kept"
      end
    end

    def finish_failure(id, reserved, result, kind, record)
      usage = result.payload.is_a?(Hash) ? result.payload["usage"] : nil
      priced = price_usage(usage)
      record["price"] = priced
      if kind == :timeout || kind == :transport
        @ledger.append(attempt_event("kept", id, record["turn"], record["attempt"], reserved, nil))
        record["ledger"] = "kept"
      elsif priced["cost_status"] == "priced"
        @ledger.append(attempt_event("settled", id, record["turn"], record["attempt"], reserved, priced["cost_usd"]))
        record["ledger"] = "settled"
      elsif kind == :rate_limit || kind == :adapt || kind == :auth
        @ledger.append(attempt_event("released", id, record["turn"], record["attempt"], reserved, "0.000000"))
        record["ledger"] = "released"
      else
        @ledger.append(attempt_event("kept", id, record["turn"], record["attempt"], reserved, nil))
        record["ledger"] = "kept"
      end
    end

    def price_usage(usage)
      return { "cost_status" => "usage_absent", "cost_usd" => nil } unless usage.is_a?(Hash)

      priced = InterpreterAnthropicAdapter.price(MODEL_ID, usage)
      return priced if priced["cost_status"] == "priced"

      allowed = InterpreterAnthropicAdapter::PRICED_USAGE_KEYS +
        InterpreterAnthropicAdapter::USAGE_BREAKDOWN_KEYS +
        InterpreterAnthropicAdapter::INTERPRETED_USAGE_KEYS
      extra = usage.keys - allowed
      return priced if extra.empty? || extra.any? { |key| key.to_s.match?(/token/) }

      stripped = usage.slice(*allowed)
      again = InterpreterAnthropicAdapter.price(MODEL_ID, stripped)
      again["ignored_keys"] = extra
      again
    end

    def classify(result)
      return :timeout if result.error_code == "timeout"
      return :transport if result.error_code == "transport_error" || result.http_status.nil?

      status = result.http_status.to_i
      err = result.payload.is_a?(Hash) ? result.payload["error"] : nil
      err_type = err.is_a?(Hash) ? err["type"].to_s : ""
      message = result.error_message.to_s
      return :ok if status == 200 && result.error_code.nil?
      return :rate_limit if status == 429
      return :overload if status == 529 || err_type == "overloaded_error" || message.match?(/overload/i)
      return :server if status >= 500 && status <= 599
      return :adapt if status == 400
      return :auth if status == 401 || status == 403

      :other
    end

    def retryable?(kind)
      %i[timeout transport rate_limit overload server].include?(kind)
    end

    def correct(body, message)
      text = message.to_s
      updated = JSON.parse(JSON.generate(body))
      changed = false
      if text.match?(/temperature|top_p|top_k/i)
        %w[temperature top_p top_k].each { |key| changed = true if updated.delete(key) }
      end
      if text.match?(/budget_tokens|thinking/i) && text.match?(/disabled|enabled|budget_tokens|display/i)
        updated["thinking"] = { "type" => "adaptive" }
        changed = true
      end
      if text.match?(/effort/i) && text.match?(/invalid|unsupported|not supported|permitted/i)
        current = updated.dig("output_config", "effort")
        index = EFFORT_ORDER.index(current)
        if index && EFFORT_ORDER[index + 1]
          updated["output_config"] = { "effort" => EFFORT_ORDER[index + 1] }
          changed = true
        end
      end
      if text.match?(/max_tokens/i) && text.match?(/too large|maximum|invalid/i) && updated["max_tokens"].to_i > 16_000
        updated["max_tokens"] = 16_000
        changed = true
      end
      if text.match?(/stream/i) && updated.delete("stream")
        changed = true
      end
      if text.match?(/anthropic-version/i)
        changed = true
      end
      changed ? updated : nil
    end

    def delay_seconds(result, retry_index)
      header = result.retry_after.to_s
      if header.match?(/\A\d+\z/)
        return [ header.to_i, RETRY_AFTER_CAP ].min
      end
      if header.present?
        begin
          seconds = Time.httpdate(header) - Time.zone.now
          return [ [ seconds.ceil, RETRY_AFTER_CAP ].min, 0 ].max
        rescue ArgumentError
          nil
        end
      end
      2**retry_index
    end

    def visible_response(payload)
      blocks = Array(payload["content"]).map { |block|
        case block["type"]
        when "text"
          Block.new(block["text"].to_s, nil)
        when "tool_use"
          Block.new(nil, block)
        else
          Block.new(nil, nil)
        end
      }
      message = Struct.new(:content).new(blocks)
      output = Struct.new(:message).new(message)
      response = Struct.new(:stop_reason, :output).new(payload["stop_reason"].to_s, output)
      composed = CompanionDirectAnswer.compose(response)
      { "text" => composed.text.to_s, "stop_reason" => composed.stop_reason.to_s, "rejected" => composed.rejected }
    end

    Block = Struct.new(:text, :tool_use)

    def thinking_text(payload)
      Array(payload["content"]).filter_map { |block|
        next unless block.is_a?(Hash) && block["type"] == "thinking"

        block["thinking"].to_s.presence
      }.join("\n")
    end

    def publish_safely(number, text, stop_reason)
      publish_turn(number, text, stop_reason)
    rescue StandardError => error
      { "accepted" => false, "reasons" => [ { "rule" => "local", "detail" => error.class.name } ], "publishable" => "", "quotes" => [], "visible_markers" => [] }
    end

    def write_publication(turn_dir, published)
      File.write(turn_dir.join("published.txt"), published["publishable"].to_s)
      write_json(turn_dir.join("citations.json"), published["quotes"])
      write_json(turn_dir.join("gate.json"), published.except("safety_text"))
    end

    def usage_document(outcome, composed, usage)
      {
        "stop_reason" => composed["stop_reason"],
        "rejected" => composed["rejected"],
        "truncated" => composed["stop_reason"].to_s == "max_tokens",
        "usage" => usage,
        "attempts" => outcome["attempts"],
        "status" => outcome["status"]
      }
    end

    def attempt_event(event, id, turn, attempt, reserved, actual)
      {
        "event" => event,
        "id" => id,
        "turn" => turn,
        "attempt" => attempt,
        "reserved_usd" => reserved,
        "actual_usd" => actual,
        "at" => Time.now.utc.iso8601
      }
    end

    def inspect_turn(number)
      directory = CANONICAL.join(format("turn-%d", number))
      canonical = JSON.parse(directory.join("request.json").read)
      loaded = CompanionDirectCaptureReplay.load_turn(number)
      resolved = Array(loaded.dig("resolved", "messages"))
      messages = message_list(canonical)
      system = system_text(canonical)
      mismatches = []
      mismatches << "turn-#{number}:system_sha" unless Digest::SHA256.hexdigest(system) == CompanionDirectCaptureReplay::HISTORICAL_PROMPT_SHA
      captured = File.read(CompanionDirectCaptureReplay::CAPTURED_PROMPT_PATH)
      mismatches << "captured:system_sha" unless Digest::SHA256.hexdigest(captured) == CompanionDirectCaptureReplay::PROMPT_SHA
      live = File.read(CompanionDirectAnswer::SYSTEM_PROMPT_PATH)
      mismatches << "live:system_loaded" unless live == CompanionDirectAnswer::SYSTEM_PROMPT
      mismatches << "turn-#{number}:roles" unless messages.pluck("role") == resolved.pluck("role")
      mismatches << "turn-#{number}:texts" unless messages.each_with_index.all? { |message, index|
        message["text"] == resolved[index].to_h["text"]
      }
      mismatches << "turn-#{number}:inference" unless canonical["inference_config"] == { "temperature" => 0, "max_tokens" => 700 }
      mismatches << "turn-#{number}:tools" if canonical.key?("tool_config")
      mismatches << "turn-#{number}:ends_with_user" unless messages.last.to_h["role"] == "user"
      sources = join_sources(number, messages.last.to_h["text"])
      mismatches << "turn-#{number}:sources" if sources.empty? || sources.any?(&:nil?)
      evidence = CompanionDirectCaptureReplay::EVIDENCE.join(format("turn-%d", number))
      {
        "turn" => number,
        "mismatches" => mismatches,
        "input_tokens" => system.length + messages.sum { |message| message["text"].length },
        "roles" => messages.pluck("role"),
        "message_sha256" => messages.map { |message| Digest::SHA256.hexdigest(message["text"]) },
        "sources_joined" => sources.any? && sources.none?(&:nil?),
        "source_count" => sources.compact.size,
        "sources" => sources,
        "question" => evidence.join("question.txt").read,
        "episode" => JSON.parse(evidence.join("episode.json").read),
        "messages" => resolved,
        "canonical" => canonical
      }
    end

    def join_sources(number, text)
      directory = CompanionDirectCaptureReplay::EVIDENCE.join(format("turn-%d", number))
      capture = JSON.parse(directory.join("capture.json").read)
      retrieved = capture["events"].find { |event| event["kind"] == "retrieval_results" && event["role"] == "retrieved" }
      return [] unless retrieved

      CompanionDirectCaptureReplay.prompt_sources(text).map do |narrative|
        CompanionDirectCaptureReplay.join_source(directory, narrative, Array(retrieved["rows"]))
      end
    end

    def completed_same_config?(number)
      path = @output.join(format("turn-%d", number), "usage.json")
      return false unless path.file?

      usage = JSON.parse(path.read)
      request = JSON.parse(@output.join(format("turn-%d", number), "request.json").read)
      usage["status"] == "returned" &&
        request.dig("body", "model") == MODEL_ID &&
        request.dig("body", "output_config", "effort") == EFFORT &&
        request.dig("body", "thinking", "type") == "adaptive" &&
        request.dig("body", "max_tokens") == @max_tokens
    rescue StandardError
      false
    end

    def prior_runs
      return [] unless @output.directory?

      (1..3).filter_map do |number|
        path = @output.join(format("turn-%d", number), "request.json")
        next unless path.file?

        body = JSON.parse(path.read)
        { "turn" => number, "effort" => body.dig("body", "output_config", "effort"), "max_tokens" => body.dig("body", "max_tokens") }
      end
    rescue StandardError
      []
    end

    def system_text(canonical)
      Array(canonical["system"] || canonical[:system]).map { |block|
        block.is_a?(Hash) ? (block["text"] || block[:text]).to_s : block.to_s
      }.join
    end

    def message_list(canonical)
      Array(canonical["messages"] || canonical[:messages]).map do |message|
        content = Array(message["content"] || message[:content])
        text = content.map { |block| block.is_a?(Hash) ? (block["text"] || block[:text]).to_s : block.to_s }.join
        { "role" => (message["role"] || message[:role]).to_s, "text" => text }
      end
    end

    def adjustments(max_tokens)
      [
        { "parameter" => "model", "action" => "replace", "value" => MODEL_ID, "source" => SOURCES["model"] },
        { "parameter" => "temperature", "action" => "omit", "captured" => 0, "source" => SOURCES["migration"],
          "impact" => "Haiku 5.5 no admite temperature, top_p ni top_k." },
        { "parameter" => "thinking", "action" => "set", "value" => THINKING, "source" => SOURCES["effort"],
          "impact" => "effort max rechaza thinking disabled. Adaptive queda explícito. display summarized deja el razonamiento legible; la compuerta publica solo el texto." },
        { "parameter" => "effort", "action" => "set", "value" => EFFORT, "source" => SOURCES["effort"],
          "impact" => "max es el nivel más alto que Haiku 5.5 admite: max, xhigh, high, medium, low." },
        { "parameter" => "max_tokens", "action" => "raise", "captured" => CAPTURED_MAX_TOKENS, "value" => max_tokens,
          "source" => SOURCES["migration"],
          "impact" => "Los tokens de pensamiento cuentan dentro de max_tokens. 700 cortaría la respuesta visible." },
        { "parameter" => "stream", "action" => "set", "value" => true,
          "impact" => "La lectura larga no depende de un único plazo sin bytes." }
      ]
    end

    def say(number, record)
      @io.puts "turn=#{number} attempt=#{record['attempt']} kind=#{record['kind']} ledger=#{record['ledger']} latency_ms=#{record['latency_ms']}"
      @io.flush
    end

    def write_json(path, value)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, JSON.pretty_generate(scrub(value)))
    end

    def scrub(value)
      InterpreterAnthropicAdapter.scrub(json_ready(value))
    end

    def json_ready(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key.to_s] = json_ready(item) }
      when Array
        value.map { |item| json_ready(item) }
      when BigDecimal
        self.class.money(value)
      when Symbol
        value.to_s
      when Struct
        json_ready(value.to_h)
      else
        value
      end
    end
  end
end
