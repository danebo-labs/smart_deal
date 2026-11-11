# frozen_string_literal: true

require "digest"
require "json"
require "stringio"

module Rag
  # Local adapter for the session 269 captures. It is not a product path.
  # It rebuilds the three direct Converse requests from the exported bodies,
  # replays the publication gate on the saved text, and prices a later
  # comparison that changes only the system prompt.
  module CompanionDirectCaptureReplay
    EVIDENCE = Rails.root.join("tmp/field_companion/vf5_direct_guiones/guion2")
    LEDGER = Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json")
    SESSION_SYSTEM_SHA = "30297124d0b0da27f3cd6fa6189bc716e27cb872f733313832a0ad5fad2f62bd"
    NOTICE = "Esto no está en la documentación cargada en este turno."
    SLOW = "Las puertas se abrirán lentamente en la primera operación después de un fallo de alimentación para verificar el paso libre"
    S19 = "Solo es necesario realizar otra vez el autoajuste para la configuración de los parámetros por defecto o cuando se realicen cambios como la conexión o desconexión de la fotocélula Fermator"
    OPUS_EXPECTED = BigDecimal("0.023")
    OPUS_CEILING = BigDecimal("0.089")
    GENERATION_CALLS = 3
    MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    SONNET_45_GLOBAL = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
    PROMPT_SHA = "2527363c8b3832d6773b83862caf1b9cc44d4864e2d52ec121f30b244288ca1d"
    # The product prompt the archived variants were derived from.
    CAPTURED_PROMPT_PATH = Rails.root.join("test/fixtures/vf5_vertical_r2/companion_direct_2527363c.txt")
    HISTORICAL_PROMPT_SHA = "0bf3610b29f5b839d5f27917bce5b728a47f0d8f0551755fa3f56744a6fc901f"
    SONNET_OUTPUT = Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare_sonnet")

    module_function

    def preflight(io: $stdout, ledger_path: LEDGER)
      report = build(ledger_path: ledger_path)
      io.puts JSON.generate(report)
      report["ready"] ? 0 : 2
    end

    def build(ledger_path: LEDGER)
      prompt = system_prompt
      turns = (1..3).map { |number| load_turn(number) }
      missing = turns.flat_map { |turn| turn["missing"] }
      ledger = read_ledger(ledger_path)
      prices = price_turns(turns, prompt)
      plan = call_plan(ledger, prices["ceiling_usd"])
      rubric = turns.map { |turn| review_turn(turn) }
      publication = turns.pluck("publication_compare")
      ready = missing.empty? && turns.all? { |turn| turn["request_equivalent"] } &&
        publication.all? { |row| row["matches"] } &&
        rubric.pluck("pass") == [ false, true, false ] &&
        rubric[2]["referencia_valida"] == true &&
        rubric[2]["conclusion_respaldada"] == false
      {
        "ready" => ready,
        "stopped_before_model" => true,
        "paid_run" => "not_executed",
        "session_id" => 269,
        "episode_id" => "ep_c9049e7575c8ee71",
        "system_sha256" => Digest::SHA256.hexdigest(prompt),
        "captured_system_sha256" => SESSION_SYSTEM_SHA,
        "system_changed" => Digest::SHA256.hexdigest(prompt) != SESSION_SYSTEM_SHA,
        "missing" => missing,
        "turns" => turns.map { |turn| public_turn(turn) },
        "rubric" => rubric,
        "publication" => publication,
        "price" => prices,
        "ledger" => ledger,
        "call_plan" => plan,
        "command" => command
      }
    end

    def system_prompt
      text = CAPTURED_PROMPT_PATH.read
      raise "captured prompt drifted" unless Digest::SHA256.hexdigest(text) == PROMPT_SHA

      text
    end

    def load_turn(number)
      directory = EVIDENCE.join(format("turn-%d", number))
      capture = JSON.parse(directory.join("capture.json").read)
      converse = capture["events"].find { |event| event["kind"] == "converse" && event["operation"] == "converse_message" }
      direct = capture["events"].find { |event| event["kind"] == "companion_direct" }
      published = capture["events"].find { |event| event["kind"] == "published_answer" }
      gate = capture["events"].find { |event| event["kind"] == "companion_publication" }
      retrieved = capture["events"].find { |event| event["kind"] == "retrieval_results" && event["role"] == "retrieved" }
      missing = []
      missing << "turn-#{number}:converse" unless converse
      missing << "turn-#{number}:companion_direct" unless direct
      missing << "turn-#{number}:published_answer" unless published
      missing << "turn-#{number}:companion_publication" unless gate
      missing << "turn-#{number}:retrieved" unless retrieved
      resolved = converse ? resolve_converse(directory, converse, missing, number) : nil
      request = resolved && resolved["missing"].empty? ? comparison_request(resolved, system_prompt) : nil
      publication = if request && direct && gate
        replay_publication(directory, number, resolved, direct, gate, published, retrieved)
      else
        { "matches" => false, "reason" => "incomplete_capture" }
      end
      {
        "number" => number,
        "missing" => missing,
        "resolved" => resolved,
        "request" => request,
        "request_equivalent" => request && equivalent?(resolved, request),
        "direct" => direct,
        "published_event" => published,
        "gate" => gate,
        "publication_compare" => publication,
        "answer" => directory.join("published.txt").read,
        "question" => directory.join("question.txt").read,
        "raw" => directory.join("raw.txt").read
      }
    end

    def resolve_converse(directory, event, missing, number)
      system = resolve_text(directory, event.dig("system", 0, "text"))
      missing << "turn-#{number}:system" unless system
      messages = Array(event["messages"]).map do |message|
        text = resolve_text(directory, message.dig("content", 0, "text"))
        missing << "turn-#{number}:message" unless text
        { "role" => message["role"], "text" => text }
      end
      {
        "model_id" => event["model_id"],
        "inference_config" => event["inference_config"],
        "system" => system,
        "messages" => messages,
        "tool_config" => event.key?("tool_config"),
        "missing" => missing.grep(/turn-#{number}:/)
      }
    end

    def resolve_text(directory, node)
      if node.is_a?(String)
        node
      elsif node.is_a?(Hash) && node["evidence"] == "external"
        path = directory.join(node["path"].to_s)
        return nil unless path.file?

        bytes = path.binread
        return nil unless Digest::SHA256.hexdigest(bytes) == node["sha256"]

        bytes.force_encoding(Encoding::UTF_8)
      end
    end

    def comparison_request(resolved, prompt)
      {
        model_id: resolved["model_id"],
        system: [ { text: prompt } ],
        messages: resolved["messages"].map { |message|
          { role: message["role"], content: [ { text: message["text"] } ] }
        },
        inference_config: {
          temperature: resolved.dig("inference_config", "temperature"),
          max_tokens: resolved.dig("inference_config", "max_tokens")
        }
      }
    end

    def equivalent?(resolved, request)
      return false unless resolved["model_id"] == MODEL_ID
      return false unless resolved["inference_config"] == { "temperature" => 0, "max_tokens" => 700 }
      return false if resolved["tool_config"]
      return false unless Digest::SHA256.hexdigest(resolved["system"]) == SESSION_SYSTEM_SHA
      return false unless request[:model_id] == MODEL_ID
      return false unless request[:inference_config] == { temperature: 0, max_tokens: 700 }
      return false unless request[:system] == [ { text: system_prompt } ]
      return false unless request[:messages].pluck(:role) == resolved["messages"].pluck("role")

      request[:messages].each_with_index.all? { |message, index|
        message[:content][0][:text] == resolved["messages"][index]["text"]
      }
    end

    def replay_publication(directory, number, resolved, direct, gate, published, retrieved)
      current = resolved["messages"].last["text"]
      narratives = prompt_sources(current)
      rows = Array(retrieved["rows"])
      sources = narratives.map { |narrative| join_source(directory, narrative, rows) }
      gap = sources.each_with_index.filter_map { |source, index| index + 1 if source.nil? }
      return { "turn" => number, "matches" => false, "unjoined_sources" => gap } if gap.any?

      question = directory.join("question.txt").read
      raw = direct["text"].to_s
      evidence = sources.map { |source| { content: source["content"] } }
      safety = AnswerSafetyProcessor.new(locale: :es).call(raw, evidence: evidence, require_cited_evidence: true)
      attribution = CitationAttributionGuard.new(question: question, citations: evidence).call(safety)
      episode = JSON.parse(directory.join("episode.json").read)
      publication = CompanionTurnPublication.call(
        text: raw,
        guarded_text: attribution.answer,
        sources: sources,
        stop_reason: direct["stop_reason"],
        technician_texts: technician_texts(episode, question, resolved["messages"]),
        manufacturer: manufacturer(episode),
        guards: [
          { "name" => "answer_safety", "before" => raw, "after" => safety },
          { "name" => "citation_attribution", "before" => safety, "after" => attribution.answer }
        ],
        locale: :es
      )
      actual = publication.to_h
      expected = {
        "accepted" => gate["accepted"],
        "reasons" => gate["reasons"],
        "signals" => gate["signals"],
        "quotes" => gate["quotes"]
      }
      citation = Array(published["citations"]).first
      {
        "turn" => number,
        "matches" => same_publication?(actual, expected) && safety == raw && attribution.answer == raw,
        "safety_unchanged" => safety == raw,
        "attribution_unchanged" => attribution.answer == raw,
        "publication" => actual,
        "captured" => expected,
        "citation" => citation && {
          "number" => citation["number"],
          "page" => citation["page"],
          "filename" => citation["filename"]
        }
      }
    end

    # Older captures store offsets within a fragment and omit uncited quotes.
    # The current gate records offsets in the source body and tracks more quotes.
    def same_publication?(actual, expected)
      return false unless actual.except("quotes") == expected.except("quotes")

      quotes = actual.fetch("quotes").map { |quote| quote.slice("text", "source") }
      expected.fetch("quotes").all? { |quote| quotes.include?(quote.slice("text", "source")) }
    end

    def prompt_sources(text)
      body = text.split("Fuentes de este turno:\n", 2)[1].to_s
      body.split(/^(?=\[\d+\] )/).filter_map do |part|
        heading, narrative = part.split("\n", 2)
        match = heading.to_s.match(/\A\[(\d+)\] /)
        next unless match

        { "index" => match[1].to_i, "narrative" => narrative.to_s.strip }
      end
    end

    def join_source(directory, narrative, rows)
      matches = rows.filter_map do |row|
        full = resolve_text(directory, row["text"])
        next unless full
        next unless DocumentIdentityScope.omit_terminal_evidence_records(full).strip == narrative["narrative"]

        full
      end
      return nil unless matches.one?

      {
        "index" => narrative["index"],
        "content" => matches.first,
        "applicability" => "",
        "reference_only" => false
      }
    end

    def technician_texts(episode, question, messages)
      active = episode["active_episode"] || {}
      texts = [ question ]
      texts << active.dig("goal", "text")
      Array(active["observations"]).each { |item| texts << item["text"] }
      Array(active["identifiers"]).each { |item| texts << item["value"] }
      messages.each do |message|
        next unless message["role"] == "user"
        next if message["text"].to_s.start_with?("Mensaje de este turno:")

        texts << message["text"]
      end
      texts.compact
    end

    def manufacturer(episode)
      fact = episode.dig("active_episode", "facts", "manufacturer")
      return nil unless fact.is_a?(Hash) && fact["status"] == "known"

      fact["value"].to_s.squish.presence
    end

    def review_turn(turn)
      answer = turn["answer"].to_s
      question = turn["question"].to_s
      citation = turn.dig("publication_compare", "citation") || {}
      page_8 = citation["page"].to_i == 8 && citation["filename"] == "chunk_p8_1.txt"
      source = turn.dig("resolved", "messages").to_a.last&.dig("text").to_s
      case turn["number"]
      when 1 then review_t1(answer, question, source)
      when 2 then review_t2(answer, question, source)
      when 3 then review_t3(answer, question, source, page_8)
      end
    end

    def review_t1(answer, question, source)
      documented = answer.include?(SLOW) && source.include?(SLOW)
      questions = answer.scan(/¿[^?]+\?/)
      persistence_only = questions.all? { |item|
        item.match?(/lent|persist/i) && !item.match?(/autoajuste|después del/i)
      }
      prescribes = answer.match?(/realiza el autoajuste/i)
      steps = answer.match?(/Desconecta los pines/i)
      assumes = answer.match?(/después del autoajuste/i)
      condition = question.match?(/parámetros por defecto|fotocélula|persiste/i)
      {
        "turn" => 1,
        "pass" => documented && persistence_only && !prescribes && !steps && !assumes,
        "documented_slow_opening" => documented,
        "question_only_if_persists" => questions.empty? || persistence_only,
        "prescribes_autoajuste" => prescribes,
        "gives_steps" => steps,
        "assumes_intervention" => assumes,
        "documented_condition_established" => condition
      }
    end

    def review_t2(answer, question, source)
      uses = question.include?("Fue solo la primera apertura") && answer.include?(SLOW) && source.include?(SLOW)
      concludes = answer.match?(/comportamiento es normal/i)
      reasks = answer.include?("?")
      {
        "turn" => 2,
        "pass" => uses && concludes && !reasks,
        "uses_first_opening" => uses,
        "concludes_documented" => concludes,
        "reasks" => reasks,
        "inference_noted" => answer.include?("ha recuperado su funcionamiento habitual")
      }
    end

    def review_t3(answer, question, source, page_8)
      first = answer.strip.lines.first.to_s
      answers = first.match?(/no hace falta repetir el autoajuste/i)
      literal = answer.include?(S19) && source.include?(S19)
      widened = answer.match?(/no has hecho cambios/i)
      calibrated = answer.match?(/calibrad/i)
      denied = question.match?(/configuración/i) && question.match?(/fotocélula/i)
      referencia = literal && page_8 && S19.start_with?("Solo")
      conclusion = answers && denied && !widened && !calibrated
      {
        "turn" => 3,
        "pass" => referencia && conclusion,
        "answers_at_start" => answers,
        "referencia_valida" => referencia,
        "conclusion_respaldada" => conclusion,
        "widens_negation" => widened,
        "certifies_calibration" => calibrated,
        "page_8" => page_8
      }
    end

    def price_turns(turns, prompt)
      delta = prompt.length - turns.fetch(0).dig("resolved", "system").to_s.length
      expected = BigDecimal("0")
      ceilings = []
      turns.each do |turn|
        direct = turn["direct"] || {}
        expected += LocalPassLedger.price(MODEL_ID, direct["input_tokens"].to_i + delta, direct["output_tokens"].to_i)
        request = comparison_request(turn["resolved"], prompt)
        ceilings << LocalPassLedger.price(MODEL_ID, LocalPassLedger.text_chars(request), 700)
      end
      ceiling = ceilings.sum(BigDecimal("0")) + ceilings.max
      {
        "method" => "captured_tokens_plus_system_character_delta",
        "system_character_delta" => delta,
        "expected_usd" => format("%.6f", expected),
        "opus_expected_usd" => format("%.6f", OPUS_EXPECTED),
        "expected_minus_opus_usd" => format("%.6f", expected - OPUS_EXPECTED),
        "call_ceilings_usd" => ceilings.map { |amount| format("%.6f", amount) },
        "ceiling_usd" => format("%.6f", ceiling),
        "opus_ceiling_usd" => format("%.6f", OPUS_CEILING),
        "ceiling_within_opus" => ceiling <= OPUS_CEILING,
        "ceiling_includes" => "three generation calls plus one retry of the dearest call, output capped at 700"
      }
    end

    def read_ledger(path = LEDGER)
      raw = path.file? ? path.binread : ""
      state = raw.empty? ? {} : JSON.parse(raw)
      cap = state["call_cap"].to_i
      attempts = state["attempts"].to_i
      {
        "sha256" => Digest::SHA256.hexdigest(raw),
        "attempts" => attempts,
        "call_cap" => cap,
        "remaining_calls" => cap - attempts,
        "committed" => state["committed"],
        "unknown" => state["unknown"],
        "authorization_room_usd" => format("%.6f", authorization_room(state))
      }
    end

    def authorization_room(state)
      auth = state["authorization"]
      return BigDecimal("0") unless auth.is_a?(Hash)

      after = auth["after_attempt"].to_i
      limit = BigDecimal(auth["cost_usd"].to_s)
      exposure = Array(state["entries"]).sum(BigDecimal("0")) do |entry|
        next BigDecimal("0") unless entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released"

        case entry["status"]
        when "settled", "kept"
          BigDecimal(entry["actual_usd"].to_s)
        when "unknown"
          BigDecimal((entry["reserved_usd"].presence || entry["ceiling_usd"]).to_s)
        when "reserved"
          BigDecimal(entry["ceiling_usd"].to_s)
        else
          BigDecimal("0")
        end
      end
      limit - exposure
    end

    def call_plan(ledger, ceiling_text)
      remaining = ledger["remaining_calls"].to_i
      room = BigDecimal(ledger["authorization_room_usd"])
      ceiling = BigDecimal(ceiling_text)
      {
        "generation_calls" => GENERATION_CALLS,
        "retry_budget" => remaining >= GENERATION_CALLS + 1 ? 1 : 0,
        "start" => remaining >= GENERATION_CALLS && room >= ceiling,
        "stopped_before_model" => true
      }
    end

    def command
      "env -u BUNDLE_PATH GUION2_PROMPT_COMPARE_EXECUTE=1 bin/rails runner script/field_companion/replay_direct_prompt_compare.rb"
    end

    def public_turn(turn)
      resolved = turn["resolved"] || {}
      {
        "turn" => turn["number"],
        "model_id" => resolved["model_id"],
        "inference_config" => resolved["inference_config"],
        "roles" => Array(resolved["messages"]).pluck("role"),
        "message_sha256" => Array(resolved["messages"]).map { |message|
          Digest::SHA256.hexdigest(message["text"].to_s)
        },
        "system_sha256" => resolved["system"] && Digest::SHA256.hexdigest(resolved["system"]),
        "tool_config" => resolved["tool_config"],
        "request_equivalent" => turn["request_equivalent"],
        "changed_fields" => [ "system" ],
        "captured_input_chars" => resolved["system"] && LocalPassLedger.text_chars(comparison_request(resolved, resolved["system"])),
        "input_chars" => turn["request"] && LocalPassLedger.text_chars(turn["request"]),
        "captured_input_tokens" => turn.dig("direct", "input_tokens"),
        "captured_output_tokens" => turn.dig("direct", "output_tokens")
      }
    end

    def execute(io: $stdout)
      report = build
      model = ENV["GUION2_PROMPT_COMPARE_MODEL"].to_s.strip
      prepared = model.empty? ? nil : effective_requests(model)
      if prepared
        unless prepared["ok"]
          io.puts JSON.generate(prepared.except("requests").merge("status" => "refused", "stopped_before_model" => true, "paid_run" => "not_executed"))
          return 2
        end
      elsif !(report["ready"] && report.dig("call_plan", "start"))
        io.puts JSON.generate(report.merge("status" => "refused", "stopped_before_model" => true))
        return 2
      end

      arm_ledger!(report)
      directory = prepared ? SONNET_OUTPUT : Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare")
      FileUtils.mkdir_p(directory)
      client = BedrockClient.new
      retries = prepared ? 0 : report.dig("call_plan", "retry_budget").to_i
      rows = []
      (1..3).each do |number|
        request = if prepared
          prepared["requests"][number - 1]
        else
          comparison_request(load_turn(number)["resolved"], system_prompt)
        end
        outcome = generation_call(client, request)
        if outcome.is_a?(StandardError) && retries.positive? && unavailable?(outcome)
          retries -= 1
          outcome = generation_call(client, request)
        end
        row = save_outcome(directory, number, request, outcome)
        rows << row
        break if row["status"] != "returned"
      end
      payload = { "status" => rows.all? { |row| row["status"] == "returned" } ? "executed" : "stopped", "turns" => rows, "retries_left" => retries }
      File.write(directory.join("summary.json"), JSON.generate(payload))
      io.puts JSON.generate(payload)
      payload["status"] == "executed" ? 0 : 2
    end

    def effective_requests(model, ledger_path: LEDGER)
      prompt = system_prompt
      ledger = read_ledger(ledger_path)
      requests = []
      mismatches = []
      (1..3).each do |number|
        turn = load_turn(number)
        resolved = turn["resolved"] || {}
        request = comparison_request(resolved, prompt)
        request[:model_id] = model
        requests << request
        mismatches << "turn-#{number}:system" unless Digest::SHA256.hexdigest(prompt) == PROMPT_SHA
        mismatches << "turn-#{number}:model" unless model == SONNET_45_GLOBAL && BedrockQuery::BEDROCK_PRICING.key?(model)
        mismatches << "turn-#{number}:inference" unless request[:inference_config] == { temperature: 0, max_tokens: 700 }
        mismatches << "turn-#{number}:tool_config" if request.key?(:tool_config)
        resolved_messages = Array(resolved["messages"])
        mismatches << "turn-#{number}:messages" unless request[:messages].each_with_index.all? { |message, index|
          captured = resolved_messages[index] || {}
          message[:role] == captured["role"] && message.dig(:content, 0, :text) == captured["text"]
        }
      end
      ceilings = requests.map { |request|
        LocalPassLedger.price(model, LocalPassLedger.text_chars(request), 700)
      }
      sum = ceilings.sum(BigDecimal("0"))
      room = BigDecimal(ledger["authorization_room_usd"])
      blockers = []
      blockers << "model_not_authorized" unless model == SONNET_45_GLOBAL && BedrockQuery::BEDROCK_PRICING.key?(model)
      blockers << "request_mismatch" if mismatches.any?
      blockers << "ceiling_exceeds_room" if sum > room
      blockers << "attempts_short" if ledger["remaining_calls"].to_i < GENERATION_CALLS
      {
        "ok" => blockers.empty?,
        "blockers" => blockers,
        "mismatches" => mismatches,
        "model_id" => model,
        "ceilings_usd" => ceilings.map { |amount| format("%.6f", amount) },
        "ceiling_usd" => format("%.6f", sum),
        "authorization_room_usd" => format("%.6f", room),
        "remaining_calls" => ledger["remaining_calls"],
        "retries" => 0,
        "requests" => requests
      }
    end

    def generation_call(client, request)
      client.converse_message(request)
    rescue StandardError => error
      error
    end

    def unavailable?(error)
      CompanionDirectAnswer.http_status(error) == 503 || error.class.name.include?("ServiceUnavailable")
    end

    def save_outcome(directory, number, request, outcome)
      turn_dir = directory.join(format("turn-%d", number))
      FileUtils.mkdir_p(turn_dir)
      File.write(turn_dir.join("request.json"), JSON.generate(request))
      if outcome.is_a?(StandardError)
        File.write(turn_dir.join("error.txt"), "#{outcome.class}: #{outcome.message}")
        return { "turn" => number, "status" => "failed", "error_class" => outcome.class.name }
      end

      composed = CompanionDirectAnswer.compose(outcome)
      File.write(turn_dir.join("raw.txt"), composed.text.to_s)
      { "turn" => number, "status" => "returned", "stop_reason" => composed.stop_reason, "chars" => composed.text.to_s.length }
    end

    def arm_ledger!(report)
      ENV["RAG_ASSIGNMENT_SPEND_PATH"] = LEDGER.to_s
      ENV["RAG_LOCAL_PASS_GUARD"] = "1"
      ENV["RAG_LOCAL_PASS_CALL_CAP"] = report.dig("ledger", "remaining_calls").to_s
      ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = report.dig("ledger", "authorization_room_usd").to_s
      ENV["AWS_MAX_ATTEMPTS"] = "1"
      ENV["AWS_RETRY_MODE"] = "standard"
      ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = "1"
      LocalPassLedger.reset!
      LocalPassLedger.reset_local_process!
    end
  end
end
