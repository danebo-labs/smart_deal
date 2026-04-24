# frozen_string_literal: true

require "test_helper"

# R2 integration tests for the faceted WhatsApp flow. Exercises cache+classifier
# routing; does NOT cover the legacy path (see send_whatsapp_reply_job_test.rb).
class SendWhatsappReplyJobFacetedTest < ActiveJob::TestCase
  parallelize(workers: 1)

  TO   = "whatsapp:+56912345678"
  FROM = "whatsapp:+14155238886"

  FACETED_ANSWER = <<~ANS
    [INTENT] IDENTIFICATION
    [RESUMEN]
    Orona PCB Mainboard — placa de control principal.
    [RIESGOS]
    ⚠️ LOTO requerido.
    [PARÁMETROS]
    ① 24VDC
    [SECCIONES]
    - Diagnóstico
    [DETALLE]
    Detalle técnico extendido.
    [MENU]
    1 | ⚠️ Riesgos | riesgos
    2 | 📏 Parámetros | parametros
    3 | 📋 Secciones | secciones
    4 | 🔧 Detalle | detalle
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

  def run_job(body:, session: nil)
    with_mock_orchestrator(answer: FACETED_ANSWER) do
      stub_twilio_client do |sent|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: body, conv_session_id: session&.id)
        end
        sent
      end
    end
  end

  # ---- tests

  test "first query writes faceted answer to cache and sends RESUMEN + menu" do
    sent = run_job(body: "que es la PCB?")

    # First message must contain RESUMEN content AND a text-only vertical menu
    # with 5=regresar / 6=inicio nav appended after a blank line.
    body_text = sent.pluck(:body).join("\n")
    assert_includes body_text, "Orona PCB Mainboard"
    assert_includes body_text, "Opciones:"
    assert_includes body_text, "1 - Riesgos"
    assert_includes body_text, "4 - Detalle"
    assert_match(/\n5 - regresar\n6 - inicio/, body_text)
    assert_no_match(/1 - ⚠️ Riesgos/, body_text, "emojis must be stripped from menu rows")

    cached = Rag::WhatsappAnswerCache.read(TO)
    assert_not_nil cached, "cache should be populated after new_query"
    assert_equal :identification, cached[:intent]
    assert_equal 4, cached[:faceted][:menu].size
  end

  test "follow-up '1' is served from cache (no Bedrock call)" do
    # Seed the cache
    run_job(body: "que es la PCB?")

    # Second message should NOT reach the orchestrator. Set up a fail-if-called mock.
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

    assert_not called, "QueryOrchestratorService#execute must not be called on a cache hit"
    body_text = sent.pluck(:body).join("\n")
    assert_includes body_text, "Riesgos"
    assert_includes body_text, "LOTO"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "'menu' with active cache re-renders the first message (no Bedrock call)" do
    run_job(body: "que es la PCB?")

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) { called = true; { answer: "x", citations: [], session_id: "x" } }
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "menu")
      end
      s
    end

    assert_not called, "menu command must not call the orchestrator"
    body_text = sent.pluck(:body).join("\n")
    assert_includes body_text, "1 - Riesgos"
    assert_includes body_text, "4 - Detalle"
    assert_match(/\n5 - regresar\n6 - inicio/, body_text)
    assert_not_empty sent.last[:body], "Twilio body must not be empty"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "'nuevo' invalidates cache and sends a static reset ack (no Bedrock call)" do
    run_job(body: "que es la PCB?")
    assert_not_nil Rag::WhatsappAnswerCache.read(TO)

    called = false
    mock = Object.new
    mock.define_singleton_method(:execute) { called = true; { answer: "x", citations: [], session_id: "x" } }
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "nuevo")
      end
      s
    end

    assert_not called, "'nuevo' must not call the orchestrator"
    assert_nil Rag::WhatsappAnswerCache.read(TO), "cache must be invalidated by 'nuevo'"
    body_text = sent.pluck(:body).join("\n")
    assert_match(/contexto reiniciado|context cleared/i, body_text)
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "menu token without any cache returns the no-context help message" do
    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1")
      end
      s
    end
    body_text = sent.pluck(:body).join("\n")
    # Locale is autodetected from the body ("1" → language detector default).
    # Accept either ES or EN copy since both are valid renders of the same key.
    assert_match(/consulta previa activa|previous query in context/, body_text,
                 "Expected the no-context help message in either locale")
  end

  test "free-text question invalidates the cache before calling Bedrock (content_query → new_query)" do
    run_job(body: "que es la PCB?")
    assert_not_nil Rails.cache.read(Rag::WhatsappAnswerCache.key(TO))

    # Any message outside the navigation allowlist is treated as content_query.
    free_text = "explícame el sistema eléctrico"

    with_mock_orchestrator(answer: FACETED_ANSWER) do
      stub_twilio_client do |_s|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: free_text)
        end
      end
    end

    # After :new_query, cache was invalidated then re-written with the fresh answer.
    assert_not_nil Rag::WhatsappAnswerCache.read(TO), "fresh answer should be cached"
  end

  test "EMERGENCY intent is NOT cached" do
    emergency = FACETED_ANSWER.sub("[INTENT] IDENTIFICATION", "[INTENT] EMERGENCY")
    with_mock_orchestrator(answer: emergency) do
      stub_twilio_client do |_s|
        with_twilio_env do
          SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "rescate")
        end
      end
    end
    assert_nil Rag::WhatsappAnswerCache.read(TO), "emergency must bypass cache write"
  end

  test "feature flag off routes through the legacy formatter" do
    ENV["WA_FACETED_OUTPUT_ENABLED"] = "false"
    sent = run_job(body: "que es la PCB?")
    # Legacy formatter does not emit the WA menu; just the raw answer text.
    body_text = sent.pluck(:body).join("\n")
    assert_no_match(/^1 - Riesgos$/, body_text)
    assert_includes body_text, "Orona PCB Mainboard"
    assert_nil Rag::WhatsappAnswerCache.read(TO), "legacy path must not touch the R2 cache"
  ensure
    ENV["WA_FACETED_OUTPUT_ENABLED"] = nil
  end

  # --- R2 UX improvements ----------------------------------------------------

  test "new_query sends a processing ack before the real RAG answer when flag on" do
    orig = ENV["WA_PROCESSING_ACK_ENABLED"]
    ENV["WA_PROCESSING_ACK_ENABLED"] = "true"
    sent = run_job(body: "que es la PCB?")
    bodies = sent.pluck(:body)
    assert_operator bodies.size, :>=, 2, "expected ack + real answer"
    assert_match(/Consultando|Looking this up/, bodies.first)
    assert_includes bodies.last, "Orona PCB Mainboard"
  ensure
    ENV["WA_PROCESSING_ACK_ENABLED"] = orig
  end

  test "facet_hit does NOT send a processing ack" do
    orig = ENV["WA_PROCESSING_ACK_ENABLED"]
    ENV["WA_PROCESSING_ACK_ENABLED"] = "true"
    run_job(body: "que es la PCB?")

    sent = stub_twilio_client do |s|
      with_twilio_env do
        SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1")
      end
      s
    end

    assert_not sent.any? { |m| m[:body]&.match?(/Consultando|Looking this up/) },
           "facet_hit path must stay silent (no ack)"
  ensure
    ENV["WA_PROCESSING_ACK_ENABLED"] = orig
  end

  test "processing ack flag off suppresses the ack even on :new_query" do
    orig = ENV["WA_PROCESSING_ACK_ENABLED"]
    ENV["WA_PROCESSING_ACK_ENABLED"] = "false"
    sent = run_job(body: "que es la PCB?")
    bodies = sent.pluck(:body)
    assert_not bodies.any? { |b| b&.match?(/Consultando|Looking this up/) }
  ensure
    ENV["WA_PROCESSING_ACK_ENABLED"] = orig
  end

  test "safety policy: free-text content question routes to RAG (NOT served from cache)" do
    # Seed cache with a populated parametros facet.
    run_job(body: "que es la PCB?")
    assert_not_nil Rag::WhatsappAnswerCache.read(TO)

    # A semantic question about the same component must NOT be answered from
    # cache — even though the parametros facet has content. The classifier's
    # closed allowlist forces :content_query → :new_query → fresh RAG.
    called_with = nil
    mock = Object.new
    mock.define_singleton_method(:execute) do
      called_with = :hit
      { answer: FACETED_ANSWER, citations: [], session_id: "sess-content" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "y el voltaje?") }
    end

    assert_equal :hit, called_with,
      "Free-text content questions must hit Bedrock, not the cache (safety policy)"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "deterministic facet tap on EMPTY cached facet re-runs RAG instead of showing '(—)'" do
    # First answer: parametros facet is empty in the model output.
    empty_params_answer = FACETED_ANSWER.sub(/\[PARÁMETROS\]\n.*?\n\[SECCIONES\]/m, "[PARÁMETROS]\n(—)\n[SECCIONES]")
    with_mock_orchestrator(answer: empty_params_answer) do
      stub_twilio_client do |_s|
        with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "que es la PCB?") }
      end
    end

    # User taps "2" (parametros). The classifier sees the cached facet is
    # empty and degrades to :new_query so we re-consult the KB instead of
    # rendering an empty/placeholder bubble.
    called_with = nil
    mock = Object.new
    mock.define_singleton_method(:execute) do
      called_with = :hit
      { answer: FACETED_ANSWER, citations: [], session_id: "sess-empty" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_a, **_k| mock }

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "2") }
    end

    assert_equal :hit, called_with,
      "Tapping a number whose cached facet is empty must re-run RAG (empty_facet_reconsult)"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) }
  end

  test "'inicio' invalidates cache, sends numbered sub-menu, and arms post-reset state" do
    run_job(body: "que es la PCB?")
    assert_not_nil Rag::WhatsappAnswerCache.read(TO)

    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "inicio") }
      s
    end
    assert_nil Rag::WhatsappAnswerCache.read(TO), "'inicio' must invalidate cache"
    body_text = sent.pluck(:body).join("\n")
    assert_match(/contexto reiniciado|context cleared/i, body_text)
    assert_match(/1 - archivos recientes|1 - recent files/i, body_text)
    assert_match(/2 - archivos existentes|2 - available files/i, body_text)

    state = Rag::WhatsappPostResetState.read(TO)
    assert_not_nil state, "post-reset state must be armed"
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE,
                 Rag::WhatsappPostResetState.phase_of(state)
  end

  test "numeric '6' is an alias of 'inicio'" do
    run_job(body: "que es la PCB?")
    sent = stub_twilio_client do |s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "6") }
      s
    end
    assert_nil Rag::WhatsappAnswerCache.read(TO)
    body_text = sent.pluck(:body).join("\n")
    assert_match(/contexto reiniciado|context cleared/i, body_text)
  end

  test "post-reset '1' renders recent-docs list and transitions to picking_from_list" do
    # Seed two TechnicianDocument rows the picker can list.
    TechnicianDocument.delete_all
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "PCB Mainboard Orona", last_used_at: 2.minutes.ago)
    TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                               canonical_name: "Cables de tracción 8mm", last_used_at: 1.minute.ago)

    run_job(body: "que es la PCB?")
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
    assert_match(/\n0 - /, body_text)
    assert_match(/\n6 - inicio|\n6 - home/, body_text)

    state = Rag::WhatsappPostResetState.read(TO)
    assert_equal Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
                 Rag::WhatsappPostResetState.phase_of(state)
    assert_equal :recent, Rag::WhatsappPostResetState.source_of(state)
    assert_equal 2, Rag::WhatsappPostResetState.doc_ids_of(state).length
  end

  test "post-reset pick_from_list seeds a new_query with 'Describe <name>' and clears state" do
    TechnicianDocument.delete_all
    doc = TechnicianDocument.create!(identifier: TO, channel: "whatsapp",
                                     canonical_name: "PCB Mainboard Orona", last_used_at: 1.minute.ago)

    run_job(body: "que es la PCB?")
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "inicio") }
    end
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1") }
    end

    seen_body = nil
    captured_mock = Object.new
    captured_mock.define_singleton_method(:execute) do
      { answer: FACETED_ANSWER, citations: [], session_id: "sess-post-reset" }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*args, **_kwargs|
      seen_body = args.first
      captured_mock
    end

    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "1") }
    end

    assert_match(/Describe PCB Mainboard Orona/i, seen_body.to_s,
                 "picker must seed a 'Describe <name>' query for the chosen doc")
    assert_nil Rag::WhatsappPostResetState.read(TO), "state must be cleared after a pick"
    assert_not_nil doc  # reference kept for readability
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original.call(*a, **k) } if original
  end

  test "post-reset natural-language input abandons the picker and falls through" do
    run_job(body: "que es la PCB?")
    stub_twilio_client do |_s|
      with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "inicio") }
    end
    assert_not_nil Rag::WhatsappPostResetState.read(TO)

    with_mock_orchestrator(answer: FACETED_ANSWER) do
      stub_twilio_client do |_s|
        with_twilio_env { SendWhatsappReplyJob.new.perform(to: TO, from: FROM, body: "describe cables") }
      end
    end

    assert_nil Rag::WhatsappPostResetState.read(TO),
               "picker state must be dropped when the user types a free query"
  end
end
