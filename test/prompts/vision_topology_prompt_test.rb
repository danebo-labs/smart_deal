require "test_helper"

class VisionTopologyPromptTest < ActiveSupport::TestCase
  Raster = PdfPageRasterizer::Raster

  test "user_content leads with the full page and pairs every crop with its label" do
    blocks = VisionTopologyPrompt.user_content(
      page:        raster,
      crops:       [ { raster: raster, label: "LIMITADOR" }, { raster: raster, label: "CONECTOR AI" } ],
      page_number: 17,
      total_pages: 98,
      filename:    "SEGURIDADES.pdf"
    )

    assert_equal "image", blocks[0][:type]
    assert_equal "FULL PAGE 17 of 98.", blocks[1][:text]

    assert_equal "image", blocks[2][:type]
    assert_includes blocks[3][:text], "CROP 1 of page 17"
    assert_includes blocks[3][:text], "LIMITADOR"

    assert_equal "image", blocks[4][:type]
    assert_includes blocks[5][:text], "CROP 2 of page 17"
    assert_includes blocks[5][:text], "CONECTOR AI"

    assert_includes blocks.last[:text], "SEGURIDADES.pdf"
  end

  test "image blocks carry the base64 payload the rasterizer produced" do
    block = VisionTopologyPrompt.user_content(
      page: raster, crops: [], page_number: 1, total_pages: 1, filename: "f.pdf"
    ).first

    assert_equal "base64", block[:source][:type]
    assert_equal "image/jpeg", block[:source][:media_type]
    assert_equal "AAAA", block[:source][:data]
  end

  # Measured in I-34: with no locale the model writes English evidence for a
  # Spanish page, which would land in the same chunk body as T1's Spanish
  # evidence. Endpoint labels are transcriptions and are never translated.
  test "the locale is requested for the evidence prose only when the caller has one" do
    with_locale = VisionTopologyPrompt.user_content(
      page: raster, crops: [], page_number: 1, total_pages: 1, filename: "f.pdf", locale: "es"
    ).last[:text]
    without = VisionTopologyPrompt.user_content(
      page: raster, crops: [], page_number: 1, total_pages: 1, filename: "f.pdf"
    ).last[:text]

    assert_includes with_locale, "Evidence language: es."
    assert_not_includes without, "Evidence language"
    assert_includes VisionTopologyPrompt::SYSTEM_BLOCKS.pluck(:text).join("\n"),
                    "keep the page's own spelling"
  end

  test "a crop without a raster is skipped rather than sent as a bare label" do
    blocks = VisionTopologyPrompt.user_content(
      page: raster, crops: [ { raster: nil, label: "GHOST" } ],
      page_number: 1, total_pages: 1, filename: "f.pdf"
    )

    assert_not(blocks.any? { |block| block[:text].to_s.include?("GHOST") })
  end

  # Gate B scores T2 against T1's edges as free ground truth. A prompt that
  # mentions leader lines, derived edges or a layout digest would be measuring a
  # copier, so no path into this prompt may carry them — there is deliberately no
  # parameter for them, and this pins that.
  test "nothing in the prompt exposes T1's traced edges" do
    text = (VisionTopologyPrompt::SYSTEM_BLOCKS.pluck(:text) +
      VisionTopologyPrompt.user_content(
        page: raster, crops: [ { raster: raster, label: "LIMITADOR" } ],
        page_number: 3, total_pages: 98, filename: "f.pdf"
      ).filter_map { |block| block[:text] }).join("\n")

    assert_not_includes text, "leader_line"
    assert_not_includes text, "LAYOUT DIGEST"
    assert_not_includes text, "TOPOLOGY_EDGE"
    assert_not(VisionTopologyPrompt.method(:user_content).parameters.any? { |_, name| name == :traced_edges })
  end

  # The schema is FieldPhotoPrompt's, not a new one (plan, Fase 5).
  test "the connection schema reuses the field-photo grammar verbatim" do
    text = VisionTopologyPrompt::SYSTEM_BLOCKS.pluck(:text).join("\n")

    assert_includes text, "documented_connections"
    assert_includes text, "\"from\""
    assert_includes text, "\"to\""
    assert_includes text, "\"evidence\""
    assert_includes text, "canonical_component"
    assert_includes text, "anti_hallucination_notes"
  end

  # I-11 (a pair is not a direction) and I-29 (a pair is not the whole run) are
  # properties of the data both tiers emit, so T2's prompt has to state them too.
  test "the prompt forbids claiming direction or exhaustiveness" do
    text = VisionTopologyPrompt::SYSTEM_BLOCKS.pluck(:text).join("\n")

    assert_includes text, "unordered PAIR"
    assert_includes text, "They are not exhaustive"
    assert_includes text, "never imply the run has only two"
  end

  test "prompt_fingerprint_sha256 is a stable digest of the system text" do
    expected = Digest::SHA256.hexdigest(VisionTopologyPrompt::SYSTEM_BLOCKS.pluck(:text).join("\n"))

    assert_equal expected, VisionTopologyPrompt.prompt_fingerprint_sha256
    assert_match(/\A[0-9a-f]{64}\z/, VisionTopologyPrompt.prompt_fingerprint_sha256)
  end

  private

  def raster
    @raster ||= Raster.new(data: "AAAA", media_type: "image/jpeg", width: 10, height: 10, dpi: 150, bytes: 3)
  end
end
