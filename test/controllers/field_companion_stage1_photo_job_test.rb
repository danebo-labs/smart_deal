# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Stage 1, offline. The photo job runs through vision, retrieval and the
# direct generator with scripted providers. After reload, the pending is the
# one a text turn stores for the same question and the same published answer.
# Call counts are taken from those doubles, with FIELD_CHECK_OUTCOME off and on.
class FieldCompanionStage1PhotoJobTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  MANUAL_KEY = "bulk_uploads/3/2026-08-20/THYSSEN (Manual de Maniobra Universal con MCINV4).pdf"
  MANUAL_NAME = "THYSSEN (Manual de Maniobra Universal con MCINV4)"
  QUESTION = "Estoy con un Thyssen FDN Universal con MCINV4. El ascensor quedó detenido y el display marca EA"
  QUOTE = "Ponto para ligar sinal do contato de engate do trinco, confirmando portas de pavimento fechada"
  ANSWER = "La fuente indica «#{QUOTE}» [p9].\n\n¿El trinco engancha con la puerta cerrada?"
  TOOL = {
    "move" => "report",
    "assertions" => [
      { "span" => "Thyssen", "act" => "assert", "slot_hint" => "manufacturer" },
      { "span" => "FDN Universal", "act" => "assert", "slot_hint" => "model" },
      { "span" => "MCINV4", "act" => "assert", "slot_hint" => "controller" },
      { "span" => "EA", "act" => "assert", "slot_hint" => "fault_code" }
    ],
    "observations" => [ "El ascensor quedó detenido", "el display marca EA" ],
    "pending_resolution" => nil,
    "clarification_target" => nil
  }.freeze
  VISION = {
    "canonical_component" => "Panel", "manufacturer" => "UNKNOWN", "model" => "UNKNOWN",
    "subsystem" => "CONTROLLER_LOGIC", "condition" => "GOOD", "visible_text" => [ "P1" ],
    "summary" => "Se ve el panel.", "relevance_to_goal" => "relevant", "target_visible" => true,
    "aliases" => [], "documented_functions" => [], "anti_hallucination_notes" => ""
  }.freeze

  setup do
    @user = users(:one)
    @previous_account = @user.account
    @account = accounts(:pilot)
    host! "piloto.danebo.ai"
    @user.update!(account: @account)
    sign_in @user
    @env = %w[
      HAIKU_QUERY_ANALYSIS_MODE FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED
      RAG_COMPANION_TURN DOCUMENT_IDENTITY_SCOPE_ENABLED RAG_EPISODE_SCOPE_ENABLED
      BEDROCK_KNOWLEDGE_BASE_ID RAG_COMPANION_GENERATION BEDROCK_INFERENCE ANTHROPIC_API_KEY
      SHOW_RAG_SOURCES FIELD_CHECK_OUTCOME
    ].index_with { |key| ENV[key] }
    %w[
      HAIKU_QUERY_ANALYSIS_MODE FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED
      RAG_COMPANION_TURN DOCUMENT_IDENTITY_SCOPE_ENABLED RAG_EPISODE_SCOPE_ENABLED
      RAG_COMPANION_GENERATION
    ].each { |key| ENV.delete(key) }
    ENV["ANTHROPIC_API_KEY"] = "offline-replay"
    ENV["SHOW_RAG_SOURCES"] = "true"
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "Y7RZWMFJSR"
    ENV["BEDROCK_INFERENCE"] = "blocked"
  end

  teardown do
    @env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    @user&.update!(account: @previous_account) if @previous_account
  end

  test "the photo job stores the same pending as the text turn and the flag adds no calls" do
    manual = KbDocument.create!(account: @account, s3_key: MANUAL_KEY, display_name: MANUAL_NAME, aliases: [])
    row = JSON.parse(Rails.root.join("test/fixtures/field_companion/thyssen_ea_t4/chunks.json").read)
      .fetch("rows").find { |item| item["page"] == 9 }
    counts = {}

    [ nil, "true" ].each do |flag|
      ENV["FIELD_CHECK_OUTCOME"] = flag
      label = flag == "true" ? "on" : "off"
      cassette = Cassette.new(row, @account.id, manual.canonical_uri)
      with_providers(cassette) do
        counts[label] = {
          "text" => run_text(manual, cassette),
          "photo" => run_photo(manual, cassette)
        }
      end
    end

    %w[off on].each do |label|
      text = counts[label].fetch("text")
      photo = counts[label].fetch("photo")
      assert_equal "completed", text[:status], text.inspect
      assert_equal "completed", photo[:status], photo.inspect
      assert_equal({ "interpreter" => 1, "retrieve" => 1, "generator" => 1 }, text[:calls])
      assert_equal 1, photo[:calls].fetch("vision")
      assert_equal 1, photo[:calls].fetch("interpreter")
      assert_equal 1, photo[:calls].fetch("generator")
      # The photo retrieval question is not the raw turn, so with_turn_candidates
      # issues a second Retrieve. The text turn does not.
      assert_equal 2, photo[:calls].fetch("retrieve"), photo[:calls].inspect
    end
    assert_equal counts["off"]["text"][:calls], counts["on"]["text"][:calls]
    assert_equal counts["off"]["photo"][:calls], counts["on"]["photo"][:calls]

    # Flag on: PhotoTurn#publish and the text writer both persist from_publication.
    photo_on = comparable(counts["on"]["photo"][:pending])
    text_on = comparable(counts["on"]["text"][:pending])
    assert_equal text_on, photo_on, "flag on photo=#{counts['on']['photo'][:pending].inspect}"
    assert_equal "¿El trinco engancha con la puerta cerrada?", text_on["question"]
    assert_equal [], text_on["targets"]

    # Flag off stays on the previous writers. capture_pending! invents a target
    # for the text turn. install_published_pending! does not run, so the photo
    # reloads with no pending. Same calls either way.
    assert_nil counts["off"]["photo"][:pending]
    assert_equal "¿El trinco engancha con la puerta cerrada?", comparable(counts["off"]["text"][:pending])["question"]
    assert_equal [ "¿El trinco engancha con la puerta cerrada?" ], comparable(counts["off"]["text"][:pending])["targets"].pluck("item")
  end

  private

  def run_text(manual, cassette)
    cassette.mark
    post rag_ask_path, params: {
      creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid,
      question: QUESTION, kb_document_ids: [ manual.id.to_s ]
    }, as: :json
    body = response.parsed_body
    kase = FieldCase.find(body.fetch("field_case_id"))
    turn = kase.field_turns.order(:sequence).last
    { status: turn.reload.status, pending: kase.reload.technical_state["pending_question"], calls: cassette.since, body: body }
  end

  def run_photo(manual, cassette)
    cassette.mark
    post rag_ask_path, params: {
      creation_key: SecureRandom.uuid, client_submission_id: SecureRandom.uuid,
      question: QUESTION, kb_document_ids: [ manual.id.to_s ],
      image: { data: Base64.strict_encode64("offline image"), media_type: "image/jpeg", filename: "placa.jpg" }
    }, as: :json
    body = response.parsed_body
    perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
    kase = FieldCase.find(body.fetch("field_case_id"))
    turn = kase.field_turns.order(:sequence).last
    { status: turn.reload.status, pending: kase.reload.technical_state["pending_question"], calls: cassette.since, body: body }
  end

  def comparable(pending)
    return nil unless pending.is_a?(Hash)

    {
      "type" => pending["type"],
      "question" => pending["question"],
      "targets" => pending["targets"],
      "parts" => Array(pending["parts"]).map { |part| part.slice("role", "text") }
    }
  end

  def with_providers(cassette)
    originals = {
      Anthropic::Client => Anthropic::Client.method(:new),
      Aws::BedrockAgentRuntime::Client => Aws::BedrockAgentRuntime::Client.method(:new),
      S3DocumentsService => S3DocumentsService.method(:new),
      ImageCompressionService => ImageCompressionService.method(:compress_with_thumbnail)
    }
    storage = Object.new
    storage.define_singleton_method(:upload_binary) { |key, data, _type| key }
    storage.define_singleton_method(:download) { |_key| "offline image" }
    Anthropic::Client.define_singleton_method(:new) { |*, **| cassette }
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*, **| cassette }
    S3DocumentsService.define_singleton_method(:new) { |*| storage }
    ImageCompressionService.define_singleton_method(:compress_with_thumbnail) { |*, **| { binary: "offline image", media_type: "image/jpeg" } }
    yield
  ensure
    originals&.each do |klass, method|
      klass.define_singleton_method(method.name) { |*args, **kwargs| method.call(*args, **kwargs) }
    end
  end

  class Cassette
    def initialize(row, viewer_id, focus_uri)
      @row = row
      @viewer_id = viewer_id
      @focus_uri = focus_uri
      @ops = []
      @marks = [ 0 ]
    end

    def messages
      self
    end

    def mark
      @marks << @ops.size
    end

    def since
      @ops.drop(@marks.last).tally
    end

    def create(**payload)
      tools = payload[:tools] || payload["tools"] || payload[:tool_choice] || payload["tool_choice"]
      @ops << (tools ? "interpreter" : "generator")
      return tool_reply if tools

      prompt = Array(payload[:messages]).flat_map { |message| Array(message[:content]).map { |block| block[:text].to_s } }.join
      number = prompt[/^\[(\d+)\] [^\n]+, página 9(?:\D|$)/, 1] || "1"
      text_reply(ANSWER.gsub("[p9]", "[#{number}]"))
    end

    def stream(**)
      @ops << "vision"
      text = Struct.new(:type, :text).new(:text, JSON.generate(VISION))
      usage = OpenStruct.new(input_tokens: 12, output_tokens: 8)
      message = Struct.new(:content, :usage, :model, :stop_reason).new([ text ], usage, "claude-sonnet-5-5", "end_turn")
      Struct.new(:accumulated_message).new(message)
    end

    def retrieve(_params)
      @ops << "retrieve"
      Aws::BedrockAgentRuntime::Types::RetrieveResponse.new(
        retrieval_results: [ Retrieved.new(@row, @viewer_id, @focus_uri) ]
      )
    end

    def rerank(_payload)
      @ops << "rerank"
      Struct.new(:results, :next_token).new([], nil)
    end

    private

    def tool_reply
      content = [ { type: :tool_use, id: "tool-1", name: "turn_perception", input: TOOL } ]
      message("tool_use", content)
    end

    def text_reply(text)
      message("end_turn", [ { type: :text, text: text } ])
    end

    def message(stop_reason, content)
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
      uri = "s3://#{bucket}/bulk_chunks/3/stage1/#{row['chunk']}"
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
