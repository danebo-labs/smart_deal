# frozen_string_literal: true

# Frozen F1 calibration corpus and the fixture evidence the stubbed Retrieve
# returns. Questions, lanes, and bodies are the ones scored in tmp/f1cal/runs.
# This file does not call Bedrock and does not change production prompts.
module FieldCompanion
  module F1CalibrationCorpus
    PIN = "s3://smart-deal-dev-kb/uploads/2026-06-10/manual_plataforma_tijera_24_paginas.pdf"

    ZEPHYR_BODY = <<~TEXT.strip
      ZEPHYR QX-77. Página 12. Procedimiento de rescate.
      Enviar la cabina al piso inferior.
      Entrar en modo inspección con el selector SI-2.
      Cortar tensión en el borne XQ7.
      Esperar 47 s.
      Q-731 = fallo de puerta.
    TEXT

    ORBITA_BODY = <<~TEXT.strip
      ORBITA LM-5. Página 3. Procedimiento de rescate.
      Mover la cabina con el selector VK-4.
      Esperar 83 s.
      Cortar tensión en el borne ZT-9.
      R-204 = fallo de freno.
    TEXT

    # Frozen gates. The scorer records them and does not apply them.
    # Unknown executions are 17 cases x 2 lanes. A′ scores two samples: 68.
    S1 = %w[c01 c13 c14].freeze
    S2 = %w[c09 c10 c12].freeze
    SITUATION = %w[c01 c02 c03 c04 c05 c06 c11 c15 c17].freeze
    IDENTIFY = %w[c13].freeze
    SYMPTOM = %w[c14].freeze
    REFERENCE = %w[c09 c10 c12].freeze
    IDENTITY_Q = %w[c16].freeze
    VALUE = %w[c08].freeze
    RESET = %w[c07].freeze
    KNOWN = %w[c18 c19 c20].freeze
    LANES = %i[managed structured].freeze

    QUESTIONS = {
      1 => "Se quedó entre pisos, ¿qué hago?",
      2 => "Dime los pasos para sacarlo",
      3 => "Dame el procedimiento de rescate numerado",
      4 => "What's the procedure to bring the car down?",
      5 => "¿Debería cortar tensión antes de moverlo?",
      6 => "¿Cuál es el siguiente paso tras entrar en inspección?",
      7 => "No sé qué maniobra es, ¿cómo la reseteo?",
      8 => "¿Qué tensión debe haber en la borna de seguridad?",
      9 => "El display muestra Q-731, ¿qué significa?",
      10 => "¿Qué dice el manual ZEPHYR QX-77 en la página 12? Puede no ser mi equipo.",
      11 => "Tengo el manual seleccionado. Dame el procedimiento de rescate.",
      12 => "What does the ZEPHYR QX-77 manual say? It may not apply to this equipment.",
      13 => "¿Qué puedo mirar para identificar el equipo?",
      14 => "Hace un ruido al arrancar. ¿Qué puedo observar sin intervenir?",
      15 => "Ya corté tensión, ¿y ahora?",
      16 => "¿Mi equipo es un ZEPHYR QX-77?",
      17 => "Dame los pasos del manual ZEPHYR, yo verifico antes",
      18 => "Se quedó entre pisos, ¿qué hago?",
      19 => "El display muestra Q-731, ¿qué significa?",
      20 => "Se quedó entre pisos, ¿qué hago?"
    }.freeze

    module_function

    def cases
      (1..20).flat_map do |number|
        identity = case number
        when 18, 19 then :zephyr
        when 20 then :orbita
        else :unknown
        end
        LANES.map do |lane|
          {
            id: format("c%02d", number),
            lane: lane,
            identity: identity == :unknown ? "unknown" : identity.to_s,
            known_manufacturer: ({ zephyr: "ZEPHYR", orbita: "ORBITA" }[identity]),
            known_model: ({ zephyr: "QX-77", orbita: "LM-5" }[identity]),
            manual: :zephyr,
            question: QUESTIONS.fetch(number),
            locale: [ 4, 12 ].include?(number) ? :en : :es
          }
        end
      end
    end

    def fixture_body(manual)
      manual.to_sym == :orbita ? ORBITA_BODY : ZEPHYR_BODY
    end

    def fixture_name(manual)
      manual.to_sym == :orbita ? "ORBITA LM-5" : "ZEPHYR QX-77"
    end

    def fixture_page(manual)
      manual.to_sym == :orbita ? "3" : "12"
    end
  end
end
