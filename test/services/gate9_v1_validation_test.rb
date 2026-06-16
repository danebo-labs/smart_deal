# frozen_string_literal: true

require "test_helper"

class Gate9V1ValidationTest < ActiveSupport::TestCase
  setup do
    @manual = build_pdf(24, "gate9-manual")
    @sync_pdf = build_pdf(3, "gate9-sync")
    @photos = 7.times.map do |index|
      write_file("photo-#{index}.jpg", test_image(".jpg", index))
    end
    opus = test_image(".png", 8)
    opus << "x" * (FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD + 1 - opus.bytesize)
    @photos << write_file("opus.png", opus)
  end

  test "preflight accepts the bounded V1 cohort without paid calls" do
    validation = build_validation

    preflight = validation.preflight!

    assert_equal 1.36, preflight[:expected_total_cost_usd]
    assert_equal 1.50, preflight[:budget_usd]
    assert_equal 24, preflight.dig(:inputs, :manual, :pages)
    assert_equal 3, preflight.dig(:inputs, :sync_pdf, :pages)
    assert_equal 8, preflight.dig(:inputs, :photos).size
    assert_includes preflight.dig(:routing, :photo_routes).values, :opus
    assert preflight.dig(:inputs, :photos).all? { |photo| photo[:width] == 4 && photo[:height] == 3 }
  end

  test "manual-only preflight requires only the 24-page manual and reserves one retry" do
    validation = build_validation({
      "GATE9_V1_MODE" => "manual_only",
      "GATE9_V1_SYNC_PDF" => nil,
      "GATE9_V1_PHOTOS" => nil
    })

    preflight = validation.preflight!

    assert_equal "manual_only", preflight[:mode]
    assert_equal({ manual_batch: 1.20 }, preflight[:expected_stage_costs])
    assert_equal 1.20, preflight[:expected_total_cost_usd]
    assert_equal [ :manual ], preflight[:inputs].keys
    assert_empty preflight.dig(:routing, :photo_routes)
  end

  test "preflight rejects a dirty tree" do
    validation = build_validation(git_status_loader: -> { " M app/example.rb\n" })

    error = assert_raises(Gate9V1Validation::PreflightError) { validation.preflight! }

    assert_includes error.message, "git working tree must be clean"
  end

  test "preflight rejects duplicate photo binaries" do
    duplicate_paths = Array.new(8) { @photos.first }
    validation = build_validation({ "GATE9_V1_PHOTOS" => duplicate_paths.join(",") })

    error = assert_raises(Gate9V1Validation::PreflightError) { validation.preflight! }

    assert_includes error.message, "photo cohort must contain unique binaries"
  end

  test "preflight rejects a budget below the conservative estimate" do
    validation = build_validation({ "GATE9_V1_BUDGET_USD" => "1.35" })

    error = assert_raises(Gate9V1Validation::PreflightError) { validation.preflight! }

    assert_includes error.message, "estimated cohort cost exceeds budget"
  end

  test "semantic evidence matching does not depend on generated record ids" do
    expected = {
      "record_id" => "FR-OLD",
      "type" => "STOP_WORK_CONDITION",
      "source" => "Prueba de funcionamiento",
      "action" => "Marcar y detener la máquina si ocurre un mal funcionamiento",
      "expected_result" => "Máquina detenida hasta reparación",
      "stop_trigger" => "mal funcionamiento detectado",
      "stop_action" => "marcar y detener la máquina",
      "evidence" => "la máquina debe marcarse y detenerse"
    }
    actual = Rag::FieldRecordParser::Record.new(
      record_id: "FR-NEW",
      type: "STOP_WORK_CONDITION",
      source: "Prueba de funcionamiento",
      action: "Si ocurre un mal funcionamiento, marcar y detener la máquina",
      expected_result: "La máquina queda detenida hasta reparación",
      stop_trigger: "mal funcionamiento detectado",
      stop_action: "marcar y detener la máquina",
      evidence: "la máquina debe marcarse y detenerse"
    )

    match = build_validation.send(:semantic_matches, [ expected ], [ actual ]).sole

    assert_equal "FR-NEW", match[:matched_id]
    assert_operator match[:score], :>=, 0.6
  end

  test "stop-work semantic matching preserves B3 mandatory paraphrases" do
    pairs = [
      [
        {
          "record_id" => "FR-480A25A947279253",
          "type" => "STOP_WORK_CONDITION",
          "source" => "Principio básico",
          "action" => "Inspeccionar la máquina en busca de daños o cambios no autorizados en el estado de fábrica.",
          "expected_result" => "Si se encuentran daños o cambios no autorizados en el estado de fábrica, " \
            "la máquina debe marcarse y detenerse.",
          "stop_trigger" => "daños o cambios no autorizados en el estado de fábrica",
          "stop_action" => "la máquina debe marcarse y detenerse",
          "evidence" => "la máquina debe marcarse y detenerse"
        },
        parsed_field_record(
          record_id: "FR-148BB87FA0EB098B",
          source: "2.2 Comprobación previa a la operación — Principio básico",
          action: "Si se encuentran daños o cambios no autorizados en el estado de fábrica, " \
            "marcar la máquina y detenerla.",
          expected_result: "Máquina marcada y detenida hasta resolución.",
          stop_trigger: "daños o cambios no autorizados en el estado de fábrica",
          stop_action: "detener y marcar la máquina",
          evidence: "la máquina debe marcarse y detenerse"
        )
      ],
      [
        {
          "record_id" => "FR-16CA529ADAF49091",
          "type" => "STOP_WORK_CONDITION",
          "source" => "(continuación de página anterior)",
          "action" => "Verificar que la pendiente medida no supere la pendiente máxima ni la " \
            "clasificación de pendiente lateral.",
          "expected_result" => "Si la pendiente supera la pendiente máxima o la clasificación de pendiente " \
            "lateral, la máquina debe levantarse o transportado hacia arriba y hacia abajo a lo largo de la rampa.",
          "stop_trigger" => "pendiente supera pendiente máxima o clasificación de pendiente lateral",
          "stop_action" => "no operar; levantar o transportar por la rampa; consultar sección Transporte y elevación",
          "evidence" => "la máquina debe levantarse o transportado hacia arriba y hacia abajo a lo largo de la rampa"
        },
        parsed_field_record(
          record_id: "FR-20474BC5853A2F7E",
          source: "Determinar el gradiente",
          action: "Verificar que la pendiente no supere la pendiente máxima ni la clasificación de pendiente " \
            "lateral antes de operar la máquina.",
          expected_result: "Si la pendiente supera los límites, la máquina debe levantarse o transportarse " \
            "hacia arriba y hacia abajo a lo largo de la rampa — no operar en desplazamiento propio.",
          stop_trigger: "pendiente supera la pendiente máxima o la clasificación de pendiente lateral",
          stop_action: "la máquina debe levantarse o transportado — consulte sección Transporte y elevación",
          evidence: "la máquina debe levantarse o transportado hacia arriba y hacia abajo a lo largo de la rampa"
        )
      ]
    ]
    validation = build_validation

    pairs.each do |expected, actual|
      match = validation.send(:semantic_matches, [ expected ], [ actual ]).sole

      assert_equal actual.record_id, match[:matched_id]
      assert_operator match[:score], :>=, 0.6, expected["record_id"]
    end
  end

  test "stop-work semantic matching preserves distinct control stations" do
    platform_expected = {
      "record_id" => "FR-83721CBE0DF567B8",
      "type" => "STOP_WORK_CONDITION",
      "source" => "Control de plataforma",
      "action" => "Presione el botón de parada de emergencia rojo a la posición \"OFF\"",
      "expected_result" => "Se detienen todas las funciones de la máquina",
      "stop_trigger" => "necesidad de parada de emergencia",
      "stop_action" => "presionar botón rojo a posición OFF",
      "evidence" => "presione el botón de parada de emergencia rojo a la posición \"OFF\" para detener todas las funciones"
    }
    ground_expected = {
      "record_id" => "FR-7CB5544444B37D08",
      "type" => "STOP_WORK_CONDITION",
      "source" => "2.1.1 Controles de tierra — Parada de emergencia",
      "action" => "Presione el botón de parada de emergencia a su posición 'apagado'",
      "expected_result" => "Se detienen todas las funciones",
      "stop_trigger" => "emergencia / necesidad de parada total",
      "stop_action" => "presionar botón rojo a posición apagado",
      "evidence" => "Presione el botón de parada de emergencia a su posición 'apagado' para detener todas las funciones"
    }
    ground_actual = parsed_field_record(
      record_id: "FR-GROUND",
      source: "Controles de tierra — Parada de emergencia",
      action: "Presione el botón de parada de emergencia a su posición 'apagado'",
      expected_result: "Se detienen todas las funciones",
      stop_trigger: "necesidad de parada inmediata",
      stop_action: "detener todas las funciones",
      evidence: "Presione el botón de parada de emergencia a su posición 'apagado' para detener todas las funciones"
    )
    platform_actual = parsed_field_record(
      record_id: "FR-PLATFORM",
      source: "Control de plataforma",
      action: "Presionar el botón de parada de emergencia rojo a la posición \"OFF\"",
      expected_result: "Se detienen todas las funciones de la máquina",
      stop_trigger: "necesidad de detener la máquina",
      stop_action: "presionar botón rojo a posición OFF",
      evidence: "presione el botón de parada de emergencia rojo a la posición \"OFF\" para detener todas las funciones"
    )
    validation = build_validation

    matches = validation.send(
      :semantic_matches,
      [ platform_expected, ground_expected ],
      [ ground_actual, platform_actual ]
    )

    assert_equal "FR-PLATFORM", matches.first[:matched_id]
    assert_operator matches.first[:score], :>=, 0.6
    assert_equal "FR-GROUND", matches.second[:matched_id]
    assert_operator matches.second[:score], :>=, 0.6
    assert_operator validation.send(:evidence_similarity, platform_expected, ground_actual), :<, 0.6
  end

  test "stop-work semantic matching still rejects unrelated safety records" do
    expected = {
      "record_id" => "FR-480A25A947279253",
      "type" => "STOP_WORK_CONDITION",
      "source" => "Principio básico",
      "action" => "Inspeccionar la máquina en busca de daños o cambios no autorizados.",
      "expected_result" => "La máquina debe marcarse y detenerse.",
      "stop_trigger" => "daños o cambios no autorizados en el estado de fábrica",
      "stop_action" => "la máquina debe marcarse y detenerse",
      "evidence" => "la máquina debe marcarse y detenerse"
    }
    unrelated = parsed_field_record(
      record_id: "FR-UNRELATED",
      source: "Carga de batería",
      action: "Conectar el cargador a una toma autorizada.",
      expected_result: "La batería inicia carga.",
      stop_trigger: "batería descargada",
      stop_action: "cargar la batería",
      evidence: "conecte el cargador a la batería"
    )

    score = build_validation.send(:evidence_similarity, expected, unrelated)

    assert_operator score, :<, 0.6
  end

  test "manual batch retries invalid JSON before merge" do
    page_results = [
      {
        page_number: 6,
        text: '{"chunks":[{"text":"unterminated","page":6}',
        model: "claude-sonnet-4-6",
        stop_reason: "end_turn"
      }
    ]
    retry_service = Object.new
    retry_service.define_singleton_method(:retry_failed_pages!) do |page_results:, **|
      page_results.first[:text] = '{"chunks":[{"text":"valid"}]}'
      page_results
    end
    validation = build_validation(
      { "GATE9_V1_MODE" => "manual_only" },
      retry_service: retry_service
    )

    summary = validation.send(
      :retry_manual_pages!,
      page_results,
      s3_key: "manual.pdf",
      filename: "manual.pdf",
      sha256: "a" * 64
    )

    assert_equal [ { page: 6, reason: "invalid_json" } ], summary[:candidates]
    assert_empty summary[:final_failed_pages]
    assert BatchPageRetryService.parseable_json?(page_results.first[:text])
  end

  test "manual batch does not classify recoverable quoted JSON for retry" do
    page_results = [
      {
        page_number: 6,
        text: '{"chunks":[{"text":"Consulte la sección "Etiquetas"","page":6}]}',
        model: "claude-sonnet-4-6",
        stop_reason: "end_turn"
      }
    ]
    retry_service = Object.new
    retry_service.define_singleton_method(:retry_failed_pages!) do |page_results:, **|
      page_results
    end
    validation = build_validation(
      { "GATE9_V1_MODE" => "manual_only" },
      retry_service: retry_service
    )

    summary = validation.send(
      :retry_manual_pages!,
      page_results,
      s3_key: "manual.pdf",
      filename: "manual.pdf",
      sha256: "a" * 64
    )

    assert_empty summary[:candidates]
    assert_equal 0, summary[:calls]
    assert_empty summary[:final_failed_pages]
    assert BatchPageRetryService.parseable_json?(page_results.first[:text])
  end

  private

  def parsed_field_record(record_id:, source:, action:, expected_result:, stop_trigger:, stop_action:, evidence:)
    Rag::FieldRecordParser::Record.new(
      record_id: record_id,
      type: "STOP_WORK_CONDITION",
      source: source,
      action: action,
      expected_result: expected_result,
      stop_trigger: stop_trigger,
      stop_action: stop_action,
      evidence: evidence
    )
  end

  def build_validation(overrides = {}, git_status_loader: -> { "" }, retry_service: nil)
    env = {
      "GATE9_V1_MANUAL" => @manual,
      "GATE9_V1_SYNC_PDF" => @sync_pdf,
      "GATE9_V1_PHOTOS" => @photos.join(","),
      "GATE9_V1_BUDGET_USD" => "1.50",
      "BEDROCK_KNOWLEDGE_BASE_ID" => "test-kb",
      "KNOWLEDGE_BASE_S3_BUCKET" => "test-bucket",
      "BEDROCK_RERANKER_ENABLED" => "false",
      "QUERY_ROUTING_ENABLED" => "false",
      "ANTHROPIC_API_KEY" => "test-key"
    }.merge(overrides)

    Gate9V1Validation.new(
      env: env,
      identity_loader: -> { { account: "123", arn: "arn:test", user_id: "user" } },
      git_status_loader: git_status_loader,
      retry_service: retry_service
    )
  end

  def build_pdf(page_count, name)
    doc = HexaPDF::Document.new
    page_count.times do |index|
      page = doc.pages.add
      page.canvas.font("Helvetica", size: 12)
      page.canvas.text("#{name} page #{index + 1}", at: [ 40, 700 ])
    end
    io = StringIO.new("".b)
    doc.write(io, validate: false)
    write_file("#{name}.pdf", io.string)
  end

  def write_file(name, content)
    path = Rails.root.join("tmp", "test-#{SecureRandom.hex(4)}-#{name}")
    File.binwrite(path, content)
    path.to_s
  end

  def test_image(extension, value)
    Vips::Image.black(4, 3).new_from_image([ value, value, value ]).write_to_buffer(extension)
  end
end
