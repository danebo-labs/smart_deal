# frozen_string_literal: true

require "test_helper"

class Rag::FollowupQueryRewriterTest < ActiveSupport::TestCase
  SPRING = "Cómo se ajustan los resortes de la fijación de cables ?"
  FOLLOW = "es Fuji Yida"
  NOW = Time.zone.parse("2026-09-18T13:56:28-03:00")
  ASSISTANT = "La documentación recuperada no trae ese procedimiento."
  PROMPT_SHA = "2999231aa9962aec66af6eb8d5091f8f5345e8f424c5bdaf1d5a6dc07b36d537"

  test "generation prompt bytes stay on the continuity baseline" do
    path = Rails.root.join("app/prompts/bedrock/generation.txt")
    assert_equal PROMPT_SHA, Digest::SHA256.file(path).hexdigest
  end

  test "composes the stored technical question with the catalog identifier" do
    guide = create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    session = build_session(pair_history(assistant: ASSISTANT))

    calls = []
    result = with_resolver_calls(calls) do
      rewrite(session, FOLLOW)
    end

    assert result.applied
    assert_equal "rewritten", result.reason
    assert_equal "#{SPRING}\n#{FOLLOW}", result.question
    assert_equal "photo:spring", result.previous_correlation_id
    assert_equal [ guide.id ], result.catalog_matches.map { |match| match.document.id }
    assert_equal [ "Fuji Yida" ], calls
  end

  test "accepts the pair when the stored assistant has no identification question" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    session = build_session(pair_history(assistant: ASSISTANT))

    result = rewrite(session, FOLLOW)

    assert result.applied
    assert_not_includes result.question, "¿"
  end

  test "strips closed prefixes without rewriting the catalog name" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])

    [ "es un Fuji Yida", "es una Fuji Yida", "it's Fuji Yida", "it is a Fuji Yida" ].each do |follow_up|
      session = build_session(pair_history(assistant: ASSISTANT, follow_up: follow_up))
      calls = []
      result = with_resolver_calls(calls) { rewrite(session, follow_up) }

      assert result.applied, follow_up
      assert_equal "#{SPRING}\n#{follow_up}", result.question
      assert_equal [ "Fuji Yida" ], calls
    end
  end

  test "a bare brand is not an identifier when the catalog name is longer" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    session = build_session(pair_history(assistant: ASSISTANT, follow_up: "Fuji"))

    result = rewrite(session, "Fuji")

    assert_not result.applied
    assert_equal "not_identifier", result.reason
    assert_equal "Fuji", result.question
  end

  test "a specific designator is covered by matched tokens without an exact title" do
    create_guide(display_name: "Control board MPK418", aliases: [ "board manual" ])
    session = build_session(pair_history(assistant: ASSISTANT, follow_up: "MPK418"))

    result = rewrite(session, "MPK418")

    assert result.applied
    assert_equal "#{SPRING}\nMPK418", result.question
    assert_equal [ "MPK418" ], result.catalog_matches.flat_map(&:matched_tokens)
  end

  test "a new question is excluded before the catalog" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    session = build_session(pair_history(assistant: ASSISTANT, follow_up: "y el torque?"))
    calls = []

    result = with_resolver_calls(calls) { rewrite(session, "y el torque?") }

    assert_not result.applied
    assert_equal "new_question", result.reason
    assert_equal "y el torque?", result.question
    assert_empty calls
  end

  test "thanks and ok do not continue the previous question" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])

    [ "gracias", "ok" ].each do |follow_up|
      session = build_session(pair_history(assistant: ASSISTANT, follow_up: follow_up))
      result = rewrite(session, follow_up)

      assert_not result.applied, follow_up
      assert_equal "not_identifier", result.reason
      assert_equal follow_up, result.question
    end
  end

  test "missing session, another channel, and another account do not rewrite" do
    assert_equal "no_session", rewrite(nil, FOLLOW).reason

    whatsapp = build_session(pair_history(assistant: ASSISTANT), channel: "whatsapp")
    assert_equal "non_web_channel", rewrite(whatsapp, FOLLOW).reason

    other = build_session(pair_history(assistant: ASSISTANT), account: accounts(:climb))
    calls = []
    result = with_resolver_calls(calls) { rewrite(other, FOLLOW) }
    assert_equal "account_mismatch", result.reason
    assert_empty calls
  end

  test "history outside the episode window is not a pair" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    old = (NOW - 5.hours).iso8601
    history = pair_history(assistant: ASSISTANT).map do |row|
      row["role"] == "user" && row["correlation_id"] == "query:follow" ? row : row.merge("ts" => old)
    end
    session = build_session(history)

    result = rewrite(session, FOLLOW)

    assert_not result.applied
    assert_equal "no_episode", result.reason
  end

  test "duplicate correlation ids do not guess a pair" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    history = pair_history(assistant: ASSISTANT)
    history << history.last.merge("ts" => "2026-09-18T13:56:20-03:00")
    session = build_session(history)

    assert_equal "ambiguous_history", rewrite(session, FOLLOW).reason
  end

  test "a technical question that was not stored whole is not continued" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    truncated = "¿#{'a' * 296}..."
    assert_equal ConversationSession::MAX_MSG_LENGTH, truncated.length
    history = pair_history(assistant: ASSISTANT).map do |row|
      row["correlation_id"] == "photo:spring" && row["role"] == "user" ? row.merge("content" => truncated) : row
    end

    result = rewrite(build_session(history), FOLLOW)

    assert_not result.applied
    assert_equal "no_discriminant", result.reason
  end

  test "a generation-retry or photo-only assistant is not a pair" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])

    retry_assistant = I18n.t("rag.generation_retry", locale: :es)
    retry_result = rewrite(build_session(pair_history(assistant: retry_assistant)), FOLLOW)
    assert_equal "no_discriminant", retry_result.reason

    photo_only = [
      user_row(SPRING, "2026-09-18T13:49:25-03:00", "photo:spring"),
      assistant_row("[FOTO] Componente observado", "2026-09-18T13:49:36-03:00", "photo:spring"),
      user_row(FOLLOW, "2026-09-18T13:56:28-03:00", "query:follow")
    ]
    assert_equal "no_discriminant", rewrite(build_session(photo_only), FOLLOW).reason
  end

  test "two identification questions in the assistant do not guess" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    assistant = "¿Cuál es la marca del equipo? ¿Cuál es el modelo del equipo?"
    result = rewrite(build_session(pair_history(assistant: assistant)), FOLLOW)

    assert_not result.applied
    assert_equal "ambiguous_history", result.reason
  end

  test "the thread menu copy does not block a catalog follow-up" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])

    %i[es en].each do |locale|
      prompt = I18n.t("rag.thread_menu_prompt", locale: locale)
      result = rewrite(build_session(pair_history(assistant: prompt)), FOLLOW)

      assert result.applied, locale
      assert_equal "rewritten", result.reason
    end
  end

  test "an intervening user turn invalidates the pair" do
    create_guide(display_name: "Fuji Yida Guia del Usuario", aliases: [ "Fuji Yida" ])
    later = [ user_row("y el otro equipo?", "2026-09-18T13:55:00-03:00", "query:middle") ]
    result = rewrite(build_session(pair_history(assistant: ASSISTANT, later: later)), FOLLOW)

    assert_equal "ambiguous_history", result.reason
  end

  test "the longest eligible composition stays inside the character and token caps" do
    previous = "¿#{'a' * 299}"
    identifier = "B" * Rag::FollowupQueryRewriter::MAX_FOLLOWUP_CHARS
    assert_equal ConversationSession::MAX_MSG_LENGTH, previous.length
    create_guide(display_name: identifier, aliases: [])
    history = [
      user_row(previous, "2026-09-18T13:49:25-03:00", "photo:spring"),
      assistant_row(ASSISTANT, "2026-09-18T13:49:44-03:00", "photo:spring"),
      user_row(identifier, "2026-09-18T13:56:28-03:00", "query:follow")
    ]

    result = rewrite(build_session(history), identifier)
    delta = AnthropicTokenCounter::LocalTokenizer.estimate(result.question) -
            AnthropicTokenCounter::LocalTokenizer.estimate(identifier)

    assert result.applied
    assert_operator result.question.length, :<=, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS
    assert_operator delta, :<=, 160
  end

  private

  def rewrite(session, question, account: accounts(:legacy), correlation_id: "query:follow")
    Rag::FollowupQueryRewriter.call(
      question: question,
      conversation_session: session,
      account: account,
      correlation_id: correlation_id,
      now: NOW
    )
  end

  def build_session(history, channel: "web", account: accounts(:legacy))
    ConversationSession.create!(
      identifier: "followup-#{SecureRandom.hex(6)}",
      channel: channel,
      account: account,
      expires_at: 30.days.from_now,
      conversation_history: history
    )
  end

  def create_guide(display_name:, aliases:)
    KbDocument.create!(
      account: accounts(:legacy),
      s3_key: "uploads/followup/#{SecureRandom.hex(8)}.pdf",
      display_name: display_name,
      aliases: aliases
    )
  end

  def pair_history(assistant:, follow_up: FOLLOW, later: [])
    [
      user_row(SPRING, "2026-09-18T13:49:25-03:00", "photo:spring"),
      assistant_row("[FOTO] Componente observado", "2026-09-18T13:49:36-03:00", "photo:spring"),
      assistant_row(assistant, "2026-09-18T13:49:44-03:00", "photo:spring"),
      *later,
      user_row(follow_up, "2026-09-18T13:56:28-03:00", "query:follow")
    ]
  end

  def user_row(content, ts, correlation_id)
    { "role" => "user", "content" => content, "ts" => ts, "correlation_id" => correlation_id }
  end

  def assistant_row(content, ts, correlation_id)
    { "role" => "assistant", "content" => content, "ts" => ts, "correlation_id" => correlation_id }
  end

  def with_resolver_calls(calls)
    original = KbDocumentResolver.method(:resolve_scoped)
    KbDocumentResolver.define_singleton_method(:resolve_scoped) do |query, account:|
      calls << query
      original.call(query, account: account)
    end
    yield
  ensure
    KbDocumentResolver.define_singleton_method(:resolve_scoped) do |*args, **kwargs|
      original.call(*args, **kwargs)
    end
  end
end
