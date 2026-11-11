# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "../../support/companion_direct_capture_replay"

class Rag::CompanionCaseRecordTest < ActiveSupport::TestCase
  G2_PHRASE = "Fue solo la primera apertura"
  G2_QUESTIONS = [
    "Estoy con un Fermator VF5+. Después de un corte de alimentación, al volver la corriente la puerta abrió muy despacio. ¿Por dónde empiezo?",
    "Fue solo la primera apertura. Después volvió a abrir y cerrar como antes.",
    "No he cambiado la configuración ni conectado o desconectado la fotocélula. Con lo que te conté, ¿hace falta repetir el autoajuste?"
  ].freeze
  G1_QUESTIONS = [
    "Estoy revisando un operador de puerta Fermator VF5+. La puerta se reabre sola durante el cierre. El LED está apagado y no veo obstrucción. Todavía no he revisado el ajuste de #54 ni he hecho mediciones. ¿Cómo seguimos?",
    "Corrijo un dato: el LED está encendido, no apagado.",
    "Revisé la fotocélula y no está activada.",
    "¿Qué sigue?",
    "No sé cómo identificar si está activada la entrada #21 ni cómo saber si hay un contacto cerrado entre #21 y #23. ¿Qué información necesitas de mí para orientar el caso?"
  ].freeze
  OLD_PARAGRAPH = "Las fuentes numeradas de este mensaje son las únicas de este turno. Un [n] de un mensaje anterior pertenece a otras fuentes."
  NEW_PARAGRAPH = "Las fuentes numeradas son las del caso. Un [n] de un mensaje anterior es la misma fuente, con el mismo número."

  setup do
    @episode_flag = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
  end

  teardown do
    @episode_flag.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = @episode_flag
  end

  test "retrieval keeps whole turns in case order and traces what did not fit" do
    session = memory_session([
      turn("primero", "c1", 4),
      turn("segundo-corto", "c2", 3),
      turn("tercero", "c3", 2),
      turn("actual", "c4", 1)
    ])
    retrieval = Rag::CompanionCaseRecord.retrieval_text(session, "actual", correlation_id: "c4", now: Time.current)

    assert_equal "actual\nprimero\ntercero\nsegundo-corto", retrieval.text
    assert_equal false, retrieval.current_truncated
    assert_equal %w[c4 c1 c3 c2], retrieval.included.pluck("correlation_id")
    assert_empty retrieval.omitted
  end

  test "a later short turn still fits after an earlier turn that does not" do
    session = memory_session([
      turn("P" * 200, "c1", 4),
      turn("M" * 200, "c2", 3),
      turn("S" * 20, "c3", 2),
      turn("C" * 200, "c4", 1)
    ])
    retrieval = Rag::CompanionCaseRecord.retrieval_text(session, "C" * 200, correlation_id: "c4", now: Time.current)

    assert_equal [ ("C" * 200), ("P" * 200), ("S" * 20) ].join("\n"), retrieval.text
    assert_equal [ { "correlation_id" => "c2", "chars" => 200, "reason" => "budget" } ], retrieval.omitted
    assert_equal false, retrieval.current_truncated
  end

  test "a current message longer than the retrieve limit is cut and keeps the original for generation" do
    previous = "Fue solo la primera apertura. Después volvió a abrir."
    current = ("a" * 450) + "COLA-LARGA"
    session = memory_session([
      turn(previous, "c1", 2),
      turn(current, "c2", 1)
    ])
    retrieval = Rag::CompanionCaseRecord.retrieval_text(session, current, correlation_id: "c2", now: Time.current)

    assert_equal current[0, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS], retrieval.text
    assert_equal true, retrieval.current_truncated
    assert_equal true, retrieval.included.first["truncated"]
    assert_equal current.length, retrieval.included.first["total_chars"]
    assert_not_includes retrieval.text, "COLA-LARGA"
    assert_not_includes retrieval.text, previous
    assert_equal %w[c2 c1], retrieval.omitted.pluck("correlation_id")
    assert retrieval.omitted.all? { |row| row["reason"] == "current_over_limit" }

    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: current, chunks: [ passage("sensor", "s3://manual/a") ],
      episode: { "episode_id" => "ep_a" }, session: session, correlation_id: "c2"
    )
    assert_includes prepared.user, "COLA-LARGA"
    assert_includes prepared.messages.map { |message| message[:content][0][:text] }.join("\n"), previous
  end

  test "full content and a cut legacy message stay available outside retrieve" do
    kept = "arranque. #{G2_PHRASE}"
    full_session = memory_session([
      {
        "role" => "user",
        "content" => "resumen",
        "full_content" => kept,
        "ts" => 1.minute.ago.iso8601,
        "correlation_id" => "c1"
      }
    ])
    long = ("a" * 700) + G2_PHRASE
    stored = long.truncate(ConversationSession::MAX_MSG_LENGTH)
    legacy = memory_session([
      {
        "role" => "user",
        "content" => stored,
        "ts" => 1.minute.ago.iso8601,
        "correlation_id" => "c2"
      }
    ])
    from_full = Rag::CompanionCaseRecord.retrieval_text(full_session, "pregunta breve", correlation_id: "c-new", now: Time.current)
    from_legacy = Rag::CompanionCaseRecord.retrieval_text(legacy, long, correlation_id: "c2", now: Time.current)

    assert_includes from_full.text, G2_PHRASE
    assert_not_includes from_full.text, "resumen"
    assert_equal long[0, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS], from_legacy.text
    assert_not_includes from_legacy.text, G2_PHRASE
    assert_not_includes from_legacy.text, "..."
  end

  test "a blank retrieve composition falls back to the original question" do
    previous = ENV["RAG_COMPANION_GENERATION"]
    ENV["RAG_COMPANION_GENERATION"] = "direct"
    service = BedrockRagService.allocate
    session = memory_session([])
    sent = service.send(
      :direct_case_retrieve_question, "pregunta original",
      raw_question: "", conv_session: session, correlation_id: nil, companion_focus: true
    )
    untouched = service.send(
      :direct_case_retrieve_question, "pregunta original",
      raw_question: "otra", conv_session: session, correlation_id: nil, companion_focus: false
    )

    assert_equal "pregunta original", sent
    assert_equal "pregunta original", untouched
  ensure
    previous.nil? ? ENV.delete("RAG_COMPANION_GENERATION") : ENV["RAG_COMPANION_GENERATION"] = previous
  end

  test "cited passages keep their number and a fresh passage takes the next free number" do
    first = passage("alpha estable", "s3://manual/a")
    second = passage("beta estable", "s3://manual/b")
    recorded = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: "ep_a", chunks: [ first, second ],
      published_text: "Uno [1] y dos [2].", correlation_id: "t1", outcome: "published"
    )
    session = memory_session([], recorded.state)
    fresh = passage("gamma nueva", "s3://manual/c")
    merged = Rag::CompanionCaseRecord.sources(session, "ep_a", [ fresh, second ])

    assert_equal [ 1, 2, 3 ], merged.map.with_index { |chunk, index| Rag::CompanionCaseRecord.number_of(chunk, index) }
    assert_equal digest("alpha estable"), merged[0][:chunk_sha256]
    assert_equal digest("beta estable"), merged[1][:chunk_sha256]
    assert_equal "gamma nueva", Rag::CompanionCaseRecord.text_of(merged[2])
    assert_equal "published_citation", recorded.state["sources"][0]["provenance"]
    assert_not recorded.state["sources"][0].key?("applicability")
    assert_nil merged[0][:identity_applicability]
    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: "sigue", chunks: [ fresh ], episode: { "episode_id" => "ep_a" }, session: session
    )
    assert_includes prepared.user, "[1] "
    assert_includes prepared.user, "alpha estable"
    assert_includes prepared.user, "[3] "
    assert_includes prepared.user, "gamma nueva"
  end

  test "a full ledger retires the new number and does not give it to another text" do
    chunks = 9.times.map { |index| passage("pasaje #{index}", "s3://manual/#{index}") }
    cited = (1..9).map { |number| "[#{number}]" }.join(" ")
    recorded = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: "ep_a", chunks: chunks, published_text: cited,
      correlation_id: "t1", outcome: "published"
    )

    assert_equal true, recorded.ledger_full
    assert_equal 8, recorded.state["sources"].size
    assert_equal [ 9 ], recorded.state["retired"]
    assert_includes recorded.history_text, "[8]"
    assert_not_includes recorded.history_text, "[9]"

    session = memory_session([], recorded.state)
    fresh = passage("texto distinto", "s3://manual/nuevo")
    merged = Rag::CompanionCaseRecord.sources(session, "ep_a", [ fresh ])

    assert Rag::CompanionCaseRecord.gap?(merged[8])
    assert_equal 9, Rag::CompanionCaseRecord.number_of(merged[8])
    assert_equal 10, Rag::CompanionCaseRecord.number_of(merged[9])
    assert_equal "texto distinto", Rag::CompanionCaseRecord.text_of(merged[9])
    assert_equal "", Rag::CompanionCaseRecord.text_of(merged[8])
  end

  test "the character cap stops admission without evicting an older passage" do
    big = "x" * 7_000
    recorded = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: "ep_a",
      chunks: [ passage(big, "s3://1"), passage(big, "s3://2"), passage("corto", "s3://3") ],
      published_text: "Uno [1]. Dos [2]. Tres [3].",
      correlation_id: "t1", outcome: "published"
    )

    assert_equal true, recorded.ledger_full
    assert_equal [ digest(big) ], recorded.state["sources"].pluck("sha256")
    assert_equal [ 2, 3 ], recorded.state["retired"]
    assert_includes recorded.history_text, "[1]"
    assert_not_includes recorded.history_text, "[2]"
  end

  test "a reference-only duplicate does not replace the stored passage" do
    original = passage("texto citado", "s3://manual/a")
    recorded = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: "ep_a", chunks: [ original ],
      published_text: "Dato [1].", correlation_id: "t1", outcome: "published"
    )
    duplicate = passage("texto citado", "s3://manual/a").merge(identity_applicability: "reference_only")
    merged = Rag::CompanionCaseRecord.sources(memory_session([], recorded.state), "ep_a", [ duplicate ])

    assert_equal 1, merged.size
    assert_equal "ledger", merged[0][:case_origin]
    assert_equal "texto citado", Rag::CompanionCaseRecord.text_of(merged[0])
    assert_nil merged[0][:identity_applicability]
  end

  test "abstention keeps the technician text and the previous passages" do
    session = open_case
    episode_id = session.live_episode_id
    cited = passage("pasaje previo", "s3://manual/a")
    published = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: episode_id, chunks: [ cited ],
      published_text: "Orientación [1].", correlation_id: "t1", outcome: "published"
    )
    abstained = Rag::CompanionCaseRecord.record(
      state: published.state, episode_id: episode_id, chunks: [ passage("no publicar", "s3://manual/b") ],
      published_text: "No pude preparar una orientación [2].", correlation_id: "t2", outcome: "abstained"
    )
    notice = I18n.t("rag.companion_contract_invalid", locale: :es)
    write_history(session, [
      user_row(G2_PHRASE, "u1", 3.minutes.ago),
      user_row("pregunta siguiente", "u2", 1.minute.ago)
    ])
    persist_case(session, "Orientación [1].", published.state, "published", "t1", "Orientación [1].")
    persist_case(session, notice, abstained.state, "abstained", "t2", nil)

    stored = session.reload.case_evidence
    assert_equal published.state["sources"], stored["sources"]
    assert_equal published.state["revision"] + 1, stored["revision"]
    assert_equal "abstained", session.conversation_history.last["outcome"]
    retrieval = Rag::CompanionCaseRecord.retrieval_text(session, "pregunta siguiente", correlation_id: "u2")
    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: "pregunta siguiente", chunks: [], episode: session.active_episode, session: session, correlation_id: "u2"
    )
    history = prepared.messages.map { |message| message[:content][0][:text] }.join("\n")

    assert_includes retrieval.text, G2_PHRASE
    assert_includes history, G2_PHRASE
    assert_includes history, "pasaje previo"
    assert_not_includes history, notice
  end

  test "session 269 turn 3 keeps the technician sentence and the cited passage" do
    passage_text = g2_cited_passage
    digest_before = digest(passage_text)
    session = open_case
    write_history(session, G2_QUESTIONS.each_with_index.map { |text, index|
      user_row(text, "g2-#{index + 1}", (5 - index).minutes.ago)
    })
    recorded = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: session.live_episode_id, chunks: [ manual_chunk(passage_text) ],
      published_text: "La primera apertura es lenta [1].", correlation_id: "g2-1", outcome: "published"
    )
    persist_case(session, "La primera apertura es lenta [1].", recorded.state, "published", "g2-1", recorded.history_text)
    session.reload
    retrieval = Rag::CompanionCaseRecord.retrieval_text(session, G2_QUESTIONS[2], correlation_id: "g2-3")
    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: G2_QUESTIONS[2], chunks: [ passage("otro manual", "s3://otro") ],
      episode: session.active_episode, session: session, correlation_id: "g2-3"
    )
    source = prepared.chunks.find { |chunk| chunk[:case_origin] == "ledger" }
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_turn, true)
    texts = service.send(:companion_technician_texts, session, session.active_episode, G2_QUESTIONS[2])

    assert_includes retrieval.text, G2_PHRASE
    assert_includes prepared.messages.map { |message| message[:content][0][:text] }.join("\n"), G2_PHRASE
    assert_includes texts.join("\n"), G2_PHRASE
    assert_equal 1, Rag::CompanionCaseRecord.number_of(source)
    assert_equal digest_before, source[:chunk_sha256]
    assert_equal passage_text, Rag::CompanionCaseRecord.text_of(source)
    assert_equal digest_before, session.case_evidence["sources"][0]["sha256"]
  end

  test "a source cited on G1 turn 3 remains on turn 4 when retrieve does not return it" do
    body, uri, page = g1_turn3_source
    session = open_case
    write_history(session, G1_QUESTIONS.first(4).each_with_index.map { |text, index|
      user_row(text, "g1-#{index + 1}", (6 - index).minutes.ago)
    })
    chunk = manual_chunk(body, uri: uri, page: page)
    recorded = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: session.live_episode_id, chunks: [ chunk ],
      published_text: "La fotocélula no cierra el caso [1].", correlation_id: "g1-3", outcome: "published"
    )
    persist_case(session, "La fotocélula no cierra el caso [1].", recorded.state, "published", "g1-3", recorded.history_text)
    fresh = passage("pasaje que retrieve trae ahora", "s3://manual/fresco")
    merged = Rag::CompanionCaseRecord.sources(session.reload, session.live_episode_id, [ fresh ])
    kept = merged.find { |item| item[:case_origin] == "ledger" }

    assert_equal 1, Rag::CompanionCaseRecord.number_of(kept)
    assert_equal digest(body), kept[:chunk_sha256]
    assert_equal body, Rag::CompanionCaseRecord.text_of(kept)
    assert_equal 2, Rag::CompanionCaseRecord.number_of(merged.last)
    assert_equal "pasaje que retrieve trae ahora", Rag::CompanionCaseRecord.text_of(merged.last)
  end

  test "a new episode in the same session starts an empty file and drops the previous history" do
    session = open_case
    previous_id = session.live_episode_id
    write_history(session, [ user_row(G2_PHRASE, "old", 10.minutes.ago) ])
    recorded = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: previous_id, chunks: [ passage("viejo", "s3://viejo") ],
      published_text: "Antes [1].", correlation_id: "old-a", outcome: "published"
    )
    persist_case(session, "Antes [1].", recorded.state, "published", "old-a", recorded.history_text)
    fresh = Rag::ActiveEpisode.open(correlation_id: "new", now: 1.minute.ago)
    session.update!(active_episode: fresh.to_h)
    late = persist_case(
      session, "tarde [1]", { "episode_id" => previous_id, "revision" => 1, "sources" => [ { "n" => 1, "text" => "intruso" } ] },
      "published", "late", "tarde", expected_episode_id: previous_id, expected_revision: 1
    )

    assert_instance_of ConversationSession::CaseWriteConflict, late
    assert_equal "stale_episode", late.status
    assert_equal digest("viejo"), session.reload.case_evidence["sources"][0]["sha256"]
    assert_empty Rag::CompanionCaseRecord.sources(session, fresh.episode_id, [])
    retrieval = Rag::CompanionCaseRecord.retrieval_text(session, "caso nuevo", correlation_id: "nuevo")
    assert_equal "caso nuevo", retrieval.text
    assert_not_includes retrieval.text, G2_PHRASE
    opened = Rag::CompanionCaseRecord.record(
      state: session.case_evidence, episode_id: fresh.episode_id, chunks: [],
      published_text: "", correlation_id: "new", outcome: "abstained"
    )
    assert_equal [], opened.state["sources"]
    assert_equal fresh.episode_id, opened.state["episode_id"]
    assert_equal session.case_evidence["revision"] + 1, opened.state["revision"]
  end

  test "the same episode rejects a stale revision and leaves the file unchanged" do
    session = open_case
    episode_id = session.live_episode_id
    first = Rag::CompanionCaseRecord.record(
      state: {}, episode_id: episode_id, chunks: [ passage("primero", "s3://1") ],
      published_text: "Uno [1].", correlation_id: "t1", outcome: "published"
    )
    applied = persist_case(session, "Uno [1].", first.state, "published", "t1", first.history_text)
    stale = persist_case(
      session, "Dos [1].", { "episode_id" => episode_id, "revision" => 1, "sources" => [] },
      "published", "t2", "Dos", expected_revision: 0
    )

    assert_equal :assistant, applied.decision
    assert_equal "case_conflict", stale.status
    assert_equal 0, stale.expected_revision
    assert_equal 1, stale.current_revision
    assert_equal episode_id, stale.current_episode_id
    assert_equal [ digest("primero") ], session.reload.case_evidence["sources"].pluck("sha256")
    assert_equal 1, session.conversation_history.count { |message| message["role"] == "assistant" }
    assert_equal I18n.t("rag.case_write_conflict", locale: :es), Rag::CompanionCaseWrite.conflict_answer(:es)
    writer = Rails.root.join("app/services/rag/companion_case_write.rb").read
    assert_not_includes writer, "CompanionDirectAnswer"
    assert_not_includes writer, "converse"
  end

  test "case recording stays off when the session does not record episodes" do
    session = open_case(channel: "whatsapp")
    written = persist_case(session, "hola", {}, "published", "t1", "hola", expected_revision: 0)

    assert_equal "not_recording", written.status
    assert_empty session.reload.conversation_history
  end

  test "the direct request keeps the captured defaults until the run environment is set" do
    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: "¿qué reviso?", chunks: [ passage("sensor", "s3://a") ],
      episode: { "episode_id" => "ep_a" }, session: memory_session([])
    )
    params = prepared.params

    assert_equal "anthropic", Rag::CompanionDirectAnswer.provider
    assert_equal "claude-haiku-5-5", params[:model_id]
    assert_nil params.dig(:inference_config, :temperature)
    assert_equal Rag::CompanionDirectAnswer::GENERATION_MAX_TOKENS, params.dig(:inference_config, :max_tokens)
    assert_nil params[:tool_config]
    assert_nil params[:additional_model_request_fields]
    with_direct_env do
      payload = Rag::CompanionDirectAnswer.anthropic_payload(
        Rag::CompanionDirectAnswer.prepare(
          raw_question: "¿qué reviso?", chunks: [ passage("sensor", "s3://a") ],
          episode: { "episode_id" => "ep_a" }, session: memory_session([])
        ).params
      )
      outbound = Rag::CompanionDirectAnswer.outbound_request(
        Rag::CompanionDirectAnswer.prepare(
          raw_question: "¿qué reviso?", chunks: [ passage("sensor", "s3://a") ],
          episode: { "episode_id" => "ep_a" }, session: memory_session([])
        )
      )
      assert_equal "claude-haiku-5-5", payload[:model]
      assert_equal 16_000, payload[:max_tokens]
      assert_equal "high", payload.dig(:output_config, :effort)
      assert_equal({ type: "adaptive", display: "summarized" }, payload[:thinking])
      assert_nil payload[:temperature]
      assert_nil payload[:tools]
      assert_nil payload[:api_key]
      assert_equal "anthropic", outbound[:provider]
      assert_equal "claude-haiku-5-5-direct", Rag::CompanionDirectAnswer.tracking_model_id
    end
  end

  test "thinking text is not part of the composed answer" do
    response = Struct.new(:stop_reason, :usage, :content).new(
      "end_turn",
      Struct.new(:input_tokens, :output_tokens).new(3, 4),
      [
        Struct.new(:type, :thinking).new("thinking", "interno"),
        Struct.new(:type, :text).new("text", "visible")
      ]
    )
    composed = Rag::CompanionDirectAnswer.compose(Rag::CompanionDirectAnswer.wrap_anthropic(response))

    assert_equal "visible", composed.text
    assert_equal "end_turn", composed.stop_reason
    assert_nil composed.rejected
    assert_not_includes composed.text, "interno"
  end

  test "a truncated generation is not published" do
    response = Struct.new(:stop_reason, :usage, :content).new(
      "max_tokens",
      Struct.new(:input_tokens, :output_tokens).new(3, 4),
      [ Struct.new(:type, :text).new("text", "visible a medias") ]
    )
    composed = Rag::CompanionDirectAnswer.compose(Rag::CompanionDirectAnswer.wrap_anthropic(response))

    assert_equal "", composed.text
    assert_equal "max_tokens", composed.stop_reason
    assert_equal "truncated", composed.rejected
  end

  test "the system change is only the case numbering paragraph" do
    live = Rails.root.join("app/prompts/bedrock/companion_direct.txt").read
    text = File.read(Rag::CompanionDirectCaptureReplay::CAPTURED_PROMPT_PATH)
    product = Rails.root.join("app/services/rag/companion_case_record.rb").read

    assert_includes live, NEW_PARAGRAPH
    assert_not_includes live, OLD_PARAGRAPH
    assert_equal Rag::CompanionDirectCaptureReplay::HISTORICAL_PROMPT_SHA, Digest::SHA256.hexdigest(text.sub(NEW_PARAGRAPH, OLD_PARAGRAPH))
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, Digest::SHA256.hexdigest(text)
    assert_equal live, Rag::CompanionDirectAnswer::SYSTEM_PROMPT
    %w[VF5 Fermator fotocélula autoajuste YS-K01].each do |token|
      assert_not_includes product, token
    end
    controller = Rails.root.join("app/controllers/rag_controller.rb").read
    runner = Rails.root.join("script/field_companion/run_guion2.rb").read
    assert_equal 2, controller.scan("written = persist_companion_result!").size
    assert_includes controller, "Rag::CompanionCaseWrite.persist!"
    assert_includes runner, "Rag::CompanionCaseWrite.persist!"
    assert_not_includes controller, "record_assistant_turn!"
    assert_not_includes runner, "record_assistant_turn!"
  end

  class Race < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @flag = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    end

    teardown do
      ConversationSession.where("identifier LIKE ?", "web:case-record-race-%").delete_all
      @flag.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = @flag
    end

    test "two writes of the same episode cannot both publish" do
      session = ConversationSession.create!(
        account: accounts(:legacy), user: users(:one), channel: "web",
        identifier: "web:case-record-race-#{SecureRandom.hex(4)}", expires_at: 1.day.from_now,
        active_episode: Rag::ActiveEpisode.open(correlation_id: "race", now: Time.current).to_h,
        case_evidence: { "episode_id" => "pending", "revision" => 0, "ledger_full" => false, "retired" => [], "sources" => [] }
      )
      episode_id = session.live_episode_id
      session.update!(case_evidence: session.case_evidence.merge("episode_id" => episode_id))
      ready = Queue.new
      go = Queue.new
      results = Queue.new
      errors = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            row = ConversationSession.find(session.id)
            ready << index
            go.pop
            written = row.record_assistant_turn!(
              "respuesta #{index} [1]",
              user_id: users(:one).id, correlation_id: "race-#{index}",
              expected_episode_id: episode_id, outcome: "published", expected_case_revision: 0,
              case_evidence: evidence_for(episode_id, "texto #{index}"),
              prompt_reply: "respuesta #{index} [1]"
            )
            results << written
          end
        rescue StandardError => error
          errors << error
        end
      end
      Timeout.timeout(5) do
        2.times { ready.pop }
        2.times { go << true }
        threads.each(&:join)
      end

      flunk(errors.pop.full_message) unless errors.empty?
      written = 2.times.map { results.pop }
      assert_equal 1, written.count { |item| item.is_a?(ConversationSession::CaseWriteConflict) }
      assert_equal 1, written.count { |item| item.respond_to?(:decision) }
      stored = session.reload
      assert_equal 1, stored.case_evidence["revision"]
      assert_equal 1, stored.case_evidence["sources"].size
      assert_equal 1, stored.conversation_history.count { |message| message["role"] == "assistant" }
    end

    def evidence_for(episode_id, text)
      {
        "episode_id" => episode_id,
        "revision" => 1,
        "ledger_full" => false,
        "retired" => [],
        "sources" => [ {
          "n" => 1, "location_uri" => "s3://manual/race", "page" => 1,
          "sha256" => Digest::SHA256.hexdigest(text), "text" => text,
          "first_cid" => "race", "provenance" => "published_citation"
        } ]
      }
    end
  end

  private

  def memory_session(history, evidence = {})
    cutoff = Time.zone.parse("2000-01-01T00:00:00Z")
    Struct.new(:conversation_history, :case_evidence) do
      define_method(:episode_history_cutoff) { |_now = Time.current| cutoff }
    end.new(history, evidence)
  end

  def turn(text, correlation_id, minutes_ago)
    {
      "role" => "user",
      "content" => text,
      "ts" => minutes_ago.minutes.ago.iso8601,
      "correlation_id" => correlation_id
    }
  end

  def passage(text, uri)
    { content: text, location_uri: uri, metadata: { "page_number" => 4, "canonical_name" => "Manual" } }
  end

  def manual_chunk(text, uri: "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf", page: 8.0)
    {
      content: text,
      location_uri: uri,
      metadata: { "page_number" => page, "canonical_name" => "Módulo electrónico VF5+ Fermator", "original_filename" => "VF5.pdf" }
    }
  end

  def digest(text)
    Digest::SHA256.hexdigest(text.to_s)
  end

  def open_case(channel: "web")
    episode = Rag::ActiveEpisode.open(correlation_id: "setup", now: 30.minutes.ago)
    ConversationSession.create!(
      account: accounts(:legacy), user: users(:one), channel: channel,
      identifier: "web:case-record-#{SecureRandom.hex(4)}", expires_at: 1.day.from_now,
      active_episode: episode.to_h, conversation_history: []
    )
  end

  def write_history(session, rows)
    session.update!(conversation_history: rows)
  end

  def user_row(text, correlation_id, at)
    row = {
      "role" => "user",
      "content" => text.length > ConversationSession::MAX_MSG_LENGTH ? text.truncate(ConversationSession::MAX_MSG_LENGTH) : text,
      "ts" => at.iso8601,
      "correlation_id" => correlation_id
    }
    row["full_content"] = text if text.length > ConversationSession::MAX_MSG_LENGTH
    row
  end

  def persist_case(session, answer, evidence, outcome, correlation_id, history, expected_episode_id: nil, expected_revision: nil)
    session.record_assistant_turn!(
      answer,
      user_id: users(:one).id,
      correlation_id: correlation_id,
      expected_episode_id: expected_episode_id || session.live_episode_id,
      case_evidence: evidence,
      outcome: outcome,
      expected_case_revision: expected_revision.nil? ? Rag::CompanionCaseRecord.column_revision(session.case_evidence) : expected_revision,
      prompt_reply: history
    )
  end

  def g2_cited_passage
    path = [
      Rails.root.join("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/bodies/b0018.txt"),
      Pathname("/Users/lahirisan/smart_deal/tmp/field_companion/vf5_direct_guiones/guion2/turn-1/bodies/b0018.txt")
    ].find(&:file?)
    flunk "falta la captura de la sesión 269" unless path

    match = path.read.match(/\[1\] [^\n]*\n(.*?)(?=\n\[\d+\] |\z)/m)
    flunk "no se pudo leer la fuente 1 de la sesión 269" unless match

    match[1].strip
  end

  def g1_turn3_source
    root = Pathname("/Users/lahirisan/smart_deal/tmp/vf5_citation_gui_20261029/2026-10-29_2026-10-29_danebo-legacy/validation_captures/web-danebo-legacy/ebacf496-163e-4c53-ac81-607b62d7e818")
    flunk "falta la captura G1 T3" unless root.join("capture.json").file?

    capture = JSON.parse(root.join("capture.json").read)
    row = capture["events"].find { |event| event["kind"] == "retrieval_results" && event["role"] == "retrieved" }.fetch("rows").first
    [ root.join(row.dig("text", "path")).read, row["uri"], row["page"] ]
  end

  def with_direct_env
    keys = %w[COMPANION_DIRECT_PROVIDER COMPANION_DIRECT_MODEL_ID COMPANION_DIRECT_MAX_TOKENS COMPANION_DIRECT_EFFORT COMPANION_DIRECT_THINKING]
    previous = keys.index_with { |key| ENV[key] }
    ENV["COMPANION_DIRECT_PROVIDER"] = "anthropic"
    ENV["COMPANION_DIRECT_MODEL_ID"] = "claude-haiku-5-5"
    ENV["COMPANION_DIRECT_MAX_TOKENS"] = "16000"
    ENV["COMPANION_DIRECT_EFFORT"] = "high"
    ENV["COMPANION_DIRECT_THINKING"] = "adaptive"
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
