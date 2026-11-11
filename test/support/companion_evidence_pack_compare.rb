# frozen_string_literal: true

require Rails.root.join("test/support/companion_vertical_ladder")

module Rag
  # One A/B of evidence packaging. Arm A is the archived request. Arm B adds
  # only verified hierarchy lines. It does not change the product prompt.
  class CompanionEvidencePackCompare
    PREFIX = "CONTEXTO"
    ANNOTATION = /\A\[CONTEXTO (\d+) \| (.*) \| (.*) \| (\d+(?:\.\d+)?)\]\z/
    EVIDENCE_MARK = "Fuentes de este turno:\n"
    RUBRIC_VERSION = "fable-2026-11-06"
    SYSTEM_SHA = "b1b55d3e95ba9f09ea342bcd27e724b32e95649f143d89ec5f97e523c8a8a0e2"
    ARCHIVE = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/guion_scope_b1b55d3e")
    OUTPUT = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261106/evidence_pack_b1b55d3e")
    VERTICAL_ROOT = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55")
    AUTHORIZED_ANTHROPIC = BigDecimal("1.00")
    # docs/ARCH_REVIEW_CONVERSATIONAL_VS_HAIKU_2026-09-25.md: USD 2 per 1,000 queries.
    RERANK_USD = BigDecimal("2") / 1_000
    DOCUMENT_UID = "126cda62-64ad-4469-8674-a29f12e38d48"
    INDEXED_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
    KNOWLEDGE_BASE_ID = "Y7RZWMFJSR"
    YS_QUESTION = "El YS-K01 muestra E001 justo al encender. ¿El manual lo considera normal?"
    # Common transcription of Table 5-1, PDF page 46. Typos are the page's.
    YS_LU_REASONS = "At the begining of power on and at the end of power off; Input voltage is too low; Improper wiring leads to undervoltage of hardware"
    YS_LU_MEASURES = "It is normal state of power on and power off; Please check input power voltage; Please check wiring and wire properly"
    YS_E001_REASONS = "Input voltage is too high; Deceleartion time is too short; Improper wiring leads to overvoltage of hardware"
    YS_E001_MEASURES = "Please check power input; Please set a proper value for Dec time; Please check wiring and wire properly"
    CASES = [
      { "id" => "g1-t2", "script" => "guion1", "turn" => 2 },
      { "id" => "g2-t1", "script" => "guion2", "turn" => 1 },
      { "id" => "g1-t4", "script" => "guion1", "turn" => 4 },
      { "id" => "g1-t5", "script" => "guion1", "turn" => 5 },
      { "id" => "ys-k01", "script" => nil, "turn" => nil }
    ].freeze
    HARNESS = [
      { "script" => "guion2", "turns" => 3 },
      { "script" => "guion1", "turns" => 5 }
    ].freeze

    class << self
      def build_pair(request)
        original = deep(request)
        annotated = deep(request)
        text = message_text(original)
        packed, provenance = pack_message(text)
        write_message(annotated, packed)
        {
          "a" => original,
          "b" => annotated,
          "system_sha256" => Digest::SHA256.hexdigest(system_text(original)),
          "provenance" => provenance
        }
      end

      def pack_sources(text)
        pack_message(text).first
      end

      def strip_annotations(text)
        text.to_s.each_line.reject { |line| annotation?(line) }.join
      end

      def annotation?(line)
        line.to_s.sub(/\r?\n\z/, "").match?(ANNOTATION)
      end

      def outside_evidence(request)
        copy = deep(request)
        text = message_text(copy)
        prefix, = split_evidence(text)
        write_message(copy, prefix.to_s)
        copy
      end

      def ysk01_request(template)
        request = deep(template)
        body = request.fetch("body")
        body["messages"] = [
          { "role" => "user", "content" => [ { "type" => "text", "text" => ysk01_message } ] }
        ]
        request
      end

      def ysk01_message
        [
          "Mensaje de este turno:",
          YS_QUESTION,
          "",
          "Fuentes de este turno:",
          "[1] E-Shine YS-K01 door operator, página 46",
          "Table 5-1 Fault alarm description and counter-measures",
          "| Fault code | Fault name | Possible reasons of fault | Counter-measures |",
          "| -Lu- | DC bus undervoltage | #{YS_LU_REASONS} | #{YS_LU_MEASURES} |",
          "| E001 | DC bus overvoltage | #{YS_E001_REASONS} | #{YS_E001_MEASURES} |"
        ].join("\n")
      end

      def load_request(script, turn)
        JSON.parse(ARCHIVE.join("#{script}-high/turn-#{turn}/request.json").read)
      end

      def case_request(spec, template: nil)
        return ysk01_request(template || load_request("guion2", 1)) if spec["id"] == "ys-k01"

        load_request(spec.fetch("script"), spec.fetch("turn"))
      end

      private

      def pack_message(text)
        prefix, evidence = split_evidence(text)
        return [ text.to_s, [] ] if evidence.nil?

        packed, provenance = pack_region(evidence)
        [ "#{prefix}#{EVIDENCE_MARK}#{packed}", provenance ]
      end

      def split_evidence(text)
        source = text.to_s
        index = source.rindex(EVIDENCE_MARK)
        return [ source, nil ] if index.nil?

        [ source[0...index], source[(index + EVIDENCE_MARK.length)..] ]
      end

      def pack_region(region)
        lines = region.lines
        packed = +""
        provenance = []
        index = 0
        while index < lines.length
          heading = lines[index]
          match = heading.match(/\A\[(\d+)\] /)
          unless match
            packed << heading
            index += 1
            next
          end
          number = match[1]
          page = heading[/página\s+(\d+(?:\.\d+)?)/, 1]
          index += 1
          body = +""
          while index < lines.length && !lines[index].match?(/\A\[\d+\] /)
            body << lines[index]
            index += 1
          end
          annotated, notes = annotate_body(body, number, page, heading)
          packed << heading << annotated
          provenance.concat(notes)
        end
        [ packed, provenance ]
      end

      # The parser locates each passage. A numbered entry replaces its section
      # inside the parser, so the parent is taken from the lines already seen.
      def annotate_body(body, number, page, heading)
        statements = CompanionStatements.parse([
          { content: body, metadata: { "page_number" => page } }
        ]).statements
        cursor = 0
        inserts = {}
        statements.each do |statement|
          next if statement.kind == "heading" || statement.kind == "item"

          found = body.index(statement.text, cursor)
          next if found.nil?

          cursor = found + statement.text.length
          line_start = body.rindex("\n", found - 1)
          line_start = line_start.nil? ? 0 : line_start + 1
          next if inserts.key?(line_start)

          before = "#{heading}#{body[0...line_start]}"
          context = context_line(number, hierarchy(before))
          next if context.nil?

          inserts[line_start] = context
        end
        notes = []
        built = +""
        point = 0
        inserts.keys.sort.each do |at|
          built << body[point...at] << inserts[at] << "\n"
          point = at
          notes << provenance_note(number, inserts[at], body[at, 180])
        end
        built << body[point..]
        [ built, notes ]
      end

      def hierarchy(text)
        section = nil
        entry = nil
        item = nil
        page = nil
        text.each_line do |raw|
          line = raw.strip
          if (mark = line.match(CompanionStatements::PAGE_MARK))
            page = mark[1]
          elsif (heading = line.match(/\A\[\d+\] .*página\s+(\d+(?:\.\d+)?)/))
            page = heading[1]
          elsif line.empty? || line.match?(CompanionStatements::HEADER_LINE) || line.match?(CompanionStatements::TABLE_RULE)
            next
          elsif line.match?(CompanionStatements::SECTION_LINE)
            section = line
            entry = nil
            item = nil
          elsif line.match?(CompanionStatements::ENTRY_LINE)
            entry = line
            item = nil
          elsif (bullet = line.match(CompanionStatements::ITEM_LINE))
            item = bullet[:text]
          end
        end
        { "section" => section, "entry" => entry, "item" => item, "page" => page, "text" => text }
      end

      def context_line(number, state)
        section = state["section"]
        entry = state["entry"]
        item = state["item"]
        page = state["page"]
        text = state["text"]
        return nil if page.blank? || !page_visible?(text, page)
        return nil if [ section, entry, item ].compact.any? { |value| value.include?("|") }

        apartado = if entry
          return nil if section.blank? || item.present?
          return nil unless line_visible?(text, section) && line_visible?(text, entry)

          entry
        elsif item
          return nil if section.blank?
          return nil unless line_visible?(text, section) && item_visible?(text, item)

          item
        elsif section
          return nil unless line_visible?(text, section)

          ""
        else
          return nil
        end
        "[CONTEXTO #{number} | #{section} | #{apartado} | #{page}]"
      end

      def page_visible?(text, page)
        text.match?(/\[PDF_PAGE:\s*#{Regexp.escape(page)}\]/) ||
          text.match?(/página\s+#{Regexp.escape(page)}(?!\d)/)
      end

      def line_visible?(text, value)
        text.each_line.any? { |raw| raw.strip == value }
      end

      def item_visible?(text, item)
        text.each_line.any? do |raw|
          bullet = raw.strip.match(CompanionStatements::ITEM_LINE)
          bullet && bullet[:text] == item
        end
      end

      def provenance_note(number, line, following)
        match = line.match(ANNOTATION)
        {
          "source" => number.to_i,
          "line" => line,
          "section" => match[2],
          "apartado" => match[3],
          "page" => match[4],
          "following" => following.to_s.each_line.first.to_s.strip
        }
      end

      def message_text(request)
        request.dig("body", "messages", -1, "content", 0, "text").to_s
      end

      def write_message(request, text)
        request.fetch("body").fetch("messages").last.fetch("content")[0]["text"] = text
      end

      def system_text(request)
        request.dig("body", "system", 0, "text").to_s
      end

      def deep(value)
        JSON.parse(JSON.generate(value))
      end
    end

    # Frozen before any model call. Evaluator examples live in the test.
    class Rubric
      PERSISTENCE = /persist|si el problema (?:continúa|continua|sigue)|si sigue/i
      REOPEN = /re-?abre|re-?apertura/i
      SLOW = /primera/i
      SLOW_MOTION = /lent/i
      POWER = /alimentaci[oó]n|corte/i
      CONFIGURE = /configuraci[oó]n de los par[aá]metros por defecto|configurar los par[aá]metros por defecto/i
      CONFLICT = /contradic|discrep|conflicto|no coincide|C2/i

      def self.evaluate(case_id, text)
        criteria = send(case_id.tr("-", "_"), text.to_s)
        {
          "rubric" => RUBRIC_VERSION,
          "case" => case_id,
          "pass" => criteria.values.all? { |row| row["pass"] },
          "criteria" => criteria
        }
      end

      def self.g1_t2(text)
        tests = sentences(text).select { |sentence| sentence.match?(/\bTEST\b/) }
        governed = tests.all? { |sentence| persistence_near?(text, sentence) }
        {
          "reopen_context" => flag(text.match?(REOPEN) && tests.any? && governed),
          "persistence" => flag(tests.any? && governed),
          "not_obstruction_led_alone" => flag(!obstruction_only?(text))
        }
      end

      def self.g2_t1(text)
        {
          "first_slow_opening" => flag(text.match?(SLOW) && text.match?(SLOW_MOTION) && text.match?(POWER)),
          "default_parameters_intact" => flag(text.match?(CONFIGURE)),
          "thirty_five_not_applied" => flag(!applies_thirty_five?(text))
        }
      end

      def self.g1_t4(text)
        {
          "c2_visible" => flag(text.match?(CONFLICT) && text.match?(/#8|\b8\b/) && text.match?(/#12|\b12\b/) && text.match?(/OPEN|abrir/i) && text.match?(/CLOSE|cerrar/i)),
          "omits_dependent_instruction" => flag(!prescribes_disputed?(text)),
          "independent_orientation" => flag(text.match?(/#54|potenci[oó]metro|obstrucci[oó]n mec[aá]nica|\b21\b/i))
        }
      end

      def self.g1_t5(text)
        contact = text.match?(/libres de tensi[oó]n|conectar[^\n]{0,40}23|contacto/i)
        {
          "normally_open" => flag(contact && text.match?(/normalmente abierto/i)),
          "not_recommissioned" => flag(!recommission?(text))
        }
      end

      def self.ys_k01(text)
        {
          "e001_overvoltage" => flag(text.match?(/E001/i) && text.match?(/sobretensi[oó]n|overvoltage/i)),
          "lu_normality_separate" => flag(!affirms_e001_normal?(text) && !imports_lu?(text)),
          "cause_not_already_found" => flag(!text.match?(/ya se comprob|la causa (?:es|fue)|queda confirmad/i))
        }
      end

      def self.sentences(text)
        text.to_s.split(/\n+|(?<=[.!?])[[:space:]]+/).map(&:strip).reject(&:empty?)
      end

      def self.persistence_near?(text, sentence)
        at = text.index(sentence)
        return false if at.nil?

        text[[ at - 220, 0 ].max..at + sentence.length].to_s.match?(PERSISTENCE)
      end

      def self.obstruction_only?(text)
        text.to_s.split(/(?=\*\*Si es )/i).any? do |part|
          part.match?(/OBSTRUCCI[ÓO]N/i) && part.match?(/\bTEST\b/) && !part.match?(PERSISTENCE)
        end
      end

      def self.applies_thirty_five?(text)
        sentences(text).any? do |sentence|
          sentence.match?(/35\s*cm/i) && !sentence.match?(/\bsi\b/i) && sentence.match?(/autoajuste|este caso|esta puerta|hay que|debes/i)
        end
      end

      def self.prescribes_disputed?(text)
        sentences(text).any? do |sentence|
          imperative = sentence.match?(/\b(?:comprueba|verifica|revisa|mide|conecta|desconecta)\b/i)
          definite = sentence.match?(/entrada OPEN[^\n]{0,40}#8|#8[^\n]{0,30}OPEN|se[nñ]al de cerrado[^\n]{0,40}#12|#12[^\n]{0,30}cerrad/i)
          hedge = sentence.match?(CONFLICT)
          imperative && definite && !hedge
        end
      end

      def self.recommission?(text)
        sentences(text).any? do |sentence|
          sentence.match?(/identific(?:ar|a) si est[aá] activad/i) ||
            sentence.match?(/contacto cerrado/i) && sentence.match?(/\?|comprueba|dime|revisa/i) ||
            sentence.match?(/entrada (?:#)?21[^\n]{0,40}activad/i) && sentence.match?(/\?|comprueba|dime/i)
        end
      end

      def self.affirms_e001_normal?(text)
        sentences(text).any? do |sentence|
          sentence.match?(/E001/i) && sentence.match?(/normal/i) && !sentence.match?(/\bno\b[^\n]{0,50}normal/i)
        end
      end

      def self.imports_lu?(text)
        sentences(text).any? do |sentence|
          sentence.match?(/E001/i) && sentence.match?(/-Lu-/i) && sentence.match?(/normal/i) && !sentence.match?(/\bno\b/i)
        end
      end

      def self.flag(value)
        { "pass" => value == true }
      end
    end

    class Runner < CompanionVerticalLadder
      class << self
        def prepare(output: OUTPUT, io: $stdout)
          new(output_root: output, io: io, budget: AUTHORIZED_ANTHROPIC).prepare_assignment
        end

        def execute(output: OUTPUT, io: $stdout, transport: nil, credential: nil)
          new(output_root: output, io: io, transport: transport, credential: credential, budget: AUTHORIZED_ANTHROPIC).execute_assignment
        end
      end

      def prepare_assignment
        FileUtils.mkdir_p(offline_dir)
        report = isolation_report
        ceiling = ceiling_document(report)
        write_json(offline_dir.join("isolation.json"), report)
        write_json(Pathname(@output).join("ceiling.json"), ceiling)
        @io.puts JSON.generate(ceiling.except("turns", "bedrock"))
        report["pass"] ? 0 : 2
      end

      def execute_assignment
        code = prepare_assignment
        return code unless code.zero?

        ceiling = JSON.parse(Pathname(@output).join("ceiling.json").read)
        unless ceiling["isolated_fits"]
          return refuse("ceiling", ceiling)
        end
        key = @credential.nil? ? ENV["ANTHROPIC_API_KEY"].to_s : @credential.to_s
        if key.empty?
          return refuse("credential_absent", ceiling)
        end

        boot(ceiling["anthropic_balance_usd"])
        isolated = run_isolated(key)
        verdict = fable_verdict(isolated)
        write_json(Pathname(@output).join("ab_verdict.json"), verdict)
        return stop_after("isolated", isolated, verdict) if halt_reason(isolated)

        harness = nil
        if !verdict["advance"]
          harness = { "status" => "not_run", "reason" => "fable", "ceiling_fits" => ceiling["harness_fits"], "calls" => [] }
        elsif !ceiling["harness_fits"]
          harness = harness_budget_block(ceiling)
        else
          harness = run_harness(key)
          return stop_after("harness", isolated, verdict, harness) if halt_reason(harness["calls"])
        end
        bedrock = bedrock_phase(verdict, harness, ceiling)
        diagnosis = diagnosis_document(ceiling, isolated, verdict, harness, bedrock)
        write_json(Pathname(@output).join("diagnosis.json"), diagnosis)
        write_json(Pathname(@output).join("summary.json"), diagnosis.except("failures"))
        @io.puts JSON.generate(diagnosis.except("failures"))
        0
      end

      def exercise_maximum_plan(output: nil)
        @output = Pathname(output || Dir.mktmpdir)
        FileUtils.mkdir_p(@output)
        boot("100")
        key = "local"
        isolated = run_isolated(key)
        harness = run_harness(key)
        { "isolated" => isolated.length, "harness" => harness["calls"].length }
      end

      def isolation_report
        rows = CASES.map { |spec| isolation_case(spec) }
        { "pass" => rows.all? { |row| row["errors"].empty? }, "cases" => rows, "code" => code_identity }
      end

      def ceiling_document(report = isolation_report)
        balance = anthropic_balance
        rows = []
        CASES.each do |spec|
          pair = build_loaded(spec)
          [ "a", "b" ].each do |arm|
            2.times do |sample|
              chars = input_chars(pair[arm])
              rows << reservation_row("isolated", spec["id"], arm, sample + 1, chars)
            end
          end
        end
        harness_rows = harness_ceiling_rows
        isolated = rows.sum(BigDecimal("0")) { |row| BigDecimal(row["reservation_usd"]) }
        harness = harness_rows.sum(BigDecimal("0")) { |row| BigDecimal(row["reservation_usd"]) }
        bedrock = bedrock_ceiling
        {
          "written_before_call" => true,
          "model_call" => "not_executed",
          "attempts_per_generation" => 1,
          "retries_allowed" => 0,
          "correct" => "disabled",
          "max_tokens" => MAX_TOKENS,
          "model_id" => MODEL_ID,
          "effort" => "high",
          "thinking" => THINKING,
          "geo_multiplier" => GEO.to_s("F"),
          "geo_note" => "Multiplicador US 1,1 del arnés. Es el techo conservador; global sería 1,0.",
          "system_sha256" => SYSTEM_SHA,
          "authorized_anthropic_usd" => self.class.money(AUTHORIZED_ANTHROPIC),
          "anthropic_spent_usd" => self.class.money(balance["spent"]),
          "anthropic_balance_usd" => self.class.money(balance["balance"]),
          "anthropic_ledgers" => balance["ledgers"],
          "excluded_duplicate_ledgers" => balance["duplicates"],
          "excluded_other_pool" => balance["other_pool"],
          "isolated_generations" => rows.size,
          "harness_generations" => harness_rows.size,
          "maximum_generations" => rows.size + harness_rows.size,
          "isolated_ceiling_usd" => self.class.money(isolated),
          "harness_ceiling_usd" => self.class.money(harness),
          "anthropic_full_ceiling_usd" => self.class.money(isolated + harness),
          "bedrock" => bedrock,
          "combined_ceiling_usd" => self.class.money(isolated + harness + BigDecimal(bedrock["ceiling_usd"])),
          "isolated_fits" => rows.size == 20 && isolated <= balance["balance"],
          "harness_fits" => isolated + harness <= balance["balance"],
          "full_plan_fits" => isolated + harness <= balance["balance"] && bedrock["fits"],
          "isolation_pass" => report["pass"],
          "turns" => rows + harness_rows
        }
      end

      def anthropic_balance
        seen = {}
        spent = BigDecimal("0")
        ledgers = []
        duplicates = []
        other = []
        VERTICAL_ROOT.glob("**/attempts.jsonl").each do |path|
          digest = Digest::SHA256.file(path).hexdigest
          if seen[digest]
            duplicates << path.to_s
            next
          end
          seen[digest] = path.to_s
          amount = ledger_spent(path)
          if path.to_s.include?("vf5_direct_prompt_compare")
            other << { "path" => path.to_s, "spent_usd" => self.class.money(amount), "pool" => "anthropic_0_30" }
            next
          end
          spent += amount
          ledgers << { "path" => path.to_s, "spent_usd" => self.class.money(amount) }
        end
        extra = Pathname("/Users/lahirisan/smart_deal/tmp/field_companion/vf5_vertical_haiku55/attempts.jsonl")
        if extra.file?
          digest = Digest::SHA256.file(extra).hexdigest
          if seen[digest]
            duplicates << extra.to_s
          else
            seen[digest] = extra.to_s
            amount = ledger_spent(extra)
            spent += amount
            ledgers << { "path" => extra.to_s, "spent_usd" => self.class.money(amount) }
          end
        end
        direct = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_direct_prompt_compare_haiku55/attempts.jsonl")
        if direct.file?
          digest = Digest::SHA256.file(direct).hexdigest
          unless seen[digest]
            amount = ledger_spent(direct)
            other << { "path" => direct.to_s, "spent_usd" => self.class.money(amount), "pool" => "anthropic_0_30" }
          end
        end
        {
          "spent" => spent,
          "balance" => AUTHORIZED_ANTHROPIC - spent,
          "ledgers" => ledgers,
          "duplicates" => duplicates,
          "other_pool" => other
        }
      end

      def install_pack_hook!
        return if defined?(@pack_hook) && @pack_hook

        hook = Module.new do
          def sources_block(chunks)
            block = super
            return block unless ENV["COMPANION_EVIDENCE_PACK"] == "contexto"

            Rag::CompanionEvidencePackCompare.pack_sources(block)
          end
        end
        CompanionDirectAnswer.singleton_class.prepend(hook)
        @pack_hook = true
      end

      private

      def boot(balance)
        @budget = BigDecimal(balance.to_s)
        @ledger = Ledger.new(Pathname(@output).join("attempts.jsonl"))
        @transport ||= Transport.new
        @version = ANTHROPIC_VERSION
        @max_tokens = MAX_TOKENS
        @effort = "high"
        @sleeper ||= ->(seconds) { sleep(seconds) }
      end

      def retries_allowed
        0
      end

      def correct(_body, _message)
        nil
      end

      def run_isolated(api_key)
        calls = []
        CASES.each do |spec|
          pair = build_loaded(spec)
          [ %w[a b], %w[b a] ].each_with_index do |order, sample|
            order.each do |arm|
              calls << one_call(
                api_key,
                spec: spec,
                arm: arm,
                sample: sample + 1,
                phase: "ab",
                request: pair[arm],
                evidence: evidence_text(pair["a"]),
                annotated: evidence_text(pair["b"]),
                provenance: pair["provenance"]
              )
              return calls if halt_reason(calls)
            end
          end
        end
        calls
      end

      def run_harness(api_key)
        calls = []
        fed = []
        HARNESS.each do |script|
          prior = []
          script["turns"].times do |offset|
            number = offset + 1
            spec = { "id" => "#{script['script']}-t#{number}", "script" => script["script"], "turn" => number }
            archived = packer.load_request(script["script"], number)
            chained = chain_request(archived, prior)
            pair = packer.build_pair(chained)
            call = one_call(
              api_key,
              spec: spec,
              arm: "b",
              sample: 1,
              phase: "harness/#{script['script']}",
              request: pair["b"],
              evidence: evidence_text(pair["a"]),
              annotated: evidence_text(pair["b"]),
              provenance: pair["provenance"],
              fed: prior.dup
            )
            calls << call
            break if halt_reason(calls)

            prior << call["published"]
            fed << { "script" => script["script"], "turn" => number, "into_next" => strip_markers(call["published"].to_s) }
          end
        end
        { "calls" => calls, "fed_forward" => fed, "scripts" => harness_scripts(calls) }
      end

      def one_call(api_key, spec:, arm:, sample:, phase:, request:, evidence:, annotated:, provenance:, fed: nil)
        directory = Pathname(@output).join(phase, spec["id"], "sample-#{sample}", arm)
        FileUtils.mkdir_p(directory)
        body = request.fetch("body")
        refuse_shape(body)
        write_json(directory.join("request.json"), scrub(request))
        File.write(directory.join("evidence_original.txt"), evidence)
        File.write(directory.join("evidence_annotated.txt"), annotated)
        write_request_diff(directory, evidence, annotated)
        File.write(directory.join("message.txt"), current_question(body))
        write_json(directory.join("history.json"), history_messages(body))
        write_json(directory.join("provenance.json"), provenance)
        write_json(directory.join("fed_forward.json"), fed || [])
        input = input_chars(request)
        outcome = call_with_retries(spec["turn"] || 1, body, input, api_key, directory)
        write_json(directory.join("attempts.json"), outcome["attempts"])
        record = {
          "phase" => phase, "case" => spec["id"], "arm" => arm, "sample" => sample,
          "directory" => directory.to_s, "status" => outcome["status"],
          "max_tokens" => body["max_tokens"], "attempts" => Array(outcome["attempts"]).size
        }
        payload = outcome["payload"]
        write_json(directory.join("provider_response.json"), scrub(payload)) if payload
        unless outcome["status"] == "returned" && payload.is_a?(Hash)
          return record.merge("stop" => true, "error" => outcome["error_code"])
        end

        composed = visible_response(payload)
        File.write(directory.join("raw.txt"), composed["text"])
        File.write(directory.join("thinking.txt"), thinking_text(payload))
        built = publication_input(body, evidence)
        published = begin
          publish_answer(built, composed["text"], composed["stop_reason"])
        rescue StandardError => error
          File.write(directory.join("publication_error.txt"), "#{error.class}: #{error.message}")
          return record.merge("stop" => true, "error" => "publication", "raw" => composed["text"])
        end
        write_publication(directory, published)
        usage = payload["usage"].is_a?(Hash) ? payload["usage"] : {}
        write_json(directory.join("usage.json"), usage_document(outcome, composed, usage))
        evaluation = evaluate_call(spec, composed["text"], published, built["messages"])
        write_json(directory.join("evaluation.json"), evaluation)
        record.merge(
          "stop_reason" => composed["stop_reason"],
          "truncated" => composed["stop_reason"].to_s == "max_tokens",
          "stop" => composed["stop_reason"].to_s == "max_tokens",
          "raw" => composed["text"],
          "published" => published["publishable"],
          "accepted" => published["accepted"],
          "raw_equals_published" => composed["text"] == published["publishable"],
          "evaluation" => evaluation,
          "usage" => usage
        )
      end

      def write_request_diff(directory, original, annotated)
        inserted = annotated.to_s.lines.reject { |line| original.to_s.lines.include?(line) }
        write_json(directory.join("request_diff.json"), {
          "outside_evidence" => "identical",
          "only_change" => "annotation_lines",
          "inserted_lines" => inserted.map { |line| line.sub(/\n\z/, "") }
        })
      end

      def evaluate_call(spec, raw, published, messages)
        case_id = rubric_case(spec["id"])
        raw_doc = case_id ? Rubric.evaluate(case_id, raw) : nil
        published_doc = case_id ? Rubric.evaluate(case_id, published["publishable"]) : nil
        limitation = case_id == "g1-t5" ? technician_limitation(published["publishable"].to_s) : nil
        {
          "documentary_raw" => raw_doc,
          "documentary_published" => published_doc,
          "technician_limitation" => limitation,
          "historical_judge" => historical_judge(spec, published["publishable"].to_s, messages),
          "publication" => {
            "accepted" => published["accepted"],
            "raw_equals_published" => raw == published["publishable"],
            "markers" => published["visible_markers"]
          }
        }
      end

      def historical_judge(spec, text, messages)
        texts = Array(messages).select { |message| message["role"] == "user" }.pluck("text")
        id = spec["id"]
        reasons = if id.start_with?("g1-") || id.start_with?("guion1")
          number = spec["turn"] || id[/\d+\z/].to_i
          judge_guion1(number, text, technician_texts: texts)
        elsif id.start_with?("g2-") || id.start_with?("guion2")
          number = spec["turn"] || id[/\d+\z/].to_i
          judge_guion2(number, text)
        else
          []
        end
        { "reasons" => reasons, "pass" => reasons.empty? }
      end

      def rubric_case(id)
        {
          "g1-t2" => "g1-t2", "g1-t4" => "g1-t4", "g1-t5" => "g1-t5", "g2-t1" => "g2-t1", "ys-k01" => "ys-k01",
          "guion1-t2" => "g1-t2", "guion1-t4" => "g1-t4", "guion1-t5" => "g1-t5", "guion2-t1" => "g2-t1"
        }[id]
      end

      def fable_verdict(calls)
        groups = calls.group_by { |call| [ call["case"], call["arm"] ] }
        principal = %w[g1-t2 g2-t1 g1-t4]
        rows = CASES.map do |spec|
          arms = %w[a b].to_h do |arm|
            samples = Array(groups[[ spec["id"], arm ]])
            [ arm, samples.map { |sample| sample.dig("evaluation", "documentary_published", "pass") == true } ]
          end
          { "case" => spec["id"], "a" => arms["a"], "b" => arms["b"] }
        end
        b_principal = principal.all? do |id|
          row = rows.find { |item| item["case"] == id }
          row["b"] == [ true, true ]
        end
        differential = principal.any? do |id|
          row = rows.find { |item| item["case"] == id }
          row["a"] == [ false, false ] && row["b"] == [ true, true ]
        end
        regression = %w[g1-t5 ys-k01].any? { |id| regressed?(groups, id) }
        {
          "rows" => rows,
          "b_principal" => b_principal,
          "differential" => differential,
          "regression" => regression,
          "advance" => b_principal && differential && !regression
        }
      end

      def regressed?(groups, case_id)
        %w[a b].all? { |arm| Array(groups[[ case_id, arm ]]).size == 2 } &&
          criterion_keys(groups, case_id).any? do |key|
            a_pass = pass_count(groups, case_id, "a", key)
            b_pass = pass_count(groups, case_id, "b", key)
            b_pass < a_pass
          end
      end

      def criterion_keys(groups, case_id)
        sample = Array(groups[[ case_id, "a" ]]).first
        criteria = sample&.dig("evaluation", "documentary_published", "criteria") || {}
        keys = criteria.keys
        keys << "technician_limitation" if case_id == "g1-t5"
        keys
      end

      def pass_count(groups, case_id, arm, key)
        Array(groups[[ case_id, arm ]]).count do |sample|
          if key == "technician_limitation"
            sample.dig("evaluation", "technician_limitation", "recognized") == true
          else
            sample.dig("evaluation", "documentary_published", "criteria", key, "pass") == true
          end
        end
      end

      def harness_scripts(calls)
        HARNESS.map do |script|
          turns = calls.select { |call| call["case"].start_with?("#{script['script']}-t") }
          fidelity = turns.all? do |call|
            documentary = call.dig("evaluation", "documentary_published")
            documentary.nil? || documentary["pass"] == true
          end
          continuity = continuity_pass?(script["script"], turns)
          limitation = script["script"] != "guion1" || turns.any? { |call|
            call["case"] == "guion1-t5" && call.dig("evaluation", "technician_limitation", "recognized") == true
          }
          {
            "script" => script["script"],
            "fidelity" => fidelity,
            "continuity" => continuity,
            "technician_limitation" => limitation,
            "pass" => fidelity && continuity && limitation
          }
        end
      end

      def continuity_pass?(script, turns)
        ordered = turns.sort_by { |call| call["case"][/\d+\z/].to_i }
        ordered.each_cons(2).all? do |previous, nxt|
          expected = strip_markers(previous["published"].to_s)
          history = JSON.parse(File.read(File.join(nxt["directory"], "history.json")))
          assistants = history.select { |message| message["role"] == "assistant" }.map { |message| message["text"] }
          assistants.include?(expected)
        end && (script != "guion1" || ordered.none? { |call|
          call["case"] != "guion1-t1" && call["published"].to_s.match?(/\bapagado\b/i) &&
            !call["published"].to_s.match?(/correcci[oó]n|ya no|encendido/i)
        })
      end

      def harness_budget_block(ceiling)
        full = BigDecimal(ceiling["anthropic_full_ceiling_usd"])
        balance = BigDecimal(ceiling["anthropic_balance_usd"])
        {
          "status" => "blocked",
          "reason" => "anthropic_ceiling",
          "anthropic_full_ceiling_usd" => ceiling["anthropic_full_ceiling_usd"],
          "anthropic_balance_usd" => ceiling["anthropic_balance_usd"],
          "shortfall_usd" => self.class.money(full - balance),
          "calls" => []
        }
      end

      def bedrock_phase(verdict, harness, ceiling)
        status = bedrock_status(ceiling)
        passed = harness.is_a?(Hash) && Array(harness["scripts"]).size == 2 && harness["scripts"].all? { |row| row["pass"] }
        if harness.is_a?(Hash) && harness["status"] == "blocked"
          return {
            "status" => "blocked",
            "reason" => status["fits"] ? "harness_budget" : status["reason"],
            "budget" => status,
            "note" => "El harness no corre: el techo Anthropic de 28 generaciones supera el saldo. Bedrock tampoco cabe en las llamadas de la asignación."
          }
        end
        unless verdict["advance"] && passed
          return { "status" => "not_reached", "reason" => verdict["advance"] ? "harness_fidelity" : "fable", "budget" => status }
        end
        unless status["fits"]
          return { "status" => "blocked", "reason" => status["reason"], "budget" => status }
        end

        execute_bedrock(status)
      end

      def bedrock_status(ceiling)
        path = ENV["VF5_ASSIGNMENT_SPEND"].presence ||
          Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json").to_s
        return { "fits" => false, "reason" => "assignment_spend_absent", "path" => path } unless File.file?(path)

        data = JSON.parse(File.read(path))
        auth = data["authorization"].is_a?(Hash) ? data["authorization"] : {}
        cap = auth["call_cap"].to_i
        cap = data["call_cap"].to_i if cap.zero?
        attempts = data["attempts"].to_i
        remaining = cap - attempts
        room = authorization_room(data, auth)
        needed = 16
        reason = if remaining < needed
          "assignment_calls"
        elsif room < BigDecimal(ceiling.dig("bedrock", "ceiling_usd").to_s)
          "authorization_dollars"
        end
        {
          "fits" => reason.nil?,
          "reason" => reason,
          "path" => path,
          "attempts" => attempts,
          "call_cap" => cap,
          "remaining_calls" => remaining,
          "needed_calls" => needed,
          "room_usd" => self.class.money(room),
          "model_id" => BedrockClient::QUERY_MODEL_ID
        }
      end

      def authorization_room(data, auth)
        after = auth["after_attempt"].to_i
        limit = BigDecimal(auth["cost_usd"].to_s)
        exposure = Array(data["entries"]).sum(BigDecimal("0")) do |entry|
          next BigDecimal("0") unless entry.is_a?(Hash) && entry["id"].to_i > after && entry["status"] != "released"

          BigDecimal((entry["actual_usd"].presence || entry["ceiling_usd"]).to_s)
        end
        limit - exposure
      end

      def execute_bedrock(status)
        install_pack_hook!
        keys = %w[COMPANION_EVIDENCE_PACK RAG_COMPANION_GENERATION BEDROCK_KNOWLEDGE_BASE_ID AWS_MAX_ATTEMPTS RAG_TRANSIENT_ATTEMPT_LIMIT RAG_LOCAL_PASS_GUARD RAG_LOCAL_PASS_CALL_CAP RAG_LOCAL_PASS_COST_CAP_USD HAIKU_QUERY_ANALYSIS_MODE FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED DOCUMENT_IDENTITY_SCOPE_ENABLED SHARED_SESSION_ENABLED]
        previous = keys.index_with { |key| ENV[key] }
        ENV["COMPANION_EVIDENCE_PACK"] = "contexto"
        ENV["RAG_COMPANION_GENERATION"] = "direct"
        ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = KNOWLEDGE_BASE_ID
        ENV["AWS_MAX_ATTEMPTS"] = "1"
        ENV["RAG_TRANSIENT_ATTEMPT_LIMIT"] = "1"
        ENV["RAG_LOCAL_PASS_GUARD"] = "1"
        ENV["RAG_LOCAL_PASS_CALL_CAP"] = status["remaining_calls"].to_s
        ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = status["room_usd"]
        ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
        ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
        ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
        ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
        ENV["SHARED_SESSION_ENABLED"] = "false"
        pin = verify_pin
        write_json(Pathname(@output).join("bedrock/pin.json"), pin)
        return { "status" => "blocked", "reason" => pin["reason"], "pin" => pin } unless pin["pass"]

        runs = []
        HARNESS.each do |script|
          runs << bedrock_script(script)
        end
        { "status" => "executed", "model_id" => BedrockClient::QUERY_MODEL_ID, "runs" => runs, "pin" => pin }
      ensure
        previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end

      def verify_pin
        document = KbDocument.find_by(document_uid: DOCUMENT_UID)
        return { "pass" => false, "reason" => "document_absent", "document_uid" => DOCUMENT_UID } if document.nil?

        uri = document.canonical_uri.to_s
        name = document.try(:display_name).to_s
        name = document.stem_from_s3_key if name.blank? && document.respond_to?(:stem_from_s3_key)
        {
          "pass" => uri == INDEXED_URI && name.to_s.match?(/VF5/) && document.id.present?,
          "reason" => uri == INDEXED_URI ? nil : "indexed_uri",
          "document_id" => document.id,
          "document_uid" => document.document_uid,
          "name" => name,
          "canonical_uri" => uri,
          "expected_uri" => INDEXED_URI,
          "knowledge_base_id" => KNOWLEDGE_BASE_ID
        }
      end

      def bedrock_script(script)
        questions = script["script"] == "guion2" ? GUION2_QUESTIONS : GUION1_QUESTIONS
        document = KbDocument.find_by!(document_uid: DOCUMENT_UID)
        account = document.account
        user = User.where(account_id: account.id).order(:id).first
        session = ConversationSession.create!(
          identifier: "web:#{script['script']}-pack-#{SecureRandom.hex(4)}",
          channel: "web", expires_at: 1.day.from_now, user: user, account: account, conversation_history: []
        )
        pinned = session.pin_kb_document!(document)
        session.reload
        directory = Pathname(@output).join("bedrock", script["script"])
        FileUtils.mkdir_p(directory)
        write_json(directory.join("session.json"), {
          "session_id" => session.id, "pinned" => pinned == true,
          "focus_document_ids" => session.focus_document_ids,
          "document_focus" => session.try(:document_focus)
        })
        return { "script" => script["script"], "status" => "pin_failed" } unless pinned == true

        turns = []
        questions.each_with_index do |question, index|
          turns << bedrock_turn(session, user, question, index + 1, directory)
        end
        { "script" => script["script"], "session_id" => session.id, "turns" => turns }
      end

      def bedrock_turn(session, user, question, number, directory)
        turn_dir = directory.join(format("turn-%d", number))
        FileUtils.mkdir_p(turn_dir)
        File.write(turn_dir.join("message.txt"), question)
        events = []
        result = nil
        error = nil
        correlation_id = "query:#{SecureRandom.uuid}"
        Rag::ValidationCapture.capture do |bucket|
          Rag::ValidationCapture.bind(run_id: "evidence-pack-bedrock", session_id: session.id, correlation_root: correlation_id)
          events = bucket
          episode_turn = session.record_user_turn!(question, user_id: user.id, correlation_id: correlation_id, locale: :es)
          session.reload
          host = BedrockHost.new(session.account, user)
          result = host.execute(
            question,
            session_context: SessionContextBuilder.build(session),
            conv_session: session,
            entity_s3_uris: SessionContextBuilder.entity_s3_uris(session),
            account: session.account,
            user_id: user.id,
            correlation_id: correlation_id,
            episode_turn: episode_turn,
            output_channel: :web
          )
          if result.respond_to?(:success?) && result.success?
            session.record_assistant_turn!(
              result.answer.to_s, user_id: user.id, correlation_id: result.correlation_id,
              pending_question: result.pending_question, expected_episode_id: session.live_episode_id,
              focus_ids: session.focus_document_ids, prompt_reply: result.history_answer
            )
          end
        rescue StandardError, Rag::LocalPassLedger::Stop => raised
          error = raised
        end
        capture = Rag::ValidationCapture.export_capture(events, turn_dir, run_id: directory.basename.to_s)
        File.write(turn_dir.join("capture.json"), JSON.generate(capture))
        session.reload
        history = session.conversation_history
        write_json(turn_dir.join("history.json"), history)
        published = result.respond_to?(:answer) ? result.answer.to_s : ""
        File.write(turn_dir.join("published.txt"), published)
        raw = Array(capture["events"]).reverse.find { |event| event["kind"] == "companion_direct" && event["text"].present? }
        File.write(turn_dir.join("raw.txt"), raw ? raw["text"].to_s : "")
        write_json(turn_dir.join("trace.json"), bedrock_trace(capture, history))
        {
          "turn" => number,
          "status" => error.nil? && result.respond_to?(:success?) && result.success? ? "returned" : "failed",
          "error_class" => error&.class&.name,
          "error_message" => error&.message.to_s,
          "directory" => turn_dir.to_s,
          "published" => published
        }
      end

      def bedrock_trace(capture, history)
        events = Array(capture["events"])
        kinds = %w[interpreter_request interpreter_raw effective_query retrieve retrieval_results companion_rerank converse companion_direct published_answer assistant_history]
        found = kinds.index_with { |kind| events.select { |event| event["kind"] == kind } }
        missing = kinds.select { |kind| found[kind].empty? }
        {
          "model_id" => BedrockClient::QUERY_MODEL_ID,
          "knowledge_base_id" => ENV["BEDROCK_KNOWLEDGE_BASE_ID"],
          "evidence_pack" => ENV["COMPANION_EVIDENCE_PACK"],
          "events" => found,
          "missing" => missing,
          "persisted_roles" => Array(history).pluck("role")
        }
      end

      def halt_reason(calls)
        Array(calls).any? { |call| call["truncated"] || call["status"] != "returned" || call["stop"] }
      end

      def stop_after(stage, isolated, verdict, harness = nil)
        diagnosis = diagnosis_document(JSON.parse(Pathname(@output).join("ceiling.json").read), isolated, verdict, harness, { "status" => "not_reached", "reason" => stage })
        diagnosis["stopped_at"] = stage
        write_json(Pathname(@output).join("diagnosis.json"), diagnosis)
        @io.puts JSON.generate(diagnosis.except("failures"))
        2
      end

      def refuse(reason, ceiling)
        payload = { "status" => "refused", "reason" => reason, "paid_run" => "not_executed", "ceiling" => ceiling.except("turns") }
        write_json(Pathname(@output).join("preflight.json"), payload)
        @io.puts JSON.generate(payload.except("ceiling"))
        2
      end

      def diagnosis_document(ceiling, isolated, verdict, harness, bedrock)
        {
          "rubric" => RUBRIC_VERSION,
          "system_sha256" => SYSTEM_SHA,
          "code" => code_identity,
          "ceiling" => ceiling.except("turns"),
          "spent_usd" => self.class.money(@ledger ? @ledger.spent : 0),
          "ab" => summarize_calls(isolated),
          "fable" => verdict,
          "harness" => harness&.except("calls"),
          "bedrock" => bedrock,
          "failures" => failure_packets(isolated, harness)
        }
      end

      def summarize_calls(calls)
        Array(calls).map do |call|
          call.except("raw", "published", "usage", "evaluation").merge(
            "documentary_pass" => call.dig("evaluation", "documentary_published", "pass"),
            "historical_reasons" => call.dig("evaluation", "historical_judge", "reasons"),
            "accepted" => call["accepted"],
            "raw_equals_published" => call["raw_equals_published"]
          )
        end
      end

      def failure_packets(isolated, harness)
        packets = []
        Array(isolated).each { |call| packets << packet(call) if call.dig("evaluation", "documentary_published", "pass") == false }
        Array(harness && harness["calls"]).each { |call| packets << packet(call) if call.dig("evaluation", "documentary_published", "pass") == false }
        packets
      end

      def packet(call)
        {
          "directory" => call["directory"],
          "case" => call["case"],
          "arm" => call["arm"],
          "sample" => call["sample"],
          "stage" => call.dig("evaluation", "documentary_raw", "pass") == true ? "compuerta" : "generación",
          "criteria" => call.dig("evaluation", "documentary_published", "criteria")
        }
      end

      def isolation_case(spec)
        pair = build_loaded(spec)
        errors = []
        a_text = packer.send(:message_text, pair["a"])
        b_text = packer.send(:message_text, pair["b"])
        errors << "system" unless pair["system_sha256"] == SYSTEM_SHA
        errors << "prefix_in_a" if a_text.include?("[CONTEXTO")
        errors << "byte" unless packer.strip_annotations(b_text) == a_text
        errors << "outside" unless JSON.generate(packer.outside_evidence(pair["a"])) == JSON.generate(packer.outside_evidence(pair["b"]))
        errors << "max_tokens" unless pair["a"].dig("body", "max_tokens") == MAX_TOKENS && pair["b"].dig("body", "max_tokens") == MAX_TOKENS
        errors << "parameters" unless same_parameters?(pair["a"], pair["b"])
        errors << "history" unless pair["a"].dig("body", "messages")[0..-2] == pair["b"].dig("body", "messages")[0..-2]
        { "id" => spec["id"], "errors" => errors, "system_sha256" => pair["system_sha256"], "annotations" => pair["provenance"].size }
      end

      def same_parameters?(left, right)
        %w[model max_tokens stream thinking output_config system].all? do |key|
          left.dig("body", key) == right.dig("body", key)
        end
      end

      def build_loaded(spec)
        packer.build_pair(packer.case_request(spec))
      end

      def packer
        CompanionEvidencePackCompare
      end

      def harness_ceiling_rows
        rows = []
        HARNESS.each do |script|
          script["turns"].times do |offset|
            number = offset + 1
            request = packer.load_request(script["script"], number)
            body = request.fetch("body")
            body["messages"].each do |message|
              next unless message["role"] == "assistant"

              message["content"][0]["text"] = "x" * PUBLISHED_BOUND_CHARS
            end
            pair = packer.build_pair(request)
            chars = input_chars(pair["b"])
            rows << reservation_row("harness", "#{script['script']}-t#{number}", "b", 1, chars)
          end
        end
        rows
      end

      def reservation_row(phase, id, arm, sample, chars)
        amount = self.class.reservation_usd(chars, MAX_TOKENS)
        {
          "phase" => phase, "case" => id, "arm" => arm, "sample" => sample,
          "input_chars" => chars, "max_tokens" => MAX_TOKENS,
          "reservation_usd" => self.class.money(amount)
        }
      end

      def bedrock_ceiling
        model = BedrockClient::QUERY_MODEL_ID
        interpreter_in = TurnInterpreter::PROMPT.length + 4_000
        generation_in = CompanionDirectAnswer::SYSTEM_PROMPT.length + CompanionDirectAnswer::HISTORY_MAX_CHARS +
          CompanionPlan::STATEMENTS_MAX_CHARS + 8_000
        interpreter = LocalPassLedger.price(model, interpreter_in, TurnInterpreter::MAX_TOKENS)
        generation = LocalPassLedger.price(model, generation_in, CompanionDirectAnswer::MAX_TOKENS)
        embed = LocalPassLedger.price("amazon.titan-embed-text-v2:0", 2_000, 0)
        per_turn = interpreter + generation + RERANK_USD + embed
        turns = 8
        ceiling = per_turn * turns
        room = bedrock_room_preview
        {
          "model_id" => model,
          "profile_note" => "El id efectivo es el que BedrockClient carga. Haiku 4.5 valida esa configuración.",
          "turns" => turns,
          "attempts_per_turn" => 1,
          "interpreter_usd" => self.class.money(interpreter),
          "generation_usd" => self.class.money(generation),
          "rerank_usd" => self.class.money(RERANK_USD),
          "embed_usd" => self.class.money(embed),
          "retrieve_api_usd" => "0",
          "retrieve_note" => "Retrieve no tiene tarifa de token en BedrockQuery. La consulta se acota con Titan Embeddings V2.",
          "ceiling_usd" => self.class.money(ceiling),
          "assignment" => room,
          "fits" => room["remaining_calls"].to_i >= 16 && BigDecimal(room["room_usd"].to_s) >= ceiling
        }
      end

      def bedrock_room_preview
        path = Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json")
        return { "remaining_calls" => 0, "room_usd" => "0.000000", "reason" => "assignment_spend_absent" } unless path.file?

        data = JSON.parse(path.read)
        auth = data["authorization"].is_a?(Hash) ? data["authorization"] : {}
        cap = auth["call_cap"].to_i
        cap = data["call_cap"].to_i if cap.zero?
        {
          "remaining_calls" => cap - data["attempts"].to_i,
          "room_usd" => self.class.money(authorization_room(data, auth)),
          "call_cap" => cap,
          "attempts" => data["attempts"]
        }
      end

      def ledger_spent(path)
        Ledger.new(path).spent
      end

      def input_chars(request)
        body = request.fetch("body")
        body.dig("system", 0, "text").to_s.length +
          Array(body["messages"]).sum { |message| message.dig("content", 0, "text").to_s.length }
      end

      def evidence_text(request)
        _prefix, evidence = packer.send(:split_evidence, packer.send(:message_text, request))
        evidence.to_s
      end

      def chain_request(request, prior)
        copy = packer.send(:deep, request)
        messages = copy.fetch("body").fetch("messages")
        assistants = messages.each_index.select { |index| messages[index]["role"] == "assistant" }
        raise ArgumentError, "history length" unless assistants.size == prior.size

        prior.each_with_index do |text, index|
          messages[assistants[index]]["content"][0]["text"] = strip_markers(text.to_s)
        end
        copy
      end

      def strip_markers(text)
        text.to_s.gsub(MARKER, "").strip
      end

      def current_question(body)
        text = body.dig("messages", -1, "content", 0, "text").to_s
        text.split(EVIDENCE_MARK, 2).first.to_s
      end

      def history_messages(body)
        Array(body["messages"])[0..-2].map do |message|
          { "role" => message["role"], "text" => message.dig("content", 0, "text").to_s }
        end
      end

      def publication_input(body, evidence)
        episode = JSON.parse(CompanionDirectCaptureReplay::EVIDENCE.join("turn-1/episode.json").read)
        sources = gate_sources(evidence)
        messages = history_messages(body) + [ { "role" => "user", "text" => current_question(body) } ]
        {
          "sources" => sources,
          "question" => current_question(body).sub("Mensaje de este turno:\n", "").strip,
          "episode" => episode,
          "messages" => messages
        }
      end

      def gate_sources(evidence)
        lines = evidence.lines
        sources = []
        index = 0
        while index < lines.length
          next index += 1 unless lines[index].match?(/\A\[(\d+)\] /)

          index += 1
          body = +""
          while index < lines.length && !lines[index].match?(/\A\[\d+\] /)
            body << lines[index]
            index += 1
          end
          sources << { "index" => sources.size + 1, "content" => body, "id" => "s#{sources.size + 1}" }
        end
        sources
      end

      def refuse_shape(body)
        raise ArgumentError, "max_tokens" unless body["max_tokens"] == MAX_TOKENS
        raise ArgumentError, "temperature" if body.key?("temperature")
      end

      def code_identity
        file = Rails.root.join("test/support/companion_evidence_pack_compare.rb")
        head = `git -C #{Rails.root} rev-parse HEAD 2>/dev/null`.strip
        { "git_head" => head, "file_sha256" => Digest::SHA256.file(file).hexdigest }
      end

      def offline_dir
        Pathname(@output).join("offline")
      end
    end

    class BedrockHost
      include RagQueryConcern

      def initialize(account, user)
        @current_account = account
        @current_user = user
      end

      attr_reader :current_account, :current_user

      def execute(question, **)
        execute_rag_query(question, **)
      end
    end
  end
end
