# frozen_string_literal: true

# Fase B — A/B de disponibilidad de generación sobre H3 (foto URM).
#
# EFECTOS: consume llamadas `retrieve_and_generate` facturadas (~US$0,010 cada
# una, medido en el humo r3–r5) y escribe filas en `bedrock_queries`. Crea una
# `ConversationSession` de sonda y la destruye al terminar. No despliega, no
# toca `app/prompts/bedrock/generation.txt` y no cambia la flag del contenedor
# que sirve tráfico: el ENV se muta sólo dentro de este proceso de
# `bin/rails runner`, que es un proceso aparte del servidor.
#
# Pregunta que responde: el colapso de H3 (`canned_with_retrieval`, 1 de 8 entre
# r2 y r5) ¿es una propiedad de R&G en turnos con bloque de foto, o lo introduce
# gs-v1? Y si es muestreo, ¿lo reduce temperatura 0?
#
# Brazos, todos con la plantilla inyectada por `custom_config` para que el arnés
# sea idéntico y la única variable sea la intencional:
#   A  gs-v1 (plantilla desplegada)            temperatura actual
#   B  estricta (misma plantilla sin gs-v1)    temperatura actual
#   C  gs-v1                                    temperatura 0.0
# Controles de arnés: H4 en A (debe colapsar, 6/6 en r3–r5) y en B (el A/B del
# 11-sep no colapsaba sin gs-v1). Si los controles no se comportan, el
# experimento está mal montado y no se interpreta nada.
#
# Los brazos se intercalan (A,B,C,A,B,C…) para que una degradación temporal del
# servicio no se cargue entera sobre un brazo.
#
# Alcance del brazo B: cambia la **plantilla**, no la flag. El post-proceso
# (`normalize_absence_semantics`, D5, contract_version) sigue en modo gs porque
# la instancia se construye con la flag on. No sesga la medición:
# `canned_with_retrieval` lo decide Bedrock antes de cualquier post-proceso.
#
#   CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker ps --filter label=service=smart-deal --filter label=role=web \
#      --filter status=running --format '{{.Names}}' | head -1")
#   ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker exec -i -e N_PER_ARM=20 $CID bin/rails runner -" \
#     < script/fase_b_ab_colapso_h3_2026-09-17.rb \
#     | tee tmp/razonamiento_tecnico/fase_b/ab_colapso_h3_2026-09-17.txt
#
# ENV: N_PER_ARM (20), N_CONTROL (3), HARD_CAP (llamadas facturadas, 0 = auto),
#      EXPECTED_GENERATION_SHA (opcional, aborta si no coincide),
#      REGRESSION_ACCOUNT_ID (3), REGRESSION_USER_ID (7), ARMS ("A,B,C").

require "json"
require "securerandom"
require "stringio"

N_PER_ARM = Integer(ENV.fetch("N_PER_ARM", "20"))
N_CONTROL = Integer(ENV.fetch("N_CONTROL", "3"))
ARMS = ENV.fetch("ARMS", "A,B,C").split(",").map(&:strip)
ZERO_TEMPERATURE = 0.0
# generation.txt of 6ee694b / 6c7ffea (prompt unchanged by D14 copy).
PINNED_GENERATION_SHA = "6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f".freeze

H3_QUESTION = "¿Qué equipo es esto y qué me está mostrando?"
H4_QUESTION = "¿Qué significa este código en un Schindler?"

URM_PHOTO_BLOCK = <<~BLOCK.strip
  ## Photo Evidence (this turn)
  The technician attached a photo in this same turn and the question refers to it. The fields below were read from the image, not from the knowledge base; use them to interpret the question. Procedures, values and part identity come only from the retrieved manuals.
  - Component: UNKNOWN
  - Manufacturer: UNKNOWN
  - Model: UNKNOWN
  - Visible text/codes: URM, LCB II
  - Condition: UNKNOWN
BLOCK

def abort_with(msg)
  puts "ABORT: #{msg}"
  exit 1
end

# Renderiza la plantilla completa (directivas de idioma/canal + contexto de
# sesión + contrato de salida) tal como la construiría producción, con la flag
# forzada. Sólo afecta a este proceso.
def rendered_prompt(account:, grounded:, question:, session_context:)
  previous = ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"]
  ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = grounded ? "true" : "false"
  BedrockRagService.new(account: account).send(
    :load_generation_prompt_with_locale,
    question,
    session_context: session_context,
    output_channel: :web
  )
ensure
  if previous.nil?
    ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
  else
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = previous
  end
end

def prompt_config(template)
  { generation_configuration: { prompt_template: { text_prompt_template: template } } }
end

def temperature_config(value)
  { generation_configuration: { inference_config: { text_inference_config: { temperature: value } } } }
end

def last_rag_quality(log_io, correlation_id)
  log_io.string.lines.reverse_each do |line|
    next unless line.include?("[RAG_QUALITY]")

    payload = JSON.parse(line.split("[RAG_QUALITY] ", 2).last)
    return payload if payload["correlation_id"] == correlation_id
  rescue JSON::ParserError
    next
  end
  nil
end

# Wilson 95% — con n=20 y 0 eventos el intervalo alto es ~16%, que es lo que
# hace decidible "no vi ninguno" frente a "la tasa es del 12%".
def wilson(successes, total)
  return [ 0.0, 0.0 ] if total.zero?

  z = 1.96
  phat = successes.to_f / total
  denom = 1 + (z**2 / total)
  centre = (phat + (z**2 / (2 * total))) / denom
  spread = (z * Math.sqrt((phat * (1 - phat) / total) + (z**2 / (4 * total**2)))) / denom
  [ [ centre - spread, 0.0 ].max, [ centre + spread, 1.0 ].min ]
end

account = Account.find_by(id: ENV.fetch("REGRESSION_ACCOUNT_ID", "3"))
abort_with("cuenta no encontrada") unless account
user = User.find_by(id: ENV.fetch("REGRESSION_USER_ID", "7"))
abort_with("usuario no encontrado") unless user
abort_with("usuario no pertenece a la cuenta") unless user.account_id == account.id

generation_sha = Digest::SHA256.file(Rails.root.join("app/prompts/bedrock/generation.txt")).hexdigest
expected_sha = ENV.fetch("EXPECTED_GENERATION_SHA", PINNED_GENERATION_SHA)
abort_with("generation.txt sha #{generation_sha} != #{expected_sha}") unless generation_sha == expected_sha
abort_with("la flag debe estar on para que el brazo A sea producción") unless Rag::GroundedSynthesisFlag.enabled_for?(account)

puts "cuenta=#{account.id} user=#{user.id}"
puts "generation_sha=#{generation_sha}"
puts "flag.enabled_for_account=#{Rag::GroundedSynthesisFlag.enabled_for?(account)}"
puts "partial_abstention=#{Rag::PartialAbstentionContractFlag.enabled?}"
puts "arms=#{ARMS.inspect} n_per_arm=#{N_PER_ARM} n_control=#{N_CONTROL}"

# Plantillas. Verificar que la gs-v1 reconstruida es byte-idéntica a la que el
# servicio usaría sin inyección: si no lo es, el arnés introduce una variable y
# el A/B no mide lo que dice medir.
service = BedrockRagService.new(account: account)
h3_gs = rendered_prompt(account: account, grounded: true, question: H3_QUESTION, session_context: URM_PHOTO_BLOCK)
h3_strict = rendered_prompt(account: account, grounded: false, question: H3_QUESTION, session_context: URM_PHOTO_BLOCK)
h4_gs = rendered_prompt(account: account, grounded: true, question: H4_QUESTION, session_context: nil)
h4_strict = rendered_prompt(account: account, grounded: false, question: H4_QUESTION, session_context: nil)
h3_live = service.send(:load_generation_prompt_with_locale, H3_QUESTION, session_context: URM_PHOTO_BLOCK, output_channel: :web)

abort_with("la plantilla gs reconstruida no es idéntica a la viva") unless h3_gs == h3_live
abort_with("gs y estricta son idénticas: la flag no está discriminando") if h3_gs == h3_strict
puts "plantilla_gs_chars=#{h3_gs.length} plantilla_estricta_chars=#{h3_strict.length} arnes_identico=true"

RUNS = []
N_PER_ARM.times do |rep|
  ARMS.each do |arm|
    RUNS << { arm: arm, rep: rep, case: "H3-urm" }
  end
end
N_CONTROL.times do |rep|
  RUNS << { arm: "A", rep: rep, case: "H4-control" }
  RUNS << { arm: "B", rep: rep, case: "H4-control" }
end

hard_cap = Integer(ENV.fetch("HARD_CAP", "0"))
hard_cap = RUNS.size if hard_cap.zero?
abort_with("HARD_CAP #{hard_cap} < llamadas planificadas #{RUNS.size}") if hard_cap < RUNS.size
puts "llamadas_planificadas=#{RUNS.size} hard_cap=#{hard_cap} coste_estimado_usd=#{(RUNS.size * 0.0100).round(3)}"

session = ConversationSession.create!(
  identifier: "fase-b-ab-h3-#{SecureRandom.hex(4)}",
  channel: "web", account: account, user: user, expires_at: 2.hours.from_now
)
puts "session_id=#{session.id}"

log_io = StringIO.new
Rails.logger.broadcast_to(ActiveSupport::Logger.new(log_io))

start_id = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i
warmup_started = Time.current
WarmBedrockKbJob.perform_now
puts "=== warmup #{(Time.current - warmup_started).round(1)}s"

TEMPLATES = {
  [ "H3-urm", "A" ] => h3_gs, [ "H3-urm", "B" ] => h3_strict, [ "H3-urm", "C" ] => h3_gs,
  [ "H4-control", "A" ] => h4_gs, [ "H4-control", "B" ] => h4_strict
}.freeze

results = []
billed = 0

RUNS.each_with_index do |run, index|
  abort_with("HARD_CAP #{hard_cap} alcanzado en la llamada #{index}") if billed >= hard_cap

  photo = run[:case] == "H3-urm"
  question = photo ? H3_QUESTION : H4_QUESTION
  template = TEMPLATES.fetch([ run[:case], run[:arm] ])
  custom_config = prompt_config(template)
  custom_config = custom_config.deep_merge(temperature_config(ZERO_TEMPERATURE)) if run[:arm] == "C"

  correlation_id = "fase-b-ab:#{run[:case]}:#{run[:arm]}:r#{run[:rep]}"
  log_io.truncate(0)
  log_io.rewind
  started = Time.current
  result = service.query(
    question,
    custom_config: custom_config,
    session_context: photo ? URM_PHOTO_BLOCK : nil,
    output_channel: :web,
    user_id: user.id,
    conversation_session_id: session.id,
    correlation_id: correlation_id,
    include_diagnostics: true
  )
  elapsed = Time.current - started
  billed += 1

  diagnostics = result[:diagnostics] || {}
  quality = last_rag_quality(log_io, correlation_id)
  answer = result[:answer].to_s
  collapsed = diagnostics[:canned_with_retrieval] == true
  uris = Array(quality && quality["retrieved_source_uris"])

  results << { arm: run[:arm], case: run[:case], rep: run[:rep], collapsed: collapsed }

  puts "=== #{run[:case]} brazo=#{run[:arm]} r#{run[:rep]} billed=#{billed} lat=#{elapsed.round(1)}s"
  puts "  canned_with_retrieval=#{diagnostics[:canned_with_retrieval]} canned_no_results=#{diagnostics[:canned_no_results]} " \
       "citas=#{Array(result[:citations]).size} evidence_mode=#{quality && quality['evidence_mode']}"
  puts "  chunks=#{uris.map { |uri| uri.to_s.split('/').last }.join(',')}"
  puts "  raw_output_chars=#{diagnostics[:raw_answer].to_s.length} answer_chars=#{answer.length}"
  puts "  VISIBLE<<#{answer}>>"
  puts ""
end

spent = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_id).sum(&:cost) }
session.destroy!

puts "=== RESUMEN"
results.group_by { |r| [ r[:case], r[:arm] ] }.sort.each do |(kase, arm), rows|
  collapses = rows.count { |r| r[:collapsed] }
  low, high = wilson(collapses, rows.size)
  puts format("  %-12s brazo %s: %2d/%2d colapsos (%.1f%%), IC95 %.1f%%–%.1f%%",
              kase, arm, collapses, rows.size, 100.0 * collapses / rows.size, 100 * low, 100 * high)
end

control_a = results.select { |r| r[:case] == "H4-control" && r[:arm] == "A" }
control_b = results.select { |r| r[:case] == "H4-control" && r[:arm] == "B" }
puts "  control A (gs, debe colapsar): #{control_a.count { |r| r[:collapsed] }}/#{control_a.size}"
puts "  control B (estricta, no es inmune): #{control_b.count { |r| r[:collapsed] }}/#{control_b.size}"
puts "=== llamadas=#{billed} costo_usd=#{spent.round(4)}"
# Inválido sólo si el control A no reproduce el colapso estructural. Un
# colapso aislado de B no anula el experimento: la estricta tampoco es tasa 0.
puts "=== ARNÉS INVÁLIDO: los controles no reprodujeron el patrón conocido; no interpretar los brazos." if control_a.none? { |r| r[:collapsed] }
