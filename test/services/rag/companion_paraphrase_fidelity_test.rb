# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/companion_vertical_ladder")

class Rag::CompanionParaphraseFidelityTest < ActiveSupport::TestCase
  ARCHIVE = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/guion1_control_20261105T223845Z")
  CAPTURE_ROOT = Pathname("/Users/lahirisan/smart_deal/tmp/vf5_citation_gui_20261029/2026-10-29_2026-10-29_danebo-legacy/validation_captures/web-danebo-legacy")
  CONTROL_PARAGRAPH = "Pon [n] junto a la afirmación que esa fuente respalda. Cuando cites una regla, una condición, un valor, un terminal o un paso, cópialo literal y deja [n] en la misma oración. Conserva palabras como «solo», «si» y «cuando». Mantén separadas las hipótesis propias y las condiciones o recomendaciones documentadas."
  NUMBERING_NOW = "Las fuentes numeradas son las del caso. Un [n] de un mensaje anterior es la misma fuente, con el mismo número."
  NUMBERING_THEN = "Las fuentes numeradas de este mensaje son las únicas de este turno. Un [n] de un mensaje anterior pertenece a otras fuentes."
  PARAPHRASE_PARAGRAPH = "Distingue paráfrasis atribuida y cita literal. Puedes explicar con tus palabras lo respaldado por una fuente, sin comillas y conservando su alcance, negaciones y condiciones. Usa comillas solo para un fragmento literal contiguo de esa fuente, sin sustituir ni omitir palabras. Cada afirmación documental lleva su propio [n] antes del punto, aunque repita la fuente de la oración anterior o de la misma viñeta. Un marcador de otra oración no la cubre. Una fuente debe respaldar lo afirmado; su número por sí solo no basta. Conserva las condiciones de aplicación también al parafrasear y mantén separadas y señaladas las hipótesis propias."
  ABSTENTION = "No pude preparar una orientación fiable para este turno; el caso se conserva."
  FALSE_LED = "Con el LED apagado, esa comprobación no aplica"
  LED_CHECK = "Comprobar si el LED de la fotocélula esta activado"
  FORCE = "fuerza de cierre de la puerta (sensibilidad a reaperturas)"
  PUMP_SOURCES = [
    "El filtro de la bomba HC-14 se cambia cada 2000 horas.",
    "El caudal de la bomba HC-14 se lee en litros por minuto.",
    "Si la presión supera 4 bar, cierre la válvula de aislamiento. No la abra con la bomba en marcha."
  ].freeze

  setup do
    @ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
  end

  test "the paraphrase fixture replaces only the citation paragraph and keeps the control file" do
    control = File.read(Rag::CompanionDirectCaptureReplay::CAPTURED_PROMPT_PATH)
    variant = File.read(Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_PATH)
    previous = File.read(Rag::CompanionVerticalLadder::VARIANT_PROMPT_PATH)

    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, Digest::SHA256.hexdigest(control)
    assert_equal Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_SHA, Digest::SHA256.hexdigest(variant)
    assert_equal Rag::CompanionVerticalLadder::VARIANT_PROMPT_SHA, Digest::SHA256.hexdigest(previous)
    assert_equal control.sub(CONTROL_PARAGRAPH, PARAPHRASE_PARAGRAPH).sub(NUMBERING_NOW, NUMBERING_THEN), variant
    assert_equal 1, control.scan(CONTROL_PARAGRAPH).size
    assert_equal 1, control.scan(NUMBERING_NOW).size
    assert_equal 1, variant.scan(NUMBERING_THEN).size
    assert_not_includes control, "Distingue paráfrasis atribuida"
    assert_not_includes variant, "Fermator"
    assert_not_includes variant, "VF5"
  end

  test "archived guion 1 replays the five gates and the five published texts" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    prior = []
    (1..5).each do |number|
      raw = turn_file(number, "raw.txt").read
      stop = JSON.parse(turn_file(number, "usage.json").read).fetch("stop_reason")
      archived = JSON.parse(turn_file(number, "gate.json").read)
      result = publish(@ladder.assemble("guion1", number, prior), raw, stop)

      assert_equal archived.except("safety_text"), result.except("safety_text"), "turn #{number}"
      assert_equal turn_file(number, "published.txt").read, result["publishable"], "turn #{number}"
      prior << { question: Rag::CompanionVerticalLadder::GUION1_QUESTIONS[number - 1], published: result["publishable"] }
    end
  end

  test "guion 1 mutations separate the gate from documentary fidelity" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    built = turns
    t1 = mutate_t1(built[1]["raw"])
    t2 = mutate_t2(built[2]["raw"])
    t4 = mutate_t4(built[4]["raw"])
    g1 = publish(built[1]["built"], t1)
    g2 = publish(built[2]["built"], t2)
    g4 = publish(built[4]["built"], t4)
    led = built[1]["built"]["sources"][2]["content"]
    force = built[2]["built"]["sources"][3]["content"]
    units = built[4]["built"]["sources"][3]["content"]
    conflict = built[4]["built"]["sources"][1]["content"]

    assert_equal true, g1["accepted"], g1["reasons"].inspect
    assert_includes g1["publishable"], FALSE_LED
    assert_includes led, LED_CHECK
    assert_includes led, "La puerta se abre pero no se cierra"
    assert_not_includes led, FALSE_LED

    assert_equal true, g2["accepted"], g2["reasons"].inspect
    assert_includes g2["publishable"], "¿El LED encendido es el de FOTOCÉLULA o el de OBSTRUCCIÓN?"
    assert_includes force, FORCE
    assert_not_includes t2, "\"fuerza de cierre (sensibilidad a reaperturas)\""
    assert_includes t2, "fuerza de cierre (sensibilidad a reaperturas)"

    assert_equal true, g4["accepted"], g4["reasons"].inspect
    assert_includes t4, "Otra parte de la documentación da la unidad en N [4]."
    assert_includes t4, "El documento rotula #8 de forma contradictoria, así que confírmalo en el equipo [2]."
    assert_includes units, "60 a 150Nm"
    assert_includes units, "CONFLICTO_DOCUMENTAL C3"
    assert_includes conflict, "CONFLICTO_DOCUMENTAL C2"
    assert_includes conflict, "#8"
  end

  test "vf5 controls keep an unsupported pass as a documentary negative" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    built = @ladder.assemble("guion1", 1, [])
    invented = publish(built, 'El manual fija "noventa y nueve voltios de calibración" [1].')
    dropped = publish(built, 'Haz la prueba: "desconectar la fotocélula y volver a pulsar el botón de TEST" [1].')
    carried = publish(built, 'En caso que el problema persista, "desconectar la fotocélula y volver a pulsar el botón de TEST" [1].')
    uncited = publish(built, "Según el manual, el primer paso es el ajuste de #54.")
    irrelevant = publish(built, "La fuerza de #54 se ajusta hasta 400 mm/s [2].")
    paraphrase = publish(built, "Desconecta la fotocélula y vuelve a pulsar el botón de TEST [1].")
    procedure = built["sources"][0]["content"]
    other = built["sources"][1]["content"]

    assert_equal false, invented["accepted"]
    assert_equal [ { "rule" => "R2", "detail" => "noventa y nueve voltios de calibración" } ], invented["reasons"]
    assert_equal false, dropped["accepted"]
    assert_includes dropped["reasons"], { "rule" => "R2", "detail" => "condition_dropped:desconectar la fotocélula y volver a pulsar el botón de TEST" }
    assert_equal true, carried["accepted"], carried["reasons"].inspect
    assert_equal false, uncited["accepted"]
    assert uncited["reasons"].any? { |reason| reason["rule"] == "R3" }
    assert_equal true, irrelevant["accepted"], irrelevant["reasons"].inspect
    assert_not_includes other, "400 mm/s"
    assert_equal true, paraphrase["accepted"], paraphrase["reasons"].inspect
    assert_includes procedure, "En caso que el problema persista"
    assert_not_includes paraphrase["publishable"], "En caso que el problema persista"
  end

  test "the same contract holds for another manual and other citation numbers" do
    built = pump_case
    invented = publish(built, 'El manual dice "abra la válvula a 12 bar" [3].')
    dropped = publish(built, 'El manual pide "cierre la válvula de aislamiento" [3].')
    carried = publish(built, 'Si la presión supera 4 bar, "cierre la válvula de aislamiento" [3].')
    uncited = publish(built, "Según el manual, cierre la válvula de aislamiento.")
    irrelevant = publish(built, "La presión de trabajo es 4 bar [1].")
    missing = publish(built, "El filtro de la bomba HC-14 se cambia cada 2000 horas [9].")
    paraphrase = publish(built, "Cierra la válvula de aislamiento [3].")
    kept = publish(built, "Cuando la presión supera 4 bar, cierra la válvula de aislamiento [3].")
    rule = built["sources"][2]["content"]
    filter = built["sources"][0]["content"]

    assert_equal false, invented["accepted"]
    assert_includes invented["reasons"], { "rule" => "R2", "detail" => "abra la válvula a 12 bar" }
    assert_equal false, dropped["accepted"]
    assert_includes dropped["reasons"], { "rule" => "R2", "detail" => "condition_dropped:cierre la válvula de aislamiento" }
    assert_equal true, carried["accepted"], carried["reasons"].inspect
    assert_equal false, uncited["accepted"]
    assert uncited["reasons"].any? { |reason| reason["rule"] == "R3" }
    assert_equal true, irrelevant["accepted"], irrelevant["reasons"].inspect
    assert_not_includes filter, "4 bar"
    assert_equal false, missing["accepted"]
    assert_includes missing["reasons"], { "rule" => "R1", "detail" => "missing:9" }
    assert_equal true, paraphrase["accepted"], paraphrase["reasons"].inspect
    assert_includes rule, "Si la presión supera 4 bar"
    assert_not_includes paraphrase["publishable"], "4 bar"
    assert_equal true, kept["accepted"], kept["reasons"].inspect
    assert_includes kept["publishable"], "Cuando la presión supera 4 bar"
  end

  test "guion 2 keeps its gate and its sources when only the system changes" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    control = @ladder.preview_request(@ladder.assemble("guion2", 1, []))
    variant = @ladder.preview_request(@ladder.assemble("guion2", 1, []), system: paraphrase_text)
    raw = Rails.root.join("test/fixtures/vf5_vertical_r2/guion2_t3_raw.txt").read
    published = publish(@ladder.assemble("guion2", 3, []), raw)

    assert_equal blank_system(control["body"]), blank_system(variant["body"])
    assert_equal Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_SHA, Digest::SHA256.hexdigest(variant.dig("body", "system", 0, "text"))
    assert_equal false, published["accepted"]
    assert_includes published["reasons"], { "rule" => "R2", "detail" => "condition_dropped:configuración de los parámetros por defecto" }
    assert_includes @ladder.send(:judge_guion2, 1, "Si la apertura lenta persiste, realiza el autoajuste."), "t1:autoajuste_if_still_slow"
  end

  test "turn 5 keeps the automatic reading beside the section 5.5 description" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    published = turn_file(5, "published.txt").read
    texts = Rag::CompanionVerticalLadder::GUION1_QUESTIONS
    reading = @ladder.send(:t5_assessment, published, technician_texts: texts)
    judged = @ladder.send(:judge_guion1, 5, published, technician_texts: texts)
    section = @ladder.assemble("guion1", 5, []).fetch("sources")[3].fetch("content")

    assert_equal false, reading.dig("technician_limitation", "recognized")
    assert_equal true, reading.dig("method_limit", "present")
    assert_includes reading.dig("method_limit", "phrase"), "no explica cómo comprobar"
    assert_equal false, reading.dig("identification_request", "present")
    assert_equal "pending", reading.dig("led", "status")
    assert_equal true, reading.dig("led", "useful")
    assert_includes judged, "t5:misses_unknown"
    assert_includes judged, "t5:drops_normally_open"
    assert_not_includes judged, "t5:reasks_identification"
    assert_not_includes judged, "t5:repeats_led"
    assert_includes published, "se activa al conectar la entrada 21 con la 23, usando contactos libres de tensión"
    assert_not_includes published, "normalmente abierto"
    assert_includes section, "Para activar esta señal, se debe conectar la entrada re-apertura (21) con la entrada de +12V (23)."
    assert_includes section, "Se debe usar siempre contactos libres de tensión y normalmente abierto."
  end

  test "the historical route and the frozen runner change the query at different stages" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    prior = []
    (1..5).each do |number|
      capture = JSON.parse(CAPTURE_ROOT.join(Rag::CompanionVerticalLadder::GUION1_CAPTURES.fetch(number), "capture.json").read)
      user = event(capture, "user_message")
      query = event(capture, "effective_query")
      retrieve = event(capture, "retrieve")
      body = event(capture, "converse").dig("messages", 0, "content", 0, "text")
      generator = File.read(CAPTURE_ROOT.join(Rag::CompanionVerticalLadder::GUION1_CAPTURES.fetch(number), body.fetch("path")))
      question = Rag::CompanionVerticalLadder::GUION1_QUESTIONS[number - 1]
      built = @ladder.assemble("guion1", number, prior)
      control = @ladder.preview_request(built)
      variant = @ladder.preview_request(built, system: paraphrase_text)
      archived = JSON.parse(turn_file(number, "request.json").read)
      question_line = built["messages"].last["text"].split("\n", 3)[1]

      assert_equal question, user["original"]
      assert_equal user["original"], user["sent"]
      assert_equal "none", user["transform"]
      assert_equal user["original"], query["sent_turn"]
      assert_equal query["composed"], query["effective"]
      assert_equal query["effective"], retrieve.dig("retrieval_query", "text")
      assert_equal "compose", query["stage"]
      assert_equal "retrieve", retrieve["stage"]
      assert generator.start_with?("Mensaje de este turno:\n#{user["original"]}\n")
      assert_includes generator, "Caso (estado actual, dicho por el técnico; no es documentación):"
      assert_includes generator, "Documentación (afirmaciones numeradas; usa sus ids):"
      assert_equal question, question_line
      assert_equal "simulated", built.dig("stages", "retrieval")
      assert_equal archived.dig("body", "messages"), control.dig("body", "messages")
      assert_equal File.read(Rag::CompanionDirectAnswer::SYSTEM_PROMPT_PATH), control.dig("body", "system", 0, "text")
      assert_equal blank_system(control["body"]), blank_system(variant["body"])
      assert_equal Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_SHA, Digest::SHA256.hexdigest(variant.dig("body", "system", 0, "text"))
      assert_equal "high", variant.dig("body", "output_config", "effort")
      assert_equal 48_000, variant.dig("body", "max_tokens")
      assert_equal({ "type" => "adaptive", "display" => "summarized" }, variant.dig("body", "thinking"))
      if number == 1
        assert_equal user["original"], query["composed"]
        assert_equal [ "current_turn:full", "identity:absent", "identifiers:absent", "observations:0", "photo:absent", "goal:absent", "truncated:false" ], query["components"]
      else
        assert_not_equal user["original"], query["composed"]
        assert query["composed"].start_with?("#{user["original"]} ")
        assert_not_equal question_line, query["composed"]
      end
      prior << { question: question, published: turn_file(number, "published.txt").read }
    end

    history = JSON.parse(turn_file(5, "request.json").read).dig("body", "messages")
    assistants = history.select { |message| message["role"] == "assistant" }.map { |message| message.dig("content", 0, "text") }
    published_t3 = turn_file(3, "published.txt").read

    assert_equal 4, assistants.size
    assert_equal 3, assistants.count(ABSTENTION)
    assert assistants.none? { |text| text.match?(/\[\d+\]/) }
    assert_includes published_t3, "[1]"
    assert_equal published_t3.gsub(/\[\d+\]/, "").strip, assistants[2]
  end

  test "a simulated client reserves and sends exactly the five guion 1 turns" do
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
          "content" => [ { "type" => "text", "text" => "Simulación de paráfrasis." } ],
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
    ).execute_paraphrase
    ceiling = JSON.parse(File.read(File.join(dir, "ceiling.json")))
    summary = JSON.parse(File.read(File.join(dir, "summary.json")))
    reserved = File.readlines(File.join(dir, "attempts.jsonl")).map { |line| JSON.parse(line) }.select { |event| event["event"] == "reserved" }
    one = BigDecimal(ceiling["one_pass_ceiling_usd"])

    assert_equal 0, code
    assert_equal [ [ "guion1", "high" ] ], ceiling["scripts"]
    assert_equal 5, ceiling["generations"]
    assert_equal 3, ceiling["attempts_per_generation"]
    assert_equal "execute", ceiling["decision"]
    assert_equal one * 3, BigDecimal(ceiling["ceiling_usd"])
    assert_equal BigDecimal(ceiling["ceiling_usd"]), BigDecimal(ceiling["retry_storm_ceiling_usd"])
    assert_operator BigDecimal(ceiling["ceiling_usd"]), :<=, BigDecimal("1")
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, ceiling["product_prompt_sha256"]
    assert_equal Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_SHA, ceiling["prompt_sha256"]
    assert_equal [ "query_composition", "retrieve", "rerank" ], ceiling["stages_not_executed"]
    assert_equal 5, posts.size
    assert_equal [ "high" ], posts.map { |body| body.dig("output_config", "effort") }.uniq
    assert_equal [ 48_000 ], posts.pluck("max_tokens").uniq
    assert_equal [ { "type" => "adaptive", "display" => "summarized" } ], posts.pluck("thinking").uniq
    assert_equal [ Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_SHA ], posts.map { |body| Digest::SHA256.hexdigest(body.dig("system", 0, "text")) }.uniq
    assert_equal 5, reserved.size
    assert_equal [ 1 ], reserved.pluck("attempt").uniq
    assert_equal 5, summary["calls"]
    assert_equal 5, summary["generations"]
    assert_equal 0, summary["medium_generations"]
    assert_equal [ [ "guion1", "high" ] ], summary["runs"].map { |row| [ row["script"], row["effort"] ] }
  end

  test "the paraphrase command writes the ceiling and does not call without a credential" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    dir = Dir.mktmpdir
    calls = 0
    transport = Object.new
    transport.define_singleton_method(:post) { calls += 1 }
    code = Rag::CompanionVerticalLadder.new(
      output_root: dir, budget: BigDecimal("1"), credential: "", transport: transport, io: StringIO.new
    ).execute_paraphrase

    assert_equal 2, code
    assert_equal 0, calls
    assert_equal "credential_absent", JSON.parse(File.read(File.join(dir, "preflight.json")))["reason"]
    assert_equal "execute", JSON.parse(File.read(File.join(dir, "ceiling.json")))["decision"]
    assert_not File.exist?(File.join(dir, "attempts.jsonl"))
  end

  private

  def publish(built, text, stop = "end_turn")
    @ladder.send(:publish_answer, built, text, stop)
  end

  def turn_file(number, name)
    ARCHIVE.join("guion1-high", "turn-#{number}", name)
  end

  def turns
    prior = []
    (1..5).to_h do |number|
      built = @ladder.assemble("guion1", number, prior)
      raw = turn_file(number, "raw.txt").read
      prior << { question: built["question"], published: turn_file(number, "published.txt").read }
      [ number, { "built" => built, "raw" => raw } ]
    end
  end

  def mutate_t1(raw)
    raw.sub(
      "Sigue con la revisión documentada: primero el ajuste de #54, luego la obstrucción mecánica.",
      "Sigue con la revisión documentada: primero el ajuste de #54, luego la obstrucción mecánica [1]."
    ).sub('"si está activado"', "si está activado")
  end

  def mutate_t2(raw)
    raw.sub('"fuerza de cierre (sensibilidad a reaperturas)"', "fuerza de cierre (sensibilidad a reaperturas)")
  end

  def mutate_t4(raw)
    raw.sub(
      "Otra parte de la documentación da la unidad en N.",
      "Otra parte de la documentación da la unidad en N [4]."
    ).sub(
      "El documento rotula #8 de forma contradictoria, así que confírmalo en el equipo.",
      "El documento rotula #8 de forma contradictoria, así que confírmalo en el equipo [2]."
    )
  end

  def pump_case
    {
      "question" => "La bomba HC-14 no mantiene la presión. ¿Qué hago?",
      "episode" => {},
      "messages" => [ { "role" => "user", "text" => "La bomba HC-14 no mantiene la presión. ¿Qué hago?" } ],
      "sources" => PUMP_SOURCES.map { |content| { "content" => content, "applicability" => "", "reference_only" => false } }
    }
  end

  def paraphrase_text
    File.read(Rag::CompanionVerticalLadder::PARAPHRASE_PROMPT_PATH)
  end

  def event(capture, kind)
    capture.fetch("events").find { |item| item["kind"] == kind }
  end

  def blank_system(body)
    copy = JSON.parse(JSON.generate(body))
    copy["system"][0]["text"] = ""
    copy
  end
end
