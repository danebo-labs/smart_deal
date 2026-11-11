# frozen_string_literal: true

require "test_helper"

require Rails.root.join("test/support/companion_vertical_ladder")

class Rag::CompanionVerticalLadderTest < ActiveSupport::TestCase
  setup do
    @require = ENV["VERTICAL_LADDER_REQUIRE"]
    ENV["VERTICAL_LADDER_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/run_vertical_ladder.rb")
  end

  teardown do
    @require.nil? ? ENV.delete("VERTICAL_LADDER_REQUIRE") : ENV["VERTICAL_LADDER_REQUIRE"] = @require
  end

  test "guion 2 chains the new answer and keeps the canonical sources" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    first = ladder.assemble("guion2", 1, [])
    canonical = JSON.parse(Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare/turn-1/request.json").read)
    assert_equal canonical["messages"].last["content"][0]["text"], first["messages"].last["text"]
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, Digest::SHA256.file(Rag::CompanionDirectCaptureReplay::CAPTURED_PROMPT_PATH).hexdigest
    assert_equal Rag::CompanionDirectAnswer::SYSTEM_PROMPT, File.read(Rag::CompanionDirectAnswer::SYSTEM_PROMPT_PATH)
    historical = Rails.root.join("test/fixtures/vf5_vertical_r2/companion_direct_a6b486fc.txt").read
    assert_equal Rag::CompanionVerticalLadder::CITATION_PROMPT_SHA, Digest::SHA256.hexdigest(historical)
    assert_not_equal historical, Rag::CompanionDirectAnswer::SYSTEM_PROMPT

    published = "La cita queda en [1]. Sin pasos."
    second = ladder.assemble("guion2", 2, [ { question: Rag::CompanionVerticalLadder::GUION2_QUESTIONS[0], published: published } ])
    assert_equal %w[user assistant user], second["messages"].pluck("role")
    assert_equal "La cita queda en . Sin pasos.", second["messages"][1]["text"]
    later = JSON.parse(Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare/turn-2/request.json").read)
    assert_equal later["messages"].last["content"][0]["text"], second["messages"].last["text"]
    assert_equal first["fuentes_sha256"], Digest::SHA256.hexdigest(first["messages"].last["text"].split("Fuentes de este turno:\n", 2)[1])
  end

  test "guion 1 uses the accepted capture and does not call the network" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    built = ladder.assemble("guion1", 1, [])
    assert_equal Rag::CompanionVerticalLadder::GUION1_QUESTIONS[0], built["question"]
    assert_includes built["messages"].last["text"], "Fuentes de este turno:"
    assert_equal "simulated", built["stages"]["retrieval"]
    assert_operator built["sources"].size, :>=, 1
    assert_not_includes built["messages"].last["text"], "temperature"
  end

  test "high and medium stay scheduled when a script fails the rubric" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    assert_equal [
      [ "guion2", "high" ],
      [ "guion1", "high" ],
      [ "guion2", "medium" ],
      [ "guion1", "medium" ]
    ], Rag::CompanionVerticalLadder::BAND_PAIRS
    assert_equal false, ladder.send(:script_stops?, { "status" => "returned", "truncated" => true, "accepted" => false })
    assert_equal true, ladder.send(:script_stops?, { "status" => "budget", "stop_run" => true })
    assert_equal true, ladder.send(:band_halt?, { "turns" => [ { "stop_run" => true } ] })
    assert_equal false, ladder.send(:band_halt?, { "turns" => [ { "status" => "returned", "accepted" => false } ] })
  end

  test "the band ceiling is a fresh reservation and refuses before any call" do
    dir = Dir.mktmpdir
    calls = 0
    transport = Object.new
    transport.define_singleton_method(:post) { calls += 1 }
    code = Rag::CompanionVerticalLadder.new(
      output_root: dir, budget: BigDecimal("0"), transport: transport, credential: "local"
    ).execute_band

    assert_equal 2, code
    assert_equal 0, calls
    ceiling = JSON.parse(File.read(File.join(dir, "ceiling.json")))
    assert_equal "ceiling_above_authorization", ceiling["decision"]
    assert_equal 16, ceiling["generations"]
    assert_equal "0.000000", ceiling["spent_at_open_usd"]
    assert_equal 0, ceiling["calls_at_open"]
    assert_equal "not_used", ceiling["bedrock_ledger"]
    assert_equal 8, ceiling["historical_max_calls"]
    assert_equal "0.150027", ceiling["historical_max_spent_usd"]
    assert_not_equal ceiling["historical_ledger"], ceiling["band_ledger"]
    assert_not File.exist?(File.join(dir, "attempts.jsonl"))
  end

  test "the saved max answers reproduce the two R2 rejections" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    guion2 = ladder.explain_r2(
      "guion2", 3,
      Rails.root.join("test/fixtures/vf5_vertical_r2/guion2_t3_raw.txt").read
    )
    guion1 = ladder.explain_r2(
      "guion1", 5,
      Rails.root.join("test/fixtures/vf5_vertical_r2/guion1_t5_raw.txt").read
    )

    assert_equal false, guion2["accepted"]
    assert_equal "condition_dropped:configuración de los parámetros por defecto", guion2["reasons"].first["detail"]
    assert_equal true, guion2["findings"].first["literal_in_cited_source"]
    assert_includes guion2["findings"].first.dig("match", "before"), "Solo"
    assert guion1["reasons"].none? { |reason| reason["detail"] == "condition_dropped:La puerta se abre pero no se cierra" }, guion1["reasons"].inspect
  end

  test "high validation runs the two high scripts and does not continue into medium" do
    dir = Dir.mktmpdir
    seen = []
    ladder = Rag::CompanionVerticalLadder.new(output_root: dir, budget: BigDecimal("1"), credential: "local")
    ladder.define_singleton_method(:run_script) do |name, effort, _key|
      seen << [ name, effort ]
      { "script" => name, "effort" => effort, "pass" => false, "stopped" => false, "reasons" => [], "turns" => [] }
    end

    assert_equal 0, ladder.execute_high
    assert_equal [ [ "guion2", "high" ], [ "guion1", "high" ] ], seen
    summary = JSON.parse(File.read(File.join(dir, "summary.json")))
    assert_equal [ [ "guion2", "high" ], [ "guion1", "high" ] ], summary["runs"].map { |row| [ row["script"], row["effort"] ] }
  end

  test "the closure ceiling prices the base and one bounded variant before any call" do
    calls = 0
    transport = Object.new
    transport.define_singleton_method(:post) { calls += 1 }
    ladder = Rag::CompanionVerticalLadder.new(
      output_root: Dir.mktmpdir, budget: BigDecimal("1"), transport: transport, credential: "local"
    )
    document = ladder.closure_ceiling_document

    assert_equal 16, document["generations"]
    assert_equal "execute", document["decision"]
    assert_equal 0, calls
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, document["prompt_sha256"]
    assert_operator BigDecimal(document["ceiling_usd"]), :<=, BigDecimal("1")
  end

  test "a simulated high run reserves and sends eight attempts and does not call medium" do
    dir = Dir.mktmpdir
    runs = Dir.mktmpdir
    posts = []
    transport = Object.new
    transport.define_singleton_method(:post) do |body:, api_key:, version:|
      posts << body.dig("output_config", "effort")
      Rag::CompanionHaiku55Compare::Result.new(
        http_status: 200,
        payload: {
          "stop_reason" => "end_turn",
          "content" => [ { "type" => "text", "text" => "Simulación de cierre." } ],
          "usage" => {
            "input_tokens" => 20,
            "output_tokens" => 8,
            "cache_creation_input_tokens" => 0,
            "cache_read_input_tokens" => 0,
            "service_tier" => "standard",
            "inference_geo" => "global"
          }
        },
        retry_after: nil, error_code: nil, error_message: nil, partial: false
      )
    end
    ladder = Rag::CompanionVerticalLadder.new(
      output_root: dir, budget: BigDecimal("1"), credential: "local", transport: transport, io: StringIO.new
    )
    ladder.runs_root = runs

    assert_equal 0, ladder.execute_high
    ceiling = JSON.parse(File.read(File.join(dir, "ceiling.json")))
    summary = JSON.parse(File.read(File.join(dir, "summary.json")))
    ledger = File.readlines(File.join(dir, "attempts.jsonl")).map { |line| JSON.parse(line) }
    reserved = ledger.select { |event| event["event"] == "reserved" }

    assert_equal [ [ "guion2", "high" ], [ "guion1", "high" ] ], ceiling["scripts"]
    assert_equal ceiling["scripts"], summary["runs"].map { |row| [ row["script"], row["effort"] ] }
    assert_equal 8, ceiling["generations"]
    assert_equal 8, posts.size
    assert_equal [ "high" ], posts.uniq
    assert_equal 8, reserved.size
    assert_equal [ 1 ], reserved.pluck("attempt").uniq
    assert_equal 8, summary["calls"]
  end

  test "archived turns separate the literal quote, the dropped condition, and the unnecessary question" do
    archive = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55")
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    old_t1 = (archive / "guion2-high/turn-1/published.txt").read
    new_t1 = (archive / "citation_prompt_20261105/guion2-high/turn-1/published.txt").read
    old_t3 = (archive / "guion2-high/turn-3/published.txt").read
    new_t3 = (archive / "citation_prompt_20261105/guion2-high/turn-3/published.txt").read
    new_t5 = (archive / "citation_prompt_20261105/guion1-high/turn-5/published.txt").read
    request = JSON.parse((archive / "citation_prompt_20261105/guion1-high/turn-5/request.json").read)
    current = request.dig("body", "messages").last.dig("content", 0, "text")

    assert_empty ladder.send(:judge_guion2, 1, old_t1)
    assert_includes ladder.send(:judge_guion2, 1, new_t1), "t1:missing_slow_opening"
    assert_includes ladder.send(:judge_guion2, 1, new_t1), "t1:procedure_drops_condition"
    assert_not_includes ladder.send(:judge_guion2, 1, new_t1), "t1:autoajuste_if_still_slow"
    assert_empty ladder.send(:judge_guion2, 3, old_t3)
    assert_includes ladder.send(:judge_guion2, 3, new_t3), "t3:unnecessary_question"
    assert_includes ladder.send(:judge_guion2, 3, new_t3), "t3:reopens_denied_scope"
    assert_includes current, "No sé cómo identificar si está activada la entrada #21"
    assert_includes ladder.send(:judge_guion1, 5, new_t5), "t5:reasks_identification"
    assert_includes ladder.send(:judge_guion1, 5, new_t5), "t5:misses_unknown"
  end

  test "the guion 1 turn 2 capture is rejected because it tells the technician to consult the manufacturer" do
    archive = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/citation_prompt_20261105/guion1-high/turn-2")
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    published = ladder.send(:publish_answer, ladder.assemble("guion1", 2, []), archive.join("raw.txt").read, "end_turn")
    consultation = published["reasons"].select { |reason| reason["rule"] == "R3" }

    assert_equal [ "Confírmela con el fabricante antes de ajustar" ], consultation.pluck("detail")
    assert_includes archive.join("raw.txt").read, "60 a 150Nm"
    assert_equal false, published["accepted"]
  end

  test "high validation reserves eight generations and keeps the prior ledgers apart" do
    dir = Dir.mktmpdir
    calls = 0
    transport = Object.new
    transport.define_singleton_method(:post) { calls += 1 }
    code = Rag::CompanionVerticalLadder.new(
      output_root: dir, budget: BigDecimal("0"), transport: transport, credential: "local"
    ).execute_high

    assert_equal 2, code
    assert_equal 0, calls
    ceiling = JSON.parse(File.read(File.join(dir, "ceiling.json")))
    assert_equal 8, ceiling["generations"]
    assert_equal [ [ "guion2", "high" ], [ "guion1", "high" ] ], ceiling["scripts"]
    assert_equal "0.000000", ceiling["spent_at_open_usd"]
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, ceiling["prompt_sha256"]
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, ceiling["historical_prompt_sha256"]
    assert_equal Rag::CompanionVerticalLadder::CITATION_PROMPT_SHA, ceiling["historical_citation_prompt_sha256"]
  end

  test "guion 2 keeps a denied configuration closed and guion 1 t5 keeps an unknown identification" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    reopened = "No hace falta repetir el autoajuste. ¿Los parámetros siguen siendo los de fábrica?"
    closed = "No hace falta repetir el autoajuste. «Solo es necesario realizar otra vez el autoajuste para la configuración de los parámetros por defecto o cuando se realicen cambios como la conexión o desconexión de la fotocélula Fermator»."
    assert_includes ladder.send(:judge_guion2, 3, reopened), "t3:reopens_denied_scope"
    assert_empty ladder.send(:judge_guion2, 3, closed)

    asked = "¿Qué hay conectado entre 21 y 23?"
    recognized = "Ya indicaste que no puedes identificar #21 ni el contacto entre #21 y #23. Cómo medirlo no está en la documentación cargada en este turno."
    assert_includes ladder.send(:judge_guion1, 5, asked), "t5:reasks_identification"
    assert_includes ladder.send(:judge_guion1, 5, asked), "t5:misses_unknown"
    assert_empty ladder.send(:judge_guion1, 5, recognized)
  end

  test "guion 2 flags a factory state that would force autoajuste and still allows the documented action" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    stated = "Si el equipo tiene los parámetros de fábrica, hay que repetir el autoajuste."
    distinguished = "Solo es necesario repetir el autoajuste para la configuración de los parámetros por defecto. Que el equipo tenga ahora esos valores es un estado, no esa acción."

    assert_includes ladder.send(:judge_guion2, 3, stated), "t3:factory_state_requires_repeat"
    assert_not_includes ladder.send(:judge_guion2, 3, stated), "t3:unnecessary_question"
    assert_empty ladder.send(:judge_guion2, 3, distinguished)
  end

  test "guion 1 t5 separates a measurement mention from a request and checks the diagram qualifiers" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    mention = "No puedo identificar qué borne recibe #21. La documentación cargada no explica cómo medir el contacto entre #21 y #23."
    request = "¿Hay algún cable o contacto conectado a 21 o 23?"
    definition = 'Para activar la re-apertura, "se debe conectar la entrada re-apertura (21) con la entrada de +12V (23). Utilizar contactos libres de tensión." [4]'
    requirement = "#{definition}\nPrecaución general: la entrada debe recibir un contacto libre de tensión."
    diagram = "No puedo identificar qué borne de INPUTS recibe la línea de #21 o #23. El dibujo no lo indica."
    pending = "Para orientar, necesito saber qué LED está encendido: Fotocélula o Estado."
    given = [ "El LED encendido es el de Fotocélula." ]

    mention_reading = ladder.send(:t5_assessment, mention)
    assert_not_includes ladder.send(:judge_guion1, 5, mention), "t5:reasks_identification"
    assert_equal false, mention_reading.dig("technician_limitation", "recognized")
    assert_equal true, mention_reading.dig("method_limit", "present")
    assert_includes ladder.send(:judge_guion1, 5, mention), "t5:misses_unknown"
    withdrawal = "Retiro mi sugerencia anterior de comprobar 21 con 23 como paso. No hace falta que la identifiques para seguir."
    quoted = "Dijiste «qué hay conectado entre 21 y 23» y no lo repito."
    measure = "Las fuentes no dicen cómo medir la entrada #21."
    unable = "No puedo indicarte cómo identificar la entrada #21 ni el contacto."
    commission = "Podrías localizar qué cables llegan a esos bornes y comprobar si el LED cambia al aislar uno de ellos."
    led_only = "Pregunta: ¿el LED encendido es el de FOTOCÉLULA?"
    assert_equal false, ladder.send(:t5_assessment, withdrawal).dig("identification_request", "present")
    assert_equal true, ladder.send(:t5_assessment, withdrawal).dig("technician_limitation", "recognized")
    assert_equal false, ladder.send(:t5_assessment, quoted).dig("identification_request", "present")
    assert_equal false, ladder.send(:t5_assessment, measure).dig("technician_limitation", "recognized")
    assert_equal true, ladder.send(:t5_assessment, measure).dig("method_limit", "present")
    assert_equal false, ladder.send(:t5_assessment, unable).dig("technician_limitation", "recognized")
    assert_includes ladder.send(:t5_assessment, unable).dig("method_limit", "phrase"), "No puedo indicarte cómo identificar"
    assert_equal "commission", ladder.send(:t5_assessment, commission).dig("identification_request", "kind")
    assert_equal "pending", ladder.send(:t5_assessment, led_only, technician_texts: [ "El LED está encendido." ]).dig("led", "status")
    assert_includes ladder.send(:t5_assessment, led_only).dig("led", "phrase"), "¿el LED encendido es el de FOTOCÉLULA?"
    assert_includes ladder.send(:judge_guion1, 5, request), "t5:reasks_identification"
    assert_not_includes ladder.send(:judge_guion1, 5, definition), "t5:drops_normally_open"
    assert_includes ladder.send(:judge_guion1, 5, requirement), "t5:drops_normally_open"
    assert_includes ladder.send(:judge_guion1, 5, diagram), "t5:misreads_priority_inputs"
    pending_led = ladder.send(:led_datum, pending, [ "El LED está encendido." ])
    assert_equal "pending", pending_led["status"]
    assert_equal true, pending_led["useful"]
    assert_includes ladder.send(:judge_guion1, 5, pending, technician_texts: given), "t5:repeats_led"
    assert_not_includes ladder.send(:judge_guion1, 5, pending, technician_texts: [ "El LED está encendido." ]), "t5:repeats_led"
  end

  test "closure captures change publication only where the revised gate attaches the marker or the label" do
    archive = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55/closure_base_0bf3610b")
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    prior = []
    guion1 = (1..5).to_h { |number|
      raw = (archive / "guion1-high/turn-#{number}/raw.txt").read
      old = JSON.parse((archive / "guion1-high/turn-#{number}/gate.json").read)["accepted"]
      now = ladder.send(:publish_answer, ladder.assemble("guion1", number, prior), raw, "end_turn")
      prior << { question: Rag::CompanionVerticalLadder::GUION1_QUESTIONS[number - 1], published: "historial" }
      [ number, { "old" => old, "now" => now["accepted"] } ]
    }

    assert_equal false, guion1[1]["now"]
    assert_equal false, guion1[1]["old"]
    assert_equal true, guion1[2]["now"]
    assert_equal true, guion1[3]["now"]
    assert_equal false, guion1[3]["old"]
    assert_equal true, guion1[4]["now"]
    assert_equal false, guion1[4]["old"]
    assert_equal true, guion1[5]["now"]
    published = (archive / "guion1-high/turn-5/published.txt").read
    judged = ladder.send(:judge_guion1, 5, published, technician_texts: Rag::CompanionVerticalLadder::GUION1_QUESTIONS)
    closure_reading = ladder.send(:t5_assessment, published, technician_texts: Rag::CompanionVerticalLadder::GUION1_QUESTIONS)
    assert_not_includes judged, "t5:reasks_identification"
    assert_includes judged, "t5:misses_unknown"
    assert_equal false, closure_reading.dig("technician_limitation", "recognized")
    assert_includes closure_reading.dig("method_limit", "phrase"), "No puedo identificar"
    assert_includes judged, "t5:misreads_priority_inputs"
    assert_includes judged, "t5:drops_normally_open"
    assert_equal "pending", closure_reading.dig("led", "status")
    assert_equal true, closure_reading.dig("led", "useful")
  end

  test "the adjustment ceiling prices twenty four high generations before any call" do
    dir = Dir.mktmpdir
    calls = 0
    transport = Object.new
    transport.define_singleton_method(:post) { calls += 1 }
    ladder = Rag::CompanionVerticalLadder.new(
      output_root: dir, budget: BigDecimal("0"), transport: transport, credential: "local"
    )
    code = ladder.execute_adjustment

    assert_equal 2, code
    assert_equal 0, calls
    ceiling = JSON.parse(File.read(File.join(dir, "ceiling.json")))
    assert_equal 24, ceiling["generations"]
    assert_equal 0, ceiling["medium_generations"]
    assert_equal "high", ceiling["effort"]
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, ceiling["product_prompt_sha256"]
    assert_equal Rag::CompanionVerticalLadder::VARIANT_PROMPT_SHA, ceiling["variant_prompt_sha256"]
    assert_equal [ [ "A", 1 ], [ "B", 1 ], [ "B", 2 ] ], ceiling["passes"]
  end

  test "a simulated adjustment reserves twenty four high attempts and does not call medium" do
    dir = Dir.mktmpdir
    posts = []
    transport = Object.new
    transport.define_singleton_method(:post) do |body:, api_key:, version:|
      posts << body.dig("output_config", "effort")
      Rag::CompanionHaiku55Compare::Result.new(
        http_status: 200, payload: {
          "stop_reason" => "end_turn",
          "content" => [ { "type" => "text", "text" => "Simulación de ajuste." } ],
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
    ).execute_adjustment
    ceiling = JSON.parse(File.read(File.join(dir, "ceiling.json")))
    summary = JSON.parse(File.read(File.join(dir, "summary.json")))
    ledger = File.readlines(File.join(dir, "attempts.jsonl")).map { |line| JSON.parse(line) }
    reserved = ledger.select { |event| event["event"] == "reserved" }

    assert_equal 0, code
    assert_equal 24, ceiling["generations"]
    assert_equal 24, posts.size
    assert_equal [ "high" ], posts.uniq
    assert_equal 24, reserved.size
    assert_equal [ 1 ], reserved.pluck("attempt").uniq
    assert_equal 24, summary["calls"]
    assert_equal 0, summary["medium_generations"]
    assert_equal BigDecimal(ceiling["ceiling_usd"]) <= BigDecimal("1"), true
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, Digest::SHA256.hexdigest(File.read(Rag::CompanionDirectAnswer::SYSTEM_PROMPT_PATH))
    control = JSON.parse(File.read(File.join(dir, "A/guion2-high/turn-1/request.json")))
    variant = JSON.parse(File.read(File.join(dir, "B1/guion2-high/turn-1/request.json")))
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, Digest::SHA256.hexdigest(control.dig("body", "system", 0, "text"))
    assert_equal Rag::CompanionVerticalLadder::VARIANT_PROMPT_SHA, Digest::SHA256.hexdigest(variant.dig("body", "system", 0, "text"))
  end

  test "eight archived turn 5 answers keep the technician limit apart from the method limit" do
    root = Pathname("/Users/lahirisan/smart_deal-vertical-artifacts/20261105/vf5_vertical_haiku55")
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    texts = Rag::CompanionVerticalLadder::GUION1_QUESTIONS
    expected = {
      "high" => { "tech" => false, "method" => true, "request" => nil, "led" => "pending" },
      "medium" => { "tech" => false, "method" => true, "request" => "request", "led" => "pending" },
      "max" => { "tech" => false, "method" => false, "request" => nil, "led" => nil },
      "citation" => { "tech" => false, "method" => true, "request" => "question", "led" => nil },
      "closure" => { "tech" => false, "method" => true, "request" => nil, "led" => "pending" },
      "A" => { "tech" => false, "method" => true, "request" => "commission", "led" => "pending" },
      "B1" => { "tech" => true, "method" => true, "request" => nil, "led" => "pending" },
      "B2" => { "tech" => false, "method" => false, "request" => nil, "led" => nil }
    }
    paths = {
      "high" => root / "guion1-high/turn-5/published.txt",
      "medium" => root / "guion1-medium/turn-5/published.txt",
      "max" => root / "guion1-max/turn-5/published.txt",
      "citation" => root / "citation_prompt_20261105/guion1-high/turn-5/published.txt",
      "closure" => root / "closure_base_0bf3610b/guion1-high/turn-5/published.txt",
      "A" => root / "opus_adjustment/A/guion1-high/turn-5/published.txt",
      "B1" => root / "opus_adjustment/B1/guion1-high/turn-5/published.txt",
      "B2" => root / "opus_adjustment/B2/guion1-high/turn-5/published.txt"
    }
    paths.each do |name, path|
      reading = ladder.send(:t5_assessment, path.read, technician_texts: texts)
      want = expected.fetch(name)
      assert_equal want["tech"], reading.dig("technician_limitation", "recognized"), name
      assert_equal want["method"], reading.dig("method_limit", "present"), name
      if want["request"].nil?
        assert_nil reading.dig("identification_request", "kind"), name
      else
        assert_equal want["request"], reading.dig("identification_request", "kind"), name
      end
      if want["led"].nil?
        assert_nil reading.dig("led"), name
      else
        assert_equal want["led"], reading.dig("led", "status"), name
        assert_equal true, reading.dig("led", "useful"), name
      end
    end

    raw_max = ladder.send(:t5_assessment, (root / "guion1-max/turn-5/raw.txt").read, technician_texts: texts)
    raw_b2 = ladder.send(:t5_assessment, (root / "opus_adjustment/B2/guion1-high/turn-5/raw.txt").read, technician_texts: texts)
    assert_equal true, raw_max.dig("method_limit", "present")
    assert_equal false, raw_max.dig("technician_limitation", "recognized")
    assert_equal "pending", raw_max.dig("led", "status")
    assert_includes raw_b2.dig("method_limit", "phrase"), "No puedo indicarte cómo identificar"
    assert_equal false, raw_b2.dig("technician_limitation", "recognized")
    assert_equal false, raw_b2.dig("identification_request", "present")
    assert_equal "pending", raw_b2.dig("led", "status")
    assert_includes ladder.send(:t5_assessment, (root / "opus_adjustment/A/guion1-high/turn-5/published.txt").read).dig("identification_request", "phrase"), "localizar"
    assert_includes ladder.send(:t5_assessment, (root / "opus_adjustment/B1/guion1-high/turn-5/published.txt").read).dig("technician_limitation", "phrase"), "no hace falta que la identifiques"
  end

  test "a persistent slow opening that orders autoajuste fails guion 2" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    bad = "Si la apertura lenta persiste, realiza el autoajuste."
    good = "#{Rag::CompanionDirectCaptureReplay::SLOW} Si sigue lenta: Esto no está en la documentación cargada en este turno."
    assert_includes ladder.send(:judge_guion2, 1, bad), "t1:autoajuste_if_still_slow"
    assert_empty ladder.send(:judge_guion2, 1, good)
  end
end
