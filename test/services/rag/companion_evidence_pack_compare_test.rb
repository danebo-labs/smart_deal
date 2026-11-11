# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/companion_evidence_pack_compare")

class Rag::CompanionEvidencePackCompareTest < ActiveSupport::TestCase
  Pack = Rag::CompanionEvidencePackCompare
  Archive = Pack::ARCHIVE

  test "stripping B restores A and the request is unchanged outside the evidence" do
    require_historical_capture(Archive.join("guion1-high/turn-2/request.json"))
    Pack::CASES.each do |spec|
      pair = Pack.build_pair(Pack.case_request(spec))
      original = text_of(pair["a"])
      packed = text_of(pair["b"])

      assert_equal original, Pack.strip_annotations(packed), spec["id"]
      assert_equal JSON.generate(Pack.outside_evidence(pair["a"])), JSON.generate(Pack.outside_evidence(pair["b"])), spec["id"]
      assert_equal Pack::SYSTEM_SHA, pair["system_sha256"], spec["id"]
      assert_not_includes original, "[CONTEXTO"
      assert_equal 48_000, pair["a"].dig("body", "max_tokens")
      assert_equal pair["a"].dig("body", "model"), pair["b"].dig("body", "model")
      assert_equal pair["a"].dig("body", "thinking"), pair["b"].dig("body", "thinking")
      assert_equal pair["a"].dig("body", "output_config"), pair["b"].dig("body", "output_config")
      assert_equal false, pair["b"].dig("body").key?("temperature")
      assert_equal pair["a"].dig("body", "messages")[0..-2], pair["b"].dig("body", "messages")[0..-2]
    end
  end

  test "section 5.5 keeps entries 21 and 23 on the normally open passage" do
    require_historical_capture(Archive.join("guion1-high/turn-5/request.json"))
    packed = text_of(Pack.build_pair(Pack.load_request("guion1", 5))["b"])
    passage = packed[/\[CONTEXTO 4 \| 5\.5 Otras entradas \(26, 21, 25, 23\) \| 23\.- \+ 12 V\. COM \| 7\]\n.*normalmente abierto\./m]

    assert_includes packed, "[CONTEXTO 4 | 5.5 Otras entradas (26, 21, 25, 23) | 21.- Re-apertura | 7]"
    assert_includes packed, "[CONTEXTO 4 | 5.5 Otras entradas (26, 21, 25, 23) | 23.- + 12 V. COM | 7]"
    assert_includes passage, "Se debe usar siempre contactos libres de tensión y normalmente abierto."
    assert_not_includes packed, "[CONTEXTO 4 | 23.- + 12 V. COM |"
    assert_not_includes packed, "[CONTEXTO 4 | 21.- Re-apertura |"
  end

  test "the TEST step keeps the reopen item and page 13" do
    require_historical_capture(Archive.join("guion1-high/turn-2/request.json"))
    packed = text_of(Pack.build_pair(Pack.load_request("guion1", 2))["b"])
    step = "En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST."

    assert_includes packed, "[CONTEXTO 1 | 8.2 Funcionamiento normal | La puerta se re-abre sola. | 13]\n– #{step}"
    assert_includes packed, step
  end

  test "section 5.8 stays apart from the 35 cm branch" do
    require_historical_capture(Archive.join("guion2-high/turn-1/request.json"))
    packed = text_of(Pack.build_pair(Pack.load_request("guion2", 1))["b"])
    slow = "Las puertas se abrirán lentamente en la primera operación después de un fallo de alimentación para verificar el paso libre."
    branch = "Este es el paso libre de un controlador que no ha sido ajustado."
    lines = packed.lines
    slow_index = lines.index { |line| line.include?(slow) }
    branch_index = lines.index { |line| line.include?(branch) }

    assert_equal "[CONTEXTO 1 | 5.8 Pulsador de autoajuste (51) |  | 8.0]\n", lines[slow_index - 1]
    assert_equal "[CONTEXTO 9 | 8.2 Funcionamiento normal | La puerta solo cierra 35 cm. | 12.0]\n", lines[branch_index - 1]
    assert_not_includes lines[slow_index - 1], "35 cm"
    assert_not_includes lines[branch_index - 1], "5.8"
  end

  test "the conflict and the extraction note stay literal" do
    require_historical_capture(Archive.join("guion1-high/turn-4/request.json"))
    fourth = Pack.build_pair(Pack.load_request("guion1", 4))
    fifth = Pack.build_pair(Pack.load_request("guion1", 5))
    conflict = text_of(fourth["a"]).lines.find { |line| line.include?("[CONFLICTO_DOCUMENTAL C2:") }
    note = text_of(fifth["a"]).lines.find { |line| line.include?("[NOTA_EXTRACCION]") }

    assert_includes text_of(fourth["b"]), conflict
    assert_includes text_of(fourth["b"]), "[CONTEXTO"
    assert_includes text_of(fifth["b"]), note
    assert_includes note, "DATA_NOT_AVAILABLE"
    assert_not_includes text_of(fifth["b"]).sub(note, ""), note
  end

  test "an entry without a parent section is left unannotated" do
    message = sample_message("[1] Manual, página 3\n4.- Entrada\nTexto del apartado.\n")
    packed = Pack.pack_sources(message)

    assert_not_includes packed, "[CONTEXTO"
    assert_equal message, Pack.strip_annotations(packed)
  end

  test "an entry under a section keeps both levels" do
    message = sample_message("[1] Manual, página 4\n9.1 Sección padre\n 4.- Entrada hija\nTexto que sigue a la entrada.\n")
    packed = Pack.pack_sources(message)

    assert_includes packed, "[CONTEXTO 1 | 9.1 Sección padre | 4.- Entrada hija | 4]\nTexto que sigue a la entrada."
    assert_equal message, Pack.strip_annotations(packed)
  end

  test "three hierarchy levels leave the passage unannotated" do
    message = sample_message("[1] Manual, página 4\n9.1 Sección padre\n 4.- Entrada hija\n• Apartado concreto.\n– Paso condicionado.\n")
    packed = Pack.pack_sources(message)

    assert_not_includes packed, "[CONTEXTO"
    assert_includes packed, "– Paso condicionado."
    assert_equal message, Pack.strip_annotations(packed)
  end

  test "the YS-K01 rows stay intact in both arms" do
    require_historical_capture(Archive.join("guion2-high/turn-1/request.json"))
    pair = Pack.build_pair(Pack.case_request({ "id" => "ys-k01" }))
    original = text_of(pair["a"])
    packed = text_of(pair["b"])

    assert_equal original, packed
    assert_includes original, Pack::YS_QUESTION
    assert_includes original, "begining"
    assert_includes original, "Deceleartion"
    assert_includes original, "It is normal state of power on and power off"
    assert_includes original, "DC bus overvoltage"
    assert_equal 1, original.lines.count { |line| line.start_with?("| -Lu- |") }
    assert_equal 1, original.lines.count { |line| line.start_with?("| E001 |") }
    pdf = Pathname("/Users/lahirisan/Documents/Danebo/Danebo RAG elevator  Agosto/Manuales Gonzalo/FUJI YIDA/yida/enviar a servicio fabrimetal/E-Shine YS-K01 door operator.pdf")
    if pdf.file?
      assert_equal "0f846aea3abd8ddc26b0ce0b06bc884535f1c6a42e6f7f329b779175b3ec58e9", Digest::SHA256.file(pdf).hexdigest
    end
  end

  test "the frozen rubric fails the archived answers and accepts faithful paraphrases" do
    require_historical_capture(Archive.join("guion1-high/turn-2/published.txt"))
    archived = {
      "g1-t2" => (Archive / "guion1-high/turn-2/published.txt").read,
      "g2-t1" => (Archive / "guion2-high/turn-1/published.txt").read,
      "g1-t4" => (Archive / "guion1-high/turn-4/published.txt").read,
      "g1-t5" => (Archive / "guion1-high/turn-5/published.txt").read
    }
    faithful = {
      "g1-t2" => "El paso de pulsar TEST pertenece a la reapertura y solo vale si el problema persiste: desconecta la fotocélula y pulsa TEST. El LED de obstrucción por sí solo no autoriza ese paso.",
      "g2-t1" => "Tras un corte de alimentación, la primera apertura es lenta para verificar el paso libre. El autoajuste se repite para la configuración de los parámetros por defecto, o si se conecta o desconecta la fotocélula. Si la puerta solo cierra 35 cm, esa es otra rama y no la aplico a este caso.",
      "g1-t4" => "Hay una contradicción: una fuente llama OPEN al #8 y cerrado al #12, y otra asigna CLOSE al 8 y OPEN al 12. No te indico ese paso. La orientación que sí sigue es revisar el #54.",
      "g1-t5" => "Para ordenar la reapertura hacen falta contactos libres de tensión y normalmente abierto entre 21 y 23. No hace falta que identifiques si está activada. ¿Ves un cable en el borne 21?"
    }
    examples = {
      "ys-k01" => "E001 es sobretensión del bus al encender. No es el estado normal. La fila -Lu- es la que describe el estado normal de encendido y apagado. El manual no confirma una causa.",
      "ys-normal" => "E001 es normal al encender, igual que la fila -Lu-.",
      "ys-cause" => "E001 es sobretensión y ya se comprobó que la tensión de entrada es la causa."
    }

    archived.each do |case_id, text|
      assert_equal false, Pack::Rubric.evaluate(case_id, text)["pass"], case_id
    end
    faithful.each do |case_id, text|
      assert_equal true, Pack::Rubric.evaluate(case_id, text)["pass"], case_id
    end
    assert_equal true, Pack::Rubric.evaluate("g2-t1", archived["g2-t1"])["criteria"]["thirty_five_not_applied"]["pass"]
    assert_equal false, Pack::Rubric.evaluate("g2-t1", archived["g2-t1"])["criteria"]["default_parameters_intact"]["pass"]
    assert_equal true, Pack::Rubric.evaluate("g1-t5", archived["g1-t5"])["criteria"]["not_recommissioned"]["pass"]
    assert_equal false, Pack::Rubric.evaluate("g1-t5", archived["g1-t5"])["criteria"]["normally_open"]["pass"]
    limitation = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    assert_equal false, limitation.send(:technician_limitation, archived["g1-t5"])["recognized"]
    assert_equal true, limitation.send(:technician_limitation, faithful["g1-t5"])["recognized"]
    assert_equal true, Pack::Rubric.evaluate("ys-k01", examples["ys-k01"])["pass"]
    assert_equal false, Pack::Rubric.evaluate("ys-k01", examples["ys-normal"])["pass"]
    assert_equal false, Pack::Rubric.evaluate("ys-k01", examples["ys-cause"])["pass"]
  end

  test "the simulated maximum plan sends 28 single attempts at 48000 tokens" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/episode.json")
    dir = Dir.mktmpdir
    posts = []
    transport = scripted_transport(posts)
    runner = Pack::Runner.new(output_root: dir, transport: transport, credential: "local", io: StringIO.new, budget: BigDecimal("100"))
    counts = runner.exercise_maximum_plan(output: dir)
    ledger = File.readlines(File.join(dir, "attempts.jsonl")).map { |line| JSON.parse(line) }
    reserved = ledger.select { |event| event["event"] == "reserved" }

    assert_equal 20, counts["isolated"]
    assert_equal 8, counts["harness"]
    assert_equal 28, posts.size
    assert_equal [ 48_000 ], posts.pluck("max_tokens").uniq
    assert posts.none? { |body| body.key?("temperature") }
    assert_equal [ 1 ], reserved.pluck("attempt").uniq
    assert_equal 28, reserved.size
    diff = JSON.parse(File.read(Dir[File.join(dir, "ab/g1-t2/sample-1/b/request_diff.json")].first))
    assert_equal "identical", diff["outside_evidence"]
    assert diff["inserted_lines"].all? { |line| line.start_with?("[CONTEXTO ") }
    assert_equal 0, runner.send(:retries_allowed)
    assert_nil runner.send(:correct, { "max_tokens" => 48_000 }, "temperature is invalid")
  end

  test "a rejected call is not corrected or retried" do
    require_historical_capture(Archive.join("guion1-high/turn-2/request.json"))
    dir = Dir.mktmpdir
    posts = []
    transport = Object.new
    transport.define_singleton_method(:post) do |body:, api_key:, version:|
      posts << body
      Rag::CompanionHaiku55Compare::Result.new(
        http_status: 400, payload: { "error" => { "type" => "invalid_request_error", "message" => "temperature is invalid" } },
        retry_after: nil, error_code: "http_400", error_message: "temperature is invalid", partial: false
      )
    end
    runner = Pack::Runner.new(output_root: dir, transport: transport, credential: "local", io: StringIO.new, budget: BigDecimal("100"))
    runner.send(:boot, "100")
    calls = runner.send(:run_isolated, "local")

    assert_equal 1, posts.size
    assert_equal 48_000, posts.first["max_tokens"]
    assert_equal "failed", calls.first["status"]
    assert_equal 1, calls.first["attempts"]
  end

  test "the anthropic balance dedupes the copied ledger and uses the one dollar pool" do
    require_historical_capture(Archive.join("guion1-high/turn-2/request.json"))
    balance = Pack::Runner.new(output_root: Dir.mktmpdir, budget: BigDecimal("1")).anthropic_balance

    assert_operator balance["balance"], :<, Pack::AUTHORIZED_ANTHROPIC
    assert_operator balance["balance"], :>, 0
    assert balance["duplicates"].any?
    assert balance["other_pool"].any? { |row| row["pool"] == "anthropic_0_30" }
    assert_equal Pack::AUTHORIZED_ANTHROPIC - balance["spent"], balance["balance"]
  end

  private

  def text_of(request)
    request.dig("body", "messages", -1, "content", 0, "text")
  end

  def sample_message(evidence)
    "Mensaje de este turno:\nPregunta de prueba\n\nFuentes de este turno:\n#{evidence}"
  end

  def scripted_transport(posts)
    transport = Object.new
    transport.define_singleton_method(:post) do |body:, api_key:, version:|
      posts << body
      Rag::CompanionHaiku55Compare::Result.new(
        http_status: 200,
        payload: {
          "stop_reason" => "end_turn",
          "content" => [ { "type" => "text", "text" => "Simulación de cierre." } ],
          "usage" => {
            "input_tokens" => 20, "output_tokens" => 8,
            "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0,
            "service_tier" => "standard", "inference_geo" => "global"
          }
        },
        retry_after: nil, error_code: nil, error_message: nil, partial: false
      )
    end
    transport
  end
end
