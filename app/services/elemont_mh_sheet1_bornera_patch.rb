# frozen_string_literal: true

# Rewrites the explicit sheet-1 bornera rows of Elemont MH chunk_p1_2 that
# contradict the sheet-2 designation table. The new cell is a referral to
# that table. It does not copy sheet-2 borne assignments onto sheet 1.
#
# Sheet 2 (chunk_p2_1, SHA 70fa1eaf…) is the authority read before a write:
# Seguridad OUT is 23, Seguridad IN is 24, Presostato OUT is 25, Presostato
# IN is 26, micro nivel inferior is 30, micro nivel superior is 31, llamada
# nivel 1 is 33, llamada nivel 2 is 34. Sheet 1 row 25 (PRESOSTATO OUT)
# matches that table and is left in place.
class ElemontMhSheet1BorneraPatch
  REFERRAL = "ver tabla de borneras, hoja 2"

  SHEET2_ROWS = [
    "| 23 | Seguridad OUT |",
    "| 24 | Seguridad IN |",
    "| 25 | Presostato OUT |",
    "| 26 | Presostato IN |",
    "| 30 | Micro nivel inferior |",
    "| 31 | Micro nivel superior |",
    "| 33 | Llamada nivel 1 |",
    "| 34 | Llamada nivel 2 |"
  ].freeze

  REPLACEMENTS = [
    [ "| 12 | SEGURIDAD IN |", "| 12 | #{REFERRAL} |" ],
    [ "| 13 | SEGURIDAD OUT |", "| 13 | #{REFERRAL} |" ],
    [ "| 14 | PRESOSTATO IN |", "| 14 | #{REFERRAL} |" ],
    [ "| 15 | PRESOSTATO OUT |", "| 15 | #{REFERRAL} |" ],
    [ "| 22 | SEGURIDAD OUT (señal de salida) |", "| 22 | #{REFERRAL} |" ],
    [ "| 23 | SEGURIDAD IN (señal de entrada) |", "| 23 | #{REFERRAL} |" ],
    [ "| 24 | PRESOSTATO IN |", "| 24 | #{REFERRAL} |" ],
    [ "| 26 | LIMITE INFERIOR |", "| 26 | #{REFERRAL} |" ],
    [ "| 27 | LIMITE SUPERIOR |", "| 27 | #{REFERRAL} |" ],
    [ "| 31 | LLAMADA NIVEL 1 |", "| 31 | #{REFERRAL} |" ],
    [ "| 32 | LLAMADA NIVEL 2 |", "| 32 | #{REFERRAL} |" ],
    [
      "ACTION: SEGURIDAD IN / SEGURIDAD OUT — señales de cadena de seguridad en terminales 12/13 y 22/23 del bloque",
      "ACTION: #{REFERRAL}"
    ],
    [
      "EVIDENCE: SEGURIDAD IN — SEGURIDAD OUT terminales identificados en bloque",
      "EVIDENCE: #{REFERRAL}"
    ],
    [
      "ACTION: PRESOSTATO IN / PRESOSTATO OUT — señales de presostato en terminales 14/15 y 24/25",
      "ACTION: #{REFERRAL}"
    ],
    [
      "EVIDENCE: PRESOSTATO IN — PRESOSTATO OUT",
      "EVIDENCE: #{REFERRAL}"
    ],
    [
      "ACTION: LIMITE SUPERIOR / LIMITE INFERIOR — señales de final de carrera en terminales 27 y 26 respectivamente",
      "ACTION: #{REFERRAL}"
    ],
    [
      "EVIDENCE: LIMITE SUPERIOR — LIMITE INFERIOR",
      "EVIDENCE: #{REFERRAL}"
    ],
    [
      "ACTION: LLAMADA NIVEL 1 / LLAMADA NIVEL 2 — señales de llamada de piso en terminales 31 y 32",
      "ACTION: #{REFERRAL}"
    ],
    [
      "EVIDENCE: LLAMADA NIVEL 1 — LLAMADA NIVEL 2 terminales 31 32",
      "EVIDENCE: #{REFERRAL}"
    ]
  ].freeze

  FALSE_LINE = /
    (?:\b12\b.*SEGURIDAD\s+IN)|
    (?:SEGURIDAD\s+IN.*\b12\b)|
    (?:\b13\b.*SEGURIDAD\s+OUT)|
    (?:SEGURIDAD\s+OUT.*\b13\b)|
    (?:\b14\b.*PRESOSTATO)|
    (?:PRESOSTATO.*\b14\b)|
    (?:\b15\b.*PRESOSTATO)|
    (?:PRESOSTATO.*\b15\b)|
    (?:\b22\b.*SEGURIDAD\s+OUT)|
    (?:SEGURIDAD\s+OUT.*\b22\b)|
    (?:\b23\b.*SEGURIDAD\s+IN)|
    (?:SEGURIDAD\s+IN.*\b23\b)|
    (?:\b24\b.*PRESOSTATO\s+IN)|
    (?:PRESOSTATO\s+IN.*\b24\b)|
    (?:\b26\b.*LIMITE\s+INFERIOR)|
    (?:LIMITE\s+INFERIOR.*\b26\b)|
    (?:\b27\b.*LIMITE\s+SUPERIOR)|
    (?:LIMITE\s+SUPERIOR.*\b27\b)|
    (?:\b31\b.*LLAMADA\s+NIVEL\s+1)|
    (?:LLAMADA\s+NIVEL\s+1.*\b31\b)|
    (?:\b32\b.*LLAMADA\s+NIVEL\s+2)|
    (?:LLAMADA\s+NIVEL\s+2.*\b32\b)
  /ix

  class Error < StandardError; end

  def self.apply!(text)
    patched = text.dup
    REPLACEMENTS.each do |from, to|
      count = patched.scan(from).size
      raise Error, "expected 1 occurrence of #{from.inspect}, found #{count}" unless count == 1

      patched.sub!(from, to)
    end
    raise Error, "patch did not change the chunk" if patched == text

    leftovers = false_assignment_lines(patched)
    raise Error, "false assignment still present: #{leftovers.inspect}" if leftovers.any?

    patched
  end

  def self.false_assignment_lines(text)
    text.each_line.select { |line| FALSE_LINE.match?(line) }
  end

  # Body with each replaced span removed, so a caller can prove the rest
  # of the chunk is unchanged.
  def self.unchanged_body(text)
    REPLACEMENTS.inject(text.dup) do |memo, (from, to)|
      memo.sub(from, "\u0000").sub(to, "\u0000")
    end
  end

  def self.sheet2_authority?(text)
    SHEET2_ROWS.all? { |row| text.scan(row).size == 1 }
  end
end
