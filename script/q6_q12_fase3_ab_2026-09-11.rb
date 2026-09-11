# frozen_string_literal: true

# Fase 4 — confirmación de la atribución (docs/EJECUCION_PRE_DEMO_2026-09-10.md).
# Read-only, 3 retrieve_and_generate. Cierra dos preguntas del gate:
#   1. ¿el «Sorry» de la 12 con las líneas de Fase 3 es reproducible sin ellas? (2ª muestra)
#   2. ¿esas líneas cumplen su objetivo en la 6, que es la que motivó la Fase 3?
ADDED = /^- Do not describe, list, or infer what the documentation set or catalog contains\n\s*or which manufacturers are indexed;[^\n]*\n/.freeze
BRANDS = /\b(KONE|OTIS|THYSSEN|TKE|BLT|MITSUBISHI|FUJI|YIDA|WEG|ORONA|EDEL|MCTC[\w-]*|MPDK\d*|MPK)\b/i.freeze
CATALOG = /(?:documentaci[oó]n|documentos?|manuales?) (?:disponibles?|recuperada|indexados?)|la b[uú]squeda devolvi[oó]|cat[aá]logo|otros tipos de|que incluye/i.freeze
Q6 = "¿Qué hace la tarjeta LCE y dónde está su configuración?"
Q12 = "¿Qué significa este código en un Schindler?"

account = Account.find(Integer(ENV.fetch("PILOT_BATTERY_ACCOUNT_ID", "3")))
service = BedrockRagService.new(account: account)

[ [ Q12, "sin Fase 3 (2ª muestra)", true ], [ Q6, "con Fase 3 (desplegado)", false ], [ Q6, "sin Fase 3", true ] ]
  .each do |question, label, strip|
  prompt = service.send(:load_generation_prompt_with_locale, question, output_channel: :web)
  custom = strip ? { generation_configuration: { prompt_template: { text_prompt_template: prompt.sub(ADDED, "") } } } : {}
  raise "las lineas de Fase 3 no estan en el prompt" if strip && !prompt.match?(ADDED)

  result = service.query(question, output_channel: :web, custom_config: custom, include_diagnostics: true)
  answer = result[:answer].to_s
  puts "=== #{label} — #{question}"
  puts "  canned_con_evidencia=#{result.dig(:diagnostics, :canned_with_retrieval)} citas=#{result[:citations].size}"
  puts "  marcas=#{answer.scan(BRANDS).flatten.uniq.inspect} catalogo=#{answer.scan(CATALOG).uniq.inspect}"
  puts "  VISIBLE<<#{answer}>>"
end
