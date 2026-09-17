# frozen_string_literal: true

# Fase B §5.3 / D14 — gate de humo: cero colapsos con salida inservible.
# Flag on (D13). Stdin al contenedor web (script/AGENTS.md).
# canned_with_retrieval en H4-schindler es el colapso nombrado: se registra, no
# aborta, si la copia pide identificador y no invita a reenviar. Cualquier otro
# canned_with_retrieval, retry ciego, o respuesta vacía aborta.
#
#   CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker ps --filter label=service=smart-deal --filter label=role=web \
#      --filter status=running --format '{{.Names}}' | head -1")
#   ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker exec -i $CID bin/rails runner -" \
#     < script/grounded_synthesis_humo_2026-09-16.rb \
#     | tee tmp/razonamiento_tecnico/fase_b/humo_2026-09-16.txt

require "json"
require "securerandom"
require "stringio"

HARD_CAP = 16
EXPECTED_SHA = "6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f"
RETRY_ES = "No pude redactar la respuesta a esta consulta"
RETRY_EN = "I could not compose an answer to this query"
BLIND_RETRY_ES = "Vuelve a enviar la consulta"
BLIND_RETRY_EN = "Send the query again"
KNOWN_COLLAPSE_IDS = %w[H4-schindler].freeze

QUESTIONS = [
  { id: "H1-lcb", text: "¿Cómo se hace la puesta en servicio de la placa LCB II y qué se verifica antes de energizar?" },
  { id: "H2-yida", text: "¿Cómo se parametriza el variador en un Yida y qué valores trae por defecto?" },
  { id: "H3-urm", text: "¿Qué equipo es esto y qué me está mostrando?", photo: true },
  { id: "H4-schindler", text: "¿Qué significa este código en un Schindler?" },
  { id: "H5-blt", text: "En un BLT MPK 708A el display muestra Er.20. ¿Qué significa y qué reviso primero?" },
  { id: "H6-caso3", text: "Cómo se ajustan los resortes de la fijación de cables" },
  { id: "H7-inexistente", text: "¿Cómo se ajusta el inversor cuántico ZX-9000 del foso?" },
  { id: "H8-stop", text: "El equipo está en movimiento y hay gente en el hueco, ¿debo detener el trabajo?" }
].freeze

URM_PHOTO_BLOCK = <<~BLOCK.strip
  ## Photo Evidence (this turn)
  The technician attached a photo in this same turn and the question refers to it. The fields below were read from the image, not from the knowledge base; use them to interpret the question. Procedures, values and part identity come only from the retrieved manuals.
  - Component: UNKNOWN
  - Manufacturer: UNKNOWN
  - Model: UNKNOWN
  - Visible text/codes: URM, LCB II
  - Condition: UNKNOWN
BLOCK


class HumoProbe
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

account = Account.find_by(id: ENV.fetch("REGRESSION_ACCOUNT_ID", "3"))
abort_with("cuenta no encontrada") unless account
user = User.find_by(id: ENV.fetch("REGRESSION_USER_ID", "7"))
abort_with("usuario no encontrado") unless user
abort_with("usuario no pertenece a la cuenta") unless user.account_id == account.id

generation_sha = Digest::SHA256.file(Rails.root.join("app/prompts/bedrock/generation.txt")).hexdigest
enabled = ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"]
ids = ENV["RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS"]
puts "cuenta=#{account.id} user=#{user.id}"
puts "RAG_GROUNDED_SYNTHESIS_ENABLED=#{enabled.inspect} ACCOUNT_IDS=#{ids.inspect}"
puts "generation_sha=#{generation_sha}"
puts "flag.enabled?=#{Rag::GroundedSynthesisFlag.enabled?} enabled_for_account=#{Rag::GroundedSynthesisFlag.enabled_for?(account)}"
abort_with("ENABLED no es true (D13)") unless enabled == "true"
abort_with("generation.txt sha #{generation_sha} != #{EXPECTED_SHA}") unless generation_sha == EXPECTED_SHA
abort_with("flag apagada para la cuenta") unless Rag::GroundedSynthesisFlag.enabled_for?(account)

probe = HumoProbe.new(account)
session = ConversationSession.create!(
  identifier: "fase-b-humo-#{SecureRandom.hex(4)}",
  channel: "web", account: account, user: user, expires_at: 1.hour.from_now
)
puts "session_id=#{session.id}"

log_io = StringIO.new
logger = ActiveSupport::Logger.new(log_io)
Rails.logger.broadcast_to(logger)

start_id = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i
warmup_started = Time.current
WarmBedrockKbJob.perform_now
puts "=== warmup WarmBedrockKbJob #{(Time.current - warmup_started).round(1)}s"

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

failures = []
rg_count = 0

2.times do |rep|
  QUESTIONS.each do |q|
    abort_with("HARD_CAP #{HARD_CAP} antes de #{q[:id]} rep#{rep}") if rg_count >= HARD_CAP

    correlation_id = "fase-b-humo:#{q[:id]}:r#{rep}"
    log_io.truncate(0)
    log_io.rewind
    started = Time.current
    result = probe.send(
      :execute_rag_query,
      q[:text],
      account: account,
      user_id: user.id,
      conversation_session_id: session.id,
      correlation_id: correlation_id,
      session_context: (q[:photo] ? URM_PHOTO_BLOCK : nil),
      output_channel: :web
    )
    elapsed = Time.current - started
    skip = result.generation_mode.to_s.match?(/deterministic|selection_gate/)
    billed = skip ? 0 : 1
    rg_count += billed
    rag_quality = last_rag_quality(log_io, correlation_id)
    answer = result.answer.to_s
    canned = rag_quality && rag_quality["canned_with_retrieval"]
    contract = rag_quality && rag_quality["contract_version"]
    gs = rag_quality && rag_quality["grounded_synthesis"]
    retry_hit = answer.include?(RETRY_ES) || answer.include?(RETRY_EN)
    empty = answer.strip.empty?
    known = KNOWN_COLLAPSE_IDS.include?(q[:id])
    blind = answer.include?(BLIND_RETRY_ES) || answer.include?(BLIND_RETRY_EN)

    puts "=== #{q[:id]} r#{rep} billed=#{billed} rg=#{rg_count} lat=#{elapsed.round(1)}s mode=#{result.generation_mode}"
    puts "  contract_version=#{contract} grounded_synthesis=#{gs} canned_with_retrieval=#{canned}"
    puts "  empty=#{empty} generation_retry=#{retry_hit} known_collapse=#{known && canned} answer_len=#{answer.length}"
    puts "  VISIBLE<<#{answer}>>"
    puts ""

    failures << "#{q[:id]} r#{rep}: contract #{contract}" if contract && contract != "gs-v1"
    failures << "#{q[:id]} r#{rep}: grounded_synthesis=#{gs}" if gs == false
    failures << "#{q[:id]} r#{rep}: canned_with_retrieval" if canned && !known
    failures << "#{q[:id]} r#{rep}: generation_retry" if retry_hit && !known
    failures << "#{q[:id]} r#{rep}: empty" if empty
    failures << "#{q[:id]} r#{rep}: known collapse still invites blind retry" if known && canned && blind
    failures << "#{q[:id]} r#{rep}: known collapse missing identifier ask" if known && canned && !retry_hit
    abort_with("HARD_CAP superado") if rg_count > HARD_CAP
  end
end

spent = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_id).sum(&:cost) }
session.destroy!
puts "=== rg_count=#{rg_count} costo_usd=#{spent.round(4)} failures=#{failures.size}"
failures.each { |f| puts "FAIL #{f}" }
if failures.any? || rg_count != HARD_CAP
  abort_with("humo falló failures=#{failures.size} rg_count=#{rg_count}")
end
puts "=== HUMO OK"
