# frozen_string_literal: true

# Fase 4 — atribución del fallo de la pregunta 12 (docs/EJECUCION_PRE_DEMO_2026-09-10.md).
# Read-only, 3 retrieve_and_generate. La 12 devolvió el mensaje de reintento
# (canned "Sorry" de Bedrock con evidencia recuperada) en vez de declarar
# ausencia. No hay baseline pre-deploy para la 12, así que se compara el prompt
# desplegado contra el MISMO prompt sin las dos líneas que añadió la Fase 3,
# inyectado por custom_config (sin deploy, sin tocar código).
ADDED = /^- Do not describe, list, or infer what the documentation set or catalog contains\n\s*or which manufacturers are indexed;[^\n]*\n/.freeze
QUESTION = "¿Qué significa este código en un Schindler?"

account = Account.find(Integer(ENV.fetch("PILOT_BATTERY_ACCOUNT_ID", "3")))
service = BedrockRagService.new(account: account)
deployed = service.send(:load_generation_prompt_with_locale, QUESTION, output_channel: :web)
without_fase3 = deployed.sub(ADDED, "")
puts "fase3_lineas_presentes=#{deployed.match?(ADDED)} prompt_cambia=#{deployed != without_fase3}"

runs = {
  "desplegado (con Fase 3), intento 1" => {},
  "desplegado (con Fase 3), intento 2" => {},
  "sin las 2 lineas de Fase 3" => {
    generation_configuration: { prompt_template: { text_prompt_template: without_fase3 } }
  }
}
runs.each do |label, custom_config|
  result = service.query(QUESTION, output_channel: :web, custom_config: custom_config, include_diagnostics: true)
  diagnostics = result[:diagnostics] || {}
  puts "=== #{label}"
  puts "  canned=#{diagnostics[:canned_no_results]} canned_con_evidencia=#{diagnostics[:canned_with_retrieval]} " \
       "citas=#{result[:citations].size} chunks_evidencia=#{Array(diagnostics[:safety_evidence_chunks]).size}"
  puts "  RAW<<#{diagnostics[:raw_answer]}>>"
  puts "  VISIBLE<<#{result[:answer]}>>"
end
