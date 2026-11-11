# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/haiku55_journey_rubric")

# Authenticated HTTP replay of the twelve Opus turns. External calls are the
# captured interpreter tool, the captured Retrieve bodies, and the captured
# generator text. Focus, the Retrieve query, the evidence, and the published
# answer are the product path.
class FieldCompanionHaiku55JourneyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  FIXTURES = "test/fixtures/files/field_companion/haiku55_journeys"
  SCRIPTS = {
    "guion2" => {
      "capture" => "#{FIXTURES}/guion2",
      "uid" => "126cda62-64ad-4469-8674-a29f12e38d48",
      "name" => "VF5",
      "key" => "bulk_uploads/1/2026-08-31/VF5.pdf"
    },
    "guion1" => {
      "capture" => "#{FIXTURES}/guion1",
      "uid" => "126cda62-64ad-4469-8674-a29f12e38d48",
      "name" => "VF5",
      "key" => "bulk_uploads/1/2026-08-31/VF5.pdf"
    },
    "elemont" => {
      "capture" => "#{FIXTURES}/elemont",
      "uid" => "dcc8e046-037d-48a6-8913-1992aed28507",
      "name" => "Elemont Montacargas Hidraulico Modelo MH",
      "key" => "bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf"
    }
  }.freeze

  DECISIVE = {
    "guion2" => { "turn" => 1, "suffix" => "chunk_p8_1.txt", "page" => 8, "sha256" => "e97501793af4cc7eb41e7417e4e1de415a770c83a11a90bbdf2b9e66d6d858bb" },
    "elemont" => { "turn" => 1, "suffix" => "chunk_p5_1.txt", "page" => 5, "sha256" => "a13141fe7586c9013d698aa29f2b6809f112702e98f4da99d9a47c3ba01d7779" }
  }.freeze

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @user.update!(account: @account)
    sign_in @user
    @env = %w[
      HAIKU_QUERY_ANALYSIS_MODE FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED
      RAG_COMPANION_TURN DOCUMENT_IDENTITY_SCOPE_ENABLED BEDROCK_KNOWLEDGE_BASE_ID
      RAG_COMPANION_GENERATION BEDROCK_INFERENCE RAG_VALIDATION_CAPTURE_RUN
      RAG_VALIDATION_CAPTURE_ACCOUNT_IDS COMPANION_DIRECT_EFFORT COMPANION_DIRECT_THINKING
      COMPANION_DIRECT_MAX_TOKENS COMPANION_DIRECT_MODEL_ID COMPANION_DIRECT_PROVIDER
      ANTHROPIC_API_KEY SHOW_RAG_SOURCES
    ].index_with { |key| ENV[key] }
    ENV["ANTHROPIC_API_KEY"] = "offline-replay"
    ENV["SHOW_RAG_SOURCES"] = "true"
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["RAG_COMPANION_TURN"] = "1"
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "Y7RZWMFJSR"
    ENV["RAG_COMPANION_GENERATION"] = "direct"
    ENV["BEDROCK_INFERENCE"] = "blocked"
    ENV.delete("COMPANION_DIRECT_EFFORT")
    ENV.delete("COMPANION_DIRECT_MODEL_ID")
    ENV.delete("COMPANION_DIRECT_PROVIDER")
    ENV.delete("COMPANION_DIRECT_MAX_TOKENS")
    ENV.delete("COMPANION_DIRECT_THINKING")
    Thread.current[:haiku55_block_net] = true
  end

  teardown do
    Thread.current[:haiku55_block_net] = nil
    @env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "guion 2 replays three turns through the pinned companion" do
    play("guion2")
  end

  test "guion 1 replays five turns and does not ask again for the contact the technician cannot check" do
    play("guion1")
  end

  test "elemont replays four turns on one episode" do
    play("elemont")
  end

  # A base-journey answer is the wrong answer once the variant changes the history.
  test "the variant rubric rejects the base answers where the history changed" do
    questions = load_turns(SCRIPTS.fetch("guion1")["capture"]).map(&:question)
    discarded = "Lo que ya comprobaste:\n- Fotocélula: no activada.\n- Pendiente: #54."
    still_open = "Con la fotocélula activándose durante el cierre, sigue abierta la causa: «Comprobar que la fotocélula no esté activada» [2]."
    unable = "Entendido: no te pido identificar #21 ni el contacto entre #21 y #23."
    engaged = "La fuente indica que la señal se activa al «conectar la entrada re-apertura (21) con la entrada de +12V (23)» [11]."

    assert_equal [ "variant:photocell_discarded" ], Haiku55JourneyRubric.reasons("guion1_photocell_active", 4, discarded, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1_photocell_active", 4, still_open, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1_photocell_active", 4,
      "**Comprobado:** la fotocélula se activa durante el cierre.\n- Si la fotocélula sigue activa con el haz libre.", questions)
    assert_equal [ "variant:photocell_discarded" ],
      Haiku55JourneyRubric.reasons("guion1_photocell_active", 4, "Con la fotocélula libre, esa entrada es la candidata principal.", questions)
    assert_equal %w[variant:contact_not_engaged variant:treated_as_unable],
      Haiku55JourneyRubric.reasons("guion1_can_measure", 5, unable, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1_can_measure", 5, engaged, questions)
  end

  # live4 turn 2: the interpreter sent the negate span the reference omitted.
  test "elemont keeps the correction when the interpreter negates the earlier component itself" do
    play("elemont", tool_inputs: {
      2 => {
        "move" => "correct",
        "assertions" => [
          { "span" => "Chapa nivel 3", "act" => "assert", "slot_hint" => "designator" },
          { "span" => "Chapa nivel 2", "act" => "negate", "slot_hint" => "designator" }
        ],
        "observations" => [], "pending_resolution" => nil, "clarification_target" => nil
      }
    })
  end

  # Opening sentences of live3, live5 and live4 G1-T5.
  test "guion 1 turn 5 accepts the stated limit and rejects the contact sent back as an inspection" do
    questions = load_turns(SCRIPTS.fetch("guion1")["capture"]).map(&:question)
    method_limit = "No puedo darte un método para comprobar #21 ni el contacto #21–#23, porque la documentación cargada no lo trae."
    technician_limit = "Entendido: no te pido identificar #21 ni el contacto entre #21 y #23."
    inspection = "No necesitas medir #21 ni el contacto #21–#23 para seguir. Puedes mirar si hay algo conectado a esos bornes. " \
      "No puedes identificar si #21 está activada ni verificar el contacto #21–#23."
    silent = "Revisa el potenciómetro #54 y vuelve a probar el cierre."

    assert_empty Haiku55JourneyRubric.reasons("guion1", 5, method_limit, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1", 5, technician_limit, questions)
    assert_empty Haiku55JourneyRubric.reasons("guion1", 5,
      "No puedo darte otra forma de verificar #21 con la documentación cargada, así que no te lo pediré de nuevo.", questions)
    assert_equal [ "t5:reasks_contact" ], Haiku55JourneyRubric.reasons("guion1", 5, inspection, questions)
    assert_includes Haiku55JourneyRubric.reasons("guion1", 5, silent, questions), "t5:limit_not_acknowledged"
  end

  private

  def play(name, tool_inputs: {})
    spec = SCRIPTS.fetch(name)
    turns = load_turns(spec["capture"])
    tool_inputs.each { |number, input| turns[number - 1].tool_input = input }
    document = KbDocument.create!(
      account: @account, s3_key: spec["key"], document_uid: spec["uid"],
      display_name: spec["name"], aliases: []
    )
    focus_uri = document.display_s3_uri(KbDocument::KB_BUCKET)
    ConversationSession.where(identifier: @user.id.to_s, channel: "web").delete_all
    cassette = JourneyCassette.new(turns, viewer_id: @account.id, focus_uri: focus_uri)
    episode_ids = []
    with_doubles(cassette) do
      post pinned_documents_path, params: { kb_document_id: document.id }, as: :json
      assert_includes [ 200, 204 ], response.status, response.body.to_s.truncate(400)
      assert_equal document.id, reloaded_session.document_focus_entries.sole["kb_document_id"]

      turns.each_index do |index|
        turn = turns[index]
        events = Rag::ValidationCapture.capture do
          post rag_ask_path, params: { question: turn.question }, as: :json
        end
        body = response.parsed_body
        write_trace(name, index + 1, body, events, cassette)
        assert_response :success, failure_detail(name, index + 1, body, cassette)
        assert_equal "success", body["status"], failure_detail(name, index + 1, body, cassette)
        answer = body["answer"].to_s
        assert_not_equal I18n.t("rag.service_unavailable", locale: :es), answer, failure_detail(name, index + 1, body, cassette)
        assert_not_equal I18n.t("rag.data_not_available", locale: :es), answer
        episode_ids << reloaded_session.active_episode["episode_id"]
        assert_equal document.id, reloaded_session.document_focus_entries.sole["kb_document_id"]
        query = cassette.queries[index]
        assert query.to_s.strip.present?, "turn #{index + 1} did not reach Retrieve"
        assert_equal turn.retrieve_query, query, "#{name} turn #{index + 1}: Retrieve query diverged from the capture"
        if turn.generator_messages_sha256
          assert_equal turn.generator_messages_sha256, cassette.generator_messages_sha256(index),
            "#{name} turn #{index + 1}: generator history or evidence diverged from the capture"
        end
        assert cassette.filters[index].to_json.include?(focus_uri), cassette.filters[index].to_json
        assert_behavior(name, index + 1, answer, turns.map(&:question))
        assert_payloads(cassette, index)
        assert_cited(name, index + 1, answer, body)
      end
    end
    assert_equal 1, episode_ids.compact.uniq.size, episode_ids.inspect
    assert_decisive(name, cassette)
  end

  def assert_behavior(name, number, answer, questions)
    assert_empty Haiku55JourneyRubric.reasons(name, number, answer, questions), answer
  end

  def assert_payloads(cassette, index)
    interpreter = cassette.sent.select { |body| body[:tool_choice] || body["tool_choice"] }[index]
    generator = cassette.sent.reject { |body| body[:tool_choice] || body["tool_choice"] }[index]
    assert interpreter, "missing interpreter payload #{index + 1}"
    assert_equal "claude-haiku-5-5", interpreter[:model]
    assert_equal 512, interpreter[:max_tokens]
    assert_equal({ effort: "high" }, interpreter[:output_config])
    assert_equal "turn_perception", interpreter.dig(:tool_choice, :name)
    assert_nil interpreter[:temperature]
    assert_nil interpreter[:thinking]
    assert generator, "missing generator payload #{index + 1}"
    assert_equal "claude-haiku-5-5", generator[:model]
    assert_equal 4_000, generator[:max_tokens]
    assert_equal({ type: "adaptive", display: "summarized" }, generator[:thinking])
    assert_nil generator[:output_config]
    assert_nil generator[:tools]
    assert_equal "99862136fb664f55b182ff77b900e5268d304d3df982b582d17f992830cda4ae",
      Digest::SHA256.hexdigest(generator[:system].to_s)
  end

  def assert_cited(name, number, answer, body)
    spec = DECISIVE[name]
    return unless spec && number == spec["turn"]

    assert_includes answer, "[1]"
    cited = Array(body["citations"])
    assert cited.any? { |item| item["page"].to_i == spec["page"] }, cited.pluck("page").inspect
  end

  def assert_decisive(name, cassette)
    spec = DECISIVE[name]
    return unless spec

    row = cassette.returned[spec["turn"] - 1].to_a.find { |item|
      item.uri.to_s.end_with?(spec["suffix"]) && item.page.to_i == spec["page"]
    }
    assert row, cassette.returned[spec["turn"] - 1].to_a.map(&:uri).inspect
    assert_equal spec["sha256"], Digest::SHA256.hexdigest(row.text)
  end

  def with_doubles(cassette)
    block_network
    original_anthropic = Anthropic::Client.method(:new)
    original_agent = Aws::BedrockAgentRuntime::Client.method(:new)
    Anthropic::Client.define_singleton_method(:new) { |*, **| cassette }
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*, **| cassette }
    yield
  ensure
    Anthropic::Client.define_singleton_method(:new) { |*args, **kwargs| original_anthropic.call(*args, **kwargs) } if original_anthropic
    if original_agent
      Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args, **kwargs|
        original_agent.call(*args, **kwargs)
      }
    end
  end

  def block_network
    return if Net::HTTP.ancestors.include?(NetworkBlock)

    Net::HTTP.prepend(NetworkBlock)
  end

  def load_turns(relative)
    root = Rails.root.join(relative)
    flunk("falta el fixture #{relative}") unless root.directory?

    root.glob("turn-*.json").sort_by { |path| path.basename.to_s[/\d+/].to_i }.map { |path| TurnCapture.load(path) }
  end

  def reloaded_session
    ConversationSession.find_by!(identifier: @user.id.to_s, channel: "web", account_id: @account.id)
  end

  def failure_detail(name, number, body, cassette)
    {
      "script" => name,
      "turn" => number,
      "answer" => body["answer"].to_s.truncate(500),
      "query" => cassette.queries[number - 1],
      "message" => body["message"]
    }.to_json
  end

  def write_trace(name, number, body, events, cassette)
    directory = Rails.root.join("tmp/field_companion/haiku55_offline", name, format("turn-%d", number))
    FileUtils.mkdir_p(directory)
    File.write(directory.join("published.txt"), body["answer"].to_s)
    File.write(directory.join("trace.json"), JSON.generate(
      "answer" => body["answer"],
      "query" => cassette.queries[number - 1],
      "filter" => cassette.filters[number - 1],
      "events" => events
    ))
  end

  module NetworkBlock
    def connect(*)
      raise "offline network blocked" if Thread.current[:haiku55_block_net]

      super
    end
  end

  # One fixture turn from script/field_companion/haiku55_journey_fixtures.rb.
  # Rows keep the Retrieve order and the page value the knowledge base sent.
  class TurnCapture
    def self.load(path)
      data = JSON.parse(path.read)
      new(data)
    end

    def initialize(data)
      @question = data.fetch("question")
      @tool_input = data.fetch("tool_input")
      @rows = data.fetch("rows").map { |row| row.merge("sha256" => Digest::SHA256.hexdigest(row["content"].to_s)) }
      @raw = data.fetch("generator_text")
      @stop_reason = data["stop_reason"].presence || "end_turn"
      @retrieve_query = data.fetch("retrieve_query")
      @rerank_sha256 = Array(data["rerank_sha256"])
      @generator_messages_sha256 = data["generator_messages_sha256"]
    end

    attr_reader :question, :rows, :raw, :stop_reason, :retrieve_query, :rerank_sha256,
      :generator_messages_sha256
    attr_accessor :tool_input
  end

  class JourneyCassette
    def initialize(turns, viewer_id:, focus_uri:)
      @turns = turns
      @viewer_id = viewer_id
      @focus_uri = focus_uri
      @index = 0
      @sent = []
      @queries = []
      @filters = []
      @returned = []
    end

    attr_reader :sent, :queries, :filters, :returned

    def messages
      self
    end

    def create(**payload)
      @sent << payload
      turn = @turns[@index] or raise "model call without a turn"
      if payload[:tool_choice] || payload["tool_choice"]
        reply(turn.tool_input, "tool_use", tool: true)
      else
        @index += 1
        reply(turn.raw, turn.stop_reason, tool: false)
      end
    end

    def retrieve(params)
      turn = @turns[@index] or raise "retrieve without a turn"
      config = params[:retrieval_configuration] || params["retrieval_configuration"] || {}
      vector = config[:vector_search_configuration] || config["vector_search_configuration"] || {}
      query = params.dig(:retrieval_query, :text) || params.dig("retrieval_query", "text")
      @queries << query
      @filters << (vector[:filter] || vector["filter"])
      rows = turn.rows.map { |row| Retrieved.new(row, @viewer_id, @focus_uri) }
      @returned << rows
      Struct.new(:retrieval_results).new(rows)
    end

    # Scores follow the captured Cohere order, matched by body digest.
    def rerank(payload)
      order = @turns[@index].rerank_sha256
      sources = Array(payload[:sources] || payload["sources"])
      rows = sources.each_with_index.map { |source, index|
        text = source.dig(:inline_document_source, :text_document, :text).to_s
        rank = order.index(Digest::SHA256.hexdigest(text)) || order.size + index
        Struct.new(:index, :relevance_score).new(index, 1.0 / (rank + 1))
      }
      Struct.new(:results, :next_token).new(rows, nil)
    end

    def generator_messages_sha256(index)
      payload = sent.reject { |body| body[:tool_choice] || body["tool_choice"] }[index]
      return nil unless payload

      text = Array(payload[:messages]).map { |message|
        "#{message[:role]}:" + Array(message[:content]).map { |block| block[:text].to_s }.join
      }.join("\n---\n")
      Digest::SHA256.hexdigest(text.sub(PENDING_SCOPE, ""))
    end

    # The fixtures predate this sentence of the referral note. Everything
    # else in the generator message must still match them byte for byte.
    PENDING_SCOPE = "Lo que falta no incluye un componente, ajuste o modo cuya condición o ejemplo documentado depende " \
      "de algo que el técnico ya descartó. "

    def retrieve_and_generate(*, **)
      raise "bedrock retrieve_and_generate is blocked"
    end

    private

    # The live client returns SDK models, not hashes: blocks are typed
    # objects and enums are symbols.
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
    def initialize(row, viewer_id, focus_uri)
      @text = row["content"].to_s
      @content = Struct.new(:text).new(@text)
      @score = row["score"]
      @uri = row["uri"]
      @page = row["page"]
      @location = Struct.new(:s3_location).new(Struct.new(:uri).new(@uri))
      @metadata = {
        "account_id" => viewer_id.to_s,
        "original_source_uri" => focus_uri,
        "x-amz-bedrock-kb-source-uri" => @uri,
        "page_number" => @page,
        "canonical_name" => row["document"],
        "original_filename" => File.basename(focus_uri.to_s)
      }
    end

    attr_reader :content, :score, :location, :metadata, :uri, :page, :text
  end
end
