# frozen_string_literal: true

require "test_helper"

class ElemontMhPage5SafetyNotePatchTest < ActiveSupport::TestCase
  BEFORE_PATH = Rails.root.join("test/fixtures/files/field_companion/phase1_20261010T153620Z/bodies/b0003.txt")
  AFTER_PATH = Rails.root.join("test/fixtures/files/elemont/page5_safety_note/chunk_p5_1_after.txt")
  CAPTURE_SHA = "8baae756dab099e124b046057bfb4f6e835d85a5b2922f2eff1e64a637efd09c"
  AFTER_SHA = "067ff45ffa86a6d055cedbec8f38ce63ae36c5ba15266d32a48da5ccea9c6831"
  NEWLINE_BEFORE_SHA = "7658478b42b0f4bc8e7ae603a069c11d42e78d69181d143dbf08e9709b637380"
  NEWLINE_AFTER_SHA = "b466665b37f76cf2e35441787bbd30b3fe2dd42d623b4de359e05814e2c8a85a"
  KEPT_RECORD_IDS = %w[
    FR-805D93B8B7157513
    FR-80FD5EC309BCF18E
    FR-A44060F00DF1EF49
    FR-9965A0267B71D3DA
    FR-ADBD91E792ACCE4E
    FR-CECE5263ABF9FE19
    FR-C7A12AE8C5424D0C
    FR-16D5DB6C568B4EDF
    FR-72533B2981D5BCA1
    FR-5941846F7A31D511
    FR-BEF95A3D11C60D33
    FR-F96D2D2E19D00D3A
  ].freeze

  setup do
    @before = BEFORE_PATH.binread
    @after = AFTER_PATH.binread
  end

  test "rewrites the approved spans of the captured body and keeps the fixture" do
    assert_equal 7612, @before.bytesize
    assert_equal CAPTURE_SHA, Digest::SHA256.hexdigest(@before)
    assert_equal 7359, @after.bytesize
    assert_equal AFTER_SHA, Digest::SHA256.hexdigest(@after)

    patched = ElemontMhPage5SafetyNotePatch.apply!(@before.dup.force_encoding(Encoding::UTF_8))

    assert_equal @after.b, patched.b
    assert_equal strip(@before, from_spans), strip(patched, to_spans)
    assert_equal ElemontMhPage5SafetyNotePatch.unchanged_body(@before),
                 ElemontMhPage5SafetyNotePatch.unchanged_body(patched)
    assert_equal CAPTURE_SHA, Digest::SHA256.hexdigest(BEFORE_PATH.binread)
  end

  test "keeps the identity header, the table index, the botonera and the other records" do
    patched = ElemontMhPage5SafetyNotePatch.apply!(@before.dup.force_encoding(Encoding::UTF_8))

    assert_includes patched, "[DOCUMENT: Montacargas 2N Temporizado-1 (1).pdf]"
    assert_includes patched, "[SOURCE_URI: s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/"
    assert_includes patched, "Los componentes se conectan en serie entre los nodos Seg In y Seg Out."
    assert_includes patched, "| 11 | Seg Out |\n\n---\n\nSECCIÓN BOTONERA DE PASILLO NIVEL 1"
    assert_includes patched, "SECCIÓN BOTONERA DE PASILLO NIVEL 1"
    KEPT_RECORD_IDS.each { |record_id| assert_includes patched, "RECORD_ID: #{record_id}" }
    assert_includes patched, "RECORD_ID: FR-788DC1C62E54AA33"
    assert_includes patched, "EXPECTED_RESULT: Etiquetas: Seguridad Puerta nivel 1, nivel 2, nivel 3, nivel 4, nivel 5\n"
    assert_includes patched, "tipo de contacto y cableado exacto REQUIRES_FIELD_VERIFICATION"
    assert_equal 5, patched.scan("REQUIRES_FIELD_VERIFICATION").size
    assert_not_includes patched, "ramas paralelas"
    assert_not_includes patched, "FR-096E150644BA5108"
    assert_not_includes patched, "orden serie exacto"
  end

  test "applies the same spans to the copy that ends in a newline" do
    source = @before.dup.force_encoding(Encoding::UTF_8) + "\n"
    patched = ElemontMhPage5SafetyNotePatch.apply!(source)

    assert_equal 7613, source.bytesize
    assert_equal NEWLINE_BEFORE_SHA, ElemontMhPage5SafetyNotePatch.digest(source)
    assert_equal 7360, patched.bytesize
    assert_equal NEWLINE_AFTER_SHA, ElemontMhPage5SafetyNotePatch.digest(patched)
    assert_equal @after.b + "\n".b, patched.b
    assert_equal strip(source, from_spans), strip(patched, to_spans)
  end

  test "refuses a missing span, a repeated span and a second pass" do
    note = ElemontMhPage5SafetyNotePatch::NOTE_FROM
    missing = @before.dup.force_encoding(Encoding::UTF_8)
    missing[missing.index(note), note.length] = ""
    assert_raises(ElemontMhPage5SafetyNotePatch::Error) do
      ElemontMhPage5SafetyNotePatch.apply!(missing)
    end

    order = ElemontMhPage5SafetyNotePatch::ORDER_FROM
    repeated = @before.dup.force_encoding(Encoding::UTF_8)
    repeated[repeated.index(order), order.length] = "#{order}\n#{order}"
    assert_raises(ElemontMhPage5SafetyNotePatch::Error) do
      ElemontMhPage5SafetyNotePatch.apply!(repeated)
    end

    assert_raises(ElemontMhPage5SafetyNotePatch::Error) do
      ElemontMhPage5SafetyNotePatch.apply!(@after.dup.force_encoding(Encoding::UTF_8))
    end
  end

  private

  def from_spans
    ElemontMhPage5SafetyNotePatch::REPLACEMENTS.map(&:first)
  end

  def to_spans
    ElemontMhPage5SafetyNotePatch::REPLACEMENTS.map(&:last).reject(&:empty?)
  end

  def strip(text, spans)
    memo = text.dup.force_encoding(Encoding::UTF_8)
    spans.each do |span|
      index = memo.index(span)
      flunk("span missing: #{span.byteslice(0, 48)}") if index.nil?

      memo[index, span.length] = ""
    end
    memo
  end
end
