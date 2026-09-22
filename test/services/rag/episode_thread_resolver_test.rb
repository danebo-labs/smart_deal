# frozen_string_literal: true

require "test_helper"

class Rag::EpisodeThreadResolverTest < ActiveSupport::TestCase
  SPRING = "Cómo se ajustan los resortes de la fijación de cables ?"
  SYNERGY = "ThyssenKrupp Synergy"
  U7 = "#{SPRING}\n#{SYNERGY}"
  CLARIFY = "si, me refiero a resoretes de tension"
  COMPOSED = "#{U7}\n#{CLARIFY}"
  NOW = Time.zone.parse("2026-09-21T16:17:47-03:00")
  CID = "query:ac78bcbf-735e-41f3-8782-f44e73695d9c"
  BRAKE = "Cómo se ajusta el freno del motor ?"
  DOOR = "Cómo se regula la puerta de cabina ?"
  CHAIN = "Cómo se tensiona la cadena de compensación ?"

  test "the measured episode joins one deduped thread" do
    result = resolve(measured_history, CLARIFY)

    assert_equal :join, result.outcome
    assert_equal "joined", result.reason
    assert_equal 1, result.recoverable_count
    assert_equal COMPOSED, result.composed
    assert_equal 114, result.composed.length
    assert_nil result.options
  end

  test "two distinct threads open a menu and the new query is last" do
    result = resolve(menu_history, CLARIFY)

    assert_equal :menu, result.outcome
    assert_equal 2, result.recoverable_count
    assert_equal 3, result.options.size
    assert_equal [ BRAKE, DOOR ], result.options.first(2).map { |option| option[:query].split("\n").first }
    assert result.options.first(2).all? { |option| option[:query].end_with?("\n#{CLARIFY}") }
    assert result.options.first(2).all? { |option|
      option[:label].exclude?("\n") && option[:label].length <= Rag::EpisodeThreadResolver::MAX_LABEL_CHARS
    }
    assert_equal I18n.t("rag.thread_menu_new_query", locale: :es), result.options.last[:label]
    assert_equal CLARIFY, result.options.last[:query]
  end

  test "three distinct threads produce four chips" do
    history = [
      user_row(BRAKE, "2026-09-21T16:10:00-03:00", "query:brake"),
      assistant_row("freno", "2026-09-21T16:10:05-03:00"),
      user_row(DOOR, "2026-09-21T16:12:00-03:00", "query:door"),
      assistant_row("puerta", "2026-09-21T16:12:05-03:00"),
      user_row(CHAIN, "2026-09-21T16:15:00-03:00", "query:chain"),
      assistant_row("cadena", "2026-09-21T16:15:05-03:00"),
      user_row(CLARIFY, "2026-09-21T16:17:40-03:00", CID)
    ]

    result = resolve(history, CLARIFY)

    assert_equal 4, result.options.size
    assert_equal Rag::EpisodeThreadResolver::MAX_MENU_OPTIONS, result.options.size
    assert_equal CLARIFY, result.options.last[:query]
  end

  test "a multiline segment label stays on one truncated line" do
    history = [
      user_row("Cómo se ajusta el freno ?", "2026-09-21T16:10:00-03:00", "query:spring"),
      user_row(SYNERGY, "2026-09-21T16:11:00-03:00", "query:synergy"),
      user_row(DOOR, "2026-09-21T16:14:00-03:00", "query:door"),
      user_row(CLARIFY, "2026-09-21T16:17:40-03:00", CID)
    ]

    result = resolve(history, CLARIFY)
    spring = result.options.find { |option| option[:query].include?(SYNERGY) }

    assert_equal :menu, result.outcome
    assert_includes spring[:label], " — "
    assert_not_includes spring[:label], "\n"
    assert_operator spring[:label].length, :<=, 48
  end

  test "copy lengths stay inside the history truncation" do
    assert_equal 75, I18n.t("rag.thread_menu_prompt", locale: :es).length
    assert_equal 91, I18n.t("rag.thread_menu_prompt", locale: :en).length
    assert_equal 23, I18n.t("rag.thread_menu_new_query", locale: :es).length
    assert_equal 23, I18n.t("rag.thread_menu_new_query", locale: :en).length
    assert I18n.t("rag.thread_menu_prompt", locale: :es).length < ConversationSession::MAX_MSG_LENGTH
    assert I18n.t("rag.thread_menu_prompt", locale: :en).length < ConversationSession::MAX_MSG_LENGTH
  end

  test "the flag off passes through" do
    previous = ENV["RAG_THREAD_MENU_ENABLED"]
    ENV["RAG_THREAD_MENU_ENABLED"] = "false"
    assert_equal "passthrough", resolve(measured_history, CLARIFY).reason
  ensure
    previous.nil? ? ENV.delete("RAG_THREAD_MENU_ENABLED") : ENV["RAG_THREAD_MENU_ENABLED"] = previous
  end

  test "a missing session, another channel, and a new question pass through" do
    assert_equal "passthrough", Rag::EpisodeThreadResolver.call(
      question: CLARIFY, conversation_session: nil, correlation_id: CID, locale: :es, now: NOW
    ).reason

    whatsapp = build_session(measured_history, channel: "whatsapp")
    assert_equal "passthrough", resolve_session(whatsapp, CLARIFY).reason
    assert_equal "not_followup_shape", resolve(measured_history, "como se ajusta esto?").reason
    assert_equal "not_followup_shape", resolve(measured_history, "#{CLARIFY}\nmas detalle").reason
  end

  test "an oversized segment does not join and does not open a menu" do
    long_question = "¿#{'a' * 299}"
    continuation = "b" * 200
    assert_equal ConversationSession::MAX_MSG_LENGTH, long_question.length
    history = [
      user_row(long_question, "2026-09-21T16:10:00-03:00", "query:long"),
      user_row(continuation, "2026-09-21T16:12:00-03:00", "query:cont"),
      user_row(DOOR, "2026-09-21T16:14:00-03:00", "query:door"),
      user_row(CLARIFY, "2026-09-21T16:17:40-03:00", CID)
    ]

    result = resolve(history, CLARIFY)

    assert_equal :pass, result.outcome
    assert_equal "budget_exceeded", result.reason
    assert_nil result.options
    assert_nil result.composed
  end

  test "the new-query chip does not reopen the menu" do
    history = menu_history
    history.last["correlation_id"] = "query:first"
    history << assistant_row(I18n.t("rag.thread_menu_prompt", locale: :es), "2026-09-21T16:17:41-03:00")
    history << user_row(CLARIFY, "2026-09-21T16:17:45-03:00", CID)

    result = resolve(history, CLARIFY)

    assert_equal :pass, result.outcome
    assert_equal "already_asked", result.reason
  end

  test "a different short clarification after the menu asks again" do
    history = menu_history
    history.last["content"] = "otra aclaracion corta"
    history.last["correlation_id"] = "query:first"
    history << assistant_row(I18n.t("rag.thread_menu_prompt", locale: :en), "2026-09-21T16:17:41-03:00")
    history << user_row(CLARIFY, "2026-09-21T16:17:45-03:00", CID)

    result = resolve(history, CLARIFY)

    assert_equal :menu, result.outcome
  end

  test "no recoverable thread leaves the turn unchanged" do
    history = [
      user_row(SYNERGY, "2026-09-21T16:11:28-03:00", "query:synergy"),
      user_row(CLARIFY, "2026-09-21T16:17:40-03:00", CID)
    ]

    result = resolve(history, CLARIFY)

    assert_equal :pass, result.outcome
    assert_equal "no_recoverable", result.reason
  end

  test "a turn already inside the segment is not appended twice" do
    history = [
      user_row(SPRING, "2026-09-21T16:10:00-03:00", "query:spring"),
      user_row(CLARIFY, "2026-09-21T16:16:00-03:00", "query:first"),
      user_row(DOOR, "2026-09-21T16:16:30-03:00", "query:door"),
      user_row(CLARIFY, "2026-09-21T16:17:40-03:00", CID)
    ]

    result = resolve(history, CLARIFY)
    spring = result.options.find { |option| option[:query].start_with?(SPRING) }

    assert_equal :menu, result.outcome
    assert_equal "#{SPRING}\n#{CLARIFY}", spring[:query]
  end

  test "duplicate correlation ids do not guess a thread" do
    history = menu_history
    history << history.last.merge("ts" => "2026-09-21T16:17:42-03:00")

    assert_equal "passthrough", resolve(history, CLARIFY).reason
  end

  private

  def resolve(history, question, correlation_id: CID)
    resolve_session(build_session(history), question, correlation_id: correlation_id)
  end

  def resolve_session(session, question, correlation_id: CID)
    Rag::EpisodeThreadResolver.call(
      question: question,
      conversation_session: session,
      correlation_id: correlation_id,
      locale: :es,
      now: NOW
    )
  end

  def build_session(history, channel: "web")
    ConversationSession.create!(
      identifier: "thread-#{SecureRandom.hex(6)}",
      channel: channel,
      account: accounts(:legacy),
      expires_at: 30.days.from_now,
      conversation_history: history
    )
  end

  def measured_history
    [
      user_row("EN la imgen, como se ajustan los resortes ?", "2026-09-21T16:01:19-03:00", "photo:u1"),
      assistant_row("foto", "2026-09-21T16:01:36-03:00"),
      user_row("si dame mas detalle del amarred de cables de suspension", "2026-09-21T16:02:23-03:00", "query:u2"),
      assistant_row("amarre", "2026-09-21T16:02:31-03:00"),
      user_row("ok, como seria para el caso Fuji Yida", "2026-09-21T16:03:13-03:00", "query:u3"),
      assistant_row("fuji", "2026-09-21T16:03:27-03:00"),
      user_row(SPRING, "2026-09-21T16:10:15-03:00", "query:u4"),
      assistant_row("resortes", "2026-09-21T16:10:23-03:00"),
      user_row(SPRING, "2026-09-21T16:10:37-03:00", "photo:u5"),
      assistant_row("foto", "2026-09-21T16:10:44-03:00"),
      user_row(SYNERGY, "2026-09-21T16:11:28-03:00", "query:u6"),
      assistant_row("synergy", "2026-09-21T16:11:35-03:00"),
      user_row(U7, "2026-09-21T16:16:57-03:00", "query:u7"),
      assistant_row("respuesta", "2026-09-21T16:17:02-03:00"),
      user_row(CLARIFY, "2026-09-21T16:17:40-03:00", CID)
    ]
  end

  def menu_history
    [
      user_row(BRAKE, "2026-09-21T16:10:00-03:00", "query:brake"),
      assistant_row("freno", "2026-09-21T16:10:05-03:00"),
      user_row(DOOR, "2026-09-21T16:14:00-03:00", "query:door"),
      assistant_row("puerta", "2026-09-21T16:14:05-03:00"),
      user_row(CLARIFY, "2026-09-21T16:17:40-03:00", CID)
    ]
  end

  def user_row(content, ts, correlation_id)
    { "role" => "user", "content" => content, "ts" => ts, "correlation_id" => correlation_id }
  end

  def assistant_row(content, ts)
    { "role" => "assistant", "content" => content, "ts" => ts }
  end
end
