# frozen_string_literal: true

# Fase A pasos 4–5 — diagnóstico R&G cuenta 3 (16-sep-2026).
# Read-only salvo 1 ConversationSession de sonda (se destruye al final).
# No modifica scripts históricos. Presupuesto: ≤ 20 retrieve_and_generate.
# Ruta = RagQueryConcern (auto-scope, structured route), no BedrockRagService crudo.
#
# Uso producción (script/AGENTS.md, stdin, rol web):
#   CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker ps --filter label=service=smart-deal --filter label=role=web \
#      --filter status=running --format '{{.Names}}' | head -1")
#   ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker exec -i $CID bin/rails runner -" \
#     < script/fase_a_diagnostico_razonamiento_2026-09-16.rb \
#     | tee tmp/razonamiento_tecnico/fase_a/diagnostico_run.txt

require "json"
require "securerandom"
require "stringio"

HARD_CAP = 20
PHOTO_SHA = "e6814d1ab3c145c8d0d3de117017232a642aba9655e72ad9321270d0e397deca"
PHOTO_VALUE = {
  canonical_name: "Fijación de Cables Motor",
  manufacturer: "UNKNOWN",
  model_visible: "UNKNOWN",
  condition: "UNKNOWN",
  visible_codes: [ "Características Motor", "Fijación de Cables", "BOLIVAR 242..." ]
}.freeze
ABSTENTION = Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN

QUESTIONS = {
  "Q-literal" => "Cómo se ajustan los resortes de la fijación de cables",
  "Q-enchufe" => "Cómo se iguala la tensión en el enchufe de cuña de los cables de suspensión",
  "Q-tuercas" => "Cómo se ajustan las tuercas de fijación de cuerda de los cables de suspensión",
  "Q-springs" => "Cómo se comprueba la tensión con los rope terminal springs",
  "B06-yida" => "En el manual Fuji Yida, ¿cómo se iguala la tensión de los cables de suspensión con terminal de cuña?",
  "B08-minispace" => "MiniSpace p. 239 dice igualar la tensión; entonces aflojo el enchufe como en cualquier amarre, ¿cuántas vueltas?"
}.freeze

PHOTO_IDS = %w[Q-literal Q-enchufe Q-tuercas Q-springs].freeze

class FaseAProbe
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

def photo_evidence_block
  codes = PHOTO_VALUE[:visible_codes].join(", ")
  <<~BLOCK.strip
    ## Photo Evidence (this turn)
    The technician attached a photo in this same turn and the question refers to it. The fields below were read from the image, not from the knowledge base; use them to interpret the question. Procedures, values and part identity come only from the retrieved manuals.
    - Component: #{PHOTO_VALUE[:canonical_name]}
    - Manufacturer: #{PHOTO_VALUE[:manufacturer]}
    - Model: #{PHOTO_VALUE[:model_visible]}
    - Visible text/codes: #{codes}
    - Condition: #{PHOTO_VALUE[:condition]}
  BLOCK
end

def blob_from(citations, rag_quality)
  parts = []
  Array(citations).each do |c|
    if c.is_a?(Hash)
      parts << [ c[:title], c["title"], c[:filename], c["filename"], c[:page], c["page"] ].join(" ")
    else
      parts << c.to_s
    end
  end
  parts.concat(Array(rag_quality && rag_quality["citation_titles"]))
  parts.concat(Array(rag_quality && rag_quality["retrieved_source_uris"]))
  parts.join(" | ").downcase
end

def chunk_flags(blob)
  {
    minispace_239: blob.match?(/minispace/) && blob.match?(/\b239\b|chunk_p239/),
    yida_45: blob.match?(/yida/) && blob.match?(/chunk_p45|\bp\.?\s*45\b/),
    yida_46: blob.match?(/yida/) && blob.match?(/chunk_p46|\bp\.?\s*46\b/),
    springs_9: blob.match?(/suspension ropes|lubricacion|01327080|rope terminal/) && blob.match?(/chunk_p9[_.]|\bp\.?\s*9\b/)
  }
end

def answer_flags(answer)
  text = answer.to_s
  {
    rodaderas: text.match?(/rodader/i),
    mordazas: text.match?(/mordaza/i),
    aflojar_enchufe: text.match?(/afloj\w+\s+el\s+enchufe/i),
    cinco_pct: text.match?(/5\s*%|cinco por ciento/i),
    tres_mm: text.match?(/\b3\s*mm\b/i),
    seis_28: text.match?(/6_28/),
    footer_abstention: text.match?(ABSTENTION),
    abre_ausencia: text.match?(/\A.{0,80}(?:no contiene|no se encontr|no incluye|no especifica|DATA_NOT_AVAILABLE)/im)
  }
end

account = Account.find_by(id: ENV.fetch("REGRESSION_ACCOUNT_ID", "3"))
abort_with("cuenta no encontrada") unless account
user = User.find_by(id: ENV.fetch("REGRESSION_USER_ID", "7"))
abort_with("usuario no encontrado") unless user
abort_with("usuario no pertenece a la cuenta") unless user.account_id == account.id
photo = FieldPhoto.find_by(account_id: account.id, sha256: PHOTO_SHA)
abort_with("foto caso 3 no encontrada") unless photo

probe = FaseAProbe.new(account)
state = { rg_count: 0 }
start_id = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i
generation_sha = Digest::SHA256.file(Rails.root.join("app/prompts/bedrock/generation.txt")).hexdigest

session = ConversationSession.create!(
  identifier: "fase-a-diagnostico-#{SecureRandom.hex(4)}",
  channel: "web", account: account, user: user, expires_at: 1.hour.from_now
)
puts "cuenta=#{account.id} user=#{user.id} session_id=#{session.id} photo_id=#{photo.id}"
puts "HARD_CAP=#{HARD_CAP} generation_sha=#{generation_sha}"

log_io = StringIO.new
logger = ActiveSupport::Logger.new(log_io)
Rails.logger.broadcast_to(logger)

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

run_one = lambda do |qid, question, photo:|
  abort_with("HARD_CAP #{HARD_CAP} alcanzado antes de #{qid}") if state[:rg_count] >= HARD_CAP

  correlation_id = "fase-a:#{qid}:#{photo ? 'photo' : 'text'}"
  log_io.truncate(0)
  log_io.rewind
  started = Time.current
  result = probe.send(
    :execute_rag_query,
    question,
    account: account,
    user_id: user.id,
    conversation_session_id: session.id,
    correlation_id: correlation_id,
    session_context: (photo ? photo_evidence_block : nil),
    output_channel: :web
  )
  elapsed = Time.current - started
  skip = result.generation_mode.to_s.match?(/deterministic|selection_gate/)
  billed = skip ? 0 : 1
  state[:rg_count] += billed
  rag_quality = last_rag_quality(log_io, correlation_id)
  answer = result.answer.to_s
  citations = result.citations
  blob = blob_from(citations, rag_quality)
  flags = chunk_flags(blob)
  aflags = answer_flags(answer)
  titles = Array(rag_quality && rag_quality["citation_titles"])
  titles = Array(citations).map { |c| c.is_a?(Hash) ? (c[:title] || c["title"]) : c.to_s } if titles.empty?

  puts "=== #{qid} photo=#{photo} billed=#{billed} rg_count=#{state[:rg_count]} — #{question}"
  puts "  latencia=#{elapsed.round(1)}s generation_mode=#{result.generation_mode} canned_with_retrieval=#{rag_quality && rag_quality['canned_with_retrieval']}"
  puts "  chunk_flags #{flags.map { |k, v| "#{k}=#{v}" }.join(' ')}"
  puts "  answer_flags #{aflags.map { |k, v| "#{k}=#{v}" }.join(' ')}"
  puts "  citation_titles=#{titles.uniq.inspect}"
  puts "  retrieved_uris=#{Array(rag_quality && rag_quality['retrieved_source_uris']).map { |u| File.basename(u.to_s) }.inspect}"
  puts "  VISIBLE<<#{answer}>>"
  puts ""
  abort_with("HARD_CAP #{HARD_CAP} superado") if state[:rg_count] > HARD_CAP
end

PHOTO_IDS.each do |qid|
  question = QUESTIONS.fetch(qid)
  run_one.call(qid, question, photo: false)
  run_one.call(qid, question, photo: true)
end

%w[B06-yida B08-minispace].each do |qid|
  run_one.call(qid, QUESTIONS.fetch(qid), photo: false)
end

puts "=== Retrieve diagnóstico (no cuenta R&G) — #{QUESTIONS.fetch('Q-literal')}"
retrieve = BedrockRagService.new(account: account).retrieve_chunks(
  QUESTIONS.fetch("Q-literal"),
  account_id: account.id,
  correlation_id: "fase-a:retrieve-literal"
)
Array(retrieve[:chunks]).each do |chunk|
  uri = chunk[:location_uri] || chunk[:bedrock_source_uri] || chunk[:original_source_uri]
  basename = File.basename(uri.to_s)
  haystack = "#{uri} #{basename}".downcase
  flags = chunk_flags(haystack).select { |_, v| v }.keys
  puts "  rank=#{chunk[:rank]} score=#{chunk[:score]} #{basename} flags=#{flags.join(',')}"
end
puts ""

Rails.logger.stop_broadcasting_to(logger)
sleep 8
spent = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_id).sum(&:cost) }
session.destroy!
puts "=== rg_count=#{state[:rg_count]} costo_total_usd=#{spent.round(4)} (bedrock_queries; Retrieve/warmup no están aquí)"
