# frozen_string_literal: true

require "test_helper"

class Gate9V1ValidationTest < ActiveSupport::TestCase
  setup do
    @manual = build_pdf(24, "gate9-manual")
    @sync_pdf = build_pdf(3, "gate9-sync")
    @photos = 7.times.map { |index| write_file("photo-#{index}.jpg", "photo-#{index}") }
    @photos << write_file("opus.bin", "x" * (FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD + 1))
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

  private

  def build_validation(overrides = {}, git_status_loader: -> { "" })
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
      git_status_loader: git_status_loader
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
end
