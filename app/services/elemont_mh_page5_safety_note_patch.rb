# frozen_string_literal: true

require "digest"

# Local substitution for the page-5 safety-line note. The approved spans are
# the ones in docs/PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md,
# "Inspección de la nota de la página 5, 2026-10-13". Bytes outside those
# spans stay. This class does not read S3 and does not decide that a local
# SHA is the live object.
class ElemontMhPage5SafetyNotePatch
  KEY = "bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p5_1.txt"
  SIDECAR_KEY = "#{KEY}.metadata.json"
  BUCKET = "multimodal-source-destination"
  KNOWLEDGE_BASE_ID = "Y7RZWMFJSR"
  DATA_SOURCE_ID = "PJ0N58DMHG"
  REGION = "us-east-1"

  ORDER_FROM = "El diagrama indica los siguientes elementos en el circuito, en el orden visible de arriba hacia abajo:"
  ORDER_TO = "El diagrama indica los siguientes elementos en una cadena en serie plegada en dos columnas. " \
    "Seguridad Puerta nivel 2 queda entre Seguridad Puerta nivel 3 y Seguridad Puerta nivel 1. " \
    "La tabla ordena esa lectura. Sus números de posición no están impresos en el plano."

  NOTE_FROM = "\n\nNota: El orden exacto de conexión en serie entre los dispositivos de seguridad de puerta por nivel " \
    "(niveles 1 al 5) y los demás elementos de la cadena debe verificarse físicamente en campo, ya que el diagrama " \
    "presenta ramas paralelas visuales en la representación gráfica. REQUIRES_FIELD_VERIFICATION: disposición serie " \
    "exacta de cada dispositivo en la cadena."

  RECORD_FROM = "RECORD_ID: FR-096E150644BA5108"
  RECORD_TO = "RECORD_ID: FR-788DC1C62E54AA33"

  EXPECTED_FROM = "EXPECTED_RESULT: Etiquetas: Seguridad Puerta nivel 1, nivel 2, nivel 3, nivel 4, nivel 5 " \
    "\u2014 orden serie exacto REQUIRES_FIELD_VERIFICATION"
  EXPECTED_TO = "EXPECTED_RESULT: Etiquetas: Seguridad Puerta nivel 1, nivel 2, nivel 3, nivel 4, nivel 5"

  REPLACEMENTS = [
    [ ORDER_FROM, ORDER_TO ],
    [ NOTE_FROM, "" ],
    [ RECORD_FROM, RECORD_TO ],
    [ EXPECTED_FROM, EXPECTED_TO ]
  ].freeze

  class Error < StandardError; end

  def self.apply!(text)
    patched = utf8(text)
    REPLACEMENTS.each do |from, to|
      count = occurrence_count(patched, from)
      raise Error, "expected 1 occurrence, found #{count}" unless count == 1

      replace_once!(patched, from, to)
    end
    raise Error, "patch did not change the chunk" if patched == text

    patched
  end

  # Span complement. A before body and its after body compare equal here
  # when only the approved spans differ. Matching is literal: the note
  # contains periods, so a regexp substitution would not preserve bytes.
  def self.unchanged_body(text)
    memo = utf8(text)
    REPLACEMENTS.each do |from, to|
      delete_once!(memo, from)
      delete_once!(memo, to)
    end
    memo
  end

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

  def self.digest(bytes)
    Digest::SHA256.hexdigest(bytes.to_s.b)
  end

  def self.utf8(text)
    copy = text.dup.force_encoding(Encoding::UTF_8)
    raise Error, "not valid UTF-8" unless copy.valid_encoding?

    copy
  end
  private_class_method :utf8
end
