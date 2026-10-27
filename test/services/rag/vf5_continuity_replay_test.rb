# frozen_string_literal: true

require "test_helper"
require_relative "../../support/companion_plan_response"

# Morning and midday GUI captures of 27 Oct 2026, walked through
# record_user_turn!, the reducer, the plan check, and publication.
# The interpreter tool, the retrieved bodies, and the plan tool are the
# capture. Definition pages are the vendored chunk texts. Nothing calls Bedrock.
class Rag::Vf5ContinuityReplayTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FOCUS_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
  STATUS_SENTENCE = "no obedece a las señales"

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "morning keeps the led correction and the unknown on the named datum" do
    walked = walk("morning")
    assert_sample(walked, led_question_replaces: false)
  end

  test "midday keeps the open datum when the model asks which indicator" do
    walked = walk("midday")
    assert_sample(walked, led_question_replaces: true)
  end

  private

  def assert_sample(walked, led_question_replaces:)
    t2 = walked.fetch("t2")
    t3 = walked.fetch("t3")
    t4 = walked.fetch("t4")
    t5 = walked.fetch("t5")
    open_question = walked.fetch("t2")[:episode].pending_question["question"]

    assert_match(/#21/, open_question)
    assert_match(/encendido/i, t2[:episode].observations.pluck("text").join(" "))
    assert t2[:episode].observations.none? { |item| item["text"].match?(/apagado/i) }
    assert_not_includes t2[:text], "parpadeante"
    assert_equal open_question, t2[:episode].pending_question["question"]

    assert_equal open_question, t3[:episode].pending_question["question"]
    assert t3[:episode].observations.none? { |item| item.dig("answers", "r") == "unknown" }
    assert_equal "done", check_status(t3[:episode], /fotoc[eé]lula/)
    assert_equal "not_done", check_status(t3[:episode], /#54/)
    assert_equal "not_done", check_status(t3[:episode], /medicion/)
    assert t3[:episode].checks.none? { |item| item["subject"].to_s.match?(/obstruc/) && item["status"] == "done" }
    assert_not_includes t3[:text], STATUS_SENTENCE
    if led_question_replaces
      assert_match(/LED/i, t3[:episode].pending_question.dig("shown", "question").to_s)
      assert_includes t3[:text], "Fotocélula"
    end

    assert t4[:episode].observations.none? { |item| item["text"].match?(/qu[eé] sigue/i) }
    assert_equal open_question, t4[:episode].pending_question["question"]
    assert_not_includes t4[:text], STATUS_SENTENCE
    assert_includes t4[:text], "potenciómetro"

    unknown = t5[:episode].observations.find { |item| item.dig("answers", "r") == "unknown" }
    assert unknown, t5[:episode].observations.pluck("text").inspect
    assert_includes unknown["text"], "#21"
    assert_includes unknown["text"], "contacto"
    assert_includes unknown.dig("answers", "q").to_s, "#21"
    assert_no_match(/LED encendido es el de/i, unknown.dig("answers", "q").to_s)
    assert_not_includes t5[:text], STATUS_SENTENCE
    assert_equal "not_done", check_status(t5[:episode], /#54/)
    assert_equal "done", check_status(t5[:episode], /fotoc[eé]lula/)
  end

  def check_status(episode, pattern)
    episode.checks.find { |item| item["subject"].to_s.match?(pattern) }&.dig("status")
  end

  def walk(sample)
    previous_mode = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    previous_episode = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    session = nil
    document = nil
    document = fermator_document
    session = ConversationSession.create!(
      identifier: "web:vf5-continuity-#{sample}-#{SecureRandom.hex(3)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: @user,
      account: @account,
      active_episode: {},
      conversation_history: [],
      document_focus: [ {
        "kb_document_id" => document.id,
        "source_uri" => FOCUS_URI,
        "display_name" => "VF5",
        "added_at" => Time.current.iso8601
      } ]
    )
    walked = {}
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      turns(sample).each do |raw|
        now = Time.current
        result = session.record_user_turn!(
          raw["user"],
          user_id: @user.id,
          correlation_id: raw["correlation_id"],
          now: now,
          interpreter_client: PerceptionClient.new(raw["interpreter"])
        )
        episode = Rag::ActiveEpisode.parse(session.reload.active_episode, now: now)
        chunks = expanded_chunks(raw)
        prepared = Rag::CompanionPlan.prepare(
          raw_question: raw["user"], chunks: chunks, episode: episode, session: session,
          correlation_id: raw["correlation_id"]
        )
        composed = Rag::CompanionPlan.compose(CompanionPlanResponse.build(raw["plan"]), prepared)
        published = Rag::CompanionTurnPublication.call(
          text: composed.text,
          sources: chunks.each_with_index.map { |chunk, index|
            { "index" => index + 1, "content" => chunk[:content].to_s, "applicability" => "compatible", "reference_only" => false }
          },
          technician_texts: BedrockRagService.allocate.send(:companion_technician_texts, session, episode, raw["user"]),
          manufacturer: episode.fact("manufacturer")&.dig("value"),
          stop_reason: "tool_use"
        )
        session.record_assistant_turn!(
          composed.text,
          user_id: @user.id,
          correlation_id: raw["correlation_id"],
          pending_question: composed.pending,
          expected_episode_id: episode.episode_id,
          prompt_reply: composed.text
        )
        stored = Rag::ActiveEpisode.parse(session.reload.active_episode, now: now)
        walked[raw["turn"]] = {
          text: composed.text, episode: stored, reason: result&.reason,
          published: published, question: composed.check&.question
        }
      end
    end
    walked
  ensure
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous_mode
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous_episode
    session&.destroy
    document&.destroy
  end

  def expanded_chunks(raw)
    chunks = raw["chunks"].map { |chunk|
      {
        content: chunk["content"],
        location_uri: chunk["uri"],
        original_source_uri: FOCUS_URI,
        metadata: {
          "original_source_uri" => FOCUS_URI,
          "page_number" => chunk["page"],
          "canonical_name" => chunk["document"],
          "original_filename" => "VF5.pdf",
          "x-amz-bedrock-kb-source-uri" => chunk["uri"]
        },
        identity_applicability: "compatible"
      }
    }
    prefix = chunks.filter_map { |chunk|
      match = chunk[:location_uri].to_s.match(%r{\As3://[^/]+/(?<key>.+)/[^/]+\z})
      match && match[:key]
    }.first
    Rag::CompanionDefinitionSource.invalidate!(prefix) if prefix
    catalog = Rag::CompanionDefinitionSource.new(store_for: ->(_) { ChunkStore.new }).catalog_for(chunks)
    expanded = Rag::CompanionDefinitionExpander.expand(chunks, catalog: catalog, targets: [])
    expanded.chunks
  end

  def turns(sample)
    Rails.root.glob("test/fixtures/vf5_continuity_20261027/#{sample}/t*.json").sort.map { |path|
      JSON.parse(File.read(path))
    }
  end

  def fermator_document
    uid = SecureRandom.uuid
    KbDocument.create!(
      account: @account, s3_key: "manuals/#{uid}.pdf", display_name: "VF5", document_uid: uid, aliases: []
    )
  end

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

  class PerceptionClient
    def initialize(input)
      @input = input
    end

    def converse(_params)
      tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, @input)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage).new(output, usage)
    end
  end
end
