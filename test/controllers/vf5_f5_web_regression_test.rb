# frozen_string_literal: true

require "test_helper"

# HTTP path of two 28 Oct 2026 web runs. The accepted run is episode
# ep_71e5c284b0315a41. The later run, ep_6dba74e041c77794, is an additional
# branch: T2 and T3 publish only the clarification. Interpreter, Retrieve,
# and the plan are the captured tool inputs and bodies. Definition pages are
# the published candidate. Nothing calls AWS. The T4 transport timeout of the
# accepted run is not replayed: that fixture is the successful read.
class Vf5F5WebRegressionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  DOCUMENT_UID = "126cda62-64ad-4469-8674-a29f12e38d48"
  TURN_1 = "Estoy revisando un operador de puerta Fermator VF5+. La puerta se reabre sola durante el cierre. El LED está apagado y no veo obstrucción. Todavía no he revisado el ajuste de #54 ni he hecho mediciones. ¿Cómo seguimos?"
  TURN_2 = "Corrijo un dato: el LED está encendido, no apagado."
  TURN_3 = "Revisé la fotocélula y no está activada."
  TURN_4 = "¿Qué sigue?"
  TURN_5 = "No sé cómo identificar si está activada la entrada #21 ni cómo saber si hay un contacto cerrado entre #21 y #23. ¿Qué información necesitas de mí para orientar el caso?"
  LED_QUESTION = /Cu[aá]l LED est[aá] encendido/i
  BAD_LED_READING = "el indicador LED se activa cuando"
  CONTACT_QUESTION = "¿Hay un contacto cerrado"
  INPUT_QUESTION = "¿Está activada la entrada de re-apertura (#21)?"

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @pilot = accounts(:pilot)
    sign_in @user
    @env = {
      "HAIKU_QUERY_ANALYSIS_MODE" => ENV["HAIKU_QUERY_ANALYSIS_MODE"],
      "FIELD_COMPANION_EPISODE_ENABLED" => ENV["FIELD_COMPANION_EPISODE_ENABLED"],
      "FIELD_COMPANION_TURN_ENABLED" => ENV["FIELD_COMPANION_TURN_ENABLED"],
      "RAG_COMPANION_TURN" => ENV["RAG_COMPANION_TURN"],
      "DOCUMENT_IDENTITY_SCOPE_ENABLED" => ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"],
      "BEDROCK_KNOWLEDGE_BASE_ID" => ENV["BEDROCK_KNOWLEDGE_BASE_ID"]
    }
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["RAG_COMPANION_TURN"] = "1"
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "test-kb"
    Rag::SharedManualCorpus.reset_account_ids!
    @document = KbDocument.create!(
      account: @account,
      s3_key: "bulk_uploads/1/2026-08-31/VF5.pdf",
      document_uid: DOCUMENT_UID,
      display_name: "VF5",
      aliases: []
    )
    @focus_uri = @document.display_s3_uri(KbDocument::KB_BUCKET)
    @session = ConversationSession.find_or_create_for(
      identifier: @user.id.to_s,
      channel: "web",
      user_id: @user.id,
      account_id: @account.id
    )
    @session.update!(
      conversation_history: [],
      active_episode: {},
      document_focus: [],
      active_entities: {},
      current_procedure: {},
      expires_at: 1.hour.from_now
    )
    install_catalog
  end

  teardown do
    Rag::CompanionDefinitionCatalog.current = nil
    Rag::CompanionDefinitionSource.invalidate!("vf5-f5-regression")
    @env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "the accepted web path keeps the five messages and the explicit manual" do
    with_captured_externals do |cassette|
      opened = ask(TURN_1)
      assert_recommendation_does_not_pin(opened)
      assert_turn_one(opened)

      confirm_manual(opened)
      replay_id = reloaded_session.conversation_history.find { |item| item["role"] == "user" }["correlation_id"]
      focused = ask(nil, replay: replay_id)
      assert_turn_one(focused)
      assert_next_antecedent(focused, "#21")
      assert pinned_filter?(cassette.filters.last), cassette.filters.last.to_json

      corrected = ask(TURN_2)
      assert_turn_two(corrected)
      assert_next_antecedent(corrected, "LED")

      reported = ask(TURN_3)
      assert_turn_three(reported)
      assert_next_antecedent(reported, "#21")

      followed = ask(TURN_4)
      assert_turn_four(followed)
      assert_next_antecedent(followed, "#21")

      unknown = ask(TURN_5)
      assert_turn_five(unknown)
      assert_next_antecedent(unknown, "Fotocélula")
      assert_equal 6, cassette.filters.size, cassette.filters.map { |filter| pinned_filter?(filter) }.inspect
      assert_not pinned_filter?(cassette.filters.first), cassette.filters.first.to_json
      cassette.filters.drop(1).each { |filter| assert pinned_filter?(filter), filter.to_json }
    end
  end

  test "a later run that publishes only the clarification keeps it beside the open question" do
    directory = "test/fixtures/vf5_f5_regression_20261028"
    with_captured_externals(directory, %w[t1 t2 t3 t4 t5]) do |cassette|
      assert_capture_provenance(directory)
      post pinned_documents_path, params: { kb_document_id: @document.id }, as: :json
      assert_response :no_content
      focus = reloaded_session.document_focus_entries.sole
      assert_equal @document.id, focus["kb_document_id"]
      assert_equal @focus_uri, focus["source_uri"]

      opened = ask(TURN_1)
      assert_turn_one(opened)
      assert_nil episode.pending_question["shown"]
      assert_includes opened["answer"], "¿Está activada la fotocélula o la entrada de re-apertura (#21)?"

      first_led = "¿Cuál LED está encendido, el de Fotocélula o el de Estado?"
      corrected = ask(TURN_2)
      assert_includes corrected["answer"], first_led
      assert_not_includes corrected["answer"], "#21)?"
      state = episode
      assert_match(/#21/, state.pending_question["question"])
      assert_equal first_led, state.pending_question.dig("shown", "question")
      assert_equal 2, state.pending_question.dig("shown", "targets").size
      assert_next_case_still_open(state)

      later_led = "¿El LED encendido es el de Fotocélula o el de Estado?"
      reported = ask(TURN_3)
      state = episode
      assert_equal "done", check_status(state, /fotoc[eé]lula/)
      assert_match(/#21/, state.pending_question["question"])
      assert_equal later_led, state.pending_question.dig("shown", "question")
      assert_includes reported["answer"], later_led
      assert_not_includes reported["answer"], "#21)?"
      assert_next_case_still_open(state)

      followed = ask(TURN_4)
      state = episode
      assert_equal "¿Está activada la fotocélula o la entrada de re-apertura (#21)?", state.pending_question["question"]
      assert_equal later_led, state.pending_question.dig("shown", "question")
      assert_not_includes followed["answer"], "¿Qué sigue?"
      assert_not_includes followed["answer"], later_led
      assert_next_case_still_open(state)

      unknown = ask(TURN_5)
      state = episode
      limit = state.observations.find { |item| item.dig("answers", "r") == "unknown" }
      assert_includes limit["text"], "#21"
      assert_includes limit["text"], "contacto"
      assert_includes limit.dig("answers", "q").to_s, "#21"
      assert_no_match(/LED encendido/i, limit.dig("answers", "q").to_s)
      assert_equal later_led, state.pending_question["question"]
      assert_nil state.pending_question["shown"]
      assert_equal 2, state.pending_question["targets"].size
      targets = state.pending_question["targets"].to_json
      assert_match(/Fotoc[eé]lula/, targets)
      assert_match(/Estado/, targets)
      assert_not_includes unknown["answer"], CONTACT_QUESTION
      assert_not_includes unknown["answer"], "¿Está activada la fotocélula o la entrada de re-apertura (#21)?"
      assert_equal "done", check_status(state, /fotoc[eé]lula/)
      assert_equal "not_done", check_status(state, /#54/)
      assert_equal "not_done", check_status(state, /medicion/)
      assert_equal 5, cassette.filters.size
      cassette.filters.each { |filter| assert pinned_filter?(filter), filter.to_json }
    end
  end

  private

  def assert_recommendation_does_not_pin(body)
    cards = Array(body.dig("manual_suggestion", "cards"))
    card = cards.find { |item| item["document_uid"] == DOCUMENT_UID }
    assert card, cards.inspect
    assert_equal @document.id, card["kb_document_id"]
    assert_empty reloaded_session.document_focus_entries
  end

  def confirm_manual(body)
    card = body.dig("manual_suggestion", "cards").find { |item| item["document_uid"] == DOCUMENT_UID }
    post pinned_documents_path, params: {
      kb_document_id: card["kb_document_id"],
      document_uid: card["document_uid"],
      correlation_id: body["correlation_id"]
    }, as: :json
    assert_response :success
    focus = reloaded_session.document_focus_entries.sole
    assert_equal @document.id, focus["kb_document_id"]
    assert_equal @focus_uri, focus["source_uri"]
    assert_includes @focus_uri, "bulk_uploads/1/2026-08-31/VF5.pdf"
  end

  def assert_turn_one(body)
    state = episode
    blob = state.to_h.to_json
    assert_match(/Fermator/, blob)
    assert_match(/VF5/, blob)
    assert_match(/reabre|re-abre/i, blob)
    assert_equal "not_done", check_status(state, /#54/)
    assert_equal "not_done", check_status(state, /medicion/)
    assert state.checks.none? { |item| item["subject"].to_s.match?(/obstruc/) && item["status"] == "done" }
    assert_includes body["answer"], "#21"
    assert_match(/fotoc[eé]lula/i, body["answer"])
  end

  def assert_turn_two(body)
    state = episode
    led = state.observations.find { |item| item["text"].to_s.match?(/\bled\b/i) }
    assert_equal "el LED está encendido", led["text"]
    assert state.observations.none? { |item| item["text"].to_s.match?(/apagado/i) }
    assert state.observations.none? { |item| item["text"].to_s.match?(/parpadeante|led de estado|led de fotoc/i) }
    assert_not_includes body["answer"], "parpadeante"
    assert_not_includes body["answer"], "condiciones apropiadas"
    assert_includes body["answer"], "#21"
    assert_match LED_QUESTION, body["answer"]
    assert_match(/#21/, state.pending_question["question"])
    shown = state.pending_question["shown"]
    assert_match LED_QUESTION, shown["question"]
    assert_equal 2, shown["targets"].size
    targets = shown["targets"].to_json
    assert_match(/Fotoc[eé]lula/, targets)
    assert_match(/Estado/, targets)
    assert_next_case_still_open(state)
  end

  def assert_turn_three(body)
    state = episode
    photo = state.checks.find { |item| item["subject"].to_s.match?(/fotoc[eé]lula/i) }
    assert_equal "done", photo["status"]
    assert_match(/no está activada/, photo["result"].to_s)
    assert_no_match(/#21/, photo["subject"].to_s)
    assert_equal INPUT_QUESTION, state.pending_question["question"]
    assert_match LED_QUESTION, state.pending_question.dig("shown", "question").to_s
    assert_includes body["answer"], INPUT_QUESTION
    assert_not_includes body["answer"], BAD_LED_READING
    assert_not_includes body["answer"], "pero el LED está encendido"
    assert_not_includes body["answer"], "es el de fotocélula"
    assert_match(/potenci[oó]metro|reabre|#54/i, body["answer"])
    assert_next_case_still_open(state)
  end

  def assert_turn_four(body)
    state = episode
    assert state.observations.none? { |item| item["text"].to_s.match?(/qu[eé] sigue/i) }
    assert_no_match(/qu[eé] sigue/i, state.goal&.[]("text").to_s)
    assert_equal INPUT_QUESTION, state.pending_question["question"]
    assert_match LED_QUESTION, state.pending_question.dig("shown", "question").to_s
    assert_includes body["answer"], "#21"
    assert_not_includes body["answer"], "¿Qué sigue?"
    assert_not_includes body["answer"], "no obedece a las señales"
    assert_next_case_still_open(state)
    assert_equal "done", check_status(state, /fotoc[eé]lula/)
  end

  def assert_turn_five(body)
    state = episode
    unknown = state.observations.find { |item| item.dig("answers", "r") == "unknown" }
    assert_includes unknown["text"], "#21"
    assert_includes unknown["text"], "contacto"
    assert_includes unknown.dig("answers", "q").to_s, "#21"
    assert_no_match(/Cu[aá]l LED/i, unknown.dig("answers", "q").to_s)
    assert_match LED_QUESTION, state.pending_question["question"]
    assert_equal 2, state.pending_question["targets"].size
    targets = state.pending_question["targets"].to_json
    assert_match(/Fotoc[eé]lula/, targets)
    assert_match(/Estado/, targets)
    assert_not_includes body["answer"], CONTACT_QUESTION
    assert_not_includes body["answer"], INPUT_QUESTION
    assert_not_includes body["answer"], "El LED se activa cuando"
    assert_not_includes body["answer"], "es el de fotocélula"
    assert_not_includes body["answer"], "no obedece a las señales"
    assert_equal "done", check_status(state, /fotoc[eé]lula/)
    assert_equal "not_done", check_status(state, /#54/)
    assert_equal "not_done", check_status(state, /medicion/)
  end

  def assert_next_case_still_open(state)
    assert_equal "not_done", check_status(state, /#54/)
    assert_equal "not_done", check_status(state, /medicion/)
    assert state.checks.none? { |item| item["subject"].to_s.match?(/obstruc/) && item["status"] == "done" }
  end

  def assert_next_antecedent(body, marker)
    session = reloaded_session
    reply = session.conversation_history.reverse.find { |item|
      item.is_a?(Hash) && item["role"] == "assistant" && item["prompt_reply"].present?
    }&.[]("prompt_reply").to_s
    assert_includes reply, marker, body["answer"].to_s.truncate(400)
    prior = SessionContextBuilder.companion_prior_answer(session)
    assert_includes prior, reply
    assert_includes prior, marker
  end

  def check_status(state, pattern)
    state.checks.find { |item| item["subject"].to_s.match?(pattern) }&.dig("status")
  end

  def episode
    Rag::ActiveEpisode.parse(reloaded_session.active_episode)
  end

  def reloaded_session
    ConversationSession.find(@session.id)
  end

  def ask(question, replay: nil)
    params = {}
    params[:question] = question if question
    params[:replay_correlation_id] = replay if replay
    post rag_ask_path, params: params, as: :json
    body = response.parsed_body
    assert_response :success, body.to_json.truncate(800)
    assert_equal "success", body["status"], body.to_json.truncate(800)
    body
  end

  def pinned_filter?(filter)
    filter.to_json.include?(@focus_uri.to_s)
  end

  def install_catalog
    sample = [ {
      location_uri: "s3://multimodal-source-destination/vf5-f5-regression/chunk_p12_5.txt",
      metadata: { "original_source_uri" => @focus_uri, "canonical_name" => "VF5" }
    } ]
    Rag::CompanionDefinitionSource.invalidate!("vf5-f5-regression")
    catalog = Rag::CompanionDefinitionSource.new(store_for: ->(*) { ChunkStore.new }).catalog_for(sample)
    assert catalog, "published candidate catalog did not load"
    Rag::CompanionDefinitionCatalog.current = catalog
  end

  def assert_capture_provenance(directory)
    root = Rails.root.join(directory)
    provenance = JSON.parse(root.join("provenance.json").read)
    assert_equal "ep_6dba74e041c77794", provenance["episode"]
    assert_equal "eb8e097ade60e99b0a55e955b6290082d129674f", provenance["image"]
    provenance["turns"].each do |name, turn|
      fixture = JSON.parse(root.join("#{name}.json").read)
      bodies = Array(turn["bodies"])
      assert_equal bodies.size, fixture["chunks"].size, name
      bodies.each_with_index do |body, index|
        digest = Digest::SHA256.hexdigest(fixture.dig("chunks", index, "content").to_s)
        assert_equal body["sha256"], digest, "#{name} #{body["path"]}"
      end
    end
  end

  def with_captured_externals(directory = nil, names = nil)
    cassette = Cassette.new(self, directory, names)
    original_converse = BedrockClient.instance_method(:converse)
    original_message = BedrockClient.instance_method(:converse_message)
    original_client = Aws::BedrockAgentRuntime::Client.method(:new)
    BedrockClient.define_method(:converse) { |*args, **kwargs| cassette.converse(args.first || kwargs) }
    BedrockClient.define_method(:converse_message) { |*args, **kwargs| cassette.converse(args.first || kwargs) }
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*, **| cassette.agent }
    yield cassette
  ensure
    BedrockClient.define_method(:converse, original_converse) if original_converse
    BedrockClient.define_method(:converse_message, original_message) if original_message
    if original_client
      Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args, **kwargs|
        original_client.call(*args, **kwargs)
      }
    end
  end

  # Same directory the continuity replay uses for the published candidate.
  class ChunkStore
    ROOT = Rails.root.join("test/fixtures/vf5_continuity_20261027/chunks")

    def list_keys(prefix:)
      Dir[ROOT.join("chunk_p*.txt")].sort.map { |path| "#{prefix}/#{File.basename(path)}" }
    end

    def download(key)
      path = ROOT.join(File.basename(key.to_s))
      return nil unless path.file?

      path.read
    end
  end

  class Cassette
    def initialize(test, directory = nil, names = nil)
      root = Rails.root.join(directory || "test/fixtures/vf5_f5_20261028")
      list = names || %w[t1_open t1_focused t2 t3 t4 t5]
      @turns = list.map { |name| JSON.parse(root.join("#{name}.json").read) }
      @viewer_id = test.instance_variable_get(:@account).id
      @pilot_id = test.instance_variable_get(:@pilot).id
      @focus_uri = test.instance_variable_get(:@focus_uri)
      @filters = []
    end

    attr_reader :filters

    def agent
      self
    end

    def converse(params)
      name = tool_name(params)
      turn = @turns.first
      expected = if name == Rag::TurnInterpreter::TOOL_NAME
        "interpreter"
      elsif name == Rag::CompanionPlan::TOOL_NAME
        "plan"
      else
        raise "unexpected tool #{name}"
      end
      raise "unexpected #{name}; next fixture has no #{expected}" if turn.nil? || turn[expected].nil?

      input = turn[expected]
      @turns.shift if expected == "plan"
      response(name, input)
    end

    def retrieve(params)
      config = params[:retrieval_configuration] || params["retrieval_configuration"] || {}
      vector = config[:vector_search_configuration] || config["vector_search_configuration"] || {}
      @filters << (vector[:filter] || vector["filter"])
      turn = @turns.first or raise "retrieve without a fixture"
      rows = Array(turn["chunks"]).map { |chunk| Retrieved.new(chunk, @viewer_id, @pilot_id, @focus_uri) }
      Struct.new(:retrieval_results).new(rows)
    end

    def retrieve_and_generate(*, **)
      raise "the companion path called retrieve_and_generate"
    end

    private

    def tool_name(params)
      config = params[:tool_config] || params["tool_config"] || {}
      choice = config[:tool_choice] || config["tool_choice"] || {}
      tool = choice[:tool] || choice["tool"] || {}
      tool[:name] || tool["name"]
    end

    def response(name, input)
      tool = Struct.new(:name, :input).new(name, input)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage).new(output, usage)
    end
  end

  class Retrieved
    def initialize(chunk, viewer_id, pilot_id, focus_uri)
      @content = Struct.new(:text).new(chunk["content"])
      @score = chunk["score"]
      @location = Struct.new(:s3_location).new(Struct.new(:uri).new(chunk["uri"]))
      vf5 = chunk["source_uri"].to_s.include?("VF5.pdf")
      # The capture body stays intact. The pin URI is the one this process
      # stores for that same VF5 key, so identity sees the confirmed manual.
      source = vf5 ? focus_uri : chunk["source_uri"]
      @metadata = {
        "account_id" => (vf5 ? viewer_id : pilot_id).to_s,
        "original_source_uri" => source,
        "x-amz-bedrock-kb-source-uri" => source,
        "page_number" => chunk["page"],
        "canonical_name" => chunk["document"],
        "original_filename" => vf5 ? "VF5.pdf" : File.basename(chunk["source_uri"].to_s)
      }
    end

    attr_reader :content, :score, :location, :metadata
  end
end
