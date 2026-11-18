# frozen_string_literal: true

require "test_helper"

# Offline replay of turns 4 and 5 of the Thyssen EA case, from the state the
# first three turns leave. Turn 4 uses the interpreter output and the sixteen
# Retrieve rows captured in the sixth real run (narrative text only). The
# interpreter and generator are scripted; every other stage is the product
# path: perception, route, case state, Retrieve filter, rerank, the window the
# generator receives, publication and the case ledger.
class ThyssenEaMeasurementCaseTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  FIXTURES = Rails.root.join("test/fixtures/field_companion/thyssen_ea_t4")
  MANUAL_KEY = "bulk_uploads/3/2026-08-20/THYSSEN (Manual de Maniobra Universal con MCINV4).pdf"
  MANUAL_NAME = "THYSSEN (Manual de Maniobra Universal con MCINV4)"
  EA_LINE = "Quando falha de P28 - porta aberta - revisar linha dos trincos"
  NOMINAL = "RA-53 / P28 = +110 Vcc"
  OPENING = "Estoy con un Thyssen FDN Universal con MCINV4. El ascensor quedó detenido y el display marca EA"
  SYMPTOM = "La puerta del piso no termina de cerrar"
  OBSERVATION = "El trinco no engancha. Se ve desalineado"
  MEASUREMENT = "Ya lo alinearon. Ahora la puerta cierra y traba bien, pero sigue marcando EA. Tiene motor de operador. " \
    "Con la puerta cerrada y trabada, medí 0 Vcc en RA\u201153/P28. ¿Qué me dice esa lectura?"
  CLARIFICATION = "Ya, ¿por qué partirías por los trincos?"
  T4_FACTS = [
    "la puerta cierra y traba bien", "sigue marcando EA", "Tiene motor de operador", "medí 0 Vcc en RA\u201153/P28"
  ].freeze

  setup do
    @user = users(:one)
    @account = accounts(:pilot)
    host! "piloto.danebo.ai"
    @user.update!(account: @account)
    sign_in @user
    @env = %w[
      HAIKU_QUERY_ANALYSIS_MODE FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED RAG_COMPANION_TURN
      DOCUMENT_IDENTITY_SCOPE_ENABLED RAG_EPISODE_SCOPE_ENABLED BEDROCK_KNOWLEDGE_BASE_ID RAG_COMPANION_GENERATION
      BEDROCK_INFERENCE COMPANION_DIRECT_EFFORT COMPANION_DIRECT_THINKING COMPANION_DIRECT_MAX_TOKENS
      COMPANION_DIRECT_MODEL_ID COMPANION_DIRECT_PROVIDER ANTHROPIC_API_KEY SHOW_RAG_SOURCES RAG_TRANSIENT_ATTEMPT_LIMIT
    ].index_with { |key| ENV[key] }
    %w[
      HAIKU_QUERY_ANALYSIS_MODE FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED RAG_COMPANION_TURN
      DOCUMENT_IDENTITY_SCOPE_ENABLED RAG_EPISODE_SCOPE_ENABLED RAG_COMPANION_GENERATION COMPANION_DIRECT_EFFORT
      COMPANION_DIRECT_MODEL_ID COMPANION_DIRECT_PROVIDER COMPANION_DIRECT_MAX_TOKENS COMPANION_DIRECT_THINKING
    ].each { |key| ENV.delete(key) }
    ENV["ANTHROPIC_API_KEY"] = "offline-replay"
    ENV["SHOW_RAG_SOURCES"] = "true"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "Y7RZWMFJSR"
    ENV["BEDROCK_INFERENCE"] = "blocked"
  end

  teardown do
    @env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "turn 4 keeps the four facts and the nominal page, and turn 5 explains from the case record" do
    manual = KbDocument.create!(account: @account, s3_key: MANUAL_KEY, display_name: MANUAL_NAME,
      document_uid: SecureRandom.uuid, aliases: [])
    chunks = JSON.parse(FIXTURES.join("chunks.json").read).fetch("rows")
    raw_t4 = JSON.parse(FIXTURES.join("interpreter_t4.json").read)
    assert_equal 4, raw_t4.fetch("observations").size

    t5_rows = chunks.select { |row| [ 24, 19, 10, 21, 20 ].include?(row["page"]) }
    turns = [
      turn(OPENING, perception("report", assertions: opening_assertions, observations: [ "El ascensor quedó detenido", "el display marca EA" ]),
        "Con EA, «#{EA_LINE}» [p24]. ¿La puerta del piso cierra por completo?", chunks.select { |row| row["page"] == 24 }),
      turn(SYMPTOM, perception("follow_up", observations: [ SYMPTOM ]),
        "Con EA y la puerta sin cerrar, «#{EA_LINE}» [p24]. P28 es la hipótesis. ¿El trinco engancha?",
        chunks.select { |row| row["page"] == 24 }),
      turn(OBSERVATION, perception("follow_up", observations: [ "El trinco no engancha", "Se ve desalineado" ]),
        "Anotado: es tu observación. «#{EA_LINE}» [p24]. Luego comprueba si la puerta cierra, traba y EA persiste.",
        chunks.select { |row| row["page"] == 24 }),
      turn(MEASUREMENT, raw_t4,
        "Reportaste 0 Vcc en RA-53/P28 con la puerta cerrada y trabada. La tabla indica «#{NOMINAL}» [p9]. " \
        "Con EA, «#{EA_LINE}» [p24]. Revisa la línea de trincos; la causa exacta sigue abierta.",
        chunks, rank_by_page: true),
      turn(CLARIFICATION, perception("follow_up"),
        "Parto por los trincos porque «#{EA_LINE}» [p24] y la tabla indica «#{NOMINAL}» [p9]. " \
        "Reportaste 0 Vcc en ese punto. La causa exacta sigue abierta.",
        t5_rows, rank_by_page: true)
    ]
    cassette = Cassette.new(turns, viewer_id: @account.id, focus_uri: manual.canonical_uri)

    with_doubles(cassette) do
      kase = open_case(manual, cassette)
      episode_id = kase.episode_id
      ask(kase, SYMPTOM)
      ask(kase, OBSERVATION)
      assert_equal %w[24], ledger_pages(kase), "turns 1 to 3 cite page 24"

      events, body = ask(kase, MEASUREMENT)
      assert_equal "success", body.fetch("status"), body.inspect
      assert_equal "completed", body.dig("field_turn", "status") || "completed"
      perception = events.find { |event| event["kind"] == "perception_applied" }
      assert_equal true, perception["valid"], perception.inspect
      assert_not events.any? { |event| event["kind"] == "route_exit" && event["exit"] == "fallback" }
      stored = kase.reload.technical_state.fetch("observations")
      assert_equal T4_FACTS, stored.last(4).pluck("text")
      assert_equal [ "query" ] * 4, stored.last(4).map { |row| row["correlation_id"].split(":").first }
      assert_equal episode_id, kase.episode_id

      sources = events.find { |event| event["kind"] == "companion_sources" }
      assert_equal [ 24 ], sources["kept"].select { |row| row["case_ledger"] }.pluck("page").map(&:to_i)
      delivered = events.find { |event| event["kind"] == "generator_evidence" }.fetch("rows")
      assert_equal [ 24, 19, 10, 9 ], delivered.map { |row| row["page"].to_i }
      nominal_row = delivered.find { |row| row["page"].to_i == 9 }
      assert_includes nominal_row.fetch("text").to_s, NOMINAL
      prompt = cassette.generator_prompt
      assert_includes prompt, "- medí 0 Vcc en RA\u201153/P28"
      assert_not_includes prompt, "¿Qué me dice esa lectura?\nEl ascensor"
      assert_includes prompt, EA_LINE
      publication = events.find { |event| event["kind"] == "companion_publication" }
      assert_equal true, publication["accepted"], publication.inspect
      assert_includes body.fetch("answer"), "línea de trincos"
      assert_equal %w[24 9], ledger_pages(kase), "the ledger keeps the passages the answer cited"

      events, body = ask(kase, CLARIFICATION)
      assert_equal "success", body.fetch("status"), body.inspect
      assert_equal stored.size, kase.reload.technical_state.fetch("observations").size, "the clarification adds no fact"
      delivered = events.find { |event| event["kind"] == "generator_evidence" }.fetch("rows")
      pages = delivered.map { |row| row["page"].to_i }
      assert_includes pages, 9, "page 9 stays from the case record although Retrieve did not return it"
      assert_includes pages, 24
      assert_equal [ "ledger" ], delivered.select { |row| row["page"].to_i == 9 }.pluck("origin").uniq
      assert(events.find { |event| event["kind"] == "companion_publication" }["accepted"])
      assert_equal episode_id, kase.reload.episode_id
      assert_equal [ manual.id ], kase.document_focus.pluck("kb_document_id")
      cassette.filters.each { |filter| assert_includes filter.to_json, manual.canonical_uri }
    end
  end

  private

  def perception(move, assertions: [], observations: [])
    { "move" => move, "assertions" => assertions, "observations" => observations,
      "pending_resolution" => nil, "clarification_target" => nil }
  end

  def opening_assertions
    [ %w[Thyssen manufacturer], [ "FDN Universal", "model" ], %w[MCINV4 controller], %w[EA fault_code] ].map do |span, hint|
      { "span" => span, "act" => "assert", "slot_hint" => hint }
    end
  end

  def turn(question, tool_input, answer, rows, rank_by_page: false)
    { question: question, tool_input: tool_input, answer: answer, rows: rows, rank_by_page: rank_by_page }
  end

  def open_case(manual, cassette)
    post rag_ask_path, params: { creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid,
                                 question: OPENING, kb_document_ids: [ manual.id.to_s ] }, as: :json
    assert_includes [ 200, 202 ], response.status, response.body
    kase = FieldCase.find(response.parsed_body.fetch("field_case_id"))
    assert_equal [ manual.id ], kase.document_focus.pluck("kb_document_id")
    cassette.filters.each { |filter| assert_includes filter.to_json, manual.canonical_uri }
    kase
  end

  def ask(kase, question)
    body = nil
    events = Rag::ValidationCapture.capture do
      post rag_ask_path, params: { field_case_id: kase.id, client_submission_id: SecureRandom.uuid, question: question }, as: :json
      body = response.parsed_body
    end
    [ events, body ]
  end

  def ledger_pages(kase)
    Array(kase.reload.technical_state.dig("case_evidence", "sources")).map { |row| row["page"].to_i.to_s }
  end

  def with_doubles(cassette)
    original_anthropic = Anthropic::Client.method(:new)
    original_agent = Aws::BedrockAgentRuntime::Client.method(:new)
    Anthropic::Client.define_singleton_method(:new) { |*, **| cassette }
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*, **| cassette }
    yield
  ensure
    Anthropic::Client.define_singleton_method(:new) { |*args, **kwargs| original_anthropic.call(*args, **kwargs) }
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args, **kwargs| original_agent.call(*args, **kwargs) }
  end

  class Cassette
    attr_reader :sent, :filters

    def initialize(turns, viewer_id:, focus_uri:)
      @turns = turns
      @viewer_id = viewer_id
      @focus_uri = focus_uri
      @index = 0
      @sent = []
      @filters = []
    end

    def messages
      self
    end

    def create(**payload)
      @sent << payload
      turn = @turns.fetch(@index)
      return reply(turn[:tool_input], "tool_use", tool: true) if payload[:tool_choice] || payload["tool_choice"]

      @index += 1
      prompt = payload.fetch(:messages).last.fetch(:content).pluck(:text).join
      answer = turn[:answer].gsub(/\[p(\d+)\]/) do
        page = Regexp.last_match(1)
        "[#{prompt[/^\[(\d+)\] [^\n]+, página #{page}(?:\D|$)/, 1] || raise("page #{page} missing from the generator prompt")}]"
      end
      reply(answer, "end_turn", tool: false)
    end

    def generator_prompt
      sent.reject { |payload| payload[:tool_choice] }.last.fetch(:messages).last.fetch(:content).pluck(:text).join
    end

    def retrieve(params)
      vector = params.dig(:retrieval_configuration, :vector_search_configuration) || {}
      @filters << vector[:filter]
      rows = @turns.fetch(@index).fetch(:rows).map { |row| Retrieved.new(row, @viewer_id, @focus_uri) }
      Aws::BedrockAgentRuntime::Types::RetrieveResponse.new(retrieval_results: rows)
    end

    # Cohere order of the capture, matched by the digest of the passage text.
    def rerank(payload)
      turn = @turns.fetch(@index)
      order = turn[:rows].sort_by { |row| turn[:rank_by_page] ? row["rank"] || 99 : 0 }
        .map { |row| Digest::SHA256.hexdigest(row["content"].to_s) }
      sources = Array(payload[:sources] || payload["sources"])
      rows = sources.each_with_index.map { |source, index|
        text = source.dig(:inline_document_source, :text_document, :text).to_s
        rank = order.index(Digest::SHA256.hexdigest(text)) || order.size + index
        Struct.new(:index, :relevance_score).new(index, 1.0 / (rank + 1))
      }
      Struct.new(:results, :next_token).new(rows, nil)
    end

    def retrieve_and_generate(*, **)
      raise "bedrock retrieve_and_generate is blocked"
    end

    private

    def reply(value, stop_reason, tool:)
      content = if tool
        [ { type: :tool_use, id: "tool-1", name: "turn_perception", input: value } ]
      else
        [ { type: :text, text: value.to_s } ]
      end
      Anthropic::Models::Message.new(
        id: "msg-replay", type: :message, role: :assistant, model: "claude-haiku-5-5",
        stop_reason: stop_reason.to_sym, stop_sequence: nil, content: content,
        usage: { input_tokens: 32, output_tokens: 16 }
      )
    end
  end

  class Retrieved
    attr_reader :content, :score, :location, :metadata

    def initialize(row, viewer_id, focus_uri)
      @content = Aws::BedrockAgentRuntime::Types::RetrievalResultContent.new(text: row["content"].to_s)
      @score = 0.5
      bucket, = KbDocument.canonical_source(focus_uri)
      uri = "s3://#{bucket}/bulk_chunks/3/e32b956e25df4bc2dea0d200f5f25bb34750/#{row['chunk']}"
      @location = Aws::BedrockAgentRuntime::Types::RetrievalResultLocation.new(
        type: "S3", s3_location: Aws::BedrockAgentRuntime::Types::RetrievalResultS3Location.new(uri: uri)
      )
      @metadata = {
        "account_id" => viewer_id.to_s, "original_source_uri" => focus_uri, "x-amz-bedrock-kb-source-uri" => uri,
        "page_number" => row["page"].to_f, "canonical_name" => MANUAL_NAME,
        "original_filename" => File.basename(focus_uri)
      }
    end
  end
end
