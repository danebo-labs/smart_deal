# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/companion_vertical_ladder")

class Rag::CompanionScopeContractTest < ActiveSupport::TestCase
  CONTROL_ARCHIVE = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/guion1_control_20261105T223845Z/guion1-high")
  VARIANT_ARCHIVE = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/guion1_paraphrase_pending/guion1-high")
  PX72 = Rails.root.join("test/fixtures/vf5_vertical_r2/px72_scope.json")
  OLD_PROCEDURE = "Da los pasos de un procedimiento solo si consta que se cumple su condición documentada. Si falta confirmarla, explica la condición y omite los pasos."
  NEW_PROCEDURE = "Cada indicación hereda el síntoma y las condiciones del apartado donde aparece. Solo la apliques si lo informado confirma ese contexto; un indicador compartido no basta para trasladarla a otra rama. Si falta confirmarlo, explica a qué contexto pertenece y omite el paso. Si las fuentes discrepan sobre un dato necesario para la indicación, muestra las versiones con sus referencias, deja ese dato sin resolver y omite la instrucción que depende de él. No pidas al técnico que arbitre la contradicción del documento. Conserva las indicaciones independientes que sí estén respaldadas y sean aplicables."
  PARAPHRASE_PARAGRAPH = "Distingue paráfrasis atribuida y cita literal."
  REVIEW_EXAMPLE = "offline_review_not_model_output"
  FOREIGN_STEP = "Si su LED está encendido, verifica que no esté bloqueada [3]."
  OPEN_STEP = "Si es el de fotocélula, el manual pide verificar que no esté bloqueada o que la entrada OPEN (#8) no esté activa continuamente [2]."

  setup do
    @ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
  end

  test "the scope fixture replaces only the procedure paragraph of the paraphrase system" do
    product = File.read(Rag::CompanionDirectCaptureReplay::CAPTURED_PROMPT_PATH)
    paraphrase = File.read(Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_PATH)
    scope = File.read(Rag::CompanionVerticalLadder::SCOPE_PROMPT_PATH)

    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, Digest::SHA256.hexdigest(product)
    assert_equal Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_SHA, Digest::SHA256.hexdigest(paraphrase)
    assert_equal Rag::CompanionVerticalLadder::SCOPE_PROMPT_SHA, Digest::SHA256.hexdigest(scope)
    assert_equal paraphrase.sub(OLD_PROCEDURE, NEW_PROCEDURE), scope
    assert_equal paraphrase, scope.sub(NEW_PROCEDURE, OLD_PROCEDURE)
    assert_equal 1, paraphrase.scan(OLD_PROCEDURE).size
    assert_includes product, OLD_PROCEDURE
    assert_not_includes scope, OLD_PROCEDURE
    assert_includes scope, PARAPHRASE_PARAGRAPH
    assert_not_includes scope, "Pon [n] junto a la afirmación"
    assert_no_match(/Fermator|VF5|PX-72|HC-14/, scope)
  end

  test "guion 1 and guion 2 requests change only that system paragraph" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    [ CONTROL_ARCHIVE, VARIANT_ARCHIVE ].each do |archive|
      chain(archive).each { |built| assert_only_procedure_change(built) }
    end
    prior = []
    (1..3).each do |number|
      built = @ladder.assemble("guion2", number, prior)
      assert_only_procedure_change(built)
      prior << { question: built["question"], published: "Orientación publicada de prueba [1]." }
    end
  end

  test "control and variant replay with their own published histories" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    replay(CONTROL_ARCHIVE)
    replay(VARIANT_ARCHIVE)
  end

  test "archived variant turns keep mechanical acceptance apart from documentary fidelity" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    turns = variant_turns
    t1 = turns[1]
    t2 = turns[2]
    t4 = turns[4]
    marked = t1["raw"].sub("obstrucción mecánica.", "obstrucción mecánica [1].")
    marked_gate = publish(t1["built"], marked)
    reopen = t1["built"]["sources"][0]["content"]
    other = t1["built"]["sources"][2]["content"]

    assert_equal false, t1["gate"]["accepted"]
    assert t1["gate"]["reasons"].any? { |reason| reason["rule"] == "R3" }
    assert_equal true, marked_gate["accepted"], marked_gate["reasons"].inspect
    assert_includes marked_gate["publishable"], FOREIGN_STEP
    assert_includes other, "La puerta se abre pero no se cierra"
    assert_includes other, "verificar que la fotocélula no está bloqueada"
    assert_includes t1["built"]["question"], "se reabre sola"
    assert_includes t1["built"]["question"], "LED está apagado"
    assert_includes reopen, "Comprobar la sensibilidad del potenciómetro"
    assert_includes reopen, "En caso que el problema persista"
    assert_equal "documentary_negative_other_symptom", t1_documentary(marked, t1["built"])

    assert_equal true, t2["gate"]["accepted"], t2["gate"]["reasons"].inspect
    assert_equal t2["raw"], t2["gate"]["publishable"]
    assert_equal "documentary_positive_applicable_paraphrase", t2_documentary(t2)

    assert_equal true, t4["gate"]["accepted"], t4["gate"]["reasons"].inspect
    assert_equal t4["raw"], t4["gate"]["publishable"]
    assert_equal "documentary_negative_wrong_symptom_and_unresolved_label", t4_documentary(t4)
    parsed = Rag::CompanionStatements.parse(t4["built"]["sources"])
    step = parsed.by_source(2).find { |statement| statement.step? && statement.text.include?("OPEN") }
    conflict = parsed.by_source(2).find { |statement| statement.kind == "conflict" }

    assert_includes step.item, "abre pero no se cierra"
    assert_equal step.item, conflict.item
  end

  test "reviewed edits are not archived model output and still publish mechanically" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    turns = variant_turns
    t1 = turns[1]["raw"].sub("obstrucción mecánica.", "obstrucción mecánica [1].").sub(
      FOREIGN_STEP,
      "La comprobación de bloqueo con LED de fotocélula encendido pertenece al síntoma de apertura sin cierre [3]; ese síntoma no consta en este caso."
    )
    t4 = turns[4]["raw"].sub(
      OPEN_STEP,
      "La comprobación de bloqueo o de la entrada pertenece al síntoma de apertura sin cierre [2]. Ese pasaje llama OPEN al #8, pero la nota C2 recoge CLOSE en la placa y en el apartado de entradas [2]. La discrepancia queda sin resolver; omito la instrucción que depende de ese rótulo."
    )
    g1 = publish(turns[1]["built"], t1)
    g4 = publish(turns[4]["built"], t4)
    examples = { "provenance" => REVIEW_EXAMPLE, "t1" => t1, "t4" => t4 }

    assert_equal "offline_review_not_model_output", examples["provenance"]
    assert_not_equal turns[1]["raw"], examples["t1"]
    assert_not_equal turns[4]["raw"], examples["t4"]
    assert_includes turns[1]["raw"], "verifica que no esté bloqueada"
    assert_includes turns[4]["raw"], "entrada OPEN (#8)"
    assert_not_includes t1, "verifica que no esté bloqueada"
    assert_not_includes t4, "no esté activa continuamente"
    assert_includes t1, "Si el problema persiste"
    assert_includes t4, "#54"
    assert_includes t4, "CLOSE"
    assert_includes t4, "C2"
    assert_equal true, g1["accepted"], g1["reasons"].inspect
    assert_equal true, g4["accepted"], g4["reasons"].inspect
  end

  test "px-72 separates another symptom from an unresolved conflict and keeps an independent step" do
    fixture = JSON.parse(PX72.read)
    built = px72_case(fixture)
    texts = fixture.fetch("texts")
    gates = texts.transform_values { |text| publish(built, text) }
    pressure = built["sources"][0]["content"]
    flow = built["sources"][1]["content"]
    conflict = built["sources"][2]["content"]

    assert_equal true, gates["f9_paraphrase"]["accepted"], gates["f9_paraphrase"]["reasons"].inspect
    assert_includes pressure, fixture["reported_symptom"]
    assert_includes pressure, "Comprobar el filtro F9."
    assert_not_includes texts["f9_paraphrase"], "V4"
    assert_equal "documentary_positive", px72_f9(texts["f9_paraphrase"], pressure, fixture)

    assert_equal true, gates["v4_paraphrase"]["accepted"], gates["v4_paraphrase"]["reasons"].inspect
    assert_includes flow, fixture["other_symptom"]
    assert_includes flow, "revisar la válvula V4"
    assert_not_includes flow, "CONFLICTO_DOCUMENTAL"
    assert_includes fixture["question"], "L7"
    assert_not_includes fixture["question"], "no hay caudal"
    assert_equal "documentary_negative_other_symptom", px72_other_symptom(texts["v4_paraphrase"], flow, fixture)

    assert_equal true, gates["v4_literal"]["accepted"], gates["v4_literal"]["reasons"].inspect
    assert_includes texts["v4_literal"], "«revisar la válvula V4»"
    assert_equal "documentary_negative_other_symptom_literal", px72_other_symptom(texts["v4_literal"], flow, fixture)

    assert_equal true, gates["j6_paraphrase"]["accepted"], gates["j6_paraphrase"]["reasons"].inspect
    assert_includes conflict, fixture["reported_symptom"]
    assert_includes conflict, "START"
    assert_includes conflict, "STOP"
    assert_includes conflict, "CONFLICTO_DOCUMENTAL"
    assert_not_includes texts["j6_paraphrase"], "STOP"
    assert_includes texts["j6_paraphrase"], "úsala para esta comprobación"
    assert_equal "documentary_negative_conflict_as_certainty", px72_conflict_certainty(texts["j6_paraphrase"], conflict)

    assert_equal true, gates["j6_literal"]["accepted"], gates["j6_literal"]["reasons"].inspect
    assert_includes texts["j6_literal"], "«Comprobar la entrada START (J6)»"
    assert_not_includes texts["j6_literal"], "STOP"
    assert_equal "documentary_negative_conflict_as_certainty_literal", px72_conflict_certainty(texts["j6_literal"], conflict)

    assert_equal true, gates["conflict_and_f9"]["accepted"], gates["conflict_and_f9"]["reasons"].inspect
    assert_equal "documentary_positive_conflict_held_and_independent_step_kept", px72_held(texts["conflict_and_f9"], conflict, pressure)
  end

  test "earlier quote controls stay in force on vf5 and on px-72" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    vf5 = @ladder.assemble("guion1", 1, [])
    invented = publish(vf5, 'El manual fija "noventa y nueve voltios de calibración" [1].')
    dropped = publish(vf5, 'Haz la prueba: "desconectar la fotocélula y volver a pulsar el botón de TEST" [1].')
    uncited = publish(vf5, "Según el manual, el primer paso es el ajuste de #54.")
    irrelevant = publish(vf5, "La fuerza de #54 se ajusta hasta 400 mm/s [2].")

    assert_equal false, invented["accepted"]
    assert_equal [ { "rule" => "R2", "detail" => "noventa y nueve voltios de calibración" } ], invented["reasons"]
    assert_equal false, dropped["accepted"]
    assert_includes dropped["reasons"], { "rule" => "R2", "detail" => "condition_dropped:desconectar la fotocélula y volver a pulsar el botón de TEST" }
    assert_equal false, uncited["accepted"]
    assert uncited["reasons"].any? { |reason| reason["rule"] == "R3" }
    assert_equal true, irrelevant["accepted"], irrelevant["reasons"].inspect
    assert_not_includes vf5["sources"][1]["content"], "400 mm/s"
    assert_equal "documentary_negative_irrelevant_source", (irrelevant["accepted"] && vf5["sources"][1]["content"].exclude?("400 mm/s") ? "documentary_negative_irrelevant_source" : "unexpected")

    fixture = JSON.parse(PX72.read)
    built = px72_case(fixture)
    texts = fixture.fetch("texts")
    invented = publish(built, texts["invented_quote"])
    dropped = publish(built, texts["dropped_condition"])
    uncited = publish(built, texts["uncited"])
    irrelevant = publish(built, texts["irrelevant"])

    assert_equal false, invented["accepted"]
    assert_includes invented["reasons"], { "rule" => "R2", "detail" => "sello S3 a 9 bar" }
    assert_equal false, dropped["accepted"]
    assert_includes dropped["reasons"], { "rule" => "R2", "detail" => "condition_dropped:detener el ciclo de prueba" }
    assert_equal false, uncited["accepted"]
    assert uncited["reasons"].any? { |reason| reason["rule"] == "R3" }
    assert_equal true, irrelevant["accepted"], irrelevant["reasons"].inspect
    assert_not_includes built["sources"][0]["content"], "400 horas"
    assert_includes texts["irrelevant"], "[1]"
    assert_equal "documentary_negative_irrelevant_source", (irrelevant["accepted"] && texts["irrelevant"].include?("400 horas") ? "documentary_negative_irrelevant_source" : "unexpected")
  end

  test "turn 5 records the proximity false positive and the pending limitation apart from the contract" do
    require_historical_capture(VARIANT_ARCHIVE.join("turn-5/raw.txt"))
    text = VARIANT_ARCHIVE.join("turn-5/raw.txt").read
    questions = Rag::CompanionVerticalLadder::GUION1_QUESTIONS
    reading = @ladder.send(:t5_assessment, text, technician_texts: questions)
    judged = @ladder.send(:judge_guion1, 5, text, technician_texts: questions)
    sentences = @ladder.send(:sentences_of, text)
    match = text.match(/borne de INPUTS[\s\S]{0,80}(?:#21|#23|\b21\b|\b23\b)/i)

    assert_equal true, @ladder.send(:misreads_priority_inputs?, text)
    assert sentences.none? { |sentence| @ladder.send(:misreads_priority_inputs?, sentence) }
    assert_includes match[0], "borne de INPUTS recibe cada línea [3]."
    assert_includes match[0], "Hipótesis mía, sin confirmar: una entrada #21"
    assert_includes match[0], "\n\n"
    assert_equal false, reading.dig("technician_limitation", "recognized")
    assert_equal true, reading.dig("method_limit", "present")
    assert_includes reading.dig("method_limit", "phrase"), "no está en la documentación cargada en este turno"
    assert_equal false, reading.dig("identification_request", "present")
    assert_equal "pending", reading.dig("led", "status")
    assert_includes judged, "t5:misses_unknown"
    assert_includes judged, "t5:misreads_priority_inputs"
    assert_not_includes judged, "t5:reasks_identification"
  end

  test "guion 2 preview and the scope ceiling describe the plan without calling a model" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    raw = Rails.root.join("test/fixtures/vf5_vertical_r2/guion2_t3_raw.txt").read
    published = publish(@ladder.assemble("guion2", 3, []), raw)
    ceiling = @ladder.scope_ceiling_document
    restored = @ladder.preview_request(@ladder.assemble("guion1", 1, []))

    assert_equal false, published["accepted"]
    assert_includes published["reasons"], { "rule" => "R2", "detail" => "condition_dropped:configuración de los parámetros por defecto" }
    assert_includes @ladder.send(:judge_guion2, 1, "Si la apertura lenta persiste, realiza el autoajuste."), "t1:autoajuste_if_still_slow"
    assert_equal "not_executed", ceiling["model_call"]
    assert_equal Rag::CompanionVerticalLadder::SCOPE_PAIRS, ceiling["scripts"]
    assert_equal 8, ceiling["generations"]
    assert_equal 3, ceiling["attempts_per_generation"]
    assert_equal "execute", ceiling["decision"]
    assert_equal BigDecimal(ceiling["one_pass_ceiling_usd"]) * 3, BigDecimal(ceiling["ceiling_usd"])
    assert_operator BigDecimal(ceiling["ceiling_usd"]), :<=, BigDecimal("1")
    assert_equal Rag::CompanionVerticalLadder::SCOPE_PROMPT_SHA, ceiling["prompt_sha256"]
    assert_equal Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_SHA, ceiling["paraphrase_prompt_sha256"]
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, ceiling["product_prompt_sha256"]
    assert_equal [ "query_composition", "retrieve", "rerank" ], ceiling["stages_not_executed"]
    assert_equal "claude-haiku-5-5", ceiling["model_id"]
    assert_equal "high", ceiling["effort"]
    assert_equal 48_000, ceiling["max_tokens"]
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, ceiling["thinking"])
    assert_equal [ "guion2", "guion2", "guion2", "guion1", "guion1", "guion1", "guion1", "guion1" ], ceiling["turns"].pluck("script")
    assert_equal Rag::CompanionDirectAnswer::SYSTEM_PROMPT, restored.dig("body", "system", 0, "text")
    assert_equal Rag::CompanionVerticalLadder::SCOPE_CEILING_USD, ceiling["ceiling_usd"]
  end

  test "a simulated client reserves and runs the same eight-generation plan" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    dir = Dir.mktmpdir
    posts = []
    transport = Object.new
    transport.define_singleton_method(:post) do |body:, api_key:, version:|
      posts << body
      Rag::CompanionHaiku55Compare::Result.new(
        http_status: 200,
        payload: {
          "stop_reason" => "end_turn",
          "content" => [ { "type" => "text", "text" => "Simulación de alcance." } ],
          "usage" => {
            "input_tokens" => 100, "output_tokens" => 20,
            "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0,
            "service_tier" => "standard", "inference_geo" => "global"
          }
        },
        retry_after: nil, error_code: nil, error_message: nil, partial: false
      )
    end
    code = Rag::CompanionVerticalLadder.new(
      output_root: dir, budget: BigDecimal("1"), credential: "local", transport: transport, io: StringIO.new
    ).execute_scope
    ceiling = JSON.parse(File.read(File.join(dir, "ceiling.json")))
    summary = JSON.parse(File.read(File.join(dir, "summary.json")))
    reserved = File.readlines(File.join(dir, "attempts.jsonl")).map { |line| JSON.parse(line) }.select { |event| event["event"] == "reserved" }
    plan = ceiling["turns"]

    assert_equal 0, code
    assert_equal Rag::CompanionVerticalLadder::SCOPE_PAIRS, ceiling["scripts"]
    assert_equal Rag::CompanionVerticalLadder::SCOPE_CEILING_USD, ceiling["ceiling_usd"]
    assert_equal "execute", ceiling["decision"]
    assert_equal 8, posts.size
    assert_equal 8, reserved.size
    assert_equal [ 1, 2, 3, 1, 2, 3, 4, 5 ], reserved.pluck("turn")
    assert_equal [ 1 ], reserved.pluck("attempt").uniq
    assert_equal [ 1, 3, 5, 1, 3, 5, 7, 9 ], posts.map { |body| body["messages"].size }
    assert_equal [ Rag::CompanionVerticalLadder::SCOPE_PROMPT_SHA ], posts.map { |body| Digest::SHA256.hexdigest(body.dig("system", 0, "text")) }.uniq
    assert_equal [ "high" ], posts.map { |body| body.dig("output_config", "effort") }.uniq
    assert_equal [ 48_000 ], posts.pluck("max_tokens").uniq
    assert_equal [ { "type" => "adaptive", "display" => "summarized" } ], posts.pluck("thinking").uniq
    assert posts.none? { |body| body.dig("system", 0, "text").include?("Pon [n] junto a la afirmación") }
    posts.each_with_index do |body, index|
      chars = body.dig("system", 0, "text").length + body["messages"].sum { |message| message.dig("content", 0, "text").length }
      expected = Rag::CompanionHaiku55Compare.money(Rag::CompanionHaiku55Compare.reservation_usd(chars, body["max_tokens"]))
      assert_equal expected, reserved[index]["reserved_usd"]
      assert_operator BigDecimal(reserved[index]["reserved_usd"]), :<=, BigDecimal(plan[index]["reservation_usd"])
      assert_equal plan[index]["turn"], reserved[index]["turn"]
    end
    assert_operator reserved.sum(BigDecimal("0")) { |event| BigDecimal(event["reserved_usd"]) }, :<=, BigDecimal(ceiling["one_pass_ceiling_usd"])
    assert_equal 8, summary["calls"]
    assert_equal 8, summary["generations"]
    assert_equal Rag::CompanionVerticalLadder::SCOPE_PAIRS, summary["scripts"]
    assert_equal [ [ "guion2", "high" ], [ "guion1", "high" ] ], summary["runs"].map { |row| [ row["script"], row["effort"] ] }
  end

  test "the scope command writes the pinned ceiling and does not call without a credential" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    dir = Dir.mktmpdir
    calls = 0
    transport = Object.new
    transport.define_singleton_method(:post) { calls += 1 }
    code = Rag::CompanionVerticalLadder.new(
      output_root: dir, budget: BigDecimal("1"), credential: "", transport: transport, io: StringIO.new
    ).execute_scope

    assert_equal 2, code
    assert_equal 0, calls
    assert_equal "credential_absent", JSON.parse(File.read(File.join(dir, "preflight.json")))["reason"]
    ceiling = JSON.parse(File.read(File.join(dir, "ceiling.json")))
    assert_equal "execute", ceiling["decision"]
    assert_equal Rag::CompanionVerticalLadder::SCOPE_CEILING_USD, ceiling["ceiling_usd"]
    assert_not File.exist?(File.join(dir, "attempts.jsonl"))
  end

  private

  def publish(built, text, stop = "end_turn")
    @ladder.send(:publish_answer, built, text, stop)
  end

  def paraphrase_text
    File.read(Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_PATH)
  end

  def scope_text
    File.read(Rag::CompanionVerticalLadder::SCOPE_PROMPT_PATH)
  end

  def chain(archive)
    prior = []
    (1..5).map do |number|
      built = @ladder.assemble("guion1", number, prior)
      prior << { question: built["question"], published: archive.join("turn-#{number}/published.txt").read }
      built
    end
  end

  def replay(archive)
    prior = []
    (1..5).each do |number|
      built = @ladder.assemble("guion1", number, prior)
      raw = archive.join("turn-#{number}/raw.txt").read
      stop = JSON.parse(archive.join("turn-#{number}/usage.json").read).fetch("stop_reason")
      archived = JSON.parse(archive.join("turn-#{number}/gate.json").read)
      result = publish(built, raw, stop)

      assert_equal exported_gate(archived), exported_gate(result), "#{archive} turn #{number}"
      assert_equal archive.join("turn-#{number}/published.txt").read, result["publishable"]
      if archive == VARIANT_ARCHIVE && number == 5
        assert_equal [ "#21", "#23" ], result["signals"].first(2).map { |signal| signal["token"] }
        assert archived["signals"].none? { |signal| signal.key?("token") }
      end
      prior << { question: built["question"], published: result["publishable"] }
    end
  end

  def exported_gate(gate)
    copy = gate.except("safety_text")
    copy["signals"] = Array(copy["signals"]).map { |signal| signal.except("token") }
    copy
  end

  def variant_turns
    prior = []
    (1..5).to_h do |number|
      built = @ladder.assemble("guion1", number, prior)
      raw = VARIANT_ARCHIVE.join("turn-#{number}/raw.txt").read
      stop = JSON.parse(VARIANT_ARCHIVE.join("turn-#{number}/usage.json").read).fetch("stop_reason")
      prior << { question: built["question"], published: VARIANT_ARCHIVE.join("turn-#{number}/published.txt").read }
      [ number, { "built" => built, "raw" => raw, "gate" => publish(built, raw, stop) } ]
    end
  end

  def assert_only_procedure_change(built)
    base = @ladder.preview_request(built, system: paraphrase_text)
    candidate = @ladder.preview_request(built, system: scope_text)

    assert_equal base["body"].except("system"), candidate["body"].except("system")
    assert_equal paraphrase_text, base.dig("body", "system", 0, "text")
    assert_equal scope_text, candidate.dig("body", "system", 0, "text")
    assert_equal Rag::CompanionVerticalLadder::SCOPE_PROMPT_SHA, Digest::SHA256.hexdigest(candidate.dig("body", "system", 0, "text"))
    assert_equal "high", candidate.dig("body", "output_config", "effort")
    assert_equal 48_000, candidate.dig("body", "max_tokens")
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, candidate.dig("body", "thinking"))
    assert_not candidate.dig("body").key?("temperature")
  end

  def t1_documentary(text, built)
    other = built["sources"][2]["content"]
    return "unexpected" unless text.include?(FOREIGN_STEP)
    return "unexpected" unless other.include?("La puerta se abre pero no se cierra")
    return "unexpected" unless built["question"].include?("se reabre sola") && built["question"].include?("LED está apagado")

    "documentary_negative_other_symptom"
  end

  def t2_documentary(turn)
    text = turn["raw"]
    led = turn["built"]["sources"][1]["content"]
    units = turn["built"]["sources"][3]["content"]
    reopen = turn["built"]["sources"][0]["content"]
    return "unexpected" unless text.include?("Solo si el problema persiste")
    return "unexpected" unless text.include?("en Nm") && text.include?("en N") && text.include?("no aclara cuál es correcto")
    return "unexpected" unless text.include?("Se apaga") && led.include?("se deshabilita")
    return "unexpected" unless reopen.include?("En caso que el problema persista") && units.include?("CONFLICTO_DOCUMENTAL C3")

    "documentary_positive_applicable_paraphrase"
  end

  def t4_documentary(turn)
    text = turn["raw"]
    source = turn["built"]["sources"][1]["content"]
    return "unexpected" unless text.include?(OPEN_STEP)
    return "unexpected" unless source.include?("La puerta se abre pero no se cierra") && source.include?("CONFLICTO_DOCUMENTAL C2")
    return "unexpected" if text.include?("CLOSE") || text.include?("C2")

    "documentary_negative_wrong_symptom_and_unresolved_label"
  end

  def px72_case(fixture)
    {
      "question" => fixture.fetch("question"),
      "episode" => {},
      "messages" => [ { "role" => "user", "text" => fixture.fetch("question") } ],
      "sources" => fixture.fetch("sources").map { |content| { "content" => content, "applicability" => "", "reference_only" => false } }
    }
  end

  def px72_f9(text, source, fixture)
    return "unexpected" unless text.include?("filtro F9 [1]")
    return "unexpected" unless source.include?(fixture["reported_symptom"]) && source.include?("Comprobar el filtro F9.")
    return "unexpected" if text.match?(/V4|J6|START|STOP/)

    "documentary_positive"
  end

  def px72_other_symptom(text, source, fixture)
    return "unexpected" unless text.include?("V4") && source.include?(fixture["other_symptom"])
    return "unexpected" if fixture["question"].include?("no hay caudal")

    text.include?("«") ? "documentary_negative_other_symptom_literal" : "documentary_negative_other_symptom"
  end

  def px72_conflict_certainty(text, source)
    return "unexpected" unless text.include?("START") && source.include?("STOP") && source.include?("CONFLICTO_DOCUMENTAL")
    return "unexpected" if text.include?("STOP")

    text.include?("«") ? "documentary_negative_conflict_as_certainty_literal" : "documentary_negative_conflict_as_certainty"
  end

  def px72_held(text, conflict, pressure)
    return "unexpected" unless text.include?("START") && text.include?("STOP") && text.include?("no está resuelta")
    return "unexpected" unless text.include?("filtro F9 [1]") && pressure.include?("Comprobar el filtro F9.")
    return "unexpected" unless conflict.include?("CONFLICTO_DOCUMENTAL")
    return "unexpected" if text.match?(/úsa|comprobar la entrada START/i)

    "documentary_positive_conflict_held_and_independent_step_kept"
  end
end
