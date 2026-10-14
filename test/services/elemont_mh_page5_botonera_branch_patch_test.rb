# frozen_string_literal: true

require "test_helper"

class ElemontMhPage5BotoneraBranchPatchTest < ActiveSupport::TestCase
  BASE_PATH = Rails.root.join("test/fixtures/files/elemont/page5_safety_note/chunk_p5_1_after.txt")
  CANDIDATE_PATH = Rails.root.join("test/fixtures/files/elemont/page5_botonera_branch/chunk_p5_1_candidate.txt")
  PRE_SAFETY_PATH = Rails.root.join("test/fixtures/files/field_companion/phase1_20261010T153620Z/bodies/b0003.txt")
  BASE_SHA = "067ff45ffa86a6d055cedbec8f38ce63ae36c5ba15266d32a48da5ccea9c6831"
  CANDIDATE_SHA = "a13141fe7586c9013d698aa29f2b6809f112702e98f4da99d9a47c3ba01d7779"
  NEWLINE_CANDIDATE_SHA = "bc6d057d6ed34adae196692c7a48e1291ac020b08150027c51e13a398b77441e"
  KEPT_RECORD_IDS = %w[
    FR-805D93B8B7157513
    FR-80FD5EC309BCF18E
    FR-A44060F00DF1EF49
    FR-9965A0267B71D3DA
    FR-ADBD91E792ACCE4E
    FR-788DC1C62E54AA33
    FR-CECE5263ABF9FE19
  ].freeze

  setup do
    @base = BASE_PATH.binread
    @candidate = CANDIDATE_PATH.binread
  end

  test "rewrites the botonera spans of the safety-corrected body" do
    assert_equal 7359, @base.bytesize
    assert_equal BASE_SHA, Digest::SHA256.hexdigest(@base)
    assert_equal 9193, @candidate.bytesize
    assert_equal CANDIDATE_SHA, Digest::SHA256.hexdigest(@candidate)

    patched = ElemontMhPage5BotoneraBranchPatch.apply!(@base.dup.force_encoding(Encoding::UTF_8))

    assert_equal @candidate.b, patched.b
    assert_equal ElemontMhPage5BotoneraBranchPatch.unchanged_body(@base),
                 ElemontMhPage5BotoneraBranchPatch.unchanged_body(patched)
    assert_equal BASE_SHA, Digest::SHA256.hexdigest(BASE_PATH.binread)
  end

  test "keeps one trailing newline and rejects two" do
    source = @base.dup.force_encoding(Encoding::UTF_8) + "\n"
    patched = ElemontMhPage5BotoneraBranchPatch.apply!(source)

    assert_equal 9194, patched.bytesize
    assert_equal NEWLINE_CANDIDATE_SHA, ElemontMhPage5BotoneraBranchPatch.digest(patched)
    assert_equal @candidate.b + "\n".b, patched.b

    assert_raises(ElemontMhPage5BotoneraBranchPatch::Error) do
      ElemontMhPage5BotoneraBranchPatch.apply!(source + "\n")
    end
  end

  test "keeps the safety line, the header and the records outside this repair" do
    patched = ElemontMhPage5BotoneraBranchPatch.apply!(@base.dup.force_encoding(Encoding::UTF_8))

    assert_includes patched, "[DOCUMENT: Montacargas 2N Temporizado-1 (1).pdf]"
    assert_includes patched, "[SOURCE_URI: s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/"
    assert_includes patched, "Los componentes se conectan en serie entre los nodos Seg In y Seg Out."
    assert_includes patched, "cadena en serie plegada en dos columnas"
    assert_includes patched, "Seguridad Puerta nivel 2 queda entre Seguridad Puerta nivel 3 y Seguridad Puerta nivel 1."
    KEPT_RECORD_IDS.each { |record_id| assert_includes patched, "RECORD_ID: #{record_id}" }
    assert_includes patched, "tipo de contacto y cableado exacto REQUIRES_FIELD_VERIFICATION"
    assert_not_includes patched, "ramas paralelas"
    assert_not_includes patched, "FR-096E150644BA5108"

    botonera = patched.split("# FIELD-SAFETY EVIDENCE RECORDS", 2).first.split("SECCIÓN BOTONERA DE PASILLO NIVEL 1", 2).last
    assert_not_includes botonera.downcase, "salida"
    assert_not_includes botonera.downcase, "conector"
    assert_not_includes botonera.downcase, "aliment"
    assert_not_includes patched, "bobina"
    assert_not_includes patched, "En el bus inferior (PasCom 24V)"
    assert_includes patched, "No cruza PasCom 24V."
    assert_includes patched, "puente semicircular sin punto de unión"
  end

  test "recalculates record ids with the parser fingerprint and does not reuse the old ones" do
    parser = BatchResultsParserService.allocate
    patched = ElemontMhPage5BotoneraBranchPatch.apply!(@base.dup.force_encoding(Encoding::UTF_8))

    ElemontMhPage5BotoneraBranchPatch::RECORD_FIELDS.each do |record|
      actual = parser.send(
        :field_record_id,
        page: ElemontMhPage5BotoneraBranchPatch::PAGE,
        source: ElemontMhPage5BotoneraBranchPatch::SECTION,
        record_type: ElemontMhPage5BotoneraBranchPatch::RECORD_TYPE,
        action: record[:action_to],
        expected_result: record[:expected],
        evidence: record[:evidence]
      )
      copy = ElemontMhPage5BotoneraBranchPatch.record_id(
        action: record[:action_to],
        expected_result: record[:expected],
        evidence: record[:evidence]
      )

      assert_equal record[:id_to], actual
      assert_equal actual, copy
      assert_not_equal record[:id_from], actual
      assert_includes patched, "RECORD_ID: #{actual}"
      assert_not_includes patched, "RECORD_ID: #{record[:id_from]}"
    end
  end

  test "rejects a different base, a partial substitution, a repeated span and a second pass" do
    error = ElemontMhPage5BotoneraBranchPatch::Error
    pre_safety = PRE_SAFETY_PATH.binread.dup.force_encoding(Encoding::UTF_8)
    assert_raises(error) { ElemontMhPage5BotoneraBranchPatch.apply!(pre_safety) }

    shifted = @base.dup.force_encoding(Encoding::UTF_8)
    shifted.sub!("cadena en serie plegada en dos columnas", "cadena en serie plegada en tres columnas")
    assert_raises(error) { ElemontMhPage5BotoneraBranchPatch.apply!(shifted) }

    missing = @base.dup.force_encoding(Encoding::UTF_8)
    span = ElemontMhPage5BotoneraBranchPatch::FEED_FROM
    missing[missing.index(span), span.length] = ""
    assert_raises(error) { ElemontMhPage5BotoneraBranchPatch.apply!(missing) }

    repeated = @base.dup.force_encoding(Encoding::UTF_8)
    repeated.sub!(span, "#{span}\n#{span}")
    assert_raises(error) { ElemontMhPage5BotoneraBranchPatch.apply!(repeated) }

    assert_raises(error) do
      ElemontMhPage5BotoneraBranchPatch.apply!(@candidate.dup.force_encoding(Encoding::UTF_8))
    end
  end

  test "does not reference an external client" do
    source = Rails.root.join("app/services/elemont_mh_page5_botonera_branch_patch.rb").read

    assert_not_includes source, "Aws::"
    assert_not_includes source, "S3DocumentsService"
    assert_not_includes source, "Bedrock"
    assert_not_includes source, "Net::HTTP"
  end
end
