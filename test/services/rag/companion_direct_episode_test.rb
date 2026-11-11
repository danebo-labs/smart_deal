# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../support/local_chunk_directory"
require_relative "../../support/local_knowledge_base"
require_relative "../../support/companion_direct_runtime"

# Two cases on one session row, then the history the next direct request sends.
class Rag::CompanionDirectEpisodeTest < ActiveSupport::TestCase
  include CompanionDirectRuntime

  QUOTE = "Solo si el caudal baja, revisar el sensor."
  VALID = "Si el caudal baja, revisa el sensor: «#{QUOTE}» [1]"

  setup do
    @account = accounts(:legacy)
    @user = users(:one)
    @root = Pathname.new(Dir.mktmpdir("companion-direct-episode"))
    @store = LocalChunkDirectory.new(@root)
    @document = KbDocument.create!(
      s3_key: "manuals/companion-direct-episode.pdf",
      display_name: "Bomba Hidra P2",
      account: @account,
      aliases: []
    )
    @uri = @document.canonical_uri
    write_chunk
    @kb = LocalKnowledgeBase.new(@root, bucket: "local-kb")
    @requests = []
    @reply = ->(_params) { text_reply(VALID) }
    @runtime = Aws::BedrockRuntime::Client.new(stub_responses: true, region: "us-east-1")
    bind_recorded_converse(@runtime)
    test = self
    @runtime.stub_responses(:converse, ->(context) { test.converse_stub(context) })
    Thread.current[:companion_direct_runtime] = @runtime
    Thread.current[:companion_direct_kb] = @kb
    @saved_s3 = Aws.config.slice(:s3).compact
    store = @store
    Aws.config[:s3] = {
      stub_responses: {
        list_objects_v2: ->(context) { { contents: store.list_keys(prefix: context.params[:prefix]).map { |key| { key: key } }, is_truncated: false } },
        get_object: ->(context) { { body: store.download(context.params[:key]).to_s } },
        put_object: "AccessDenied",
        delete_objects: "AccessDenied"
      }
    }
    @host = CompanionDirectHost.new(@account, @user)
    install_companion_direct_runtime!
    install_direct_anthropic!(self)
  end

  teardown do
    Thread.current[:companion_direct_anthropic] = nil
    remove_companion_direct_runtime!
    Thread.current[:companion_direct_runtime] = nil
    Thread.current[:companion_direct_kb] = nil
    Thread.current[:companion_direct_service] = nil
    Aws.config.delete(:s3)
    Aws.config.merge!(@saved_s3.to_h)
    FileUtils.remove_entry(@root) if @root
  end

  test "case B on the same row excludes case A and keeps the pin" do
    session = web_session
    published = nil
    case_b = nil
    with_owner do
      travel_to Time.zone.parse("2026-11-04 12:00:00") do
        turn(session, "CASO-A el motor se para solo en la bomba hidra", "report", "el motor se para solo", "query:a1")
      end
      travel_to Time.zone.parse("2026-11-04 12:05:00") do
        turn(session, "CASO-A segunda nota del sensor de caudal", "follow_up", "segunda nota del sensor", "query:a2")
      end
      case_a = session.reload.active_episode["episode_id"]

      travel_to Time.zone.parse("2026-11-04 12:20:00") do
        turn(session, "CASO-B reviso el sensor de caudal ahora", "new_work", "reviso el sensor de caudal", "query:b1")
      end
      case_b = session.reload.active_episode["episode_id"]
      assert case_b.present?
      assert_not_equal case_a, case_b
      assert_includes session.focus_document_ids, @document.id

      b1 = request_containing("CASO-B reviso el sensor de caudal ahora")
      assert b1
      assert_not_includes request_text(b1), "CASO-A"
      assert_includes request_text(b1), "[1] Bomba Hidra P2"
      published = session.conversation_history.reverse.find { |message| message["role"] == "assistant" && message["correlation_id"] == "query:b1" }
      assert published
      assert_includes published["prompt_reply"].to_s, QUOTE

      travel_to Time.zone.parse("2026-11-04 12:25:00") do
        turn(session, "CASO-B con lo ya dicho reviso el sensor", "follow_up", "con lo ya dicho reviso", "query:b2")
      end
    end

    b2 = request_containing("CASO-B con lo ya dicho reviso el sensor")
    text = request_text(b2)
    history, sources = text.split("Fuentes de este turno:", 2)
    assert_includes history, "CASO-B reviso el sensor de caudal ahora"
    assert_includes history, QUOTE
    assert_not_includes history, "[1]"
    assert_includes published["prompt_reply"], "[1]"
    assert_includes sources, "[1] Bomba Hidra P2"
    assert_not_includes text, "CASO-A"
    assert_equal 1, text.scan("CASO-B con lo ya dicho reviso el sensor").size
    roles = request_roles(b2)
    assert_equal "user", roles.first
    assert_equal "user", roles.last
    roles.each_cons(2) { |left, right| assert_not_equal left, right }
    assert_includes session.reload.focus_document_ids, @document.id
    assert_equal case_b, session.active_episode["episode_id"]
  end

  test "a short stored answer and full text are what the next request sends" do
    session = web_session
    question = "¿El motor está encendido o apagado?"
    long = ("palabra " * 90) + "MARCA-FULL"
    user_long = ("dato " * 160) + "MARCA-USUARIO"
    with_owner do
      session.add_to_history("user", question, user_id: @user.id, correlation_id: "query:prev")
      session.record_assistant_turn!(
        long, user_id: @user.id, correlation_id: "query:ans",
        expected_episode_id: session.live_episode_id, prompt_reply: "Encendido."
      )
      session.add_to_history("user", user_long, user_id: @user.id, correlation_id: "query:largo")
      session.add_to_history("user", "¿Sigue encendido el sensor?", user_id: @user.id, correlation_id: "query:corta")
      direct { @host.ask("¿Sigue encendido el sensor?", **query_args(session, "¿Sigue encendido el sensor?", "query:corta")) }
    end

    stored = session.reload.conversation_history.find { |message| message["correlation_id"] == "query:ans" }
    assert_includes stored["full_content"], "MARCA-FULL"
    assert_not_includes stored["content"], "MARCA-FULL"
    assert_equal "Encendido.", stored["prompt_reply"]
    user = session.conversation_history.find { |message| message["correlation_id"] == "query:largo" }
    assert_includes user["full_content"], "MARCA-USUARIO"
    assert_not_includes user["content"], "MARCA-USUARIO"

    text = request_text(@requests.last)
    assert_includes text, question
    assert_includes text, "Encendido."
    assert_includes text, "MARCA-USUARIO"
    assert_not_includes text, "MARCA-FULL"
    assert_equal 1, text.scan("¿Sigue encendido el sensor?").size
  end

  test "old assistant replies drop first and a repeated turn without correlation stays" do
    session = web_session
    with_owner do
      session.add_to_history("user", "PREGUNTA-VIEJA-UNO", user_id: @user.id, correlation_id: "query:u1")
      session.add_to_history("assistant", "VIEJA-ASISTENTE-TOKEN#{'x' * 5_000}", user_id: @user.id, correlation_id: "query:vieja")
      session.add_to_history("user", "PREGUNTA-VIEJA-DOS", user_id: @user.id, correlation_id: "query:u2")
      session.add_to_history("assistant", "VIEJA-ASISTENTE-DOS#{'y' * 5_000}", user_id: @user.id, correlation_id: "query:media")
      session.add_to_history("user", "PREGUNTA-RECIENTE", user_id: @user.id, correlation_id: "query:u3")
      session.add_to_history("assistant", "Encendido.", user_id: @user.id, correlation_id: "query:corta-resp")
      session.add_to_history("user", "PREGUNTA-ACTUAL del sensor", user_id: @user.id, correlation_id: "query:actual")
      events = []
      direct do
        events = Rag::ValidationCapture.capture do
          @host.ask("PREGUNTA-ACTUAL del sensor", **query_args(session, "PREGUNTA-ACTUAL del sensor", "query:actual"))
        end
      end
      text = request_text(@requests.last)
      assert_not_includes text, "VIEJA-ASISTENTE-TOKEN"
      assert_includes text, "VIEJA-ASISTENTE-DOS"
      assert_includes text, "Encendido."
      assert_includes text, "PREGUNTA-VIEJA-UNO"
      assert_includes text, "PREGUNTA-RECIENTE"
      assert_equal 1, text.scan("PREGUNTA-ACTUAL del sensor").size
      roles = request_roles(@requests.last)
      assert_equal "user", roles.first
      assert_equal "user", roles.last
      omitted = events.find { |event| event["kind"] == "companion_direct_history" }
      assert omitted
      assert_equal "assistant", omitted.dig("omitted", 0, "role")
      assert_equal "query:vieja", omitted.dig("omitted", 0, "correlation_id")
      assert_operator omitted["history_chars"], :<=, Rag::CompanionDirectAnswer::HISTORY_MAX_CHARS
    end

    overflow = web_session
    3.times do |index|
      overflow.add_to_history("user", "U#{index}-#{'m' * 3_000}", user_id: @user.id, correlation_id: "query:over-#{index}")
    end
    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: "actual", chunks: [], episode: overflow.active_episode, session: overflow, correlation_id: nil
    )
    body = prepared.messages.map { |message| message[:content][0][:text] }.join
    assert_not_includes body, "U0-"
    assert_includes body, "U2-"
    assert_equal "user", prepared.messages.first[:role]
    assert_equal "user", prepared.messages.last[:role]
    assert_operator prepared.history_chars, :<=, Rag::CompanionDirectAnswer::HISTORY_MAX_CHARS
    assert_equal "user", prepared.omitted.first[:role]

    repeated = web_session
    repeated.add_to_history("user", "misma frase del tecnico", user_id: @user.id)
    marked = repeated.conversation_history
    marked.last["text_provenance"] = "foto"
    repeated.update!(conversation_history: marked)
    again = Rag::CompanionDirectAnswer.prepare(
      raw_question: "misma frase del tecnico", chunks: [], episode: repeated.active_episode,
      session: repeated, correlation_id: nil
    )
    sent = again.messages.map { |message| message[:content][0][:text] }.join
    assert_equal 2, sent.scan("misma frase del tecnico").size
    assert_includes sent, "[procedencia: foto]"
  end

  # live cand1 CEA-T3: a p. 22 quote was cited with the [n] of the heading
  # printed right under it.
  test "a blank line separates each passage from the next source heading" do
    chunks = [ [ "Una serie es 1 si la tensión es 24 Vcc.", 22 ], [ "Tabla de relés 77 a 99.", 75 ] ].map do |content, page|
      { content: content, metadata: { "canonical_name" => "manual-cea15p", "page_number" => page } }
    end

    prepared = Rag::CompanionDirectAnswer.prepare(raw_question: "¿Qué tensión es un 1?", chunks: chunks, episode: nil, session: nil)
    text = prepared.messages.last[:content][0][:text]

    assert_includes text, "Fuentes de este turno:\n[1] manual-cea15p, página 22\nUna serie es 1 si la tensión es 24 Vcc.\n\n[2] manual-cea15p, página 75\n"
  end

  test "a direct answer leaves the stored pending and the plan still sees it" do
    session = web_session
    question = "¿Sigue el caudal bajo?"
    with_owner do
      session.record_user_turn!(
        "CASO-P el motor se para solo en la bomba",
        user_id: @user.id, correlation_id: "query:p1", interpreter_client: client("report", "el motor se para solo"),
        interpreter_sleeper: ->(*) { }
      )
      know!(session, "query:p1")
      state = session.reload.active_episode
      state["pending_question"] = {
        "type" => "documented_context",
        "id" => "q1",
        "question" => question,
        "targets" => [ {
          "item" => "sensor de caudal",
          "document_key" => "doc-bomba",
          "filename" => "bomba.pdf",
          "page" => "3"
        } ],
        "parts" => [ { "id" => "p1", "role" => "main", "text" => question } ]
      }
      session.update!(active_episode: state)
      @reply = lambda do |_params|
        service = Thread.current[:companion_direct_service]
        service.instance_variable_set(:@companion_plan_stop_reason, "max_tokens")
        service.instance_variable_set(:@companion_plan_pending, state["pending_question"])
        text_reply(VALID)
      end
      result = direct { @host.ask("Si el caudal baja, ¿qué reviso?", **query_args(session, "Si el caudal baja, ¿qué reviso?", "query:p2")) }
      assert_nil result.pending_question
      assert_equal :answered, result.route_outcome
      session.record_assistant_turn!(
        result.answer, user_id: @user.id, correlation_id: "query:p2",
        pending_question: result.pending_question, expected_episode_id: session.live_episode_id,
        prompt_reply: result.history_answer
      )
      stored = session.reload.active_episode["pending_question"]
      assert_equal question, stored["question"]
      assert_equal "sensor de caudal", stored.dig("targets", 0, "item")
      assert_equal "doc-bomba", stored.dig("targets", 0, "document_key")

      @requests.clear
      @reply = ->(params) { plan_reply(params) }
      with_flags(generation: "plan") do
        @host.ask("Si el caudal baja, ¿qué reviso?", **query_args(session, "Si el caudal baja, ¿qué reviso?", "query:p3"))
      end
    end
    assert_includes request_text(@requests.last), question
  end

  def converse_stub(context)
    params = context.params
    @requests << params
    @reply.call(params)
  end

  private

  def turn(session, text, move, observation, correlation)
    session.record_user_turn!(
      text, user_id: @user.id, correlation_id: correlation,
      interpreter_client: client(move, observation), interpreter_sleeper: ->(*) { }
    )
    know!(session, correlation)
    result = direct { @host.ask(text, **query_args(session, text, correlation)) }
    assert result.success?, "#{correlation} #{result.error_message}"
    assert result.companion_turn, "#{correlation} #{result.generation_mode}"
    session.record_assistant_turn!(
      result.answer.to_s, user_id: @user.id, correlation_id: correlation,
      pending_question: result.pending_question, expected_episode_id: session.live_episode_id,
      prompt_reply: result.history_answer
    )
    result
  end

  def query_args(session, question, correlation)
    {
      conv_session: session.reload,
      account: @account,
      user_id: @user.id,
      correlation_id: correlation,
      response_locale: :es,
      entity_s3_uris: [ @uri ],
      raw_question: question,
      episode_turn: continued_turn(question),
      output_channel: :web
    }
  end

  def know!(session, correlation)
    episode = Rag::ActiveEpisode.parse(session.reload.active_episode)
    episode.write_fact!(
      "manufacturer", status: "known", value: "Hidra", source: "user",
      correlation_id: correlation, at: Time.current.iso8601
    )
    session.update!(active_episode: episode.to_h)
  end

  def web_session
    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: 1.hour.ago, contract: Rag::AnswerContract::VERSION)
    episode.write_fact!(
      "manufacturer", status: "known", value: "Hidra", source: "user",
      correlation_id: "query:open", at: Time.current.iso8601
    )
    session = ConversationSession.create!(
      identifier: "web:companion-episode-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.day.from_now,
      user: @user,
      account: @account,
      active_episode: episode.to_h
    )
    assert session.pin_kb_document!(@document)
    session
  end

  def request_containing(snippet)
    @requests.find { |params| request_text(params).include?(snippet) }
  end

  def continued_turn(question)
    understanding = Struct.new(:meta?, :clarify_first?, :owns_query, :retrieval_query, :clarification, :decision).new(
      false, false, false, nil, nil, "ready"
    )
    Struct.new(:understanding, :decision, :reason, :composed).new(understanding, :continued, "continued", question)
  end

  def client(move, observation)
    ScriptedDirectInterpreter.new([ {
      "move" => move,
      "assertions" => [],
      "observations" => [ observation ],
      "pending_resolution" => nil,
      "clarification_target" => nil
    } ])
  end

  def plan_reply(params)
    {
      output: { message: { role: "assistant", content: [ { tool_use: {
        tool_use_id: "tool-1", name: "companion_plan",
        input: { "links" => [], "steps" => [], "question" => "", "question_about" => [], "applicability" => { "statement" => "", "conditions" => [] } }
      } } ] } },
      stop_reason: "tool_use",
      usage: { input_tokens: 40, output_tokens: 12, total_tokens: 52 },
      metrics: { latency_ms: 4 }
    }
  end

  def write_chunk
    key = "bulk_chunks/#{@account.id}/doc-episode/chunk_p3_1.txt"
    @store.upload_text(key, "[DOCUMENT: bomba.pdf]\n[PDF_PAGE: 3]\n6.1 Caudal\nBomba Hidra P2.\n#{QUOTE}\n")
    @store.upload_text("#{key}.metadata.json", JSON.generate("metadataAttributes" => {
      "account_id" => @account.id.to_s,
      "document_id" => "doc-episode",
      "original_source_uri" => @uri,
      "original_filename" => "bomba.pdf",
      "canonical_name" => "Bomba Hidra P2",
      "aliases" => [ "Hidra" ],
      "ingestion_path" => "manual_batch_v1",
      "manual_corpus" => "account",
      "page_number" => 3
    }))
  end

  def with_owner(&block)
    with_flags(&block)
  end

  def direct(&block)
    with_flags(&block)
  end

  def with_flags(generation: "direct")
    keys = %w[
      DOCUMENT_IDENTITY_SCOPE_ENABLED RAG_COMPANION_TURN RAG_COMPANION_GENERATION
      RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED
      HAIKU_QUERY_ANALYSIS_MODE BEDROCK_KNOWLEDGE_BASE_ID
    ]
    previous = keys.index_with { |key| ENV[key] }
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["RAG_COMPANION_TURN"] = "1"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "kb-local"
    ENV.delete("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE")
    generation.nil? ? ENV.delete("RAG_COMPANION_GENERATION") : ENV["RAG_COMPANION_GENERATION"] = generation
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

class ScriptedDirectInterpreter
  def initialize(responses)
    @responses = responses.dup
  end

  def converse(_params)
    tool = Struct.new(:name, :input).new("turn_perception", @responses.shift)
    block = Struct.new(:tool_use).new(tool)
    message = Struct.new(:content).new([ block ])
    output = Struct.new(:message).new(message)
    usage = Struct.new(:input_tokens, :output_tokens).new(4, 2)
    Struct.new(:output, :usage, :stop_reason).new(output, usage, "tool_use")
  end
end
