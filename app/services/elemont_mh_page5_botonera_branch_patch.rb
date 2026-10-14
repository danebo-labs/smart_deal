# frozen_string_literal: true

require "digest"

# Local substitution for the page-5 botonera branch. The expected base is the
# safety-line correction in
# test/fixtures/files/elemont/page5_safety_note/chunk_p5_1_after.txt.
# A trailing newline is kept and is not part of that base. This class does
# not read S3, does not write S3, and does not extend
# ElemontMhPage5SafetyNotePatch.
class ElemontMhPage5BotoneraBranchPatch
  BASE_SHA = "067ff45ffa86a6d055cedbec8f38ce63ae36c5ba15266d32a48da5ccea9c6831"
  PAGE = 5
  SECTION = "SECCIÓN BOTONERA DE PASILLO NIVEL 1"
  RECORD_TYPE = "SCHEMATIC_LABEL"

  FEED_FROM = "El bus superior se alimenta desde Com 18vdc; el bus inferior corresponde a PasCom 24V."
  FEED_TO = "La horizontal superior está rotulada Com 18vdc. La horizontal inferior está rotulada PasCom 24V. " \
    "Esos rótulos se conservan como nombres impresos."

  LC_FROM = "El diagrama muestra múltiples conectores identificados con etiquetas LC y pares Sp/Dp, " \
    "distribuidos a lo largo del bus:\n\n" \
    "| Conector | Etiquetas visibles asociadas |\n|---|---|\n" \
    "| LC1 | Sp1, Dp1 |\n| LC2 | Sp2, Dp2 |\n| LC7 | Sp3, Dp3 |\n" \
    "| LC8 | Sp4, Dp4 (aparece dos veces en el diagrama) |"
  LC_TO = "La sección imprime las etiquetas LC1, LC2, LC7 y LC8, y LC8 otra vez, junto a Sp1, Dp1, Sp2, Dp2, " \
    "Sp3, Dp3, Sp4 y Dp4, y Sp4 y Dp4 otra vez. El trazo de LC1 llega al contacto rotulado Sp1 y no llega al " \
    "símbolo Dp1. El mismo patrón visible se repite: LC2 llega a Sp2, LC7 llega a Sp3 y cada LC8 llega al Sp4 " \
    "de su caja; ninguno de esos trazos llega al símbolo Dp de esa caja. Esta representación no asigna función " \
    "a Sp ni a Dp."

  DOOR_FROM = "Además se indican dos conectores AP (sin denominación adicional visible) y la etiqueta " \
    "Chapa Puerta nivel 1 conectada al bus superior."
  DOOR_TO = "Se imprimen dos etiquetas AP. Chapa Puerta nivel 1 es otra etiqueta, junto a otro símbolo a la " \
    "derecha de ese grupo. No es una de las seis etiquetas Chapa nivel. Ese símbolo queda entre la esquina de " \
    "la horizontal Com 18vdc y un nodo con punto. El contacto de una etiqueta AP llega a ese nodo y cruza con " \
    "puente el vertical de la otra etiqueta AP."

  OUTPUTS_FROM = "En el bus inferior (PasCom 24V) se identifican las siguientes salidas de chapa por nivel:\n\n" \
    "| Salida | Etiqueta |\n|---|---|\n" \
    "| 1 | Chapa nivel 1 |\n| 2 | Chapa nivel 2 |\n| 3 | Chapa nivel 3 |\n" \
    "| 4 | Chapa nivel 4 |\n| 5 | Chapa nivel 5 |\n" \
    "| 6 | Chapa nivel 1 (segunda instancia visible) |\n\n" \
    "Nota: La función específica de los pares Sp/Dp (posiblemente subida/parada y dirección/parada) y de los " \
    "conectores AP no está explicitada en el texto visible del diagrama. Sus funciones quedan como " \
    "DATA_NOT_AVAILABLE en este plano. La repetición de LC8 con Sp4/Dp4 y de Chapa nivel 1 puede indicar " \
    "derivaciones o conexiones redundantes; REQUIRES_FIELD_VERIFICATION en campo."
  OUTPUTS_TO = "La tabla siguiente no está impresa. Ordena las seis etiquetas Chapa nivel y el recorrido " \
    "visible de cada trazo. Sus filas no están impresas y no afirman que esas etiquetas pertenezcan a PasCom 24V. " \
    "La sección no imprime un nombre de papel para esos terminales.\n\n" \
    "| Representación añadida | Recorrido visible |\n|---|---|\n" \
    "| Chapa nivel 1 | Sale de Com 18vdc con punto de unión, pasa por el símbolo Dp1, cruza PasCom 24V con " \
    "un puente semicircular sin punto de unión y termina en el terminal rotulado Chapa nivel 1. El trazo del " \
    "lado Sp1 tiene punto de unión con PasCom 24V. |\n" \
    "| Chapa nivel 2 | Sale de Com 18vdc con punto de unión, pasa por el símbolo Dp2, cruza PasCom 24V con " \
    "un puente semicircular sin punto de unión y termina en el terminal rotulado Chapa nivel 2. El trazo del " \
    "lado Sp2 tiene punto de unión con PasCom 24V. |\n" \
    "| Chapa nivel 3 | Sale de Com 18vdc con punto de unión, pasa por el símbolo Dp3, cruza PasCom 24V con " \
    "un puente semicircular sin punto de unión y termina en el terminal rotulado Chapa nivel 3. El trazo del " \
    "lado Sp3 tiene punto de unión con PasCom 24V. |\n" \
    "| Chapa nivel 4 | Sale de Com 18vdc con punto de unión, pasa por el símbolo Dp4 de la primera caja, " \
    "cruza PasCom 24V con un puente semicircular sin punto de unión y termina en el terminal rotulado Chapa " \
    "nivel 4. El trazo del lado Sp4 de esa caja tiene punto de unión con PasCom 24V. |\n" \
    "| Chapa nivel 5 | Sale del símbolo Dp4 de la segunda caja y baja hasta el terminal rotulado Chapa nivel " \
    "5. No cruza PasCom 24V. Esa horizontal termina y sube al contacto Sp4 de la segunda caja, donde tiene " \
    "punto de unión. |\n" \
    "| Chapa nivel 1, segunda etiqueta impresa | Baja desde el símbolo AP de la derecha hasta el terminal " \
    "rotulado Chapa nivel 1. No cruza PasCom 24V. |\n\n" \
    "La repetición impresa de LC8, Sp4 y Dp4 queda como etiquetas visibles. Esta representación no la lee " \
    "como conexión redundante."

  RECORD_FIELDS = [
    {
      id_from: "FR-C7A12AE8C5424D0C",
      id_to: "FR-EFBC33120BE0F7B4",
      action_from: "Identificar bus de alimentación superior de botonera de pasillo nivel 1",
      action_to: "Identificar el rótulo impreso de la horizontal superior de la botonera de pasillo nivel 1",
      expected: "Etiqueta: Com 18vdc",
      evidence: "Com 18vdc"
    },
    {
      id_from: "FR-16D5DB6C568B4EDF",
      id_to: "FR-196D6FB0A2E067EB",
      action_from: "Identificar bus de alimentación inferior de botonera de pasillo nivel 1",
      action_to: "Identificar el rótulo impreso de la horizontal inferior de la botonera de pasillo nivel 1",
      expected: "Etiqueta: PasCom 24V",
      evidence: "PasCom 24V"
    },
    {
      id_from: "FR-72533B2981D5BCA1",
      id_to: "FR-26B2C19C23558634",
      action_from: "Identificar conectores de botonera en bus: LC1, LC2, LC7, LC8 con sus pares Sp/Dp asociados",
      action_to: "Identificar el contacto al que llega cada etiqueta LC de la botonera de pasillo nivel 1",
      expected_from: "LC1\u2013Sp1/Dp1, LC2\u2013Sp2/Dp2, LC7\u2013Sp3/Dp3, LC8\u2013Sp4/Dp4 \u2014 función de Sp y Dp DATA_NOT_AVAILABLE en este diagrama",
      expected_to: "LC1 llega a Sp1 y no a Dp1; LC2 llega a Sp2 y no a Dp2; LC7 llega a Sp3 y no a Dp3; cada LC8 llega al Sp4 de su caja y no al Dp4. Función de Sp y Dp DATA_NOT_AVAILABLE en este diagrama",
      evidence_from: "Sp1 Dp1 LC1 Sp2 Dp2 LC2 Sp3 Dp3 LC7 Sp4 Dp4 LC8",
      evidence_to: "LC1 Sp1 LC2 Sp2 LC7 Sp3 LC8 Sp4",
      expected: "LC1 llega a Sp1 y no a Dp1; LC2 llega a Sp2 y no a Dp2; LC7 llega a Sp3 y no a Dp3; cada LC8 llega al Sp4 de su caja y no al Dp4. Función de Sp y Dp DATA_NOT_AVAILABLE en este diagrama",
      evidence: "LC1 Sp1 LC2 Sp2 LC7 Sp3 LC8 Sp4"
    },
    {
      id_from: "FR-5941846F7A31D511",
      id_to: "FR-937E3F1B21F8A9B4",
      action_from: "Identificar conectores AP en botonera de pasillo nivel 1",
      action_to: "Identificar las etiquetas AP en la botonera de pasillo nivel 1",
      expected: "Etiqueta: AP (dos instancias visibles) \u2014 función DATA_NOT_AVAILABLE en este diagrama",
      evidence: "AP AP"
    },
    {
      id_from: "FR-BEF95A3D11C60D33",
      id_to: "FR-18586C8555E3D4D1",
      action_from: "Identificar salida de chapa de puerta nivel 1 en bus superior de botonera",
      action_to: "Identificar la etiqueta Chapa Puerta nivel 1, distinta de las etiquetas Chapa nivel",
      expected: "Etiqueta: Chapa Puerta nivel 1",
      evidence: "Chapa Puerta nivel 1"
    },
    {
      id_from: "FR-F96D2D2E19D00D3A",
      id_to: "FR-EDD34F3E3DC1E14A",
      action_from: "Identificar salidas de chapa por nivel en bus inferior PasCom 24V",
      action_to: "Registrar el recorrido visible de las seis etiquetas Chapa nivel respecto de PasCom 24V",
      expected_from: "Chapa nivel 1, Chapa nivel 2, Chapa nivel 3, Chapa nivel 4, Chapa nivel 5 \u2014 segunda instancia de Chapa nivel 1 REQUIRES_FIELD_VERIFICATION",
      expected_to: "Chapa nivel 1, Chapa nivel 2, Chapa nivel 3 y Chapa nivel 4 cruzan PasCom 24V con puente y sin punto de unión. Chapa nivel 5 y la segunda etiqueta Chapa nivel 1 no cruzan PasCom 24V",
      evidence_from: "Chapa nivel 1 Chapa nivel 2 Chapa nivel 3 Chapa nivel 4 Chapa nivel 5",
      evidence_to: "Chapa nivel 1 Chapa nivel 2 Chapa nivel 3 Chapa nivel 4 Chapa nivel 5 Com 18vdc PasCom 24V",
      expected: "Chapa nivel 1, Chapa nivel 2, Chapa nivel 3 y Chapa nivel 4 cruzan PasCom 24V con puente y sin punto de unión. Chapa nivel 5 y la segunda etiqueta Chapa nivel 1 no cruzan PasCom 24V",
      evidence: "Chapa nivel 1 Chapa nivel 2 Chapa nivel 3 Chapa nivel 4 Chapa nivel 5 Com 18vdc PasCom 24V"
    }
  ].freeze

  PROSE = [
    [ FEED_FROM, FEED_TO ],
    [ LC_FROM, LC_TO ],
    [ DOOR_FROM, DOOR_TO ],
    [ OUTPUTS_FROM, OUTPUTS_TO ]
  ].freeze

  class Error < StandardError; end

  def self.replacements
    spans = PROSE.dup
    RECORD_FIELDS.each do |record|
      spans << [ "RECORD_ID: #{record[:id_from]}", "RECORD_ID: #{record[:id_to]}" ]
      spans << [ "ACTION: #{record[:action_from]}", "ACTION: #{record[:action_to]}" ]
      if record[:expected_from]
        spans << [ "EXPECTED_RESULT: #{record[:expected_from]}", "EXPECTED_RESULT: #{record[:expected_to]}" ]
      end
      if record[:evidence_from]
        spans << [ "EVIDENCE: #{record[:evidence_from]}", "EVIDENCE: #{record[:evidence_to]}" ]
      end
    end
    spans
  end

  def self.apply!(text)
    core, newline = split_newline(utf8(text))
    spans = replacements
    spans.each do |from, to|
      count = occurrence_count(core, from)
      raise Error, "expected 1 occurrence, found #{count}" unless count == 1
      raise Error, "replacement already present" if occurrence_count(core, to).positive?
    end
    raise Error, "base mismatch" unless digest(core) == BASE_SHA

    patched = core.dup
    spans.each { |from, to| replace_once!(patched, from, to) }
    raise Error, "patch did not change the chunk" if patched == core
    raise Error, "patch changed bytes outside the approved spans" unless unchanged_body(core) == unchanged_body(patched)

    newline ? "#{patched}\n" : patched
  end

  # Span complement. Destinations are removed first: an evidence line's new
  # text starts with the old line, so deleting the source first would cut
  # the destination. Matching is literal because the note contains periods.
  def self.unchanged_body(text)
    memo = utf8(text)
    replacements.each { |_from, to| delete_once!(memo, to) }
    replacements.each { |from, _to| delete_once!(memo, from) }
    memo
  end

  # Same fingerprint as BatchResultsParserService#field_record_id for a
  # schematic label on this page. The parser method is the check; this copy
  # lets the patch name the id without constructing an S3 client.
  def self.record_id(action:, expected_result:, evidence:)
    fingerprint = [
      PAGE,
      SECTION,
      RECORD_TYPE,
      field_value(action),
      field_value(expected_result),
      field_value(evidence)
    ].join("\u001F")
    "FR-#{Digest::SHA256.hexdigest(fingerprint)[0, 16].upcase}"
  end

  def self.digest(bytes)
    Digest::SHA256.hexdigest(bytes.to_s.b)
  end

  def self.field_value(value)
    normalized = value.to_s.gsub(/\s+/, " ").strip
    normalized.empty? ? "DATA_NOT_AVAILABLE" : normalized
  end
  private_class_method :field_value

  def self.split_newline(text)
    return [ text, false ] unless text.end_with?("\n")
    raise Error, "base mismatch" if text.end_with?("\n\n")

    [ text.delete_suffix("\n"), true ]
  end
  private_class_method :split_newline

  def self.occurrence_count(text, span)
    return 0 if span.empty?

    count = 0
    offset = 0
    while (index = text.index(span, offset))
      count += 1
      offset = index + span.length
    end
    count
  end
  private_class_method :occurrence_count

  def self.replace_once!(text, from, to)
    index = text.index(from)
    raise Error, "span missing" if index.nil?

    text[index, from.length] = to
    text
  end
  private_class_method :replace_once!

  def self.delete_once!(text, span)
    return text if span.empty?

    index = text.index(span)
    return text if index.nil?

    text[index, span.length] = ""
    text
  end
  private_class_method :delete_once!

  def self.utf8(text)
    copy = text.dup.force_encoding(Encoding::UTF_8)
    raise Error, "not valid UTF-8" unless copy.valid_encoding?

    copy
  end
  private_class_method :utf8
end
