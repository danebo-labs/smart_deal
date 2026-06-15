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
