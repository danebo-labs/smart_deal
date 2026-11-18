# frozen_string_literal: true

# The capture is scoped to one case. The rubric checks the meaning of
# individual propositions, so wording and paragraph order can vary.
module PilotElevatorClosure
  CAPTURE_PATH = "test/fixtures/files/field_companion/pilot_elevator_2026_11_18.json"

  module_function

  def load_capture
    JSON.parse(Rails.root.join(CAPTURE_PATH).read)
  end

  def missing_closure_facts(answer)
    body = I18n.transliterate(answer.to_s).downcase
    checks = {
      attribution: /tecnico|segun tu|reportaste|informaste|confirmaste|mediste/,
      electrical_finding: /contacto[^.!?]*(?:no cerraba|no hacia contacto|no daba continuidad|no establecia continuidad|no estaba cerrando)[^.!?]*(?:electric|continuidad)/,
      recovered_reading: /\bp28\b[^.!?]*(?:\+\s*110\s*v(?:cc|dc)\b|110\s*voltios de corriente continua)/,
      reading_condition: /puerta[^.!?]*cerrada[^.!?]*(?:trabada|enclavada)/,
      code_cleared: /\bea\b[^.!?]*(?:desaparec|ya no|no reaparec)|(?:sin|no (?:muestra|aparece|marca|volvio a mostrar))[^.!?]*\bea\b/,
      completed_maneuver: /maniobra[^.!?]*(?:complet|satisfactori|termin|exito)|complet[^.!?]*maniobra/,
      interlock: /enclavamiento[^.!?]*(?:actu|funcion|oper|respond)/,
      unspecified_repair: /(?:sin (?:detalle|especificar)|no (?:se (?:especific|detall|report|indic|inform|document)|sabemos|indicaste)|queda sin)[^.!?]*(?:repar|intervenc|hicieron)|(?:repar|intervenc)[^.!?]*(?:sin (?:especificar|detalle)|no (?:quedo|se (?:detall|especific|indic|document)))/
    }
    checks.reject { |_fact, pattern| body.match?(pattern) }.keys
  end

  def numbered_chunks(turn, key:, full: false, pin_uri: nil)
    rows = turn.fetch(key).index_by { |source| source.fetch("n") }
    (1..(rows.keys.max || 0)).map do |number|
      source = rows[number]
      next({ case_gap: true, case_number: number }) unless source

      {
        case_number: number,
        content: source.fetch(full ? "full_text" : "text"),
        location_uri: source.fetch("uri"),
        metadata: { "page_number" => source.fetch("page"), "original_source_uri" => pin_uri }.compact
      }
    end
  end
end
