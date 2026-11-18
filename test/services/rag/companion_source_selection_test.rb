# frozen_string_literal: true

require "test_helper"

# What the generator receives when the ranked passages do not all fit the
# fresh window. The sizes and scores are those of the sixth Thyssen run, turn
# 4: the fourth ranked passage held the nominal value of the point the
# technician had just measured, and it was dropped by 148 characters.
class Rag::CompanionSourceSelectionTest < ActiveSupport::TestCase
  NOMINAL = "RA-53 / P28 = +110 Vcc | Ponto para ligar sinal do contato de engate do trinco"
  CIRCUIT = "Quando falha de P28 - porta aberta - revisar linha dos trincos"
  URI_BASE = "s3://bucket/bulk_chunks/3/manual"

  test "a passage the ledger already delivers does not take the window a second time" do
    chunks = ranked_chunks
    session = session_with_ledger([ chunks.fetch(2) ])

    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: "medí 0 Vcc en P28. ¿Qué me dice esa lectura?",
      chunks: chunks, episode: { "episode_id" => "ep_a" }, session: session, correlation_id: "c4"
    )

    assert_includes prepared.user, NOMINAL
    assert_includes prepared.user, CIRCUIT
    pages = prepared.chunks.map { |chunk| chunk.dig(:metadata, "page_number") }
    assert_equal [ 24, 19, 10, 9 ], pages.first(4)
    assert_equal 1, prepared.user.scan(CIRCUIT).size
  end

  test "the capture marks the chunk covered by the ledger and lists what was dropped" do
    chunks = ranked_chunks
    session = session_with_ledger([ chunks.fetch(2) ])
    events = Rag::ValidationCapture.capture {
      Rag::CompanionDirectAnswer.prepare(
        raw_question: "medí 0 Vcc en P28", chunks: chunks,
        episode: { "episode_id" => "ep_a" }, session: session, correlation_id: "c4"
      )
    }
    sources = events.find { |event| event["kind"] == "companion_sources" }

    covered = sources["kept"].select { |row| row["case_ledger"] }
    assert_equal [ 24 ], covered.pluck("page")
    assert_includes sources["kept"].pluck("page"), 9
    assert_not_includes sources["omitted"].pluck("page"), 24
    assert(sources["omitted"].all? { |row| row["score"] < 0.7147 })
  end

  test "without a ledger the lowest scores still go first and the window holds" do
    chunks = ranked_chunks

    kept = Rag::CompanionPlan.limit_statement_chunks(chunks)

    assert_operator kept.sum { |chunk| Rag::CompanionPlan.chunk_chars(chunk) }, :<=, Rag::CompanionPlan::STATEMENTS_MAX_CHARS
    assert_equal [ 19, 10, 24 ], kept.map { |chunk| chunk.dig(:metadata, "page_number") }
  end

  test "an equivalent case on another manual keeps the nominal passage under the same ledger" do
    sizes = [ [ 7_900, 0.81 ], [ 3_000, 0.78 ], [ 2_400, 0.75 ], [ 2_100, 0.71 ], [ 3_000, 0.70 ], [ 1_000, 0.40 ] ]
    chunks = sizes.each_with_index.map { |(chars, score), index|
      body = index == 3 ? "X9 = 24 Vcc | entrada de la cadena de seguridad #{'z' * chars}" : "otro #{index} #{'y' * chars}"
      chunk(body, page: index + 1, score: score, uri: "s3://bucket/bulk_chunks/9/otro/chunk_p#{index + 1}_1.txt")
    }
    session = session_with_ledger([ chunks.fetch(2) ])

    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: "medí 0 Vcc en X9", chunks: chunks, episode: { "episode_id" => "ep_a" },
      session: session, correlation_id: "c4"
    )

    assert_includes prepared.user, "X9 = 24 Vcc"
  end

  test "a window that is over with nothing else to drop stops instead of looping" do
    chunks = [ chunk("solo #{'q' * 17_000}", page: 1, score: 0.9, uri: "#{URI_BASE}/chunk_p1_1.txt") ]
    delivered = Set[Rag::CompanionCaseRecord.identity_of(chunks.first)]

    assert_equal chunks, Rag::CompanionPlan.limit_statement_chunks(chunks, delivered: delivered)
  end

  test "the count window skips a passage the ledger already delivers" do
    chunks = ranked_chunks
    delivered = Rag::CompanionCaseRecord.ledger_identities(session_with_ledger([ chunks.fetch(2) ]), "ep_a")

    ordered = chunks.sort_by { |chunk| -chunk[:score] }
    pages = ->(list) { list.map { |chunk| chunk.dig(:metadata, "page_number") } }

    assert_equal [ 19, 10, 24 ], pages.call(ordered.first(3))
    assert_equal [ 19, 10, 24, 9 ], pages.call(Rag::CompanionCaseRecord.fresh_window(ordered, 3, delivered))
    assert_equal pages.call(ordered.first(3)), pages.call(Rag::CompanionCaseRecord.fresh_window(ordered, 3, Set.new))
    assert_equal pages.call(ordered.first(3)), pages.call(Rag::CompanionCaseRecord.fresh_window(ordered, 3, nil))
  end

  test "a ledger passage ranked below the window adds no fresh slot" do
    chunks = ranked_chunks
    delivered = Rag::CompanionCaseRecord.ledger_identities(session_with_ledger([ chunks.last ]), "ep_a")
    ordered = chunks.sort_by { |chunk| -chunk[:score] }

    kept = Rag::CompanionCaseRecord.fresh_window(ordered, 3, delivered)

    assert_equal ordered.first(3) + [ ordered.last ], kept
  end

  private

  # page, characters of narrative, rerank score. The page 9 chunk of rank 4 is
  # the one with the nominal; page 24 is the one the ledger holds.
  def ranked_chunks
    [
      [ 19, 8_516, 0.8003, "tabela de bornes P28 ENTRADA DO SINAL DE PORTA" ],
      [ 10, 3_090, 0.7851, "RA-30 / A4+ = 110 Vcc alimentacao do circuito de trinco" ],
      [ 24, 2_543, 0.7542, CIRCUIT ],
      [ 9, 1_999, 0.7147, NOMINAL ],
      [ 21, 3_080, 0.7090, "pagina 21" ],
      [ 20, 3_017, 0.6464, "pagina 20" ],
      [ 9, 1_838, 0.6386, "sinais de selecao" ],
      [ 8, 2_596, 0.6100, "pagina 8 a" ],
      [ 8, 2_259, 0.5315, "pagina 8 b" ],
      [ 15, 1_197, 0.4558, "pagina 15" ],
      [ 7, 519, 0.3402, "pagina 7" ]
    ].each_with_index.map { |(page, chars, score, marker), index|
      chunk("#{marker} #{'.' * (chars - marker.length - 1)}", page: page, score: score,
        uri: "#{URI_BASE}/chunk_p#{page}_#{index}.txt")
    }
  end

  def chunk(body, page:, score:, uri:)
    {
      content: body, score: score, location_uri: uri, chunk_sha256: Digest::SHA256.hexdigest(body),
      metadata: { "page_number" => page, "canonical_name" => "Manual", "chunk_id" => "p#{page}-#{score}" }
    }
  end

  def session_with_ledger(cited)
    recorded = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: "ep_a", chunks: cited, correlation_id: "c2", outcome: "published",
      published_text: "La tabla dice algo [1]."
    )
    cutoff = Time.zone.parse("2000-01-01T00:00:00Z")
    Struct.new(:conversation_history, :case_evidence) do
      define_method(:episode_history_cutoff) { |_now = Time.current| cutoff }
    end.new([], recorded.state)
  end
end
