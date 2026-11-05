# frozen_string_literal: true

require Rails.root.join("test/support/companion_haiku55_compare")

module Rag
  # Chained Haiku 5.5 runs of the two VF5 scripts. Retrieval is the frozen
  # corpus. Generation is the Messages API. Production is not called.
  class CompanionVerticalLadder < CompanionHaiku55Compare
    MAX_TOKENS = 48_000
    BUDGET = BigDecimal("1.00")
    ROOT = Rails.root.join("tmp/field_companion/vf5_vertical_haiku55")
    LEDGER_PATH = ROOT.join("attempts.jsonl")
    GUION2_DIR = Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare")
    GUION1_PACK = Rails.root.join("tmp/vf5_citation_gui_20261029/2026-10-29_2026-10-29_danebo-legacy/validation_captures/web-danebo-legacy")
    DEFINITION_DIR = Rails.root.join("test/fixtures/vf5_continuity_20261027/chunks")
    GUION1_CAPTURES = {
      1 => "113786b7-89f0-45e9-b725-e8c156ad8be2",
      2 => "bf295bdc-937d-44dc-a5a4-74c47275a557",
      3 => "ebacf496-163e-4c53-ac81-607b62d7e818",
      4 => "e1a8155a-7e39-4450-a8ec-8075b79b263d",
      5 => "d929b927-8b15-4ead-aa79-bf66b0cb7e6b"
    }.freeze
    GUION2_QUESTIONS = [
      "Estoy con un Fermator VF5+. Después de un corte de alimentación, al volver la corriente la puerta abrió muy despacio. ¿Por dónde empiezo?",
      "Fue solo la primera apertura. Después volvió a abrir y cerrar como antes.",
      "No he cambiado la configuración ni conectado o desconectado la fotocélula. Con lo que te conté, ¿hace falta repetir el autoajuste?"
    ].freeze
    GUION1_QUESTIONS = [
      "Estoy revisando un operador de puerta Fermator VF5+. La puerta se reabre sola durante el cierre. El LED está apagado y no veo obstrucción. Todavía no he revisado el ajuste de #54 ni he hecho mediciones. ¿Cómo seguimos?",
      "Corrijo un dato: el LED está encendido, no apagado.",
      "Revisé la fotocélula y no está activada.",
      "¿Qué sigue?",
      "No sé cómo identificar si está activada la entrada #21 ni cómo saber si hay un contacto cerrado entre #21 y #23. ¿Qué información necesitas de mí para orientar el caso?"
    ].freeze
    SLOW = CompanionDirectCaptureReplay::SLOW
    MARKER = /\[\d+\]/

    class << self
      def execute_sequence(io: $stdout, credential: nil)
        new(io: io, credential: credential, budget: BUDGET, output_root: ROOT).execute_sequence
      end
    end

    def execute_sequence
      FileUtils.mkdir_p(ROOT)
      @ledger = Ledger.new(LEDGER_PATH)
      @transport ||= Transport.new
      @version = ANTHROPIC_VERSION
      @max_tokens = MAX_TOKENS
      @effort = "max"
      write_json(ROOT.join("ceiling.json"), ceiling_document)
      key = @credential.nil? ? ENV["ANTHROPIC_API_KEY"].to_s : @credential.to_s
      if key.empty?
        payload = { "status" => "refused", "reason" => "credential_absent", "paid_run" => "not_executed" }
        write_json(ROOT.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end

      prompt = CompanionDirectAnswer::SYSTEM_PROMPT
      unless Digest::SHA256.hexdigest(prompt) == CompanionDirectCaptureReplay::PROMPT_SHA
        payload = { "status" => "refused", "reason" => "prompt_sha", "paid_run" => "not_executed" }
        @io.puts JSON.generate(payload)
        return 2
      end

      rows = []
      guion2 = {}
      %w[max high medium].each do |effort|
        row = run_script("guion2", effort, key)
        rows << row
        guion2[effort] = row
        break if row["stopped"] || !row["pass"]
      end

      passed = %w[max high medium].select { |effort| guion2[effort] && guion2[effort]["pass"] }
      if guion2["max"] && !guion2["max"]["pass"] && !guion2["max"]["stopped"]
        rows << run_script("guion1", "max", key)
      end

      final = nil
      %w[medium high max].select { |effort| passed.include?(effort) }.each do |effort|
        row = run_script("guion1", effort, key)
        rows << row
        break if row["stopped"]

        if row["pass"]
          final = effort
          break
        end
      end

      if final
        rows << run_script("guion2", final, key, repeat: true)
        rows << run_script("guion1", final, key, repeat: true)
      end

      summary = {
        "status" => rows.any? { |row| row["stopped"] } ? "stopped" : "executed",
        "final_effort" => final,
        "guion2_passed" => passed,
        "spent_usd" => self.class.money(@ledger.spent),
        "exposure_usd" => self.class.money(@ledger.exposure),
        "max_tokens" => MAX_TOKENS,
        "runs" => rows
      }
      write_json(ROOT.join("summary.json"), summary)
      @io.puts JSON.generate(summary)
      final ? 0 : 2
    end

    def assemble(name, number, prior)
      script = load_script(name)
      turn = script[number - 1]
      messages = []
      prior.each do |item|
        messages << { "role" => "user", "text" => item[:question] }
        messages << { "role" => "assistant", "text" => item[:published].to_s.gsub(MARKER, "").strip }
      end
      messages << { "role" => "user", "text" => current_text(turn["question"], turn["fuentes"]) }
      {
        "messages" => messages,
        "sources" => turn["sources"],
        "question" => turn["question"],
        "episode" => turn["episode"],
        "fuentes_sha256" => Digest::SHA256.hexdigest(turn["fuentes"]),
        "stages" => turn["stages"]
      }
    end

    private

    def ceiling_document
      {
        "written_before_call" => true,
        "model_id" => MODEL_ID,
        "thinking" => THINKING,
        "max_tokens" => MAX_TOKENS,
        "budget_usd" => self.class.money(BUDGET),
        "prompt_sha256" => CompanionDirectCaptureReplay::PROMPT_SHA,
        "retrieval" => "simulated_frozen_corpus",
        "generation" => "anthropic_messages",
        "product_base" => "not_called",
        "product_reason" => "Haiku 4.5 con pensamiento extendido no admite temperatura ni tool_choice forzado. El plan y el intérprete de 72ee437 usan los dos.",
        "history" => "own_published_answers_markers_stripped",
        "registry" => "docs/field_companion/REGISTRO_VERSIONES_VERTICAL_20261105.md"
      }
    end

    def run_script(name, effort, api_key, repeat: false)
      @effort = effort
      @output = ROOT.join("#{name}-#{effort}#{'-repeat' if repeat}")
      FileUtils.mkdir_p(@output)
      script = load_script(name)
      prior = []
      turns = []
      stopped = false
      script.each do |turn|
        built = assemble(name, turn["number"], prior)
        outcome = generate_turn(turn["number"], built, api_key)
        turns << outcome
        if outcome["status"] != "returned"
          stopped = true
          break
        end
        prior << { question: turn["question"], published: outcome["publishable"] }
      end
      judged = judge(name, turns)
      payload = {
        "script" => name,
        "effort" => effort,
        "repeat" => repeat,
        "pass" => !stopped && judged["pass"],
        "stopped" => stopped,
        "reasons" => judged["reasons"],
        "turns" => turns.map { |turn| turn.except("publishable") }
      }
      write_json(@output.join("verdict.json"), payload)
      @io.puts JSON.generate(payload.except("turns"))
      payload
    end

    def generate_turn(number, built, api_key)
      turn_dir = @output.join(format("turn-%d", number))
      FileUtils.mkdir_p(turn_dir)
      reused = reuse_turn(turn_dir)
      return reused if reused
      canonical = {
        "system" => [ { "text" => CompanionDirectAnswer::SYSTEM_PROMPT } ],
        "messages" => built["messages"].map { |message|
          { "role" => message["role"], "content" => [ { "text" => message["text"] } ] }
        }
      }
      translated = translate(canonical, max_tokens: MAX_TOKENS)
      write_json(turn_dir.join("request.json"), translated)
      write_json(turn_dir.join("sources.json"), {
        "fuentes_sha256" => built["fuentes_sha256"],
        "stages" => built["stages"],
        "count" => built["sources"].size
      })
      input_tokens = CompanionDirectAnswer::SYSTEM_PROMPT.length + built["messages"].sum { |message| message["text"].length }
      outcome = call_with_retries(number, translated["body"], input_tokens, api_key, turn_dir)
      write_json(turn_dir.join("attempts.json"), outcome["attempts"])
      payload = outcome["payload"]
      return { "turn" => number, "status" => outcome["status"], "stop_run" => outcome["stop_run"] } unless payload.is_a?(Hash)

      write_json(turn_dir.join("provider_response.json"), payload)
      composed = visible_response(payload)
      File.write(turn_dir.join("raw.txt"), composed["text"])
      File.write(turn_dir.join("thinking.txt"), thinking_text(payload))
      published = publish_answer(built, composed["text"], composed["stop_reason"])
      write_publication(turn_dir, published)
      usage = payload["usage"].is_a?(Hash) ? payload["usage"] : {}
      write_json(turn_dir.join("usage.json"), usage_document(outcome, composed, usage))
      {
        "turn" => number,
        "status" => outcome["status"],
        "stop_reason" => composed["stop_reason"],
        "truncated" => composed["stop_reason"].to_s == "max_tokens",
        "accepted" => published["accepted"],
        "publishable" => published["publishable"],
        "chars" => composed["text"].length
      }
    end

    def reuse_turn(turn_dir)
      usage_path = turn_dir.join("usage.json")
      request_path = turn_dir.join("request.json")
      return nil unless usage_path.file? && request_path.file? && turn_dir.join("published.txt").file?

      usage = JSON.parse(usage_path.read)
      request = JSON.parse(request_path.read)
      return nil unless usage["status"] == "returned"
      return nil unless request.dig("body", "output_config", "effort") == @effort
      return nil unless request.dig("body", "max_tokens") == MAX_TOKENS

      gate = JSON.parse(turn_dir.join("gate.json").read)
      {
        "turn" => turn_dir.basename.to_s.delete_prefix("turn-").to_i,
        "status" => "returned",
        "stop_reason" => usage["stop_reason"],
        "truncated" => usage["truncated"] == true,
        "accepted" => gate["accepted"] == true,
        "publishable" => turn_dir.join("published.txt").read,
        "chars" => turn_dir.join("raw.txt").read.length,
        "reused" => true
      }
    rescue StandardError
      nil
    end

    def translate(canonical, max_tokens:)
      request = super
      request["body"]["output_config"] = { "effort" => @effort }
      request["adjustments"] = Array(request["adjustments"]).map { |item|
        item["parameter"] == "effort" ? item.merge("value" => @effort) : item
      }
      request
    end

    def correct(body, message)
      text = message.to_s
      return nil if text.match?(/effort/i) && text.match?(/invalid|unsupported|not supported|permitted/i)
      return nil if text.match?(/max_tokens/i) && text.match?(/too large|maximum|invalid/i)

      updated = JSON.parse(JSON.generate(body))
      changed = false
      if text.match?(/temperature|top_p|top_k/i)
        %w[temperature top_p top_k].each { |key| changed = true if updated.delete(key) }
      end
      if text.match?(/budget_tokens|thinking/i) && text.match?(/disabled|enabled|budget_tokens|display/i)
        updated["thinking"] = { "type" => "adaptive", "display" => "summarized" }
        changed = true
      end
      if text.match?(/stream/i) && updated.delete("stream")
        changed = true
      end
      changed = true if text.match?(/anthropic-version/i)
      changed ? updated : nil
    end

    def publish_answer(built, text, stop_reason)
      evidence = built["sources"].map { |source| { content: source["content"] } }
      safety = AnswerSafetyProcessor.new(locale: :es).call(text.to_s, evidence: evidence, require_cited_evidence: true)
      attribution = CitationAttributionGuard.new(question: built["question"], citations: evidence).call(safety)
      messages = built["messages"].map { |message| { "role" => message["role"], "text" => message["text"] } }
      publication = CompanionTurnPublication.call(
        text: text.to_s,
        guarded_text: attribution.answer,
        sources: built["sources"],
        stop_reason: stop_reason,
        technician_texts: CompanionDirectCaptureReplay.technician_texts(built["episode"], built["question"], messages),
        manufacturer: CompanionDirectCaptureReplay.manufacturer(built["episode"]),
        guards: [
          { "name" => "answer_safety", "before" => text.to_s, "after" => safety },
          { "name" => "citation_attribution", "before" => safety, "after" => attribution.answer }
        ],
        locale: :es
      )
      data = publication.to_h
      publishable = publication.accepted? ? attribution.answer.to_s : CompanionTurnPublication.abstain_message(:es)
      data.merge(
        "publishable" => publishable,
        "safety_unchanged" => safety.to_s == text.to_s,
        "attribution_unchanged" => attribution.answer.to_s == safety.to_s,
        "visible_markers" => self.class.marker_report(text.to_s, reasons: data["reasons"], quotes: data["quotes"])
      )
    end

    def load_script(name)
      @scripts ||= {}
      @scripts[name] ||= name == "guion2" ? load_guion2 : load_guion1
    end

    def load_guion2
      episode = JSON.parse(CompanionDirectCaptureReplay::EVIDENCE.join("turn-1/episode.json").read)
      GUION2_QUESTIONS.each_with_index.map do |question, index|
        number = index + 1
        request = JSON.parse(GUION2_DIR.join(format("turn-%d/request.json", number)).read)
        text = request["messages"].last["content"][0]["text"]
        fuentes = text.split("Fuentes de este turno:\n", 2)[1].to_s
        sources = join_sources(number, text).compact
        {
          "number" => number,
          "question" => question,
          "fuentes" => fuentes,
          "sources" => sources,
          "episode" => episode,
          "stages" => { "retrieval" => "simulated", "source" => "session_269_canonical_request", "generation" => "real" }
        }
      end
    end

    def load_guion1
      episode = JSON.parse(CompanionDirectCaptureReplay::EVIDENCE.join("turn-1/episode.json").read)
      GUION1_QUESTIONS.each_with_index.map do |question, index|
        number = index + 1
        capture = JSON.parse(GUION1_PACK.join(GUION1_CAPTURES.fetch(number), "capture.json").read)
        rows = capture["events"].find { |event| event["kind"] == "retrieval_results" && event["role"] == "retrieved" }.fetch("rows")
        added = capture["events"].find { |event| event["kind"] == "companion_definitions" }.fetch("added")
        chunks = rows.each_with_index.map { |row, row_index|
          body = File.read(GUION1_PACK.join(GUION1_CAPTURES.fetch(number), row.dig("text", "path")))
          chunk_for(body, row["document"], row["page"], row["score"], "retrieved-#{row_index}")
        }
        Array(added).each do |item|
          filename = item["provenance"].to_s[/(chunk_p\d+_\d+\.txt)\z/, 1]
          path = DEFINITION_DIR.join(filename.to_s)
          next unless path.file?

          chunks << chunk_for(path.read, "Módulo electrónico VF5+ Fermator", item["page"], 1.0, filename)
        end
        kept = CompanionPlan.limit_statement_chunks(chunks)
        fuentes = kept.each_with_index.map { |chunk, source|
          body = DocumentIdentityScope.omit_terminal_evidence_records(chunk["content"]).strip
          "#{CompanionPlan.source_heading(chunk, source + 1)}\n#{body}"
        }.join("\n")
        {
          "number" => number,
          "question" => question,
          "fuentes" => fuentes,
          "sources" => kept.each_with_index.map { |chunk, source|
            { "index" => source + 1, "content" => chunk["content"], "applicability" => "", "reference_only" => false, "id" => chunk["id"] }
          },
          "episode" => episode,
          "stages" => {
            "retrieval" => "simulated",
            "source" => "accepted_4a6deb9_capture_ep_63de315872dfed14",
            "definitions" => "local_fixture_named_by_capture",
            "window" => "direct_candidate_16000",
            "generation" => "real",
            "kept" => kept.map { |chunk| chunk["id"] }
          }
        }
      end
    end

    def chunk_for(body, name, page, score, id)
      {
        "content" => body,
        "score" => score.to_f,
        "id" => id,
        "metadata" => { "canonical_name" => name, "page_number" => page.to_s.sub(/\.0\z/, "") }
      }
    end

    def current_text(question, fuentes)
      "Mensaje de este turno:\n#{question}\n\nFuentes de este turno:\n#{fuentes}"
    end

    def judge(name, turns)
      reasons = []
      reasons << "incomplete" unless turns.size == (name == "guion2" ? 3 : 5) && turns.all? { |turn| turn["status"] == "returned" }
      turns.each do |turn|
        reasons << "t#{turn['turn']}:truncated" if turn["truncated"]
        reasons << "t#{turn['turn']}:gate" if turn["accepted"] == false
        text = turn["publishable"].to_s
        reasons.concat(name == "guion2" ? judge_guion2(turn["turn"], text) : judge_guion1(turn["turn"], text))
      end
      { "pass" => reasons.empty?, "reasons" => reasons }
    end

    def judge_guion2(number, text)
      case number
      when 1
        reasons = []
        reasons << "t1:missing_slow_opening" unless text.include?(SLOW)
        reasons << "t1:autoajuste_if_still_slow" if still_slow_autoajuste?(text)
        reasons
      when 2
        reasons = []
        reasons << "t2:reasks" if text.include?("?")
        reasons << "t2:unused_first_opening" unless text.include?(SLOW) || text.match?(/primera apertura/i)
        reasons << "t2:no_conclusion" unless text.match?(/coincide|normal|previsto|documentad/i)
        reasons
      else
        reasons = []
        reasons << "t3:orders_repeat" if text.match?(/hay que repetir el autoajuste|realiza el autoajuste|ejecuta el autoajuste/i)
        reasons << "t3:erased_parameters" if text.match?(/borr[oó] los par[aá]metros|perdi[oó] los par[aá]metros/i)
        reasons
      end
    end

    def judge_guion1(number, text)
      case number
      when 1
        reasons = []
        reasons << "t1:obstruction_discarded" if text.match?(/obstrucci[oó]n descartad/i)
        reasons << "t1:probable_cause" if text.match?(/causa m[aá]s probable/i)
        reasons << "t1:several_questions" if text.scan("?").size > 1
        reasons
      when 2
        text.match?(/\bapagado\b/i) && !text.match?(/correcci[oó]n|ya no|dejó de estar apagado|no est[aá] apagado/i) ? [ "t2:keeps_off" ] : []
      when 5
        text.match?(/¿[^?\n]*#21[^?\n]*\?/i) || text.match?(/¿[^?\n]*#23[^?\n]*\?/i) ? [ "t5:reasks_identification" ] : []
      else
        []
      end
    end

    def still_slow_autoajuste?(text)
      text.match?(/si la apertura lenta persiste[\s\S]{0,240}autoajuste/i) ||
        text.match?(/si (?:permanece|sigue) lenta[\s\S]{0,240}autoajuste/i) ||
        text.match?(/lentitud persist[\s\S]{0,180}autoajuste/i) ||
        text.match?(/si sigue abriendo[\s\S]{0,180}autoajuste/i)
    end
  end
end
