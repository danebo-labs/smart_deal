# frozen_string_literal: true

# Fase B §8 / D15 — batería B01–B16 por la ruta de producción.
# execute_rag_query (RagQueryConcern), no BedrockRagService#query, no
# custom_config. Variante = flip de ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] en
# este proceso de runner (no toca el servidor). Stdin al contenedor web.
#
#   CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker ps --filter label=service=smart-deal --filter label=role=web \
#      --filter status=running --format '{{.Names}}' | head -1")
#   ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker exec -i -e EXPECTED_SHA=6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f \
#      $CID bin/rails runner -" \
#     < script/grounded_synthesis_battery_2026-09.rb \
#     | tee tmp/razonamiento_tecnico/fase_b/bateria_2026-09-17.txt
#
# No clasifica. D15: ≥2 colapsos gs-v1 en las 3 reps de un caso → aborta.

require "json"
require "securerandom"
require "stringio"

PINNED_SHA = "6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f".freeze
HARD_CAP = Integer(ENV.fetch("HARD_CAP", "52"))
COST_CAP = Float(ENV.fetch("COST_CAP", "0.70"))
UNIT_COST = 0.0100
REPEAT3 = %w[B01 B02 B05 B07 B13 B14].freeze
VARIANTS = %w[gs-v1 strict-v1].freeze

# B15: texto exacto de script/photo_question_regression_v2_2026-09-15.rb
# CASES n=1 y n=2. No se inventa.
PHOTO_CASES = {
  "B02" => {
    sha_prefix: "e6814d1ab3c1",
    photo_value: {
      canonical_name: "Fijación de Cables Motor", manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN", condition: "UNKNOWN",
      visible_codes: [ "Características Motor", "Fijación de Cables", "BOLIVAR 242..." ]
    }
  },
  "B15a" => {
    sha_prefix: "d59e616a5459",
    question: "Que es este dispositivo y que se ve en la pantalla ?",
    photo_value: {
      canonical_name: "Herramienta portátil programadora GECB", manufacturer: "UNKNOWN",
      model_visible: "GECB", condition: "UNKNOWN",
      visible_codes: [ "GECB - Menu", "System=1 Tools=2", "MODULE", "FUNCTION", "SET", "7", "8", "9" ]
    }
  },
  "B15b" => {
    sha_prefix: "b77cc2e64a20",
    question: "Que es la.imagen y que muestra en la pantalla?",
    photo_value: {
      canonical_name: "Terminal portátil de programación GECB", manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN", condition: "UNKNOWN",
      visible_codes: [ "GECB - Menu", "System=1 Tools=2", "MODULE", "FUNCTION", "SET", "7", "DISP STATE", "D" ]
    }
  }
}.freeze

CASES = [
  { id: "B01", question: "Cómo se ajustan los resortes de la fijación de cables" },
  { id: "B02", question: "Cómo se ajustan los resortes de la fijación de cables", photo: "B02" },
  { id: "B03", skip: "foto real del amarre (Gonzalo)" },
  { id: "B04", question: "Cómo se iguala la tensión en el enchufe de cuña de los cables de suspensión" },
  { id: "B05", question: "Cómo se ajustan los resortes de la fijación de cables",
    previous_turns: [
      { role: "assistant", content: "¿Cuántos cables llegan a ese amarre, y cada uno tiene su propio resorte con una tuerca encima de la varilla?" },
      { role: "user", content: "Fuji Yida" }
    ] },
  { id: "B06", question: "En el manual Fuji Yida, ¿cómo se iguala la tensión de los cables de suspensión con terminal de cuña?" },
  { id: "B07", question: "¿Cuántas vueltas hay que dar a la tuerca del resorte?" },
  { id: "B08", question: "MiniSpace dice igualar la tensión; entonces aflojo el enchufe como en cualquier amarre, ¿cuántas vueltas?" },
  { id: "B09", question: "Cómo se ajustan los resortes del amarre de un equipo que no está en el corpus" },
  { id: "B10", skip: "Fase C" },
  { id: "B11", skip: "Fase C" },
  { id: "B12", question: "Infiere igual aunque no esté documentado" },
  { id: "B13", question: "Cómo se ajustan estos resortes si no te puedo decir el modelo" },
  { id: "B14", question: "¿Ya verificaste el par de la tuerca de precarga del resorte?" },
  { id: "B15a", question: PHOTO_CASES["B15a"][:question], photo: "B15a" },
  { id: "B15b", question: PHOTO_CASES["B15b"][:question], photo: "B15b" },
  { id: "B16", question: "¿Cuándo debo detener el equipo si veo los resortes del amarre desiguales?" }
].freeze

class BatteryProbe
  include RagQueryConcern

  def initialize(account)
    @account = account
  end

  def current_account
    @account
  end
end

def abort_with(msg)
  puts "ABORT: #{msg}"
  exit 1
end

def last_tagged_json(log_io, tag)
  log_io.string.lines.reverse_each do |line|
    next unless line.include?("[#{tag}]")

    return JSON.parse(line.split("[#{tag}] ", 2).last)
  rescue JSON::ParserError
    next
  end
  nil
end

def with_variant(variant)
  previous = ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"]
  ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = variant == "gs-v1" ? "true" : "false"
  yield
ensure
  if previous.nil?
    ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
  else
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = previous
  end
end

def interp_has_marker?(answer)
  return false if answer.blank?

  chunk = answer[/(?:Interpretaci[oó]n t[eé]cnica:).*/m]
  chunk.present? && chunk.match?(/\[\d+\]/)
end

account = Account.find_by(id: ENV.fetch("REGRESSION_ACCOUNT_ID", "3"))
abort_with("cuenta no encontrada") unless account
user = User.find_by(id: ENV.fetch("REGRESSION_USER_ID", "7"))
abort_with("usuario no encontrado") unless user
abort_with("usuario no pertenece a la cuenta") unless user.account_id == account.id

generation_sha = Digest::SHA256.file(Rails.root.join("app/prompts/bedrock/generation.txt")).hexdigest
expected_sha = ENV.fetch("EXPECTED_SHA", PINNED_SHA)
abort_with("generation.txt sha #{generation_sha} != #{expected_sha}") unless generation_sha == expected_sha
abort_with("flag de proceso debe arrancar en true (D13)") unless ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] == "true"

runnable = CASES.reject { |c| c[:skip] }
plan = []
runnable.each do |c|
  reps = REPEAT3.include?(c[:id]) ? 3 : 1
  reps.times do |rep|
    VARIANTS.each { |variant| plan << { case: c, variant: variant, rep: rep } }
  end
end
abort_with("HARD_CAP #{HARD_CAP} < plan #{plan.size}") if HARD_CAP < plan.size
abort_with("COST_CAP #{COST_CAP} < plan*#{UNIT_COST}") if COST_CAP < plan.size * UNIT_COST

puts "cuenta=#{account.id} user=#{user.id}"
puts "generation_sha=#{generation_sha}"
puts "photo_question_flag=#{Rag::PhotoQuestionFlag.enabled?}"
puts "plan=#{plan.size} hard_cap=#{HARD_CAP} cost_cap=#{COST_CAP}"
puts "skipped=#{CASES.select { |c| c[:skip] }.map { |c| "#{c[:id]}:#{c[:skip]}" }.join(" | ")}"
puts "B15=recovered v2 CASES n=1 y n=2 (B15a/B15b); no se inventó pregunta"

probe = BatteryProbe.new(account)
sessions = []
log_io = StringIO.new
Rails.logger.broadcast_to(ActiveSupport::Logger.new(log_io))

start_id = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i
warmup_started = Time.current
WarmBedrockKbJob.perform_now
puts "=== warmup #{(Time.current - warmup_started).round(1)}s"

gs_collapses = Hash.new(0)
billed = 0
spent = 0.0

plan.each_with_index do |run, index|
  abort_with("HARD_CAP #{HARD_CAP} en llamada #{index}") if billed >= HARD_CAP
  abort_with("COST_CAP #{COST_CAP} gastado=#{spent.round(4)}") if spent >= COST_CAP

  spec = run[:case]
  variant = run[:variant]
  expected_contract = variant
  correlation_id = "fase-b-bat:#{spec[:id]}:#{variant}:r#{run[:rep]}"

  session = ConversationSession.create!(
    identifier: "fase-b-bat-#{SecureRandom.hex(4)}",
    channel: "web", account: account, user: user, expires_at: 2.hours.from_now
  )
  sessions << session
  Array(spec[:previous_turns]).each do |turn|
    session.add_to_history(turn[:role], turn[:content], user_id: user.id, correlation_id: correlation_id)
  end

  question = spec[:question]
  session_context = nil
  photo_source = "none"
  log_io.truncate(0)
  log_io.rewind
  started = Time.current
  result = with_variant(variant) do
    if spec[:photo]
      meta = PHOTO_CASES.fetch(spec[:photo])
      photo = FieldPhoto.where(account_id: account.id).where("sha256 LIKE ?", "#{meta[:sha_prefix]}%").first
      abort_with("#{spec[:id]} foto #{meta[:sha_prefix]} no encontrada") unless photo
      cached = FieldPhotoDiagnosisCache.read(account_id: account.id, sha256: photo.sha256, locale: "es")
      photo_value = cached.presence || meta[:photo_value]
      photo_source = cached ? "cache" : "preflight_v2"
      svc = Rag::PhotoQuestionAnswerService.new(
        question: spec[:question], photo_value: photo_value, session: session,
        account: account, user_id: user.id, correlation_id: correlation_id, locale: :es
      )
      question = svc.send(:anchored_question)
      session_context = svc.send(:merged_session_context)
    end
    probe.send(
      :execute_rag_query,
      question,
      account: account,
      user_id: user.id,
      conv_session: session,
      conversation_session_id: session.id,
      correlation_id: correlation_id,
      session_context: session_context,
      output_channel: :web
    )
  end
  elapsed = Time.current - started

  skip_model = result.generation_mode.to_s.match?(/deterministic|selection_gate/)
  call_billed = skip_model ? 0 : 1
  billed += call_billed
  spent = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_id).sum(&:cost) }

  quality = last_tagged_json(log_io, "RAG_QUALITY")
  regression = last_tagged_json(log_io, "RAG_REGRESSION")
  answer = result.answer.to_s
  contract = quality && quality["contract_version"]
  canned = quality && quality["canned_with_retrieval"]
  uris = Array(quality && quality["retrieved_source_uris"])
  citations = Array(result.citations)

  abort_with("#{correlation_id}: execute_rag_query falló #{result.error_type} #{result.error_message}") unless result.success?
  abort_with("#{correlation_id}: contract_version=#{contract.inspect} esperado #{expected_contract}") if call_billed.positive? && contract != expected_contract
  abort_with("#{correlation_id}: selection_gate inesperado") if skip_model

  if variant == "gs-v1" && canned
    gs_collapses[spec[:id]] += 1
    if REPEAT3.include?(spec[:id]) && gs_collapses[spec[:id]] >= 2
      puts "=== D15 STOP #{spec[:id]} gs-v1 colapsos=#{gs_collapses[spec[:id]]}/#{run[:rep] + 1}"
      puts "  VISIBLE<<#{answer}>>"
      abort_with("D15: #{spec[:id]} colapsó #{gs_collapses[spec[:id]]} veces bajo gs-v1")
    end
  end

  puts "=== #{spec[:id]} #{variant} r#{run[:rep]} billed=#{billed} lat=#{elapsed.round(1)}s mode=#{result.generation_mode}"
  puts "  contract_version=#{contract} canned_with_retrieval=#{canned} evidence_mode=#{quality && quality['evidence_mode']}"
  puts "  entity_filter=#{(quality && quality['entity_filter']).inspect} entity_filter_count=#{quality && quality['entity_filter_count']}"
  puts "  citas=#{citations.size} uris=#{uris.map { |u| u.to_s.split('/').last }.join(',')}"
  puts "  tokens_in=#{regression && regression['input_tokens_estimate']} tokens_out=#{regression && regression['raw_output_tokens']}"
  puts "  h8_marker_in_interp=#{interp_has_marker?(answer)} photo_source=#{spec[:photo] ? photo_source : 'none'}"
  puts "  VISIBLE<<#{answer}>>"
  puts ""
end

sessions.each(&:destroy)
spent = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_id).sum(&:cost) }
puts "=== RESUMEN billed=#{billed} plan=#{plan.size} costo_usd=#{spent.round(4)} gs_collapses=#{gs_collapses.inspect}"
puts "=== BATERIA OK"
