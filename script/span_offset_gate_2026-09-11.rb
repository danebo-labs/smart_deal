# frozen_string_literal: true

# Fase 4 — gate de deploy (docs/EJECUCION_PRE_DEMO_2026-09-10.md).
# Read-only: 2 retrieve_and_generate contra la cuenta piloto. Repite la sonda de
# Fase 1 con las preguntas 6 y 12 y verifica en la respuesta VISIBLE:
#   (a) ningún marcador [n] partiendo una palabra, y ninguno delante del punto
#       (el síntoma del off-by-one que corrigió la Fase 2);
#   (b) la 12 rechaza por falta de evidencia sin enumerar marcas ni catálogo.
MARKER = /(?:\[\d+\])+/.freeze
WORD = /[\p{L}\p{M}\d]/.freeze
INSIDE_WORD = /#{WORD.source}#{MARKER.source}#{WORD.source}/.freeze
BEFORE_PUNCT = /#{MARKER.source}(?=[.,;:!?])/.freeze
BRANDS = /\b(KONE|OTIS|THYSSEN|TKE|BLT|MITSUBISHI|FUJI|YIDA|WEG|ORONA|EDEL|MCTC|MPDK|MPK|SIGMA|FERMATOR|LG-SIGMA)\b/i.freeze
CATALOG = /documentos? (?:disponibles?|indexados?)|manuales? disponibles?|cat[aá]logo|otros tipos de|marcas (?:disponibles|indexadas)/i.freeze

account = Account.find(Integer(ENV.fetch("PILOT_BATTERY_ACCOUNT_ID", "3")))
{ 6 => "¿Qué hace la tarjeta LCE y dónde está su configuración?",
  12 => "¿Qué significa este código en un Schindler?" }.each do |n, question|
  answer = BedrockRagService.new(account: account).query(question, output_channel: :web)[:answer].to_s
  puts "=== Q#{n} #{question}"
  puts "ANSWER<<#{answer}>>"
  answer.to_enum(:scan, MARKER).each do
    m = Regexp.last_match
    puts "  marcador #{m[0]} @#{m.begin(0)} ctx=#{answer[[ m.begin(0) - 14, 0 ].max...(m.end(0) + 6)].inspect}"
  end
  puts "  (a) dentro_de_palabra=#{answer.scan(INSIDE_WORD).inspect} delante_de_punto=#{answer.scan(BEFORE_PUNCT).inspect}"
  next unless n == 12
  puts "  (b) marcas_mencionadas=#{answer.scan(BRANDS).flatten.uniq.inspect} frases_catalogo=#{answer.scan(CATALOG).inspect}"
  puts "  (b) declara_ausencia=#{answer.match?(/DATA_NOT_AVAILABLE|no (?:contiene|proporciona|incluye|especifica)|no se (?:encontr[oó]|documenta)/i)}"
end
