# frozen_string_literal: true

require "test_helper"

class ElemontMhSheet1BorneraPatchTest < ActiveSupport::TestCase
  LIVE_FIXTURE = Rails.root.join("tmp/elemont_random12_patch_2026-09-24/chunk_p1_2_corrected.txt")
  LIVE_SHA = "688a5d780eef8845c489af53f186d275a3a1cc7a4b35f42b38cc2d53be03776c"
  SHEET2_FIXTURE = Rails.root.join("tmp/elemont_retrieval_patch_2026-09-24/chunk_p2_1_corrected.txt")

  setup do
    @source = <<~TEXT
      | 1 | L1 |
      | 12 | SEGURIDAD IN |
      | 13 | SEGURIDAD OUT |
      | 14 | PRESOSTATO IN |
      | 15 | PRESOSTATO OUT |
      | 22 | SEGURIDAD OUT (señal de salida) |
      | 23 | SEGURIDAD IN (señal de entrada) |
      | 24 | PRESOSTATO IN |
      | 25 | PRESOSTATO OUT |
      | 26 | LIMITE INFERIOR |
      | 27 | LIMITE SUPERIOR |
      | 28 | SUBE |
      | 31 | LLAMADA NIVEL 1 |
      | 32 | LLAMADA NIVEL 2 |
      | 35 | INSPECCION |
      - T1: Relé temporizador (Modo E, t < 3 minutos) — ver tabla de designaciones, hoja 2.
      - K1: Involucrado en circuito SUBE/BAJA y LLAMADA NIVEL 2.
      ACTION: SEGURIDAD IN / SEGURIDAD OUT — señales de cadena de seguridad en terminales 12/13 y 22/23 del bloque
      EVIDENCE: SEGURIDAD IN — SEGURIDAD OUT terminales identificados en bloque
      ACTION: PRESOSTATO IN / PRESOSTATO OUT — señales de presostato en terminales 14/15 y 24/25
      EVIDENCE: PRESOSTATO IN — PRESOSTATO OUT
      ACTION: LIMITE SUPERIOR / LIMITE INFERIOR — señales de final de carrera en terminales 27 y 26 respectivamente
      EVIDENCE: LIMITE SUPERIOR — LIMITE INFERIOR
      ACTION: LLAMADA NIVEL 1 / LLAMADA NIVEL 2 — señales de llamada de piso en terminales 31 y 32
      EVIDENCE: LLAMADA NIVEL 1 — LLAMADA NIVEL 2 terminales 31 32
      ACTION: SUBE / BAJA — señales de mando de movimiento en terminales 28 y 29 (y terminal 16 para BAJA adicional)
    TEXT
  end

  test "replaces contradicted rows with a sheet-2 referral and leaves the rest" do
    patched = ElemontMhSheet1BorneraPatch.apply!(@source)

    assert_equal ElemontMhSheet1BorneraPatch.unchanged_body(@source),
                 ElemontMhSheet1BorneraPatch.unchanged_body(patched)
    assert_empty ElemontMhSheet1BorneraPatch.false_assignment_lines(patched)
    assert_includes patched, "| 12 | ver tabla de borneras, hoja 2 |"
    assert_includes patched, "| 25 | PRESOSTATO OUT |"
    assert_includes patched, "| 1 | L1 |"
    assert_includes patched, "| 28 | SUBE |"
    assert_includes patched, "| 35 | INSPECCION |"
    assert_includes patched, "ver tabla de designaciones, hoja 2"
    assert_includes patched, "LLAMADA NIVEL 2."
    assert_includes patched, "terminales 28 y 29"
    assert_not_includes patched, "| 23 | Seguridad OUT |"
    assert_not_includes patched, "| 30 | Micro nivel inferior |"
    assert_not_includes patched, "| 33 | Llamada nivel 1 |"
    assert_not_includes patched, "L Electrovalvula"
    assert_no_match(/\b(?:12|13|14|15|23|24|26|30|31|33|34)\b/, ElemontMhSheet1BorneraPatch::REFERRAL)
  end

  test "refuses a missing or repeated target" do
    assert_raises(ElemontMhSheet1BorneraPatch::Error) do
      ElemontMhSheet1BorneraPatch.apply!("| 12 | SEGURIDAD IN |")
    end

    doubled = @source.sub("| 12 | SEGURIDAD IN |", "| 12 | SEGURIDAD IN |\n| 12 | SEGURIDAD IN |")
    assert_raises(ElemontMhSheet1BorneraPatch::Error) do
      ElemontMhSheet1BorneraPatch.apply!(doubled)
    end
  end

  test "live chunk fixture only changes the contradicted rows" do
    skip "local live fixture absent" unless LIVE_FIXTURE.file?

    source = LIVE_FIXTURE.read
    assert_equal LIVE_SHA, Digest::SHA256.hexdigest(source)

    patched = ElemontMhSheet1BorneraPatch.apply!(source)

    assert_equal ElemontMhSheet1BorneraPatch.unchanged_body(source),
                 ElemontMhSheet1BorneraPatch.unchanged_body(patched)
    assert_empty ElemontMhSheet1BorneraPatch.false_assignment_lines(patched)
    assert_includes patched, "| 25 | PRESOSTATO OUT |"
    assert_includes patched, "- T1: Relé temporizador (Modo E, t < 3 minutos) — ver tabla de designaciones, hoja 2."
    assert_not_includes patched, "| 12 | SEGURIDAD IN |"
    assert_not_includes patched, "| 14 | PRESOSTATO IN |"
    assert_not_includes patched, "| 15 | PRESOSTATO OUT |"
  end

  test "saved sheet 2 still has the authoritative rows" do
    skip "local sheet 2 fixture absent" unless SHEET2_FIXTURE.file?

    assert ElemontMhSheet1BorneraPatch.sheet2_authority?(SHEET2_FIXTURE.read)
  end
end
