# frozen_string_literal: true

# Regresion foto + pregunta (post plan foto_mas_pregunta_correccion), 2026-09-15.
#
# v2 15-Sep: anchor_clean, control texto-only caso 3, costo solo bedrock_queries.
#
# Efectos: crea 1 ConversationSession; corre hasta 3 FieldPhotoAnalysisJob.perform_now
# contra fotos ya persistidas de la cuenta piloto (cache miss => 3 llamadas de vision
# ~US$0.02-0.03 c/u + 3 retrieve_and_generate + 1 consulta de control texto-only para
# el caso 3, ~US$0.085 total); escribe PilotEvent/BedrockQuery/FieldPhotoDiagnosisCache
# y agrega turnos al historial de esa sesion.
# NO emite broadcasts reales (los intercepta) salvo BROADCAST=true.
#
# Uso local (staging inexistente, ver docs): bin/rails runner script/photo_question_regression_2026-09-15.rb
# Uso produccion (por stdin, ver script/AGENTS.md "Running against production"):
#   CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker ps --filter label=service=smart-deal --filter label=role=web --filter status=running --format '{{.Names}}' | head -1")
#   ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker exec -i -e FORCE_VISION=true $CID bin/rails runner -" \
#     < script/photo_question_regression_2026-09-15.rb | tee tmp/regresion_foto_2026-09-15.txt
#
# Env vars:
#   REGRESSION_ACCOUNT_ID (default "3"), REGRESSION_USER_ID (default "7")
#   ONLY=<n>        limita a un solo caso (1, 2 o 3)
#   FORCE_VISION=true  invalida FieldPhotoDiagnosisCache antes de cada caso (re-corre vision el mismo dia)
#   BROADCAST=true  deja pasar los broadcasts reales de KbSyncBroadcaster (por defecto se capturan y no salen)

require "json"
require "stringio"
require "securerandom"

ABSTENTION = Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN
ANCHOR_GENERIC_UPCASE = %w[MODULE FUNCTION SET MENU].freeze

CASES = [
  { n: 1, sha_prefix: "d59e616a5459", question: "Que es este dispositivo y que se ve en la pantalla ?",
    checks: { anchor_clean: true, entity_filter: /URM|LCB/i, no_abstention: true, outcome: "answered" } },
  { n: 2, sha_prefix: "b77cc2e64a20", question: "Que es la.imagen y que muestra en la pantalla?",
    checks: { anchor_clean: true, no_abstention: true, outcome: "answered" } },
  { n: 3, sha_prefix: "e6814d1ab3c1", question: "Cómo se ajustan los resortes de la fijación de cables",
    checks: { literal_question: true, forbidden: /000A60961010|Fijaci[oó]n de Cables Motor/i,
              no_abstention: true, cites: /KONE MonoSpace/i, max_distinct_docs: 3, outcome: "answered" } }
].freeze
# Checks tolerados como observacion (no bloquean RESULTADO GLOBAL) por caso, ver
# "Criterio de aceptacion v2" del plan: la vision no es deterministica y el caso 3
# puede abstener legitimamente por cobertura de KB (decide la consulta de control).
SOFT_CHECKS = { 3 => %i[cites max_distinct_docs no_abstention outcome] }.freeze

run_id = SecureRandom.hex(4)
failures = 0
warnings = 0

def abort_with(msg)
  puts "ABORT: #{msg}"
  exit 1
end

# ── 1. Guards ────────────────────────────────────────────────────────────────
abort_with("PHOTO_QUESTION_RAG_ENABLED != true en este proceso") unless Rag::PhotoQuestionFlag.enabled?

account = Account.find_by(id: ENV.fetch("REGRESSION_ACCOUNT_ID", "3"))
abort_with("cuenta no encontrada (REGRESSION_ACCOUNT_ID)") unless account

user = User.find_by(id: ENV.fetch("REGRESSION_USER_ID", "7"))
abort_with("usuario no encontrado (REGRESSION_USER_ID)") unless user
abort_with("usuario #{user.id} no pertenece a la cuenta #{account.id}") unless user.account_id == account.id

only = ENV["ONLY"].presence&.to_i
run_cases = only ? CASES.select { |c| c[:n] == only } : CASES
abort_with("ONLY=#{only} no coincide con ningun caso") if run_cases.empty?

photos = {}
CASES.each do |c|
  matches = FieldPhoto.where(account_id: account.id).where("sha256 LIKE ?", "#{c[:sha_prefix]}%")
  count = matches.count
  abort_with("caso #{c[:n]} sha_prefix=#{c[:sha_prefix]} matches=#{count} (esperado 1)") unless count == 1
  photos[c[:n]] = matches.first
end

fixed_mode = KbSyncBroadcaster.respond_to?(:photo_question_answered)
puts "modo=#{fixed_mode ? 'fixed' : 'baseline'}"
puts "cuenta=#{account.id} user=#{user.id} run_id=#{run_id} casos=#{run_cases.pluck(:n).join(',')}"

session = ConversationSession.create!(
  identifier: "regresion-foto-2026-09-15-#{run_id}",
  channel: "web", account: account, user: user, expires_at: 1.hour.from_now
)
puts "session_id=#{session.id}"

# ── 2. Cambio A (sin coste): WarmBedrockKbJob se encola solo en cache miss con pregunta ─
def stub_perform_later(klass, calls)
  original = klass.method(:perform_later)
  klass.define_singleton_method(:perform_later) do |*args, **kwargs|
    calls << { args: args, kwargs: kwargs }
  end
  original
end

def restore_perform_later(klass, original)
  klass.define_singleton_method(:perform_later) { |*a, **kw| original.call(*a, **kw) }
end

photo3 = photos[3]
if photo3
  calls = { "FieldPhotoAnalysisJob" => [], "WarmBedrockKbJob" => [] }
  orig_analysis = stub_perform_later(FieldPhotoAnalysisJob, calls["FieldPhotoAnalysisJob"])
  orig_warm     = stub_perform_later(WarmBedrockKbJob, calls["WarmBedrockKbJob"])
  begin
    binary = FieldPhotoStore.fetch_binary(photo3)
    image = { binary: binary, media_type: photo3.content_type, filename: File.basename(photo3.s3_key_original) }
    FieldPhotoDiagnosisCache.invalidate(account_id: account.id, sha256: photo3.sha256, locale: "es")
    QueryOrchestratorService.new(
      CASES.find { |c| c[:n] == 3 }.fetch(:question), images: [ image ],
      account: account, user_id: user.id, conversation_session_id: session.id
    ).execute
    with_question_ok = calls["WarmBedrockKbJob"].any? && calls["FieldPhotoAnalysisJob"].any?
    puts "#{with_question_ok ? 'PASS' : 'FAIL'} cambio_a.warm_kb_encolado_con_pregunta warm=#{calls['WarmBedrockKbJob'].size} analysis=#{calls['FieldPhotoAnalysisJob'].size}"
    failures += 1 unless with_question_ok

    calls["WarmBedrockKbJob"].clear
    calls["FieldPhotoAnalysisJob"].clear
    FieldPhotoDiagnosisCache.invalidate(account_id: account.id, sha256: photo3.sha256, locale: "es")
    QueryOrchestratorService.new(
      "", images: [ image ], account: account, user_id: user.id, conversation_session_id: session.id
    ).execute
    without_question_ok = calls["WarmBedrockKbJob"].empty?
    puts "#{without_question_ok ? 'PASS' : 'FAIL'} cambio_a.warm_kb_no_encolado_sin_pregunta warm=#{calls['WarmBedrockKbJob'].size}"
    failures += 1 unless without_question_ok
  ensure
    restore_perform_later(FieldPhotoAnalysisJob, orig_analysis)
    restore_perform_later(WarmBedrockKbJob, orig_warm)
  end
else
  puts "SKIP cambio_a (caso 3 excluido por ONLY=#{only})"
end

# ── 3. Captura de logger + broadcasts ────────────────────────────────────────
log_io = StringIO.new
logger = ActiveSupport::Logger.new(log_io)
Rails.logger.broadcast_to(logger)

broadcasts = []
broadcast_originals = {}
%i[photo_analyzed photo_question_answered failed].each do |method_name|
  next unless KbSyncBroadcaster.respond_to?(method_name)

  broadcast_originals[method_name] = KbSyncBroadcaster.method(method_name)
  original = broadcast_originals[method_name]
  KbSyncBroadcaster.define_singleton_method(method_name) do |**kwargs|
    broadcasts << { method: method_name.to_s, payload: kwargs }
    original.call(**kwargs) if ENV["BROADCAST"] == "true"
  end
end

start_bedrock_id = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i

# ── 4-6. Por caso: ejecutar, parsear telemetria, chequear, imprimir ──────────
run_cases.each do |c|
  n = c[:n]
  photo = photos.fetch(n)
  correlation_id = "regresion-foto:#{run_id}:#{n}"
  broadcasts.clear
  log_io.truncate(0)
  log_io.rewind

  FieldPhotoDiagnosisCache.invalidate(account_id: account.id, sha256: photo.sha256, locale: "es") if ENV["FORCE_VISION"] == "true"

  started = Time.current
  FieldPhotoAnalysisJob.perform_now(
    image_token: nil, image_sha256: photo.sha256, filename: File.basename(photo.s3_key_original),
    content_type: photo.content_type, account_id: account.id, user_id: user.id,
    conversation_session_id: session.id, locale: "es", correlation_id: correlation_id,
    field_photo_id: photo.id, question: c[:question]
  )
  elapsed_ms = ((Time.current - started) * 1000).round

  case_broadcasts = broadcasts.dup
  rag_quality = log_io.string.lines.filter_map do |line|
    next unless line.include?("[RAG_QUALITY]")

    payload = JSON.parse(line.split("[RAG_QUALITY] ", 2).last)
    payload if payload["correlation_id"] == correlation_id
  end.last

  usage_events = log_io.string.lines.filter_map do |line|
    next unless line.include?("[PILOT_USAGE]")

    payload = JSON.parse(line.split("[PILOT_USAGE] ", 2).last)
    payload if payload["correlation_id"] == correlation_id
  end
  usage_by_event = usage_events.group_by { |e| e["event"] }.transform_values(&:last)

  answer = case_broadcasts.find { |b| b[:method] == "photo_question_answered" }&.dig(:payload, :answer).to_s
  answer = case_broadcasts.find { |b| b[:method] == "photo_analyzed" }&.dig(:payload, :summary).to_s if answer.blank?
  citation_titles = Array(rag_quality && rag_quality["citation_titles"])

  soft = SOFT_CHECKS.fetch(n, [])
  check = lambda do |name, ok, observed|
    label = soft.include?(name) ? (ok ? "PASS" : "WARN") : (ok ? "PASS" : "FAIL")
    puts "  #{label} caso#{n}.#{name} #{observed}"
    if !ok
      if soft.include?(name)
        warnings += 1
      else
        failures += 1
      end
    end
  end

  puts "=== Caso #{n} — #{c[:question]}"
  puts "  correlation_id=#{correlation_id} latencia_total_ms=#{elapsed_ms} latencia_rag_ms=#{rag_quality && rag_quality['latency_ms']}"
  puts "  entity_filter=#{rag_quality && rag_quality['entity_filter'].inspect} citation_titles=#{citation_titles.uniq.inspect}"
  puts "  outcomes photo_question_answered=#{usage_by_event.dig('photo_question_answered', 'outcome').inspect} interaction_completed=#{usage_by_event.dig('interaction_completed', 'outcome').inspect}"
  puts "  broadcasts=#{case_broadcasts.map { |b| b[:method] }.inspect}"
  puts "  VISIBLE<<#{answer}>>"

  if c[:checks][:literal_question]
    check.call(:literal_question, rag_quality && rag_quality["question"] == c[:question], rag_quality && rag_quality["question"].inspect)
  end
  if c[:checks][:anchor_clean]
    suffix = rag_quality && rag_quality["question"].to_s[/\((.+)\)\z/, 1]
    ok = suffix.nil? || suffix.split.all? { |t| KbDocumentResolver.specific_token?(t) && ANCHOR_GENERIC_UPCASE.exclude?(t.upcase) }
    check.call(:anchor_clean, ok, "suffix=#{suffix.inspect}")
  end
  if c[:checks][:forbidden]
    ok = !answer.match?(c[:checks][:forbidden])
    check.call(:forbidden, ok, "answer=~#{c[:checks][:forbidden].inspect}")
  end
  if c[:checks][:no_abstention]
    ok = !answer.match?(ABSTENTION)
    check.call(:no_abstention, ok, "abstention=#{answer.match?(ABSTENTION)}")
  end
  if c[:checks][:cites]
    ok = citation_titles.any? { |t| t.match?(c[:checks][:cites]) }
    check.call(:cites, ok, citation_titles.inspect)
  end
  if c[:checks][:max_distinct_docs]
    ok = citation_titles.uniq.size <= c[:checks][:max_distinct_docs]
    check.call(:max_distinct_docs, ok, citation_titles.uniq.size)
  end
  if c[:checks][:entity_filter]
    entity_filter = rag_quality && rag_quality["entity_filter"]
    puts "  INFO caso#{n}.entity_filter #{entity_filter.inspect} (informativo, sin veredicto: sin alias GECB no hay ruta deterministica que lo produzca)"
  end
  # session_id y outcome son obligatorios en los 3 casos, no solo cuando el
  # caso los declara explicitamente en CASES.
  check.call(:session_id, rag_quality && rag_quality["conversation_session_id"] == session.id,
             rag_quality && rag_quality["conversation_session_id"].inspect)
  if c[:checks][:outcome]
    ok = usage_by_event.dig("interaction_completed", "outcome") == c[:checks][:outcome] &&
         usage_by_event.dig("photo_question_answered", "outcome") == c[:checks][:outcome]
    check.call(:outcome, ok, "interaction_completed=#{usage_by_event.dig('interaction_completed', 'outcome')} photo_question_answered=#{usage_by_event.dig('photo_question_answered', 'outcome')}")
  end

  expected_sequence = fixed_mode ? %w[photo_analyzed photo_question_answered] : %w[photo_analyzed]
  actual_sequence = case_broadcasts.map { |b| b[:method] }
  broadcast_ok = actual_sequence == expected_sequence
  if fixed_mode && broadcast_ok
    first, second = case_broadcasts
    broadcast_ok &&= first[:payload][:pending_question] == true && !first[:payload].key?(:answer)
    broadcast_ok &&= second[:payload][:answer].present? && first[:payload][:correlation_id] == second[:payload][:correlation_id]
  end
  check.call(:broadcasts, broadcast_ok, actual_sequence.inspect)

  history = session.reload.conversation_history.last(2)
  history_ok = history.size == 2 && history.all? { |h| h["correlation_id"] == correlation_id }
  check.call(:history, history_ok, history.map { |h| h["correlation_id"] }.inspect)

  next unless n == 3

  # Consulta de control texto-only: misma pregunta, sin foto ni ancla. Si abstiene
  # igual que el caso con foto, la causa es cobertura de KB, no el ancla — ver
  # "Veredicto" del plan v2.
  control_correlation_id = "regresion-foto:#{run_id}:3:control"
  control_result = BedrockRagService.new(account: account).query(
    c[:question], output_channel: :web, correlation_id: control_correlation_id
  )
  control_answer = control_result[:answer].to_s
  control_citation_titles = Array(control_result[:citations]).map { |cit| cit[:title] || cit["title"] }.compact
  control_abstains = control_answer.match?(ABSTENTION)
  photo_abstains = answer.match?(ABSTENTION)
  puts "  --- control texto-only (sin foto) ---"
  puts "  VISIBLE<<#{control_answer}>>"
  puts "  citation titles=#{control_citation_titles.uniq.inspect} abstention=#{control_abstains}"
  attribution = if photo_abstains && control_abstains
    "cobertura de KB (ambas abstienen) — no es el ancla"
  elsif photo_abstains && !control_abstains
    "ancla/retrieval con foto (control sin foto SI respondio)"
  else
    "n/a (caso con foto no abstuvo)"
  end
  puts "  INFO caso3.control_atribucion #{attribution}"
end

# ── 7. Cierre ─────────────────────────────────────────────────────────────────
Rails.logger.stop_broadcasting_to(logger)
broadcast_originals.each { |method_name, original| KbSyncBroadcaster.define_singleton_method(method_name) { |**kw| original.call(**kw) } }

bedrock_cost = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_bedrock_id).sum(&:cost) }
puts ""
puts "=== costo_total_usd=#{bedrock_cost.round(4)} (bedrock_queries)"
puts "=== RESULTADO GLOBAL: #{failures.zero? ? 'PASS' : 'FAIL'} (#{failures} fallos, #{warnings} observaciones)"
exit 1 unless failures.zero?
