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
    BAND_DIR = ROOT.join("band")
    BAND_LEDGER_PATH = BAND_DIR.join("attempts.jsonl")
    # Ceiling only. The call chains the real published text. Eight thousand
    # characters is the product history cap and overstates these answers.
    PUBLISHED_BOUND_CHARS = 8_000
    BAND_PAIRS = [
      [ "guion2", "high" ],
      [ "guion1", "high" ],
      [ "guion2", "medium" ],
      [ "guion1", "medium" ]
    ].freeze
    HIGH_PAIRS = [
      [ "guion2", "high" ],
      [ "guion1", "high" ]
    ].freeze
    HIGH_DIR = ROOT.join("high_validation")
    CITATION_PROMPT_SHA = "a6b486fc9b28f9bde92076714d78bd053d510c18f53ea9be532b29c4ef0569d6"
    VARIANT_PROMPT_PATH = Rails.root.join("test/fixtures/vf5_vertical_r2/companion_direct_variant.txt")
    VARIANT_PROMPT_SHA = "e7babf77052c46688d033ed208bf00d95bc349953cfbc2ddfd763b64772478c0"
    # Same path-and-SHA load as the adjustment variant. The paragraph is not
    # tied to a manual, a brand, or a citation number.
    PARAPHRASE_PROMPT_PATH = Rails.root.join("test/fixtures/vf5_vertical_r2/companion_direct_paraphrase.txt")
    PARAPHRASE_PROMPT_SHA = "2e9bbcff8cf6f75a96ac6cbb1e8479a97c2fcca3a76aec099691e8cc4cb12954"
    PARAPHRASE_DIR = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/guion1_paraphrase_pending")
    PARAPHRASE_PAIRS = [ [ "guion1", "high" ] ].freeze
    # Paraphrase system plus one procedure paragraph. Not a product prompt.
    SCOPE_PROMPT_PATH = Rails.root.join("test/fixtures/vf5_vertical_r2/companion_direct_scope.txt")
    SCOPE_PROMPT_SHA = "b1b55d3e95ba9f09ea342bcd27e724b32e95649f143d89ec5f97e523c8a8a0e2"
    # Guion 2, then Guion 1. Each script starts with an empty history.
    SCOPE_PAIRS = [ [ "guion2", "high" ], [ "guion1", "high" ] ].freeze
    SCOPE_DIR = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/guion_scope_b1b55d3e")
    SCOPE_CEILING_USD = "0.702420"
    ADJUSTMENT_DIR = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/opus_adjustment")
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
    # The technician already said they cannot identify the input, or the
    # answer tells them they do not have to. Danebo's own "no puedo" is not this.
    TECHNICIAN_LIMIT_PATTERN = /
      no[[:space:]]+hace[[:space:]]+falta[[:space:]]+que[[:space:]]+(?:(?:la|lo|las|los)[[:space:]]+)?identifiqu
      |ya[[:space:]]+(?:dijiste|indicaste|contaste)
    /ix
    # What the loaded pages or Danebo cannot do. It does not, by itself,
    # acknowledge the technician's limit.
    METHOD_LIMIT_PATTERN = /
      no[[:space:]]+puedo[[:space:]]+indicarte[[:space:]]+c[oó]mo[[:space:]]+identificar
      |no[[:space:]]+puedo[[:space:]]+identificar
      |las[[:space:]]+fuentes[[:space:]]+no[[:space:]]+dicen[[:space:]]+c[oó]mo[[:space:]]+medir
      |no[[:space:]]+(?:explica|describe|dice|dicen|indica|indican)[[:space:]]+c[oó]mo[[:space:]]+(?:medir|identificar|verificar|comprobar|probar|saber)
      |no[[:space:]]+est[aá][[:space:]]+en[[:space:]]+la[[:space:]]+documentaci[oó]n
      |no[[:space:]]+(?:da|dan)[[:space:]]+(?:voltajes|un[[:space:]]+m[eé]todo)
      |no[[:space:]]+tengo[[:space:]]+un[[:space:]]+procedimiento
      |no[[:space:]]+puedo[[:space:]]+darte[[:space:]]+(?:valores|pasos)
      |no[[:space:]]+describe[[:space:]]+(?:ese[[:space:]]+)?procedimiento
      |no[[:space:]]+le[[:space:]]+doy[[:space:]]+pasos
    /ix

    class << self
      def execute_sequence(io: $stdout, credential: nil)
        new(io: io, credential: credential, budget: BUDGET, output_root: ROOT).execute_sequence
      end

      def execute_band(io: $stdout, credential: nil, budget: BUDGET)
        new(io: io, credential: credential, budget: budget, output_root: BAND_DIR).execute_band
      end

      def execute_high(io: $stdout, credential: nil, budget: BUDGET, output_root: HIGH_DIR, prompt_sha: nil)
        ladder = new(io: io, credential: credential, budget: budget, output_root: output_root)
        ladder.expected_prompt_sha = prompt_sha if prompt_sha
        ladder.execute_high
      end

      def execute_adjustment(io: $stdout, credential: nil, budget: BUDGET, output_root: ADJUSTMENT_DIR)
        new(io: io, credential: credential, budget: budget, output_root: output_root).execute_adjustment
      end

      def execute_paraphrase(io: $stdout, credential: nil, budget: BUDGET, output_root: PARAPHRASE_DIR)
        new(io: io, credential: credential, budget: budget, output_root: output_root).execute_paraphrase
      end

      def execute_scope(io: $stdout, credential: nil, budget: BUDGET, output_root: SCOPE_DIR)
        new(io: io, credential: credential, budget: budget, output_root: output_root).execute_scope
      end

      def execute_closure(io: $stdout, credential: nil, budget: BUDGET)
        plan_root = ROOT.join("closure_plan")
        ladder = new(io: io, credential: credential, budget: budget, output_root: plan_root)
        document = ladder.closure_ceiling_document
        FileUtils.mkdir_p(plan_root)
        ladder.send(:write_json, plan_root.join("ceiling.json"), document)
        io.puts JSON.generate(document.except("turns"))
        return 2 unless document["decision"] == "execute"

        execute_high(io: io, credential: credential, budget: budget, output_root: ROOT.join("closure_base"))
      end
    end

    def execute_sequence
      FileUtils.mkdir_p(ROOT)
      @ledger = Ledger.new(LEDGER_PATH)
      @transport ||= Transport.new
      @version = ANTHROPIC_VERSION
      @max_tokens = MAX_TOKENS
      @effort = "max"
      @system_text = historical_system
      write_json(ROOT.join("ceiling.json"), ceiling_document)
      key = @credential.nil? ? ENV["ANTHROPIC_API_KEY"].to_s : @credential.to_s
      if key.empty?
        payload = { "status" => "refused", "reason" => "credential_absent", "paid_run" => "not_executed" }
        write_json(ROOT.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end

      prompt = @system_text
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

    def execute_high
      @run_pairs = HIGH_PAIRS
      execute_band
    end

    # One control pass on the product system and two passes on the variant.
    # Both use the same gate, the same judges, and one fresh ledger.
    def execute_adjustment
      @run_pairs = HIGH_PAIRS
      directory = Pathname(@output)
      FileUtils.mkdir_p(directory)
      preview = adjustment_ceiling_document
      write_json(directory.join("ceiling.json"), preview)
      @io.puts JSON.generate(preview.except("turns"))
      if preview["decision"] != "execute"
        write_json(directory.join("preflight.json"), {
          "status" => "refused", "reason" => preview["decision"], "paid_run" => "not_executed",
          "ceiling_usd" => preview["ceiling_usd"], "authorized_budget_usd" => preview["authorized_budget_usd"]
        })
        return 2
      end

      key = @credential.nil? ? ENV["ANTHROPIC_API_KEY"].to_s : @credential.to_s
      if key.empty?
        payload = { "status" => "refused", "reason" => "credential_absent", "paid_run" => "not_executed" }
        write_json(directory.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end
      unless product_prompt_sha == CompanionDirectCaptureReplay::PROMPT_SHA && variant_prompt_sha == VARIANT_PROMPT_SHA
        payload = {
          "status" => "refused", "reason" => "prompt_sha", "paid_run" => "not_executed",
          "product_prompt_sha256" => product_prompt_sha, "variant_prompt_sha256" => variant_prompt_sha
        }
        write_json(directory.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end

      @ledger = Ledger.new(directory.join("attempts.jsonl"))
      @transport ||= Transport.new
      @version = ANTHROPIC_VERSION
      @max_tokens = MAX_TOKENS
      @attempt_limit = preview["attempts_per_generation"]
      rows = []
      halted = false
      adjustment_arms.each do |arm|
        break if halted

        @system_text = arm["system"]
        self.runs_root = directory.join(arm["dir"])
        arm["pairs"].each do |name, effort|
          break if halted

          row = run_script(name, effort, key)
          row["arm"] = arm["arm"]
          row["pass"] = arm["pass"]
          row["prompt_sha256"] = Digest::SHA256.hexdigest(arm["system"])
          rows << row
          halted = band_halt?(row)
        end
      end
      summary = {
        "status" => halted ? "stopped" : "executed",
        "spent_usd" => self.class.money(@ledger.spent),
        "exposure_usd" => self.class.money(@ledger.exposure),
        "calls" => @ledger.events.count { |event| event["event"] == "reserved" },
        "generations" => rows.sum { |row| Array(row["turns"]).count { |turn| turn["status"] == "returned" } },
        "attempts_per_generation" => @attempt_limit,
        "medium_generations" => 0,
        "bedrock_ledger" => "not_used",
        "runs" => rows
      }
      write_json(directory.join("summary.json"), summary)
      @io.puts JSON.generate(summary.except("runs"))
      halted ? 2 : 0
    end

    # High and medium, both scripts, one fresh Anthropic ledger. Max stays
    # in the historical ledger and is not called again.
    def execute_band
      @run_pairs ||= BAND_PAIRS
      @system_text = band_system
      directory = Pathname(@output)
      FileUtils.mkdir_p(directory)
      preview = band_ceiling_document
      write_json(directory.join("ceiling.json"), preview)
      @io.puts JSON.generate(preview.except("turns"))
      if preview["decision"] != "execute"
        write_json(directory.join("preflight.json"), {
          "status" => "refused",
          "reason" => preview["decision"],
          "paid_run" => "not_executed",
          "ceiling_usd" => preview["ceiling_usd"],
          "authorized_budget_usd" => preview["authorized_budget_usd"]
        })
        return 2
      end

      key = @credential.nil? ? ENV["ANTHROPIC_API_KEY"].to_s : @credential.to_s
      if key.empty?
        payload = { "status" => "refused", "reason" => "credential_absent", "paid_run" => "not_executed" }
        write_json(directory.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end

      unless Digest::SHA256.hexdigest(@system_text) == expected_prompt_sha
        payload = { "status" => "refused", "reason" => "prompt_sha", "paid_run" => "not_executed", "expected_prompt_sha256" => expected_prompt_sha }
        write_json(directory.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end

      @ledger = Ledger.new(directory.join("attempts.jsonl"))
      @transport ||= Transport.new
      @version = ANTHROPIC_VERSION
      @max_tokens = MAX_TOKENS
      rows = []
      halted = false
      run_pairs.each do |name, effort|
        break if halted

        row = run_script(name, effort, key)
        rows << row
        halted = band_halt?(row)
      end
      summary = {
        "status" => halted ? "stopped" : "executed",
        "spent_usd" => self.class.money(@ledger.spent),
        "exposure_usd" => self.class.money(@ledger.exposure),
        "calls" => @ledger.events.count { |event| event["event"] == "reserved" },
        "historical_max_spent_usd" => preview["historical_max_spent_usd"],
        "historical_max_calls" => preview["historical_max_calls"],
        "bedrock_ledger" => "not_used",
        "runs" => rows
      }
      write_json(directory.join("summary.json"), summary)
      @io.puts JSON.generate(summary.except("runs"))
      halted ? 2 : 0
    end

    def explain_r2(name, number, raw)
      built = assemble(name, number, [])
      published = publish_answer(built, raw, "end_turn")
      findings = Array(published["reasons"]).select { |reason| reason["rule"] == "R2" }.map { |reason|
        quoted = reason["detail"].to_s.sub(/\Acondition_dropped:/, "")
        explain_dropped_quote(built, raw, quoted)
      }
      { "accepted" => published["accepted"], "reasons" => published["reasons"], "findings" => findings }
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

    # One Guion 1 pass on the paraphrase system. Guion 2 stays a regression
    # of the same loader; this entry does not call it.
    def execute_paraphrase
      directory = Pathname(@output)
      FileUtils.mkdir_p(directory)
      self.runs_root = directory
      preview = paraphrase_ceiling_document
      write_json(directory.join("ceiling.json"), preview)
      @io.puts JSON.generate(preview.except("turns"))
      unless product_prompt_sha == CompanionDirectCaptureReplay::PROMPT_SHA && paraphrase_prompt_sha == PARAPHRASE_PROMPT_SHA
        payload = {
          "status" => "refused", "reason" => "prompt_sha", "paid_run" => "not_executed",
          "product_prompt_sha256" => product_prompt_sha,
          "paraphrase_prompt_sha256" => paraphrase_prompt_sha,
          "expected_paraphrase_prompt_sha256" => PARAPHRASE_PROMPT_SHA
        }
        write_json(directory.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end
      if preview["decision"] != "execute"
        write_json(directory.join("preflight.json"), {
          "status" => "refused", "reason" => preview["decision"], "paid_run" => "not_executed",
          "ceiling_usd" => preview["ceiling_usd"], "authorized_budget_usd" => preview["authorized_budget_usd"]
        })
        return 2
      end

      key = @credential.nil? ? ENV["ANTHROPIC_API_KEY"].to_s : @credential.to_s
      if key.empty?
        payload = { "status" => "refused", "reason" => "credential_absent", "paid_run" => "not_executed" }
        write_json(directory.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end

      @system_text = File.read(PARAPHRASE_PROMPT_PATH)
      @run_pairs = PARAPHRASE_PAIRS
      @ledger = Ledger.new(directory.join("attempts.jsonl"))
      @transport ||= Transport.new
      @version = ANTHROPIC_VERSION
      @max_tokens = MAX_TOKENS
      rows = []
      halted = false
      PARAPHRASE_PAIRS.each do |name, effort|
        break if halted

        row = run_script(name, effort, key)
        row["prompt_sha256"] = Digest::SHA256.hexdigest(active_system)
        rows << row
        halted = band_halt?(row)
      end
      summary = {
        "status" => halted ? "stopped" : "executed",
        "spent_usd" => self.class.money(@ledger.spent),
        "exposure_usd" => self.class.money(@ledger.exposure),
        "calls" => @ledger.events.count { |event| event["event"] == "reserved" },
        "generations" => rows.sum { |row| Array(row["turns"]).count { |turn| turn["status"] == "returned" } },
        "scripts" => PARAPHRASE_PAIRS,
        "prompt_sha256" => PARAPHRASE_PROMPT_SHA,
        "medium_generations" => 0,
        "bedrock_ledger" => "not_used",
        "runs" => rows
      }
      write_json(directory.join("summary.json"), summary)
      @io.puts JSON.generate(summary.except("runs"))
      halted ? 2 : 0
    end

    # Guion 2 and Guion 1 on the scope system. The ceiling is checked before
    # any reservation. A gate rejection does not stop the next turn or script.
    def execute_scope
      directory = Pathname(@output)
      FileUtils.mkdir_p(directory)
      self.runs_root = directory
      preview = scope_ceiling_document
      write_json(directory.join("ceiling.json"), preview)
      @io.puts JSON.generate(preview.except("turns"))
      scope_sha = Digest::SHA256.hexdigest(File.read(SCOPE_PROMPT_PATH))
      unless product_prompt_sha == CompanionDirectCaptureReplay::PROMPT_SHA &&
          paraphrase_prompt_sha == PARAPHRASE_PROMPT_SHA &&
          scope_sha == SCOPE_PROMPT_SHA
        payload = {
          "status" => "refused", "reason" => "prompt_sha", "paid_run" => "not_executed",
          "product_prompt_sha256" => product_prompt_sha,
          "paraphrase_prompt_sha256" => paraphrase_prompt_sha,
          "scope_prompt_sha256" => scope_sha,
          "expected_scope_prompt_sha256" => SCOPE_PROMPT_SHA
        }
        write_json(directory.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end
      unless preview["decision"] == "execute" && preview["ceiling_usd"] == SCOPE_CEILING_USD && preview["generations"] == 8
        write_json(directory.join("preflight.json"), {
          "status" => "refused", "reason" => "ceiling_mismatch", "paid_run" => "not_executed",
          "ceiling_usd" => preview["ceiling_usd"], "expected_ceiling_usd" => SCOPE_CEILING_USD,
          "generations" => preview["generations"], "decision" => preview["decision"],
          "authorized_budget_usd" => preview["authorized_budget_usd"]
        })
        @io.puts JSON.generate({ "status" => "refused", "reason" => "ceiling_mismatch", "paid_run" => "not_executed" })
        return 2
      end

      key = @credential.nil? ? ENV["ANTHROPIC_API_KEY"].to_s : @credential.to_s
      if key.empty?
        payload = { "status" => "refused", "reason" => "credential_absent", "paid_run" => "not_executed" }
        write_json(directory.join("preflight.json"), payload)
        @io.puts JSON.generate(payload)
        return 2
      end

      @system_text = File.read(SCOPE_PROMPT_PATH)
      @run_pairs = SCOPE_PAIRS
      @ledger = Ledger.new(directory.join("attempts.jsonl"))
      @transport ||= Transport.new
      @version = ANTHROPIC_VERSION
      @max_tokens = MAX_TOKENS
      rows = []
      halted = false
      SCOPE_PAIRS.each do |name, effort|
        break if halted

        row = run_script(name, effort, key)
        row["prompt_sha256"] = Digest::SHA256.hexdigest(active_system)
        rows << row
        halted = band_halt?(row)
      end
      summary = {
        "status" => halted ? "stopped" : "executed",
        "spent_usd" => self.class.money(@ledger.spent),
        "exposure_usd" => self.class.money(@ledger.exposure),
        "calls" => @ledger.events.count { |event| event["event"] == "reserved" },
        "generations" => rows.sum { |row| Array(row["turns"]).count { |turn| turn["status"] == "returned" } },
        "scripts" => SCOPE_PAIRS,
        "prompt_sha256" => SCOPE_PROMPT_SHA,
        "medium_generations" => 0,
        "bedrock_ledger" => "not_used",
        "runs" => rows
      }
      write_json(directory.join("summary.json"), summary)
      @io.puts JSON.generate(summary.except("runs"))
      halted ? 2 : 0
    end

    def paraphrase_ceiling_document
      previous_pairs = @run_pairs
      previous_system = @system_text
      @run_pairs = PARAPHRASE_PAIRS
      @system_text = File.read(PARAPHRASE_PROMPT_PATH)
      turns = band_ceiling_rows
      one = turns.sum(BigDecimal("0")) { |turn| BigDecimal(turn["reservation_usd"]) }
      storm = one * ATTEMPTS_PER_TURN
      {
        "written_before_call" => true,
        "model_id" => MODEL_ID,
        "thinking" => THINKING,
        "effort" => "high",
        "scripts" => PARAPHRASE_PAIRS,
        "generations" => turns.size,
        "attempts_per_generation" => ATTEMPTS_PER_TURN,
        "max_tokens" => MAX_TOKENS,
        "authorized_budget_usd" => self.class.money(@budget),
        "spent_at_open_usd" => "0.000000",
        "calls_at_open" => 0,
        "one_pass_ceiling_usd" => self.class.money(one),
        "ceiling_usd" => self.class.money(storm),
        "retry_storm_ceiling_usd" => self.class.money(storm),
        "retry_storm_note" => "Tres intentos por generación. El runner reserva uno, lo liquida y solo reserva el siguiente si el anterior no cerró y la exposición sigue dentro del presupuesto.",
        "decision" => turns.size == 5 && storm <= @budget ? "execute" : "ceiling_above_authorization",
        "prompt_sha256" => Digest::SHA256.hexdigest(@system_text),
        "product_prompt_sha256" => product_prompt_sha,
        "historical_prompt_sha256" => CompanionDirectCaptureReplay::PROMPT_SHA,
        "bedrock_ledger" => "not_used",
        "retrieval" => "simulated_frozen_corpus",
        "history" => "published_text_markers_stripped",
        "stages_not_executed" => [ "query_composition", "retrieve", "rerank" ],
        "turns" => turns
      }
    ensure
      @run_pairs = previous_pairs
      @system_text = previous_system
    end
    public :paraphrase_ceiling_document

    # Ceiling only. Guion 2 and Guion 1, high, three attempts reserved one at a time.
    # It does not call the model and it does not treat the bound as a measured spend.
    def scope_ceiling_document
      previous_pairs = @run_pairs
      previous_system = @system_text
      @run_pairs = SCOPE_PAIRS
      @system_text = File.read(SCOPE_PROMPT_PATH)
      turns = band_ceiling_rows
      one = turns.sum(BigDecimal("0")) { |turn| BigDecimal(turn["reservation_usd"]) }
      storm = one * ATTEMPTS_PER_TURN
      {
        "written_before_call" => true,
        "model_call" => "not_executed",
        "model_id" => MODEL_ID,
        "thinking" => THINKING,
        "effort" => "high",
        "scripts" => SCOPE_PAIRS,
        "generations" => turns.size,
        "attempts_per_generation" => ATTEMPTS_PER_TURN,
        "max_tokens" => MAX_TOKENS,
        "authorized_budget_usd" => self.class.money(@budget),
        "spent_at_open_usd" => "0.000000",
        "calls_at_open" => 0,
        "one_pass_ceiling_usd" => self.class.money(one),
        "ceiling_usd" => self.class.money(storm),
        "retry_storm_ceiling_usd" => self.class.money(storm),
        "retry_storm_note" => "Tres intentos por generación. El runner reserva uno, lo liquida y solo reserva el siguiente si el anterior no cerró y la exposición sigue dentro del presupuesto.",
        "decision" => turns.size == 8 && storm <= @budget ? "execute" : "ceiling_above_authorization",
        "prompt_sha256" => Digest::SHA256.hexdigest(@system_text),
        "paraphrase_prompt_sha256" => PARAPHRASE_PROMPT_SHA,
        "product_prompt_sha256" => product_prompt_sha,
        "historical_prompt_sha256" => CompanionDirectCaptureReplay::PROMPT_SHA,
        "bedrock_ledger" => "not_used",
        "retrieval" => "simulated_frozen_corpus",
        "history" => "published_text_markers_stripped",
        "published_bound_chars" => PUBLISHED_BOUND_CHARS,
        "stages_not_executed" => [ "query_composition", "retrieve", "rerank" ],
        "turns" => turns
      }
    ensure
      @run_pairs = previous_pairs
      @system_text = previous_system
    end
    public :scope_ceiling_document

    def preview_request(built, system: nil)
      previous = @system_text
      @system_text = system unless system.nil?
      @effort = "high"
      canonical = {
        "system" => [ { "text" => active_system } ],
        "messages" => built["messages"].map { |message|
          { "role" => message["role"], "content" => [ { "text" => message["text"] } ] }
        }
      }
      translate(canonical, max_tokens: MAX_TOKENS)
    ensure
      @system_text = previous
    end

    private

    def script_stops?(outcome)
      outcome["status"] != "returned"
    end

    def band_halt?(row)
      Array(row["turns"]).any? { |turn| turn["stop_run"] == true }
    end

    def band_ceiling_document
      previous_system = @system_text
      @system_text ||= band_system
      historical = Ledger.new(LEDGER_PATH)
      prior_band_path = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/band/attempts.jsonl")
      prior_band = prior_band_path.file? ? Ledger.new(prior_band_path) : nil
      turns = band_ceiling_rows
      ceiling = turns.sum(BigDecimal("0")) { |turn| BigDecimal(turn["reservation_usd"]) }
      storm = ceiling * ATTEMPTS_PER_TURN
      {
        "written_before_call" => true,
        "model_id" => MODEL_ID,
        "thinking" => THINKING,
        "effort_levels" => run_pairs.map(&:last).uniq,
        "scripts" => run_pairs,
        "generations" => turns.size,
        "max_tokens" => MAX_TOKENS,
        "authorized_budget_usd" => self.class.money(@budget),
        "spent_at_open_usd" => "0.000000",
        "calls_at_open" => 0,
        "historical_max_spent_usd" => self.class.money(historical.spent),
        "historical_max_calls" => historical.events.count { |event| event["event"] == "reserved" },
        "prior_band_spent_usd" => prior_band ? self.class.money(prior_band.spent) : nil,
        "prior_band_calls" => prior_band ? prior_band.events.count { |event| event["event"] == "reserved" } : 0,
        "historical_ledger" => LEDGER_PATH.to_s,
        "band_ledger" => Pathname(@output).join("attempts.jsonl").to_s,
        "bedrock_ledger" => "not_used",
        "published_bound_chars" => PUBLISHED_BOUND_CHARS,
        "ceiling_usd" => self.class.money(ceiling),
        "retry_storm_ceiling_usd" => self.class.money(storm),
        "retry_storm_note" => "Tres intentos por generación, reservados a la vez. El runner liquida cada intento antes del siguiente y frena la llamada que cruzaría el presupuesto.",
        "decision" => ceiling <= @budget ? "execute" : "ceiling_above_authorization",
        "prompt_sha256" => Digest::SHA256.hexdigest(active_system),
        "historical_prompt_sha256" => CompanionDirectCaptureReplay::PROMPT_SHA,
        "historical_citation_prompt_sha256" => CITATION_PROMPT_SHA,
        "turns" => turns
      }
    ensure
      @system_text = previous_system
    end

    def run_pairs
      @run_pairs || BAND_PAIRS
    end

    def closure_ceiling_document
      previous_system = @system_text
      @run_pairs = HIGH_PAIRS
      @system_text = band_system
      base = band_ceiling_rows
      base.each { |turn| turn["pass"] = "base" }
      variant = base.map do |turn|
        chars = turn["input_chars"] + 500
        reservation = self.class.reservation_usd(chars, MAX_TOKENS)
        turn.merge(
          "pass" => "variant_bound",
          "input_chars" => chars,
          "long_context" => chars > LONG_AT,
          "reservation_usd" => self.class.money(reservation)
        )
      end
      turns = base + variant
      ceiling = turns.sum(BigDecimal("0")) { |turn| BigDecimal(turn["reservation_usd"]) }
      base_ceiling = base.sum(BigDecimal("0")) { |turn| BigDecimal(turn["reservation_usd"]) }
      citation_path = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/citation_prompt_20261105/high_validation/attempts.jsonl")
      citation = citation_path.file? ? Ledger.new(citation_path) : nil
      {
        "written_before_call" => true,
        "passes" => 2,
        "generations" => turns.size,
        "authorized_budget_usd" => self.class.money(@budget),
        "spent_at_open_usd" => "0.000000",
        "calls_at_open" => 0,
        "ceiling_usd" => self.class.money(ceiling),
        "base_ceiling_usd" => self.class.money(base_ceiling),
        "decision" => ceiling <= @budget ? "execute" : "ceiling_above_authorization",
        "prompt_sha256" => Digest::SHA256.hexdigest(active_system),
        "historical_prompt_sha256" => CompanionDirectCaptureReplay::PROMPT_SHA,
        "historical_citation_prompt_sha256" => CITATION_PROMPT_SHA,
        "historical_max_spent_usd" => band_ceiling_document["historical_max_spent_usd"],
        "prior_band_spent_usd" => band_ceiling_document["prior_band_spent_usd"],
        "prior_citation_spent_usd" => citation ? self.class.money(citation.spent) : nil,
        "prior_citation_calls" => citation ? citation.events.count { |event| event["event"] == "reserved" } : 0,
        "bedrock_ledger" => "not_used",
        "turns" => turns
      }
    ensure
      @system_text = previous_system
    end
    public :closure_ceiling_document

    def band_ceiling_rows
      run_pairs.flat_map do |name, effort|
        prior = []
        load_script(name).map do |turn|
          built = assemble(name, turn["number"], prior)
          input_chars = active_system.length +
            built["messages"].sum { |message| message["text"].to_s.length }
          reservation = self.class.reservation_usd(input_chars, MAX_TOKENS)
          prior << { question: turn["question"], published: "x" * PUBLISHED_BOUND_CHARS }
          {
            "script" => name,
            "effort" => effort,
            "turn" => turn["number"],
            "input_chars" => input_chars,
            "long_context" => input_chars > LONG_AT,
            "reservation_usd" => self.class.money(reservation)
          }
        end
      end
    end

    def explain_dropped_quote(built, raw, quoted)
      fragment = AnswerSafetyProcessor.fragments(raw).find { |item|
        item.include?("«#{quoted}»") || item.include?("“#{quoted}”") || item.include?("\"#{quoted}\"")
      }
      lead = fragment.to_s.split(quoted, 2).first.to_s
      numbers = fragment.to_s.scan(CompanionTurnPublication::CITATION_PATTERN).flatten.map(&:to_i).uniq
      numbers = (1..built["sources"].size).to_a if numbers.empty?
      match = numbers.filter_map { |number|
        source = built["sources"][number - 1]
        next unless source

        content = source["content"].to_s
        piece = AnswerSafetyProcessor.fragments(content).find { |item|
          CompanionTurnPublication.send(:fragment_match, item, quoted)
        }
        next unless piece

        found = CompanionTurnPublication.send(:fragment_match, piece, quoted)

        before = piece[0...found.begin(0)].to_s
        {
          "source" => number,
          "source_id" => source["id"],
          "fragment" => piece,
          "before" => before,
          "after_start" => piece[found.end(0)..].to_s[0, 180],
          "families_before" => CompanionTurnPublication::MARKER_FAMILIES.select { |_family, markers|
            markers.any? { |marker| before.match?(/(?<![[:alnum:]])#{Regexp.escape(marker)}(?![[:alnum:]])/i) }
          }.keys
        }
      }.first
      {
        "quoted" => quoted,
        "answer_fragment" => fragment,
        "lead" => lead,
        "match" => match,
        "literal_in_cited_source" => !match.nil?
      }
    end

    def ceiling_document
      {
        "written_before_call" => true,
        "model_id" => MODEL_ID,
        "thinking" => THINKING,
        "max_tokens" => MAX_TOKENS,
        "budget_usd" => self.class.money(BUDGET),
        "prompt_sha256" => Digest::SHA256.hexdigest(active_system),
        "historical_prompt_sha256" => CompanionDirectCaptureReplay::PROMPT_SHA,
        "historical_citation_prompt_sha256" => CITATION_PROMPT_SHA,
        "retrieval" => "simulated_frozen_corpus",
        "generation" => "anthropic_messages",
        "product_base" => "not_called",
        "product_reason" => "Haiku 4.5 con pensamiento extendido no admite temperatura ni tool_choice forzado. El plan y el intérprete de 72ee437 usan los dos.",
        "history" => "own_published_answers_markers_stripped",
        "registry" => "docs/field_companion/REGISTRO_VERSIONES_VERTICAL_20261105.md"
      }
    end

    attr_accessor :runs_root, :expected_prompt_sha

    def expected_prompt_sha
      @expected_prompt_sha || CompanionDirectCaptureReplay::PROMPT_SHA
    end

    def active_system
      @system_text || CompanionDirectAnswer::SYSTEM_PROMPT
    end

    def retries_allowed
      limit = @attempt_limit || (RETRIES + 1)
      [ limit.to_i - 1, 0 ].max
    end

    def historical_system
      File.read(CompanionDirectCaptureReplay::CAPTURED_PROMPT_PATH)
    end

    def band_system
      expected_prompt_sha == CompanionDirectCaptureReplay::PROMPT_SHA ? historical_system : CompanionDirectAnswer::SYSTEM_PROMPT
    end

    def product_prompt_sha
      Digest::SHA256.hexdigest(historical_system)
    end

    def variant_prompt_sha
      Digest::SHA256.hexdigest(File.read(VARIANT_PROMPT_PATH))
    end

    def paraphrase_prompt_sha
      Digest::SHA256.hexdigest(File.read(PARAPHRASE_PROMPT_PATH))
    end

    def adjustment_arms
      variant = File.read(VARIANT_PROMPT_PATH)
      product = historical_system
      [
        { "arm" => "A", "pass" => 1, "dir" => "A", "system" => product, "pairs" => HIGH_PAIRS },
        { "arm" => "B", "pass" => 1, "dir" => "B1", "system" => variant, "pairs" => HIGH_PAIRS },
        { "arm" => "B", "pass" => 2, "dir" => "B2", "system" => variant, "pairs" => HIGH_PAIRS }
      ]
    end

    def adjustment_ceiling_document
      turns = []
      adjustment_arms.each do |arm|
        @system_text = arm["system"]
        band_ceiling_rows.each do |turn|
          turns << turn.merge("arm" => arm["arm"], "pass" => arm["pass"], "dir" => arm["dir"])
        end
      end
      @system_text = nil
      planned = turns.sum(BigDecimal("0")) { |turn| BigDecimal(turn["reservation_usd"]) }
      attempts = (1..3).select { |count| planned * count <= @budget }.max || 1
      ceiling = planned * attempts
      {
        "written_before_call" => true,
        "model_id" => MODEL_ID,
        "thinking" => THINKING,
        "effort" => "high",
        "medium_generations" => 0,
        "passes" => adjustment_arms.map { |arm| [ arm["arm"], arm["pass"] ] },
        "generations" => turns.size,
        "attempts_per_generation" => attempts,
        "retry_margin_reduced" => attempts < 3,
        "max_tokens" => MAX_TOKENS,
        "authorized_budget_usd" => self.class.money(@budget),
        "spent_at_open_usd" => "0.000000",
        "calls_at_open" => 0,
        "planned_ceiling_usd" => self.class.money(planned),
        "ceiling_usd" => self.class.money(ceiling),
        "decision" => ceiling <= @budget && turns.size == 24 ? "execute" : "ceiling_above_authorization",
        "product_prompt_sha256" => product_prompt_sha,
        "variant_prompt_sha256" => variant_prompt_sha,
        "historical_prompt_sha256" => CompanionDirectCaptureReplay::PROMPT_SHA,
        "bedrock_ledger" => "not_used",
        "ledger" => Pathname(@output).join("attempts.jsonl").to_s,
        "turns" => turns
      }
    end
    public :adjustment_ceiling_document

    def runs_root
      Pathname(@runs_root || ROOT)
    end
    public :runs_root=, :expected_prompt_sha=

    def run_script(name, effort, api_key, repeat: false)
      @effort = effort
      @output = runs_root.join("#{name}-#{effort}#{'-repeat' if repeat}")
      FileUtils.mkdir_p(@output)
      script = load_script(name)
      prior = []
      turns = []
      stopped = false
      script.each do |turn|
        built = assemble(name, turn["number"], prior)
        outcome = generate_turn(turn["number"], built, api_key)
        turns << outcome
        if script_stops?(outcome)
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
        "system" => [ { "text" => active_system } ],
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
      input_tokens = active_system.length + built["messages"].sum { |message| message["text"].length }
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
      system_text = request.dig("body", "system", 0, "text").to_s
      return nil unless Digest::SHA256.hexdigest(system_text) == Digest::SHA256.hexdigest(active_system)

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
      questions = load_script(name).pluck("question")
      reasons << "incomplete" unless turns.size == (name == "guion2" ? 3 : 5) && turns.all? { |turn| turn["status"] == "returned" }
      turns.each do |turn|
        reasons << "t#{turn['turn']}:truncated" if turn["truncated"]
        reasons << "t#{turn['turn']}:gate" if turn["accepted"] == false
        text = turn["publishable"].to_s
        texts = questions.first(turn["turn"].to_i)
        reasons.concat(name == "guion2" ? judge_guion2(turn["turn"], text) : judge_guion1(turn["turn"], text, technician_texts: texts))
      end
      { "pass" => reasons.empty?, "reasons" => reasons }
    end

    def judge_guion2(number, text)
      case number
      when 1
        reasons = []
        reasons << "t1:missing_slow_opening" unless text.include?(SLOW)
        reasons << "t1:autoajuste_if_still_slow" if still_slow_autoajuste?(text)
        reasons << "t1:procedure_drops_condition" if text.match?(/correa dentada/i) && !text.match?(/fuera de servicio/i)
        reasons << "t1:procedure_drops_condition" if text.match?(/fusibles/i) && !text.match?(/no funciona/i)
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
        reasons << "t3:reopens_denied_scope" if text.include?("?") && text.match?(/par[aá]metros/i) && text.match?(/f[aá]brica|defecto/i)
        reasons << "t3:factory_state_requires_repeat" if factory_state_requires_repeat?(text)
        reasons << "t3:unnecessary_question" if text.include?("?")
        reasons << "t3:missing_solo" unless text.match?(/\bsolo\b/i)
        reasons << "t3:missing_section" unless text.include?(SLOW) || text.match?(/solo es necesario/i)
        reasons
      end
    end

    def judge_guion1(number, text, technician_texts: [])
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
        reading = t5_assessment(text, technician_texts: technician_texts)
        reasons = []
        reasons << "t5:reasks_identification" if reading.dig("identification_request", "present")
        reasons << "t5:misses_unknown" unless reading.dig("technician_limitation", "recognized")
        reasons << "t5:repeats_led" if reading.dig("led", "status") == "repeated"
        reasons << "t5:misreads_priority_inputs" if misreads_priority_inputs?(text)
        reasons << "t5:drops_normally_open" if drops_normally_open?(text)
        reasons
      else
        []
      end
    end

    def factory_state_requires_repeat?(text)
      text.match?(/s[ií] es as[ií][\s\S]{0,60}repet/i) ||
        text.match?(/s[ií] (?:el equipo )?(?:tiene|est[aá]) (?:los |sus )?(?:par[aá]metros|valores)[\s\S]{0,40}(?:f[aá]brica|defecto)[\s\S]{0,80}(?:repetir|autoajuste)/i) ||
        text.match?(/tener (?:los )?(?:par[aá]metros|valores)[\s\S]{0,30}(?:f[aá]brica|defecto)[\s\S]{0,60}(?:obliga|exige|hay que|habr[ií]a que)/i)
    end

    # Four readings, kept apart. A method limit does not acknowledge the
    # technician's limit. A commission counts without a question mark.
    # led is nil when the answer does not ask which LED is lit.
    def t5_assessment(text, technician_texts: [])
      {
        "technician_limitation" => technician_limitation(text),
        "method_limit" => method_limit(text),
        "identification_request" => identification_request(text),
        "led" => led_datum(text, technician_texts)
      }
    end

    def technician_limitation(text)
      phrase = first_sentence(text, TECHNICIAN_LIMIT_PATTERN)
      { "recognized" => !phrase.nil?, "phrase" => phrase }
    end

    def method_limit(text)
      phrase = first_sentence(text, METHOD_LIMIT_PATTERN)
      { "present" => !phrase.nil?, "phrase" => phrase }
    end

    def identification_request(text)
      sentence = identification_sentences(text).find { |item| identification_pattern?(item) }
      {
        "present" => !sentence.nil?,
        "phrase" => sentence,
        "kind" => identification_kind(sentence)
      }
    end

    def repeats_led?(text, technician_texts)
      return false unless asks_led?(text)

      Array(technician_texts).any? { |item|
        item.to_s.match?(/led\b[\s\S]{0,50}(?:de fotoc[eé]lula|de estado)/i) ||
          item.to_s.match?(/es el (?:led )?de (?:fotoc[eé]lula|estado)/i)
      }
    end

    def asks_led?(text)
      led_phrase(text).present?
    end

    def led_phrase(text)
      body = text.to_s
      folded = body.downcase
      return nil unless folded.match?(/fotoc[eé]lula|obstrucci[oó]n|\bestado\b|\bstatus\b/)

      body[/¿[^?\n]*\bled\b[^?\n]*\?/i] ||
        body[/\bled\b[^?\n]*\?/i] ||
        body[/\b(?:necesito saber|pregunta)\b[^\n]{0,180}\bled\b[^\n.]*/i]
    end

    # pending: the history has not named the lit LED, so the question can
    # still change the path. repeated: the technician already named it.
    def led_datum(text, technician_texts)
      phrase = led_phrase(text)
      return nil unless phrase

      status = repeats_led?(text, technician_texts) ? "repeated" : "pending"
      { "status" => status, "useful" => status == "pending", "phrase" => phrase.strip }
    end

    def identification_sentences(text)
      sentences_of(text).filter_map do |sentence|
        next if sentence.match?(/retiro mi sugerencia/i)

        sentence.gsub(CompanionTurnPublication::QUOTE_PATTERN, " ").squish.presence
      end
    end

    def identification_pattern?(text)
      return true if text.match?(/¿[^?\n]*#21[^?\n]*\?/i) || text.match?(/¿[^?\n]*#23[^?\n]*\?/i)
      return true if text.match?(/qu[eé] (?:hay|ves) conectad/i)
      return true if text.include?("?") && text.match?(/conectad/i) && text.match?(/\b21\b|\b23\b|#21|#23/)
      return true if text.match?(/\b(?:dime|decime|indicame|necesito que|identifica|señala)\b[\s\S]{0,80}#21/i)

      text.match?(/\b(?:localizar|localiza|aislar|aísla)\b/i) && text.match?(/cable|cableado|borne/i)
    end

    def identification_kind(sentence)
      return nil if sentence.nil?
      return "commission" if sentence.match?(/\b(?:localizar|localiza|aislar|aísla)\b/i)
      return "question" if sentence.include?("?")

      "request"
    end

    def sentences_of(text)
      text.to_s.split(/\n+|(?<=[.!?])[[:space:]]+/).map(&:strip).reject(&:empty?)
    end

    def first_sentence(text, pattern)
      sentences_of(text).find { |sentence| sentence.match?(pattern) }
    end

    def misreads_priority_inputs?(text)
      text.match?(/borne de INPUTS[\s\S]{0,80}(?:#21|#23|\b21\b|\b23\b)/i) ||
        text.match?(/21 y 23 est[aá]n en (?:la fila de )?INPUTS/i) ||
        (text.match?(/dibujo no lo indica/i) && text.match?(/#21|#23|\b21\b|\b23\b/))
    end

    def drops_normally_open?(text)
      return false if text.match?(/normalmente abierto/i)

      prose = text.to_s.gsub(CompanionTurnPublication::QUOTE_PATTERN, " ")
      prose.match?(/contactos? libres? de tensi[oó]n|debe recibir un contacto/i)
    end

    def still_slow_autoajuste?(text)
      text.match?(/si la apertura lenta persiste[\s\S]{0,240}autoajuste/i) ||
        text.match?(/si (?:permanece|sigue) lenta[\s\S]{0,240}autoajuste/i) ||
        text.match?(/lentitud persist[\s\S]{0,180}autoajuste/i) ||
        text.match?(/si sigue abriendo[\s\S]{0,180}autoajuste/i)
    end
  end
end
