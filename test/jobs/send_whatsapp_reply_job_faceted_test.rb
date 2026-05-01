# frozen_string_literal: true

require "test_helper"

# R3 integration tests for the structured (dynamic-section) WhatsApp flow.
# Exercises cache + classifier routing and the stale-label regression bug
# that motivated the refactor.
class SendWhatsappReplyJobFacetedTest < ActiveJob::TestCase
  parallelize(workers: 1)

  TO   = "whatsapp:+56912345678"
  FROM = "whatsapp:+14155238886"

  STRUCTURED_ANSWER = <<~ANS
    [INTENT] INSTALLATION
    [DOCS]
    ["Manual Orono A1", "Transformadores.pdf"]
    [RESUMEN]
    Instalación Orono A1 combinando Manual Orono A1 y Transformadores.pdf.
    [RIESGOS]
    ⚠️ LOTO obligatorio antes de conectar el transformador.
    [SECCIONES]
    ## Consideraciones iniciales | Manual Orono A1
    Validar plomada y nivelación.

    ## Componentes | Manual Orono A1, Transformadores.pdf
    ① Contrapeso.
    ② Cabina.

    ## Paso a paso | Manual Orono A1, Transformadores.pdf
    1. Fijar guías.
    2. Conectar alimentación.

    ## Verificación | Manual Orono A1
    Pruebas de recorrido.
    [MENU]
    1 | ⚠️ Riesgos | __riesgos__
    2 | Consideraciones iniciales | __sec_1__
    3 | Componentes | __sec_2__
    4 | Paso a paso | __sec_3__
    5 | Verificación | __sec_4__
    6 | 🔄 Nueva consulta | __new_query__
  ANS

  SINGLE_DOC_ANSWER = <<~ANS
    [INTENT] IDENTIFICATION
    [DOCS]
    ["Esquema SOPREL"]
    [RESUMEN]
    Esquema SOPREL — plano eléctrico del tablero.
    [RIESGOS]
    — sin riesgos específicos documentados para esta consulta.
    [SECCIONES]
    ## Descripción | Esquema SOPREL
    Plano completo.

    ## Secciones disponibles | Esquema SOPREL
    - Diagrama general
    [MENU]
    1 | ⚠️ Riesgos | __riesgos__
    2 | Descripción | __sec_1__
    3 | Secciones disponibles | __sec_2__
    4 | 🔄 Nueva consulta | __new_query__
  ANS

  setup do
    @prev_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @prev_cache
    Rag::WhatsappAnswerCache.invalidate(TO)
    Rag::WhatsappPostResetState.clear(TO)
  end

  # ---- helpers

  def with_twilio_env
    with_env("TWILIO_ACCOUNT_SID" => "ACtest", "TWILIO_AUTH_TOKEN" => "tok") { yield }
  end

  def with_env(vars)
    prev = {}
    vars.each_key { |k| prev[k] = ENV[k.to_s] }
    vars.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    vars.each_key { |k| prev[k].nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = prev[k] }
  end

  def stub_twilio_client
    sent = []
    messages = Object.new
    messages.define_singleton_method(:create) { |**kw| sent << kw }
    client = Object.new
    client.define_singleton_method(:messages) { messages }

    original = Twilio::REST::Client.method(:new)
    Twilio::REST::Client.define_singleton_method(:new) { |*_| client }
    yield sent
  ensure
    Twilio::REST::Client.define_singleton_method(:new) { |*a| original.call(*a) }
  end

  def with_mock_orchestrator(answer:, citations: [])
    mock = Object.new
    mock.define_singleton_method(:execute) do
      { answer: answer, citations: citations, session_id: "sess-1" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  def run_job(body:, session: nil, answer: STRUCTURED_ANSWER)
    with_mock_orchestrator(answer: answer) do
      stub_twilio_client do |sent|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: body, conv_session_id: session&.id)
        end
        sent
      end
    end
  end

  # ---- tests

  test "first query writes structured answer to cache and sends RESUMEN + menu + multi-doc banner" do
    sent = run_job(body: "como instalo orono a1?")

    body_text = sent.pluck(:body).join("\n")
    assert_match(/📚 \*Fuentes consultadas:\* Manual Orono A1, Transformadores\.pdf/, body_text)
    assert_includes body_text, "Instalación Orono A1"
    # Menu: 1 risks slot + 4 sections + 2 file-listing slots → 7 rows. Legacy new-query row removed.
    assert_match(/^1 - Riesgos$/, body_text)
    assert_no_match(/Nueva consulta/, body_text)
    assert_match(/^6 - Archivos recientes consultados$/, body_text)
    assert_match(/^7 - Todos los archivos$/, body_text)
    assert_no_match(/^1 - ⚠️/, body_text)
    assert_no_match(/^\d - regresar$/, body_text)

    cached = Rag::WhatsappAnswerCache.read(TO)
    assert_not_nil cached
    assert_equal :installation, cached[:intent]
    assert_equal 4, cached[:structured][:sections].size
    assert_equal 7, cached[:structured][:menu].size
    assert_equal :list_recent, cached[:structured][:menu][-2][:kind]
    assert_equal :list_all,    cached[:structured][:menu][-1][:kind]
    assert_nil cached[:document_label], "document_label has been removed from the schema"
  end

  test "single-doc query omits the multi-doc banner" do
    sent = run_job(body: "que es el esquema soprel", answer: SINGLE_DOC_ANSWER)
    body_text = sent.pluck(:body).join("\n")
    assert_no_match(/Fuentes consultadas/, body_text)
    assert_includes body_text, "Esquema SOPREL"
  end

  # Trace context: technician arrives on site, takes the FIRST photo of the
  # day, asks "que marca de ascensor es?". Multi-doc retrieval is preserved
  # (safety > precision) but the rendered first message must visually flag
  # the just-uploaded image so the tech immediately recognizes it among the
  # consulted sources.
  test "fresh image upload prepends a 📸 banner above the first message" do
    ConversationSession.delete_all
    session = ConversationSession.create!(
      identifier: TO,
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )
    session.add_entity_with_aliases("Photograph of panoramic MRL elevator", [ "Panoramic MRL Elevator" ], {
      "source"     => "image_upload",
      "source_uri" => "s3://bucket/uploads/2026-04-24/wa_20260424_211657_0.jpeg",
      "added_at"   => Time.current.iso8601
    })

    sent = run_job(body: "que marca de ascensor es?", session: session)
    body_text = sent.pluck(:body).join("\n")

    assert_match(/📸 \*Recién subido:\* Photograph of panoramic MRL elevator/, body_text)
    fresh_idx = body_text.index("Recién subido")
    docs_idx  = body_text.index("Fuentes consultadas")
    assert fresh_idx && docs_idx && fresh_idx < docs_idx,
           "fresh-upload banner must precede the multi-doc banner"
  end

  test "fresh upload banner is suppressed once the entity has a first_answer_summary" do
    ConversationSession.delete_all
    session = ConversationSession.create!(
      identifier: TO,
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )
    session.add_entity_with_aliases("Already Queried Photo", [], {
      "source"               => "image_upload",
      "source_uri"           => "s3://bucket/wa_old.jpeg",
      "added_at"             => Time.current.iso8601,
      "first_answer_summary" => "Voltage rating 220V observed."
    })

    sent      = run_job(body: "y los componentes?", session: session)
    body_text = sent.pluck(:body).join("\n")

    assert_no_match(/Recién subido/, body_text)
  end

  # --- stale-label regression (the bug that motivated the refactor) --------

  test "regression: stale active_entities must NOT leak into the rendered answer" do
    # Simulate a session where a PRIOR query wrote "PCB Mainboard Orona" into
    # active_entities. The NEW query is about Orono installation and must
    # render ONLY the docs declared by Haiku's [DOCS] in THIS turn — never
    # the stale entity name from the previous topic.
    ConversationSession.delete_all
    session = ConversationSession.create!(
      identifier:      TO,
      channel:         "whatsapp",
      active_entities: { "PCB_Mainboard_Orona" => { "source" => "prior" } },
      expires_at:      30.minutes.from_now
    )

    sent = run_job(body: "como instalo el orono a1?", session: session)
    body_text = sent.pluck(:body).join("\n")

    # The new banner only lists docs that Haiku emitted in [DOCS] for THIS answer.
    assert_match(/Manual Orono A1/, body_text)
    assert_match(/Transformadores\.pdf/, body_text)

    # The stale entity name MUST NOT appear anywhere in the rendered answer
    # (neither as a "(fuente)" prefix nor inside the resumen/section headers).
    assert_no_match(/PCB Mainboard Orona/i, body_text, "stale entity must not surface in the rendered answer")
    assert_no_match(/PCB_Mainboard_Orona/i, body_text, "raw active_entities key must not surface either")
  end

  # --- cache-served follow-ups (0 Bedrock tokens) --------------------------

  test "digit '1' serves the pinned :riesgos section from cache (no Bedrock call)" do
    run_job(body: "como instalo orono a1?")

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) { called = true; { answer: "nope", citations: [], session_id: "x" } }
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1")
      end
      s
    end

    assert_not called, "pinned :riesgos tap must not re-run RAG"
    body_text = sent.pluck(:body).join("\n")
    assert_match(/\*Riesgos/, body_text)
    assert_includes body_text, "LOTO obligatorio"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "middle digit serves the matching dynamic section (header shows the section's sources)" do
    run_job(body: "como instalo orono a1?")

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) { called = true; { answer: "x", citations: [], session_id: "x" } }
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "3") }
      s
    end

    assert_not called
    body_text = sent.pluck(:body).join("\n")
    assert_match(/\*Componentes · Manual Orono A1, Transformadores\.pdf\*/, body_text)
    assert_includes body_text, "Contrapeso"
    # Footer re-lists the other menu items without the current one.
    assert_no_match(/^3 - Componentes$/, body_text)
    assert_match(/^1 - Riesgos$/, body_text)
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "strict mode: 'menu' word is a content query (invalidates + RAG)" do
    run_job(body: "como instalo orono a1?")
    assert_not_nil Rag::WhatsappAnswerCache.read(TO)

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) do
      called = true
      { answer: STRUCTURED_ANSWER, citations: [], session_id: "sess-menu" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "menu") }
    end

    assert called, "'menu' must hit Bedrock — redraw shortcut is gone"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  # --- reset flows ---------------------------------------------------------

  test "'nuevo' resets without opening the picker" do
    run_job(body: "como instalo orono a1?")

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "nuevo") }
      s
    end
    assert_nil Rag::WhatsappAnswerCache.read(TO)
    body_text = sent.pluck(:body).join("\n")
    assert_no_match(/archivos recientes|recent files/i, body_text)
  end

  # --- file-listing slots (menu options 6 & 7) -----------------------------

  test "menu slot list_recent renders technician documents and arms picker" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "PCB Mainboard Orona", last_used_at: 2.minutes.ago)
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "Cables de tracción 8mm", last_used_at: 1.minute.ago)

    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)
    run_job(body: "como instalo orono a1?", session: session)
    assert_not_nil Rag::WhatsappAnswerCache.read(TO)

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) { called = true; { answer: "x", citations: [], session_id: "x" } }
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
      s
    end

    assert_not called, "showing the doc list must not hit Bedrock"
    body_text = sent.pluck(:body).join("\n")
    assert_match(/Archivos recientes:|Recent files:/, body_text)
    assert_includes body_text, "1 - Cables de tracción 8mm"
    assert_includes body_text, "2 - PCB Mainboard Orona"

    state = Rag::WhatsappPostResetState.read(TO)
    assert_not_nil state, "list_recent must arm PHASE_PICKING_FROM_LIST so the next digit picks a doc"
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
                 Rag::WhatsappPostResetState.phase_of(state)
    assert_equal :recent, Rag::WhatsappPostResetState.source_of(state)
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "menu slot list_all renders KB catalog and arms picker" do
    KbDocument.delete_all
    KbDocument.create!(s3_key: "doc-a.pdf", display_name: "Manual A")
    KbDocument.create!(s3_key: "doc-b.pdf", display_name: "Manual B")

    run_job(body: "como instalo orono a1?")

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) { called = true; { answer: "x", citations: [], session_id: "x" } }
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7") }
      s
    end

    assert_not called
    body_text = sent.pluck(:body).join("\n")
    assert_match(/Archivos disponibles:|Available files:/, body_text)
    assert_includes body_text, "Manual A"
    assert_includes body_text, "Manual B"

    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal :all, Rag::WhatsappPostResetState.source_of(state)
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "picking a doc after list_recent runs RAG and writes the structured cache" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "PCB Mainboard Orona", last_used_at: 1.minute.ago)
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
    end

    # User picks doc 1 from the recent list → seed_query → RAG → cache.
    sent = run_job(body: "1", session: session, answer: STRUCTURED_ANSWER)
    body_text = sent.pluck(:body).join("\n")
    assert_includes body_text, "Instalación Orono A1"
    cached = Rag::WhatsappAnswerCache.read(TO)
    assert_not_nil cached, "doc pick must trigger run_rag_and_cache"
    assert_equal :installation, cached[:intent]
  end

  test "picking a KbDocument from list_all forces entity filter and seeds active_entities" do
    KbDocument.delete_all
    kb = KbDocument.create!(
      s3_key:       "orona_arca_basico.pdf",
      display_name: "Orona ARCA BASICO — Safety Circuit Electrical Schematic"
    )
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    # Step 1: prime the cache so __list_all__ slot is reachable.
    run_job(body: "como instalo orono a1?", session: session)
    # Step 2: tap menu slot 7 → render KB list, arm picker.
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7", conv_session_id: session.id)
      end
    end

    # Step 3: pick doc #1 from the all-files list. We capture the kwargs that
    # QueryOrchestratorService receives so we can prove force_entity_filter +
    # the picked URI flow all the way through.
    captured_kwargs = nil
    mock = Object.new
    mock.define_singleton_method(:execute) do
      { answer: STRUCTURED_ANSWER, citations: [], session_id: "sess-pick" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_a, **kw|
      captured_kwargs = kw
      mock
    end

    expected_uri = nil
    with_env("KNOWLEDGE_BASE_S3_BUCKET" => "test-kb-bucket") do
      expected_uri = kb.display_s3_uri("test-kb-bucket")
      stub_twilio_client do |_s|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1", conv_session_id: session.id)
        end
      end
    end

    assert_not_nil captured_kwargs, "RAG must be invoked for the picker selection"
    assert_equal true, captured_kwargs[:force_entity_filter],
                 "picker selection must force the entity filter so the seeded query " \
                 "doesn't trip query_names_different_document?"
    assert_includes Array(captured_kwargs[:entity_s3_uris]), expected_uri,
                    "the picked KbDocument's S3 URI must be passed to Bedrock"

    session.reload
    assert session.active_entities.key?(kb.display_name),
           "picked doc must be seeded into active_entities so SessionContextBuilder " \
           "emits a Session Focus block for Haiku"
    assert_equal expected_uri,
                 session.active_entities[kb.display_name]["source_uri"],
                 "seeded entity must carry the picked doc's source_uri for follow-up turns"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "picking a doc with no resolvable S3 URI falls back to unfiltered RAG without raising" do
    # TechnicianDocument with NO source_uri (e.g. backfill never ran). The
    # picker must not crash and must NOT force a filter — the unfiltered RAG
    # path is the safe degraded mode.
    TechnicianDocument.delete_all
    td = TechnicianDocument.create!(
      identifier:     TO,
      channel:        "whatsapp",
      canonical_name: "PCB Mainboard Orona",
      source_uri:     nil,
      last_used_at:   1.minute.ago
    )
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
    end

    captured_kwargs = nil
    mock = Object.new
    mock.define_singleton_method(:execute) do
      { answer: STRUCTURED_ANSWER, citations: [], session_id: "sess-no-uri" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_a, **kw|
      captured_kwargs = kw
      mock
    end

    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1", conv_session_id: session.id)
      end
    end

    assert_not_nil captured_kwargs
    assert_equal false, captured_kwargs[:force_entity_filter],
                 "no resolvable URI → must not force the filter (safe degraded mode)"
    session.reload
    assert session.active_entities.key?(td.canonical_name),
           "doc is still seeded into active_entities for context, even without a URI"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "'inicio' opens the post-reset picker (sub-menu 1=recientes / 2=existentes)" do
    run_job(body: "como instalo orono a1?")
    assert_not_nil Rag::WhatsappAnswerCache.read(TO)

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "inicio") }
      s
    end
    assert_nil Rag::WhatsappAnswerCache.read(TO)
    body_text = sent.pluck(:body).join("\n")
    assert_match(/contexto reiniciado|context cleared/i, body_text)
    assert_match(/1 - archivos recientes|1 - recent files/i, body_text)
    assert_match(/2 - archivos existentes|2 - available files/i, body_text)

    state = Rag::WhatsappPostResetState.read(TO)
    assert_not_nil state
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE,
                 Rag::WhatsappPostResetState.phase_of(state)
  end

  # --- edge cases -----------------------------------------------------------

  test "digit without cache returns the no-context help message" do
    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1") }
      s
    end
    body_text = sent.pluck(:body).join("\n")
    assert_match(/consulta previa activa|previous query in context/, body_text)
  end

  test "free-text question invalidates the cache and runs fresh RAG (content_query)" do
    run_job(body: "como instalo orono a1?")
    assert_not_nil Rails.cache.read(Rag::WhatsappAnswerCache.key(TO))

    with_mock_orchestrator(answer: STRUCTURED_ANSWER) do
      stub_twilio_client do |_s|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "explícame el sistema eléctrico")
        end
      end
    end

    assert_not_nil Rag::WhatsappAnswerCache.read(TO), "fresh answer should be cached"
  end

  test "tap on empty :riesgos slot re-runs RAG (empty_section_reconsult)" do
    # First answer has the "no risks" sentinel line.
    with_mock_orchestrator(answer: SINGLE_DOC_ANSWER) do
      stub_twilio_client do |_s|
        with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "que es soprel?") }
      end
    end

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) do
      called = true
      { answer: STRUCTURED_ANSWER, citations: [], session_id: "sess-rerun" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1") }
    end

    assert called, "tapping an empty pinned :riesgos must re-consult the KB"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "EMERGENCY intent is NOT cached" do
    emergency = STRUCTURED_ANSWER.sub("[INTENT] INSTALLATION", "[INTENT] EMERGENCY")
    with_mock_orchestrator(answer: emergency) do
      stub_twilio_client do |_s|
        with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "rescate") }
      end
    end
    assert_nil Rag::WhatsappAnswerCache.read(TO)
  end

  test "feature flag off routes through the legacy formatter (no structured menu)" do
    ENV["WA_FACETED_OUTPUT_ENABLED"] = "false"
    sent = run_job(body: "como instalo orono a1?")
    body_text = sent.pluck(:body).join("\n")
    assert_no_match(/^1 - Riesgos$/, body_text, "legacy formatter must not emit the structured menu")
    assert_includes body_text, "Instalación Orono A1"
    assert_nil Rag::WhatsappAnswerCache.read(TO), "legacy path must not touch the R3 cache"
  ensure
    ENV["WA_FACETED_OUTPUT_ENABLED"] = nil
  end

  # --- R3 UX ---------------------------------------------------------------

  test "new_query sends a processing ack before the fresh RAG answer when flag on" do
    orig = ENV["WA_PROCESSING_ACK_ENABLED"]
    ENV["WA_PROCESSING_ACK_ENABLED"] = "true"
    sent = run_job(body: "como instalo orono a1?")
    bodies = sent.pluck(:body)
    assert_operator bodies.size, :>=, 2
    assert_match(/Consultando|Looking this up/, bodies.first)
    assert_includes bodies.last, "Instalación Orono A1"
  ensure
    ENV["WA_PROCESSING_ACK_ENABLED"] = orig
  end

  test "section_hit stays silent (no processing ack)" do
    orig = ENV["WA_PROCESSING_ACK_ENABLED"]
    ENV["WA_PROCESSING_ACK_ENABLED"] = "true"
    run_job(body: "como instalo orono a1?")

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "3") }
      s
    end

    assert_not sent.any? { |m| m[:body]&.match?(/Consultando|Looking this up/) }
  ensure
    ENV["WA_PROCESSING_ACK_ENABLED"] = orig
  end

  test "processing ack flag off suppresses the ack even on :new_query" do
    orig = ENV["WA_PROCESSING_ACK_ENABLED"]
    ENV["WA_PROCESSING_ACK_ENABLED"] = "false"
    sent = run_job(body: "como instalo orono a1?")
    bodies = sent.pluck(:body)
    assert_not bodies.any? { |b| b&.match?(/Consultando|Looking this up/) }
  ensure
    ENV["WA_PROCESSING_ACK_ENABLED"] = orig
  end

  test "safety policy: free-text content question is NOT served from cache (always fresh RAG)" do
    run_job(body: "como instalo orono a1?")
    assert_not_nil Rag::WhatsappAnswerCache.read(TO)

    called_with = nil
    mock = Object.new
    mock.define_singleton_method(:execute) do
      called_with = :hit
      { answer: STRUCTURED_ANSWER, citations: [], session_id: "sess-content" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "y el voltaje?") }
    end

    assert_equal :hit, called_with
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  # --- back-to-cached-answer (Option A) ------------------------------------

  test "menu list_recent → '0' restores the cached faceted answer (no Bedrock, no reset_ack)" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "PCB Mainboard Orona", last_used_at: 2.minutes.ago)
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
    end

    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal Rag::WhatsappPostResetState::ORIGIN_FACETED_CACHED,
                 Rag::WhatsappPostResetState.origin_of(state),
                 "tapping __list_recent__ from a live answer must mark origin as :faceted_cached"

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) { called = true; { answer: "x", citations: [], session_id: "x" } }
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "0", conv_session_id: session.id)
      end
      s
    end

    assert_not called, "back from list must not hit Bedrock when the cached answer is alive"
    body_text = sent.pluck(:body).join("\n")
    assert_no_match(/contexto reiniciado|context cleared/i, body_text,
                 "back from list must NOT show the reset_ack message")
    assert_includes body_text, "Instalación Orono A1", "the cached resumen must be re-rendered"
    assert_match(/^1 - Riesgos$/, body_text, "the cached menu must be re-rendered")
    assert_match(/^6 - Archivos recientes consultados$/, body_text)

    assert_nil Rag::WhatsappPostResetState.read(TO),
               "post-reset state must be cleared after restoring the cached answer"
    assert_not_nil Rag::WhatsappAnswerCache.read(TO),
                   "back-to-cached-answer must NOT invalidate the cache"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "menu list_recent → 'atras' (back word) also restores the cached answer" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "Cables 8mm", last_used_at: 1.minute.ago)
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
    end

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "atras", conv_session_id: session.id)
      end
      s
    end

    body_text = sent.pluck(:body).join("\n")
    assert_no_match(/contexto reiniciado|context cleared/i, body_text)
    assert_includes body_text, "Instalación Orono A1"
    assert_nil Rag::WhatsappPostResetState.read(TO)
  end

  test "menu list_recent → 'inicio' performs a true reset (clears cache, shows reset_ack)" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "PCB Orona", last_used_at: 1.minute.ago)
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
    end

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "inicio", conv_session_id: session.id)
      end
      s
    end

    body_text = sent.pluck(:body).join("\n")
    assert_match(/contexto reiniciado|context cleared/i, body_text,
                 "'inicio' from the from_list phase must full-reset (still shows reset_ack)")
    assert_nil Rag::WhatsappAnswerCache.read(TO),
               "'inicio' must invalidate the faceted cache even from the from_list phase"
    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE,
                 Rag::WhatsappPostResetState.phase_of(state)
  end

  test "inicio → 1 → 0 : back returns to the source picker (origin :reset_picker, current behavior)" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "PCB Orona", last_used_at: 1.minute.ago)

    run_job(body: "como instalo orono a1?")
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "inicio") }
    end
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1") }
    end

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "0") }
      s
    end

    body_text = sent.pluck(:body).join("\n")
    assert_match(/contexto reiniciado|context cleared/i, body_text,
                 "back from list arrived via 'inicio' (origin :reset_picker) keeps the legacy behavior")
    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE,
                 Rag::WhatsappPostResetState.phase_of(state)
  end

  test "back-to-cached-answer is no-op when the faceted cache has expired" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "PCB Orona", last_used_at: 1.minute.ago)
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
    end
    Rag::WhatsappAnswerCache.invalidate(TO) # simulate TTL expiry

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "0", conv_session_id: session.id)
      end
      s
    end

    body_text = sent.pluck(:body).join("\n")
    assert_match(/contexto reiniciado|context cleared/i, body_text,
                 "with no cache to restore, fall back to the source picker")
  end

  # --- post-reset picker (inicio path) is preserved ------------------------

  # --- regression: digit collision with home shortcut ---------------------
  #
  # Bug (Apr 2026): user opened the recent-docs list (7 items) and tapped "5"
  # expecting item 5 ("Orona ARCA BASICO ..."). Instead the session reset
  # because "5" (and "6") were in POST_RESET_HOME_TOKENS as legacy fossils.
  # With paginated lists carrying up to PAGE_SIZE=20 rows, NO single/double
  # digit ≤ PAGE_SIZE can safely double as "home" — the picker renders the
  # typed-word shortcut and the home tokens are word-only.
  test "regression: digit '5' inside picking_from_list (5+ items) picks item 5, NOT a home reset" do
    TechnicianDocument.delete_all
    # `recent` orders by last_used_at DESC → Doc A (i=0, most recent) ends up
    # at position 1, Doc E at position 5. We need ≥5 items to exercise the
    # collision case the bug was about.
    %w[A B C D E F G].each_with_index do |name, i|
      TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                                 canonical_name: "Doc #{name}",
                                 last_used_at: i.minutes.ago)
    end
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    sent_list = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
      s
    end
    list_text = sent_list.pluck(:body).join("\n")
    assert_match(/^5 - Doc E$/, list_text, "list must render 5th item")
    assert_no_match(/^6 - inicio$/, list_text,
                 "post-fix render must not use a digit prefix for the home shortcut " \
                 "(would collide with the 6th list item)")

    captured = nil
    mock = Object.new
    mock.define_singleton_method(:execute) do
      captured = :rag_called
      { answer: STRUCTURED_ANSWER, citations: [], session_id: "sess-pick-5" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "5", conv_session_id: session.id)
      end
      s
    end

    body_text = sent.pluck(:body).join("\n")
    assert_no_match(/contexto reiniciado|context cleared/i, body_text,
                 "'5' must pick list item 5, NOT trigger a home reset")
    assert_equal :rag_called, captured, "picking item 5 must run RAG with the seeded query"
    assert_includes body_text, "Instalación Orono A1"
    assert_nil Rag::WhatsappPostResetState.read(TO),
               "post-reset state must be cleared after a successful pick"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "regression: digit '6' inside picking_from_list (6+ items) picks item 6, NOT a home reset" do
    TechnicianDocument.delete_all
    %w[A B C D E F G].each_with_index do |name, i|
      TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                                 canonical_name: "Doc #{name}",
                                 last_used_at: i.minutes.ago)
    end
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
    end

    captured = nil
    mock = Object.new
    mock.define_singleton_method(:execute) do
      captured = :rag_called
      { answer: STRUCTURED_ANSWER, citations: [], session_id: "sess-pick-6" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
      s
    end

    body_text = sent.pluck(:body).join("\n")
    assert_no_match(/contexto reiniciado|context cleared/i, body_text,
                 "'6' inside picking_from_list with 6+ items must pick item 6, not reset")
    assert_equal :rag_called, captured
    assert_nil Rag::WhatsappPostResetState.read(TO)
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "regression: typed-word 'inicio' still triggers full reset from picking_from_list" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "Doc A", last_used_at: 1.minute.ago)
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6", conv_session_id: session.id)
      end
    end

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "inicio", conv_session_id: session.id)
      end
      s
    end

    body_text = sent.pluck(:body).join("\n")
    assert_match(/contexto reiniciado|context cleared/i, body_text,
                 "word-only home tokens must still work — only the colliding digits were removed")
    assert_nil Rag::WhatsappAnswerCache.read(TO)
  end

  test "post-reset '1' renders recent-docs list and transitions to picking_from_list" do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "PCB Mainboard Orona", last_used_at: 2.minutes.ago)
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "Cables de tracción 8mm", last_used_at: 1.minute.ago)

    run_job(body: "como instalo orono a1?")
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "inicio") }
    end

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1") }
      s
    end

    body_text = sent.pluck(:body).join("\n")
    assert_match(/Archivos recientes:|Recent files:/, body_text)
    assert_includes body_text, "1 - Cables de tracción 8mm"
    assert_includes body_text, "2 - PCB Mainboard Orona"

    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
                 Rag::WhatsappPostResetState.phase_of(state)
    assert_equal :recent, Rag::WhatsappPostResetState.source_of(state)
  end

  # --- pagination on the :all (KB) list ------------------------------------
  #
  # Catalogs grow into the hundreds; sending all docs in a single Twilio
  # burst would chunk into many messages. The picker paginates by
  # PAGE_SIZE=20 with `+`/`-` to walk pages while keeping `0` and `inicio`
  # always visible at the foot of every page.

  def seed_kb_docs(count)
    KbDocument.delete_all
    count.times do |i|
      KbDocument.create!(s3_key: "k-#{format('%03d', i)}.pdf",
                         display_name: format("Doc %03d", i))
    end
  end

  test "menu list_all (paginated) renders page 1 with `+` line and arms picker with page=1" do
    seed_kb_docs(Rag::WhatsappDocumentPicker::PAGE_SIZE + 5)
    run_job(body: "como instalo orono a1?")

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7") }
      s
    end
    body_text = sent.pluck(:body).join("\n")

    assert_match(/Página 1\/2|Page 1\/2/, body_text)
    assert_match(/^\+ - (siguiente página|next page)$/, body_text)
    assert_no_match(/página anterior|previous page/, body_text)
    assert_match(/^1 - Doc 000$/, body_text)
    assert_match(/^20 - Doc 019$/, body_text, "per-page numbering 1..PAGE_SIZE")
    assert_no_match(/^21 - /, body_text, "items past PAGE_SIZE must NOT be on page 1")

    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal 1, Rag::WhatsappPostResetState.page_of(state)
    assert_equal Rag::WhatsappDocumentPicker::PAGE_SIZE,
                 Rag::WhatsappPostResetState.doc_ids_of(state).length
  end

  test "`+` advances to page 2, re-arms picker with page 2's doc_ids and shows `-` instead of `+`" do
    seed_kb_docs(Rag::WhatsappDocumentPicker::PAGE_SIZE + 5)
    run_job(body: "como instalo orono a1?")

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7") }
    end

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "+") }
      s
    end
    body_text = sent.pluck(:body).join("\n")

    assert_match(/Página 2\/2|Page 2\/2/, body_text)
    assert_match(/^- - (página anterior|previous page)$/, body_text)
    assert_no_match(/siguiente página|next page/, body_text, "no `+` on the last page")
    assert_match(/^1 - Doc 020$/, body_text, "page 2 numbering restarts at 1")
    assert_match(/^5 - Doc 024$/, body_text)

    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal 2, Rag::WhatsappPostResetState.page_of(state)
    assert_equal 5, Rag::WhatsappPostResetState.doc_ids_of(state).length,
                 "doc_ids must reflect ONLY the current page's slice"
  end

  test "`+` on the last page is a no-op re-render (clamps, never collapses the picker)" do
    seed_kb_docs(Rag::WhatsappDocumentPicker::PAGE_SIZE + 5)
    run_job(body: "como instalo orono a1?")

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7") }
    end
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "+") }
    end

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "+") }
      s
    end
    body_text = sent.pluck(:body).join("\n")

    assert_match(/Página 2\/2|Page 2\/2/, body_text, "clamped to last page; picker still alive")
    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
                 Rag::WhatsappPostResetState.phase_of(state)
    assert_equal 2, Rag::WhatsappPostResetState.page_of(state)
  end

  test "`-` from page 2 goes back to page 1 (re-arms doc_ids for page 1)" do
    seed_kb_docs(Rag::WhatsappDocumentPicker::PAGE_SIZE + 5)
    run_job(body: "como instalo orono a1?")

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7") }
    end
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "+") }
    end

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "-") }
      s
    end
    body_text = sent.pluck(:body).join("\n")

    assert_match(/Página 1\/2|Page 1\/2/, body_text)
    assert_match(/^1 - Doc 000$/, body_text)
    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal 1, Rag::WhatsappPostResetState.page_of(state)
    assert_equal Rag::WhatsappDocumentPicker::PAGE_SIZE,
                 Rag::WhatsappPostResetState.doc_ids_of(state).length
  end

  test "alias `siguiente` advances the page like `+` does" do
    seed_kb_docs(Rag::WhatsappDocumentPicker::PAGE_SIZE + 1)
    run_job(body: "como instalo orono a1?")
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7") }
    end

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "siguiente") }
      s
    end
    body_text = sent.pluck(:body).join("\n")
    assert_match(/Página 2\/2|Page 2\/2/, body_text)
  end

  test "alias `mas` (accent-stripped 'más') advances the page like `+` does" do
    seed_kb_docs(Rag::WhatsappDocumentPicker::PAGE_SIZE + 1)
    run_job(body: "como instalo orono a1?")
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7") }
    end

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "más") }
      s
    end
    body_text = sent.pluck(:body).join("\n")
    assert_match(/Página 2\/2|Page 2\/2/, body_text)
  end

  test "picking digit '1' on page 2 picks the FIRST doc of page 2 (not the catalog's 1st)" do
    seed_kb_docs(Rag::WhatsappDocumentPicker::PAGE_SIZE + 3)
    ConversationSession.delete_all
    session = ConversationSession.create!(identifier: TO, channel: "whatsapp",
                                          expires_at: 30.minutes.from_now)

    run_job(body: "como instalo orono a1?", session: session)
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "7", conv_session_id: session.id)
      end
    end
    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "+", conv_session_id: session.id)
      end
    end

    captured = nil
    mock = Object.new
    mock.define_singleton_method(:execute) do
      captured = :rag_called
      { answer: STRUCTURED_ANSWER, citations: [], session_id: "sess-pick-page2" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    stub_twilio_client do |_s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1", conv_session_id: session.id)
      end
    end

    assert_equal :rag_called, captured
    session.reload
    assert session.active_entities.key?("Doc 020"),
           "page 2's item #1 must seed Doc 020, NOT Doc 000 from page 1"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "`+` on a non-paginated `:recent` source is a harmless no-op re-render" do
    TechnicianDocument.delete_all
    3.times do |i|
      TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                                 canonical_name: "Recent #{i}",
                                 last_used_at: i.minutes.ago)
    end

    run_job(body: "como instalo orono a1?")
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6") }
    end

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "+") }
      s
    end
    body_text = sent.pluck(:body).join("\n")

    assert_no_match(/contexto reiniciado|context cleared/i, body_text,
                 "`+` must NOT trigger a reset on the recent list")
    assert_no_match(/Página \d+\/\d+|Page \d+\/\d+/, body_text,
                 ":recent renders without a page indicator")
    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
                 Rag::WhatsappPostResetState.phase_of(state)
  end
end
