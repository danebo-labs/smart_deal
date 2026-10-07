# frozen_string_literal: true

# Stage 2 Journey A. Local Rails, production Knowledge Base, no pin, no L3.
# Sessions stay on the development database. This file is not product code.
# It records the request of THIS run. It does not reconstruct an earlier pass.
# Refuses to start unless STAGE2_JOURNEY_AUTHORIZED=1.
require "json"
require "fileutils"

class Stage2QueryHost
  include RagQueryConcern

  def initialize(account)
    @current_account = account
  end

  attr_reader :current_account

  def execute(question, **)
    execute_rag_query(question, **)
  end
end

abort("stage 2 runner refused without STAGE2_JOURNEY_AUTHORIZED=1") unless ENV["STAGE2_JOURNEY_AUTHORIZED"] == "1"

PROD_KB = "Y7RZWMFJSR"
UID = "dcc8e046-037d-48a6-8913-1992aed28507"
S3_KEY = "bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf"
DISPLAY = "Elemont Montacargas Hidraulico Modelo MH"
TRACE_ROOT = Rails.root.join("tmp/stage2_journey_a")

db = ActiveRecord::Base.connection_db_config
abort("refuse #{db.database}@#{db.host}") unless Rails.env.development? &&
  db.database == "smart_deal_development" &&
  %w[localhost 127.0.0.1].include?(db.host.to_s)
abort("kb #{ENV['BEDROCK_KNOWLEDGE_BASE_ID']}") unless ENV["BEDROCK_KNOWLEDGE_BASE_ID"] == PROD_KB
abort("shared session on") if SharedSession::ENABLED
abort("owner off") unless Rag::HaikuQueryAnalysisFlag.owner?
abort("episode off") unless Rag::FieldCompanionEpisodeFlag.enabled?
abort("turn off") unless Rag::FieldCompanionTurnFlag.enabled?

module InlineBedrockQueryTracking
  def perform_later(...)
    perform_now(...)
  end
end
TrackBedrockQueryJob.singleton_class.prepend(InlineBedrockQueryTracking)

Rails.logger.level = Logger::WARN


def elemont_text?(value)
  text = value.to_s
  text.include?("Elemont Montacargas") ||
    text.include?("Montacargas 2N") ||
    text.include?("dcc8e046") ||
    text.include?("121bfffe")
end

def citation_row(citation)
  data = citation.to_h.deep_stringify_keys
  meta = data["metadata"].to_h
  location = data["location"].to_s
  uri = [
    data["location_uri"], data["original_source_uri"], data["bedrock_source_uri"],
    location, meta["original_source_uri"], meta["x-amz-bedrock-kb-source-uri"]
  ].compact.join(" ")
  name = meta["canonical_name"].presence || data["title"].presence || data["filename"].presence
  {
    "name" => name.to_s,
    "page" => data["page"] || meta["page_number"] || meta["x-amz-bedrock-kb-document-page-number"],
    "account_id" => (meta["account_id"] || data["account_id"]).to_s,
    "elemont" => elemont_text?("#{name} #{uri}"),
    "uri" => uri.sub(%r{\As3://[^/]+/}, "").slice(0, 180)
  }
end

def episode_view(session)
  parsed = Rag::ActiveEpisode.parse(session.active_episode)
  {
    "episode_id" => session.live_episode_id,
    "goal" => parsed.goal.to_s,
    "facts" => parsed.facts,
    "identifiers" => parsed.identifiers,
    "observations" => parsed.observations,
    "rejected" => parsed.rejected,
    "pending_question" => parsed.pending_question.to_s
  }
end

def history_view(session)
  messages = Array(session.conversation_history)
  {
    "count" => messages.size,
    "roles" => messages.pluck("role"),
    "user_texts" => messages.select { |message| message["role"] == "user" }.map { |message| message["content"].to_s }
  }
end

# This run only. Stage2RunBudget adds the 80 calls and US$0.161562 already
# spent. Counting rows after the baseline and comparing them with 126 would
# reopen the ceiling.
def this_run_queries(baseline_id, session_id)
  BedrockQuery.where("id > ?", baseline_id).where(
    "conversation_session_id = :sid OR correlation_id LIKE :prefix",
    sid: session_id,
    prefix: "stage2:a:%"
  ).where.not(correlation_id: "stage2:a:availability").order(:id).map do |row|
    {
      "id" => row.id,
      "source" => row.source,
      "route" => row.route,
      "model_id" => row.model_id,
      "input_tokens" => row.input_tokens,
      "output_tokens" => row.output_tokens,
      "cost_usd" => row.cost.to_f,
      "correlation_id" => row.correlation_id
    }
  end
end

def run_sha
  value = IO.popen([ "git", "-C", Rails.root.to_s, "rev-parse", "HEAD" ], &:read).to_s.strip
  value.match?(/\A[0-9a-f]{40}\z/) ? value : "unknown"
rescue StandardError
  "unknown"
end

def write_manifest(directory, sha:, session_id:, run_id:, rows:)
  cost = rows.sum { |item| item["cost_usd"] }
  File.write(
    directory.join("manifest.json"),
    JSON.pretty_generate(
      Rag::Stage2RunBudget.manifest(
        sha: sha, session_id: session_id, run_id: run_id,
        new_calls: rows.size, new_cost_usd: cost
      )
    )
  )
end

def spend_snapshot(rows)
  Rag::Stage2RunBudget.snapshot(
    new_calls: rows.size,
    new_cost_usd: rows.sum { |item| item["cost_usd"] }
  )
end


account = Account.find_by(id: 1)
if account.nil?
  account = Account.create!(
    id: 1,
    slug: "index-account-1",
    display_name: "Index account 1",
    danebo_controlled: false,
    branded: false
  )
end
abort("account 1 slug collision #{account.slug}") if account.id != 1

user = User.find_by(email: "stage2-journey-a@localhost.test")
if user.nil?
  password = SecureRandom.hex(16)
  user = User.create!(
    account: account,
    email: "stage2-journey-a@localhost.test",
    password: password,
    password_confirmation: password
  )
end
abort("user account #{user.account_id}") unless user.account_id == account.id

document = KbDocument.find_by(account_id: account.id, document_uid: UID) ||
  KbDocument.find_by(account_id: account.id, s3_key: S3_KEY)
if document.nil?
  document = KbDocument.create!(
    account: account,
    document_uid: UID,
    s3_key: S3_KEY,
    display_name: DISPLAY,
    knowledge_scope: "tenant_private"
  )
end

run_id = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
session = ConversationSession.create!(
  account: account,
  user: user,
  identifier: "stage2:journey-a:#{run_id}",
  channel: "web",
  expires_at: 30.days.from_now,
  conversation_history: [],
  active_episode: {}
)
out = Rag::Stage2RunBudget.evidence_directory(TRACE_ROOT, run_id: run_id, session_id: session.id)
FileUtils.mkdir_p(out)
sha = run_sha
File.write(out.join("session.txt"), "session_id=#{session.id} account_id=#{account.id} user_id=#{user.id} document_id=#{document.id} sha=#{sha}\n")
write_manifest(out, sha: sha, session_id: session.id, run_id: run_id, rows: [])

service = BedrockRagService.new(account: account, knowledge_base_id: PROD_KB)
availability = nil
availability_capture = Rag::ValidationCapture.capture do
  Rag::ValidationCapture.correlation = "stage2:a:availability"
  availability = service.retrieve_chunks(
    "Elemont Montacargas Hidraulico Modelo MH",
    number_of_results: 5,
    account_id: account.id,
    user_id: user.id,
    correlation_id: "stage2:a:availability",
    route_taken: "availability_check"
  )
end
available = Array(availability[:chunks]).map { |chunk| citation_row(chunk) }
File.write(out.join("availability.json"), JSON.pretty_generate(
  "chunks" => available.size,
  "elemont" => available.any? { |row| row["elemont"] },
  "capture" => availability_capture,
  "rows" => available
))
unless available.any? { |row| row["elemont"] }
  warn "RETRIEVAL_EMPTY"
  exit 2
end

fixture = YAML.load_file(Rails.root.join("test/fixtures/files/field_companion/longitudinal_journeys.yml"))
turns = fixture.dig("journeys", "A", "turns")
host = Stage2QueryHost.new(account)
baseline_id = BedrockQuery.maximum(:id).to_i
trace = []
previous_answer = ""

turns.each do |row|
  rows = this_run_queries(baseline_id, session.id)
  spent = spend_snapshot(rows)
  unless spent.admit_turn
    trace << {
      "n" => row["n"],
      "stopped" => "budget",
      "calls" => spent.calls,
      "new_calls" => spent.new_calls,
      "historical_calls" => spent.historical_calls,
      "cost_usd" => spent.cost_usd.to_s("F"),
      "pass_calls_remaining" => spent.pass_calls_remaining
    }
    break
  end

  original = row["text"].to_s
  sent, notes, asked = Rag::JourneyAMessages.adapt(turn_number: row["n"], original: original, previous_answer: previous_answer)
  correlation_id = "stage2:a:t#{format('%02d', row['n'])}"
  record = {
    "n" => row["n"],
    "original" => original,
    "sent" => sent,
    "adaptation" => notes,
    "asked" => asked
  }
  capture = Rag::ValidationCapture.capture do
  begin
    Rag::ValidationCapture.correlation = correlation_id
    episode_turn = session.record_user_turn!(
      sent,
      user_id: user.id,
      correlation_id: correlation_id,
      locale: :es,
      interpreter_client: nil
    )
    expected_episode_id = session.live_episode_id
    context = SessionContextBuilder.build(session).to_s
    uris = SessionContextBuilder.entity_s3_uris(session)
    understanding = episode_turn&.understanding
    record["decision"] = understanding&.decision
    record["episode_decision"] = episode_turn&.decision&.to_s
    record["clarify_first"] = understanding.respond_to?(:clarify_first?) ? understanding.clarify_first? : nil
    record["retrieval_query"] = understanding&.retrieval_query
    record["prompt"] = context
    Rag::ValidationCapture.correlation = "#{correlation_id}:query"
    result = host.execute(
      sent,
      conv_session: session,
      account: account,
      user_id: user.id,
      correlation_id: "#{correlation_id}:query",
      conversation_session_id: session.id,
      episode_turn: episode_turn,
      response_locale: :es,
      output_channel: :web,
      raw_question: sent,
      session_context: context,
      entity_s3_uris: uris
    )
    record["success"] = result.respond_to?(:success?) ? result.success? : nil
    record["error_class"] = result.respond_to?(:error_class) ? result.error_class : nil
    record["error_type"] = result.respond_to?(:error_type) ? result.error_type&.to_s : nil
    record["answer"] = result.respond_to?(:answer) ? result.answer.to_s : ""
    record["model_invoked"] = result.respond_to?(:model_invoked) ? result.model_invoked : nil
    record["generation_mode"] = result.respond_to?(:generation_mode) ? result.generation_mode : nil
    record["effective_question"] = result.respond_to?(:effective_question) ? result.effective_question.to_s : nil
    citations = Array(result.respond_to?(:retrieved_citations) ? result.retrieved_citations : nil)
    citations = Array(result.citations) if citations.empty? && result.respond_to?(:citations)
    record["citations"] = citations.map { |citation| citation_row(citation) }
    record["searched"] = record["clarify_first"] == false && (record["model_invoked"] == true || record["citations"].any? || record["generation_mode"].present?)
    Rag::ValidationCapture.record(
      "documents",
      "retrieval_query" => record["retrieval_query"],
      "context_truncated" => session.context_truncated == true,
      "citations" => record["citations"]
    )
    if result.respond_to?(:success?) && result.success? && result.respond_to?(:answer)
      session.stamp_user_retrieval_query!(correlation_id, result.effective_question || sent) if result.images_uploaded.blank?
      session.record_assistant_turn!(
        result.answer.to_s,
        user_id: user.id,
        correlation_id: result.correlation_id,
        pending_question: result.pending_question,
        expected_episode_id: expected_episode_id,
        focus_ids: session.focus_document_ids
      )
    end
    record["context_truncated"] = session.context_truncated == true
    session.reload
    record["episode"] = episode_view(session)
    record["history"] = history_view(session)
    previous_answer = record["answer"]
  rescue StandardError => error
    record["error_class"] = error.class.name
    record["error_message"] = error.message.to_s.gsub(/AKIA[A-Z0-9]+/, "[redacted]").slice(0, 500)
    record["success"] = false
  end
  end
  record["capture"] = capture
  rows = this_run_queries(baseline_id, session.id)
  spent = spend_snapshot(rows)
  record["calls_total"] = spent.calls
  record["new_calls"] = spent.new_calls
  record["historical_calls"] = spent.historical_calls
  record["cost_usd_total"] = spent.cost_usd.to_s("F")
  record["calls"] = rows.select { |item| item["correlation_id"].to_s.include?("t#{format('%02d', row['n'])}") }
  trace << record
  File.write(out.join("trace.json"), JSON.pretty_generate(trace))
  write_manifest(out, sha: sha, session_id: session.id, run_id: run_id, rows: rows)
  warn "turn=#{row['n']} success=#{record['success']} calls=#{record['calls_total']} new=#{record['new_calls']} cost=#{record['cost_usd_total']} elemont=#{record['citations']&.any? { |item| item['elemont'] }}"
  if row["n"].to_i == 1 && record["success"] == false
    warn "INCONCLUSIVE turn 1"
    break
  end
end

File.write(out.join("trace.json"), JSON.pretty_generate(trace))
write_manifest(out, sha: sha, session_id: session.id, run_id: run_id, rows: this_run_queries(baseline_id, session.id))
warn "done turns=#{trace.size} session=#{session.id} out=#{out}"
