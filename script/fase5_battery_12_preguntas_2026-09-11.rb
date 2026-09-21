# frozen_string_literal: true

# Fase 5 — batería de las 12 preguntas de §4 del prep
# (docs/EJECUCION_PRE_DEMO_2026-09-10.md, docs/PREP_REUNION_GONZALO_2026-09-11.md).
# Read-only: 10 retrieve_and_generate contra la cuenta piloto (cuenta 3).
#
# Corre las 10 preguntas ejecutables por texto (excluye la #6, descartada en
# Fase 1 por falta de evidencia, y la #9, foto, verificada manualmente). Para
# cada una imprime la respuesta VISIBLE completa, las citas numeradas
# (documento + página), si hay algún marcador [n] partiendo una palabra o
# pegado antes del punto (regresión del fix de Fase 2), y las señales de
# diagnóstico (canned_no_results / canned_with_retrieval / cantidad de chunks
# citados y recuperados) para poder fallar el veredicto sin adivinar.
#
# La #5 (KONE LCB II) es la prioridad del plan: si la respuesta declara
# ausencia o es vaga, se marca aparte como hallazgo crítico porque la foto #9
# (menú LCB II) puede llevar a Gonzalo a encadenar esa pregunta en vivo.
MARKER = /(?:\[\d+\])+/.freeze
WORD = /[\p{L}\p{M}\d]/.freeze
INSIDE_WORD = /#{WORD.source}#{MARKER.source}#{WORD.source}/.freeze
BEFORE_PUNCT = /#{MARKER.source}(?=[.,;:!?])/.freeze
NO_EVIDENCE = /no (?:contiene|proporciona|incluye|especifica|dispone|hay evidencia)|no se (?:encontr[oó]|document[oa])|DATA_NOT_AVAILABLE/i.freeze
VAGUE_HEDGE = /verifique con (?:el )?fabricante|consulte (?:el )?manual (?:correspondiente|específico)|de manera general/i.freeze

QUESTIONS = {
  1 => { brand: "BLT", text: "¿Qué significa el código de error de la tarjeta MPK 708A y qué reviso primero?" },
  2 => { brand: "BLT", text: "Tengo un código de error en un BL6, ¿qué indica?" },
  3 => { brand: "OTIS", text: "¿Qué significan los códigos de la serie LG-Sigma en un OTIS?" },
  4 => { brand: "Thyssen", text: "En un CMC-3 hidráulico, ¿qué se revisa cuando el equipo no responde a la llamada?" },
  5 => { brand: "KONE", text: "¿Cómo se hace la puesta en servicio de la placa LCB II y qué se verifica antes de energizar?" },
  7 => { brand: "BLT", text: "¿Cuáles son los pasos de puesta en marcha del MPDK136 / MPDK176?" },
  8 => { brand: "Fuji Yida", text: "¿Cómo se parametriza el variador en un Yida y qué valores trae por defecto?" },
  10 => { brand: "Mitsubishi/BLT", text: "En el plano, ¿por dónde va el circuito de la serie de seguridad y en qué bornes?" },
  11 => { brand: "Variador", text: "¿Cómo se configura un WEG en lazo abierto para un ascensor?" },
  12 => { brand: "Schindler/Fermator", text: "¿Qué significa este código en un Schindler?" }
}.freeze

account = Account.find(Integer(ENV.fetch("PILOT_BATTERY_ACCOUNT_ID", "3")))
service = BedrockRagService.new(account: account)
start_id = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i

# Consulta de calentamiento (Fase 1/4: Aurora auto-pause paga 20-24s en la
# primera consulta del día). No se imprime ni se cuenta para el veredicto.
warmup_started = Time.current
service.query(QUESTIONS.fetch(1).fetch(:text), output_channel: :web,
              correlation_id: "fase5_battery_warmup")
puts "=== warmup #{(Time.current - warmup_started).round(1)}s (no cuenta para el veredicto)\n\n"

QUESTIONS.each do |n, q|
  started = Time.current
  result = service.query(q.fetch(:text), output_channel: :web,
                          correlation_id: "fase5_battery:#{n}", include_diagnostics: true)
  elapsed = (Time.current - started).round(1)
  answer = result[:answer].to_s
  diagnostics = result[:diagnostics] || {}
  citations = Array(result[:citations])

  puts "=== Q#{n} (#{q.fetch(:brand)}) — #{q.fetch(:text)}"
  puts "  latencia=#{elapsed}s"
  puts "  VISIBLE<<#{answer}>>"
  citations.each { |c| puts "  cita [#{c[:number]}] #{c[:title]}" }
  answer.to_enum(:scan, MARKER).each do
    m = Regexp.last_match
    puts "  marcador #{m[0]} @#{m.begin(0)} ctx=#{answer[[ m.begin(0) - 14, 0 ].max...(m.end(0) + 6)].inspect}"
  end
  puts "  dentro_de_palabra=#{answer.scan(INSIDE_WORD).inspect} delante_de_punto=#{answer.scan(BEFORE_PUNCT).inspect}"
  puts "  canned_no_results=#{diagnostics[:canned_no_results]} canned_with_retrieval=#{diagnostics[:canned_with_retrieval]} " \
       "citas=#{citations.size} chunks_evidencia=#{Array(diagnostics[:safety_evidence_chunks]).size}"
  if n == 5
    puts "  *** PRIORIDAD PLAN: declara_ausencia=#{answer.match?(NO_EVIDENCE)} vaga=#{answer.match?(VAGUE_HEDGE)} " \
         "(si alguno es true => hallazgo crítico, la foto #9 muestra un menú LCB II)"
  end
  puts ""
end

spent = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_id).sum(&:cost) }
puts "=== costo_total_usd=#{spent.round(4)} (incluye warmup)"
