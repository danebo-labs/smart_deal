# frozen_string_literal: true

require 'test_helper'

class SessionContextBuilderTest < ActiveSupport::TestCase
  setup do
    TechnicianDocument.delete_all
  end

  def build_session(channel: "web")
    ConversationSession.create!(
      identifier: "#{channel}:builder_test_#{SecureRandom.hex(4)}",
      channel:    channel,
      expires_at: 30.minutes.from_now
    )
  end

  def create_tech_doc(canonical_name:, source_uri:, channel: "whatsapp", identifier: "whatsapp:+34600000001")
    TechnicianDocument.create!(
      identifier:        identifier,
      channel:           channel,
      canonical_name:    canonical_name,
      source_uri:        source_uri,
      last_used_at:      Time.current,
      interaction_count: 1
    )
  end

  test 'returns empty string for nil session' do
    assert_equal '', SessionContextBuilder.build(nil)
  end

  test 'returns empty string when session has no entities or history' do
    session = build_session
    assert_equal '', SessionContextBuilder.build(session)
  end

  test 'includes Session Focus block when active_entities present' do
    session = build_session(channel: "whatsapp")
    session.add_entity('manual.pdf', { 'source' => 'retrieve_result' })

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Session Focus'
    assert_includes context, '[document] manual.pdf'
  end

  test 'labels image_upload entities as [image]' do
    session = build_session(channel: "whatsapp")
    session.add_entity('wa_photo.jpg', { 'source' => 'image_upload' })

    context = SessionContextBuilder.build(session)

    assert_includes context, '[image] wa_photo.jpg'
  end

  test 'prefers entity_type over pin provenance when labeling session focus' do
    session = build_session(channel: "whatsapp")
    session.add_entity('field_photo.jpg', {
      'source' => 'user_pin',
      'entity_type' => 'image_upload'
    })
    session.add_entity('manual.pdf', {
      'source' => 'user_pin',
      'entity_type' => 'document'
    })

    context = SessionContextBuilder.build(session)

    assert_includes context, '[image] field_photo.jpg'
    assert_includes context, '[document] manual.pdf'
  end

  test 'includes both retrieve_result and image_upload entities' do
    session = build_session(channel: "whatsapp")
    session.add_entity('doc.pdf',    { 'source' => 'retrieve_result' })
    session.add_entity('photo.jpg',  { 'source' => 'image_upload' })

    context = SessionContextBuilder.build(session)

    assert_includes context, '[document] doc.pdf'
    assert_includes context, '[image] photo.jpg'
  end

  test 'caps aliases per entity in prompt context' do
    session = build_session(channel: "whatsapp")
    session.add_entity('manual.pdf', {
      'source' => 'retrieve_result',
      'aliases' => %w[one two three four five six seven]
    })

    context = SessionContextBuilder.build(session)

    assert_includes context, 'one, two, three, four, five'
    assert_not_includes context, 'six'
    assert_not_includes context, 'seven'
  end

  test 'includes Recent Conversation block when history present' do
    session = build_session
    session.add_to_history('user', 'Hello')
    session.add_to_history('assistant', 'Hi there')

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Recent Conversation'
    assert_includes context, 'User: Hello'
    assert_includes context, 'Assistant: Hi there'
  end

  test 'only includes last 3 history turns' do
    session = build_session
    6.times { |i| session.add_to_history('user', "msg #{i}") }

    context = SessionContextBuilder.build(session)

    assert_not_includes context, 'msg 0'
    assert_includes context, 'msg 5'
  end

  test 'includes both blocks when session has entities and history' do
    session = build_session(channel: "whatsapp")
    session.add_entity('doc.pdf', { 'source' => 'retrieve_result' })
    session.add_to_history('user', 'What is this?')

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Session Focus'
    assert_includes context, 'Recent Conversation'
  end

  # ============================================
  # 3.1 — entity_s3_uris
  # ============================================

  test 'entity_s3_uris returns empty array for nil session' do
    assert_equal [], SessionContextBuilder.entity_s3_uris(nil)
  end

  test 'entity_s3_uris returns empty array when no entities have source_uri' do
    session = build_session(channel: "whatsapp")
    session.add_entity('doc.pdf', { 'source' => 'retrieve_result' })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris extracts s3:// URIs from active entities' do
    session = build_session(channel: "whatsapp")
    session.add_entity('Junction Box Car Top', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://my-bucket/junction_box.pdf'
    })
    session.add_entity('Motor Controller', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://my-bucket/motor_ctrl.pdf'
    })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_equal 2, uris.size
    assert_includes uris, 's3://my-bucket/junction_box.pdf'
    assert_includes uris, 's3://my-bucket/motor_ctrl.pdf'
  end

  test 'entity_s3_uris ignores non-s3 URIs' do
    session = build_session(channel: "whatsapp")
    session.add_entity('doc.pdf', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 'https://example.com/doc.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris rejects fabricated unknown-bucket URIs' do
    session = build_session(channel: "whatsapp")
    session.add_entity('Junction Box', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://unknown-bucket/unknown-path/junction_box.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris rejects placeholder-bucket URIs' do
    session = build_session(channel: "whatsapp")
    session.add_entity('Doc', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://placeholder/doc.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris keeps real URIs alongside fabricated ones' do
    session = build_session(channel: "whatsapp")
    session.add_entity('Real Doc', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://multimodal-source-destination/uploads/2026-03-27/wa_file.jpeg'
    })
    session.add_entity('Fake Doc', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://unknown-bucket/unknown-path/fake.pdf'
    })

    uris = SessionContextBuilder.entity_s3_uris(session)
    assert_equal 1, uris.size
    assert_includes uris, 's3://multimodal-source-destination/uploads/2026-03-27/wa_file.jpeg'
  end

  test 'entity_s3_uris deduplicates identical URIs' do
    session = build_session(channel: "whatsapp")
    session.add_entity('Doc A', { 'source' => 'doc_refs_rule8', 'source_uri' => 's3://bucket/same.pdf' })
    session.add_entity_with_aliases('Doc A alias', [], { 'source' => 'doc_refs_rule8', 'source_uri' => 's3://bucket/same.pdf' })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_equal 1, uris.size
  end

  # ============================================
  # 3.3 — first_answer_summary in Session Focus
  # ============================================

  test 'includes summary note when entity has first_answer_summary' do
    session = build_session(channel: "whatsapp")
    session.add_entity('Junction Box Car Top', {
      'source'               => 'doc_refs_rule8',
      'first_answer_summary' => 'Contains safety chain relay and door zone contacts.'
    })

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Summary: Contains safety chain relay'
  end

  test 'omits summary note when entity has no first_answer_summary' do
    session = build_session(channel: "whatsapp")
    session.add_entity('manual.pdf', { 'source' => 'retrieve_result' })

    context = SessionContextBuilder.build(session)

    assert_not_includes context, 'Summary:'
  end

  # ============================================
  # Session-scoped filtering (TechnicianDocument NO longer auto-merged)
  #
  # Rationale: the KB retrieval filter must mirror what the user (and Haiku,
  # via Session Focus) actually see in the current conversation. Historical
  # TechnicianDocument rows that are not active in the session would pollute
  # retrieval with unrelated docs. Queries that legitimately target a doc
  # outside the session are caught by BedrockRagService#query_names_different_document?
  # (explicit name match) and the retry-without-filter fallback.
  # ============================================

  test 'entity_s3_uris EXCLUDES TechnicianDocuments not present in session' do
    create_tech_doc(
      canonical_name: "Junction Box Manual",
      source_uri:     "s3://bucket/junction_box.pdf",
      channel:        "whatsapp"
    )

    session = build_session(channel: "whatsapp")

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_not_includes uris, "s3://bucket/junction_box.pdf"
    assert_equal [], uris
  end

  test 'entity_s3_uris returns ONLY session active_entities even when TechnicianDocuments exist' do
    create_tech_doc(
      canonical_name: "WA Doc",
      source_uri:     "s3://bucket/wa_doc.pdf",
      channel:        "whatsapp"
    )

    session = build_session(channel: "whatsapp")
    session.add_entity("Web Doc", {
      "source"     => "doc_refs_rule8",
      "source_uri" => "s3://bucket/web_doc.pdf"
    })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_not_includes uris, "s3://bucket/wa_doc.pdf"
    assert_includes uris, "s3://bucket/web_doc.pdf"
    assert_equal 1, uris.size
  end

  test 'entity_s3_uris returns session URI even if same URI exists as TechnicianDocument' do
    create_tech_doc(
      canonical_name: "Shared Doc",
      source_uri:     "s3://bucket/shared.pdf",
      channel:        "whatsapp"
    )

    session = build_session(channel: "whatsapp")
    session.add_entity("Shared Doc", {
      "source"     => "doc_refs_rule8",
      "source_uri" => "s3://bucket/shared.pdf"
    })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_equal [ "s3://bucket/shared.pdf" ], uris
  end

  # ============================================
  # 4 — Recency ordering in Session Focus
  # ============================================

  test 'Session Focus orders entities most-recent first by added_at' do
    session = build_session(channel: "whatsapp")
    older = (10.minutes.ago).iso8601
    newer = Time.current.iso8601
    session.update!(active_entities: {
      "Old Doc"   => { "source" => "retrieve_result", "added_at" => older },
      "Fresh Doc" => { "source" => "retrieve_result", "added_at" => newer }
    })

    context = SessionContextBuilder.build(session)
    fresh_idx = context.index("Fresh Doc")
    old_idx   = context.index("Old Doc")

    assert fresh_idx < old_idx, "most-recent entity must appear first in Session Focus"
  end

  # ============================================
  # 5 — Session Discipline directive
  # ============================================

  test 'Session Discipline block emitted when both pins and history present' do
    session = ConversationSession.find_or_create_for(identifier: "scb-1", channel: "web")
    kb = KbDocument.create!(s3_key: "uploads/2026/scb.pdf", display_name: "Scb", aliases: [])
    session.pin_kb_document!(kb)
    session.add_to_history("user", "hola")

    out = SessionContextBuilder.build(session)
    assert_match(/## Session Discipline/, out)
  end

  test 'Session Discipline omitted when no history' do
    session = ConversationSession.find_or_create_for(identifier: "scb-2", channel: "web")
    kb = KbDocument.create!(s3_key: "uploads/2026/no_hist.pdf", display_name: "NH", aliases: [])
    session.pin_kb_document!(kb)

    out = SessionContextBuilder.build(session)
    assert_no_match(/## Session Discipline/, out)
  end

  test 'Session Discipline omitted when no pins' do
    session = ConversationSession.find_or_create_for(identifier: "scb-3", channel: "web")
    session.add_to_history("user", "hola")

    out = SessionContextBuilder.build(session)
    assert_no_match(/## Session Discipline/, out)
  end

  test 'episode history includes three user questions and the last assistant truncated to 200' do
    now = Time.zone.parse("2026-09-16T10:51:54-03:00")
    long_assistant = "A" * 250
    session = ConversationSession.create!(
      identifier: "web:scb_episode_#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      conversation_history: [
        { "role" => "user", "content" => "Hola, tengo una falla eléctrica en un elevador hidráulico Elemont, con imanes y tarjeta Cea15", "ts" => "2026-09-16T10:49:41-03:00" },
        { "role" => "assistant", "content" => "primera respuesta", "ts" => "2026-09-16T10:49:47-03:00" },
        { "role" => "user", "content" => "La falla es en la puerta número 1 el equipo no magnetiza bien el imán de la puerta para que inicie movimiento.", "ts" => "2026-09-16T10:50:55-03:00" },
        { "role" => "assistant", "content" => long_assistant, "ts" => "2026-09-16T10:51:02-03:00" },
        { "role" => "user", "content" => "Elemont Montacargas Hidraulico Modelo MH", "ts" => "2026-09-16T10:51:54-03:00" }
      ]
    )

    travel_to now do
      context = SessionContextBuilder.build(session)
      truncated = long_assistant.truncate(200)
      assert_includes context, "Hola, tengo una falla eléctrica en un elevador hidráulico Elemont, con imanes y tarjeta Cea15"
      assert_includes context, "La falla es en la puerta número 1 el equipo no magnetiza bien el imán de la puerta para que inicie movimiento."
      assert_includes context, "Elemont Montacargas Hidraulico Modelo MH"
      assert_includes context, "Assistant: #{truncated}"
      assert_equal 200, truncated.length
      assert_not_includes context, "primera respuesta"
    end
  end

  test 'episode history plus a 15-alias pin stays within the context cap with intact Session Discipline' do
    now = Time.zone.parse("2026-09-16T10:51:54-03:00")
    aliases = 15.times.map { |i| "Alias #{i} del montacargas Elemont MH" }
    document = KbDocument.create!(
      s3_key: "uploads/scb-cap-#{SecureRandom.hex(4)}.pdf",
      display_name: "Elemont Montacargas Hidraulico Modelo MH",
      aliases: aliases
    )
    session = ConversationSession.create!(
      identifier: "web:scb_cap_#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      document_focus: [ {
        "kb_document_id" => document.id,
        "source_uri" => document.display_s3_uri(KbDocument::KB_BUCKET),
        "display_name" => document.display_name,
        "added_at" => "2026-09-16T10:51:51-03:00"
      } ],
      conversation_history: [
        { "role" => "user", "content" => "Hola, tengo una falla eléctrica en un elevador hidráulico Elemont, con imanes y tarjeta Cea15", "ts" => "2026-09-16T10:49:41-03:00" },
        { "role" => "assistant", "content" => "La documentación disponible del Elemont Montacargas Hidráulico Modelo MH no contiene información específica sobre la tarjeta CEA15.", "ts" => "2026-09-16T10:49:47-03:00" },
        { "role" => "user", "content" => "La falla es en la puerta número 1 el equipo no magnetiza bien el imán de la puerta para que inicie movimiento.", "ts" => "2026-09-16T10:50:55-03:00" },
        { "role" => "assistant", "content" => "La documentación del Montacargas Hidráulico Modelo MH identifica componentes de la puerta nivel 1 pero no el imán.", "ts" => "2026-09-16T10:51:02-03:00" },
        { "role" => "user", "content" => "Elemont Montacargas Hidraulico Modelo MH", "ts" => "2026-09-16T10:51:54-03:00" }
      ]
    )

    travel_to now do
      context = SessionContextBuilder.build(session)
      assert_operator context.length, :<=, SessionContextBuilder::MAX_CONTEXT_CHARS
      assert_includes context, "offer to re-pin it."
      assert_includes context, "## Session Discipline"
    end
  end

  test 'episode history is skipped when RAG_EPISODE_SCOPE_ENABLED is false' do
    original = ENV.fetch("RAG_EPISODE_SCOPE_ENABLED", nil)
    ENV["RAG_EPISODE_SCOPE_ENABLED"] = "false"
    now = Time.zone.parse("2026-09-16T10:51:54-03:00")
    session = ConversationSession.create!(
      identifier: "web:scb_flag_#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      conversation_history: [
        { "role" => "user", "content" => "primera pregunta del episodio", "ts" => "2026-09-16T10:49:41-03:00" },
        { "role" => "assistant", "content" => "respuesta uno", "ts" => "2026-09-16T10:49:47-03:00" },
        { "role" => "user", "content" => "segunda pregunta", "ts" => "2026-09-16T10:50:55-03:00" },
        { "role" => "assistant", "content" => "respuesta dos", "ts" => "2026-09-16T10:51:02-03:00" },
        { "role" => "user", "content" => "nombre del documento", "ts" => "2026-09-16T10:51:54-03:00" }
      ]
    )

    travel_to now do
      context = SessionContextBuilder.build(session)
      assert_not_includes context, "primera pregunta del episodio"
      assert_includes context, "segunda pregunta"
      assert_includes context, "respuesta dos"
      assert_includes context, "nombre del documento"
    end
  ensure
    original.nil? ? ENV.delete("RAG_EPISODE_SCOPE_ENABLED") : ENV["RAG_EPISODE_SCOPE_ENABLED"] = original
  end

  # Active Field Problem — Phase 2a. Both flags off keeps the context unchanged.
  FIELD_PROBLEM_NOW = Time.zone.parse("2026-09-23T15:00:00-03:00")

  test "active field problem is prepended for a current episode when both flags are on" do
    session = episode_session(
      goal: "Resortes",
      facts: {
        "manufacturer" => known_fact("Fuji Yida"),
        "model" => confirmed_fact("unknown_confirmed")
      }
    )

    travel_to FIELD_PROBLEM_NOW do
      session.add_to_history("user", "el modelo no lo sé")
      with_companion_flags do
        context = SessionContextBuilder.build(session)
        block, rest = context.split("\n\n", 2)

        assert context.start_with?(SessionContextBuilder::PROBLEM_HEADER)
        assert_equal SessionContextBuilder.field_problem_block(session), block
        assert_operator block.length, :<=, SessionContextBuilder::MAX_PROBLEM_CHARS
        assert_includes block, "Goal: Resortes"
        assert_includes block, "Manufacturer: Fuji Yida (technician)"
        assert_includes block, "Model: technician confirmed it is unknown; do not ask for it again."
        assert_includes block, SessionContextBuilder::PROBLEM_FOOTER
        assert_not_includes block, "unknown_confirmed"
        assert_includes rest, "Recent Conversation"
        assert context.index("Active Field Problem") < context.index("Recent Conversation")
      end
    end
  end

  test "active field problem uses the closed fact lines and omits empty ones" do
    session = episode_session(
      goal: "Puerta 1",
      facts: {
        "manufacturer" => known_fact("Elemont"),
        "fault_code" => confirmed_fact("absent_confirmed")
      }
    )

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        block = SessionContextBuilder.field_problem_block(session)

        assert_equal <<~BLOCK.strip, block
          ## Active Field Problem
          Goal: Puerta 1
          Manufacturer: Elemont (technician)
          Fault code: technician confirmed no code is shown; do not ask for it again.
          Not a manual. Procedures, values, terminals, and code meanings come from retrieved evidence. Ignore for other equipment.
        BLOCK
        assert_not_includes block, "absent_confirmed"
        assert_not_includes block, "\n\n"
      end
    end
  end

  test "identifiers use the technician line when the block has room" do
    session = episode_session(
      goal: "Puerta 1",
      facts: { "manufacturer" => known_fact("Elemont") },
      identifiers: [
        { "value" => "MH", "source" => "user", "correlation_id" => "q" },
        { "value" => "CEA15", "source" => "user", "correlation_id" => "q" }
      ]
    )

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        block = SessionContextBuilder.field_problem_block(session)
        assert_includes block, "Identifiers: MH, CEA15"
        assert_operator block.length, :<=, SessionContextBuilder::MAX_PROBLEM_CHARS
      end
    end
  end

  test "photo reads and conflicts stay literal and do not replace the technician" do
    photo = episode_session(
      goal: "Placa",
      facts: {
        "manufacturer" => known_fact("Fuji Yida"),
        "model" => known_fact("X1", source: "photo")
      }
    )
    conflict = episode_session(
      goal: "",
      facts: { "manufacturer" => known_fact("Fuji Yida") },
      conflicts: [
        { "fact" => "manufacturer", "user" => "Fuji Yida", "photo" => "KONE", "correlation_id" => "photo:1" }
      ]
    )

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        photo_block = SessionContextBuilder.field_problem_block(photo)
        conflict_block = SessionContextBuilder.field_problem_block(conflict)

        assert_includes photo_block, "Manufacturer: Fuji Yida (technician)"
        assert_includes photo_block, "Read from the photo, not stated by the technician: model X1"
        assert_not_includes photo_block, "Model: X1 (technician)"
        assert_includes conflict_block, "Conflict: technician said Fuji Yida; the photo shows KONE. Mention it; do not resolve it."
        assert_not_includes conflict_block, "Manufacturer: KONE"
      end
    end
  end

  test "a confirmed-unknown model stays in the block when the goal is long" do
    session = episode_session(
      goal: "Cómo se ajustan los resortes de la fijación de cables ?",
      facts: {
        "manufacturer" => known_fact("Fuji Yida"),
        "model" => confirmed_fact("unknown_confirmed")
      }
    )

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        block = SessionContextBuilder.field_problem_block(session)

        assert_operator block.length, :<=, SessionContextBuilder::MAX_PROBLEM_CHARS
        assert_includes block, "do not ask for it again"
        assert_includes block, "Manufacturer: Fuji Yida (technician)"
        assert_includes block, SessionContextBuilder::PROBLEM_FOOTER
      end
    end
  end

  test "journey A turn 14 projects the episode into both guidance prompts" do
    observations = [
      "la puerta 1 no termina de cerrar",
      "el imán no magnetiza",
      "El display muestra código 8",
      "no hay personas dentro",
      "llega al marco, pero vuelve a abrir",
      "comprobé visualmente la guía de la puerta",
      "no veo una obstrucción",
      "El LED 7 está apagado",
      "se oye un clic, pero no termina de cerrar",
      "sigue el clic y la puerta no termina de cerrar",
      "detenida cerca de planta 2"
    ].map { |text| { "text" => text, "correlation_id" => "q" } }
    session = episode_session(
      goal: "la puerta 1 no termina de cerrar el imán no magnetiza",
      facts: {
        "manufacturer" => known_fact("Elemont", source: "catalog"),
        "fault_code" => known_fact("18")
      },
      identifiers: [
        { "value" => "MH", "source" => "user", "correlation_id" => "q" },
        { "value" => "CEA15", "source" => "user", "correlation_id" => "q" }
      ],
      observations: observations,
      rejected: [ { "slot" => "fault_code", "value" => "8" } ]
    )

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        block = SessionContextBuilder.field_problem_block(session)
        known = Rag::CompanionGuidanceContext.build(
          question: "¿Y ahora?",
          identity: Rag::EquipmentIdentity.new(
            manufacturer: "Elemont",
            needles: [ "Elemont" ],
            facts: [ { "slot" => "manufacturer", "value" => "Elemont", "source" => "catalog", "correlation_id" => "q" } ]
          ),
          session_context: block,
          labels: [],
          locale: :es
        ).to_s
        unknown = Rag::CompanionGuidanceContext.build(
          question: "¿Y ahora?",
          identity: nil,
          session_context: block,
          labels: [],
          locale: :es,
          mode: :unknown
        ).to_s

        assert_operator block.length, :>, 400, block
        assert_operator block.length, :<=, 600, block
        assert_operator SessionContextBuilder::MAX_PROBLEM_CHARS, :<=, 600
        [
          "Elemont", "MH", "CEA15",
          "la puerta 1 no termina de cerrar", "el imán no magnetiza",
          "18", "fault code 8",
          "detenida cerca de planta 2",
          "guía de la puerta", "obstrucción",
          "LED 7", "clic", "no hay personas dentro"
        ].each do |phrase|
          assert_includes block, phrase, phrase
          assert_includes known, phrase, phrase
          assert_includes unknown, phrase, phrase
        end
        assert_not_includes block, "planta 1"
        assert_not_includes block, "código 8"
        assert_not_includes known, "planta 1"
        assert_not_includes unknown, "planta 1"
      end
    end
  end

  test "active field problem is absent unless both flags are on" do
    session = episode_session(facts: { "manufacturer" => known_fact("Fuji Yida") })

    travel_to FIELD_PROBLEM_NOW do
      session.add_to_history("user", "Fuji Yida")
      off = SessionContextBuilder.build(session)
      assert_not_includes off, "Active Field Problem"

      [ [ true, false ], [ false, true ], [ false, false ] ].each do |episode_flag, turn_flag|
        with_companion_flags(episode: episode_flag, turn: turn_flag) do
          assert_equal off, SessionContextBuilder.build(session)
        end
      end
    end
  end

  test "active field problem is absent when the episode is expired or invalid" do
    expired = episode_session(
      facts: { "manufacturer" => known_fact("Fuji Yida") },
      updated_at: FIELD_PROBLEM_NOW - 5.hours
    )
    invalid = episode_session(facts: { "manufacturer" => known_fact("Fuji Yida") })
    invalid.update!(active_episode: { "v" => 9 })

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        assert_not_includes SessionContextBuilder.build(expired), "Active Field Problem"
        assert_equal "", SessionContextBuilder.field_problem_block(invalid)
        assert_nothing_raised { SessionContextBuilder.build(invalid) }
      end
    end
  end

  test "active field problem does not copy pinned document text" do
    session = episode_session(
      goal: "Resortes",
      facts: { "manufacturer" => known_fact("Fuji Yida") }
    )
    document = KbDocument.create!(
      s3_key: "uploads/sentinel-#{SecureRandom.hex(4)}.pdf",
      display_name: "DOC_ONLY_SENTINEL_MANUAL",
      aliases: [ "DOCUMENTARY_TERMINAL_VALUE_99" ]
    )
    session.pin_kb_document!(document)

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        block = SessionContextBuilder.field_problem_block(session)
        context = SessionContextBuilder.build(session)
        footer_at = context.index(SessionContextBuilder::PROBLEM_FOOTER)
        rendered = context[0, footer_at + SessionContextBuilder::PROBLEM_FOOTER.length]

        assert_not_includes block, "DOC_ONLY_SENTINEL_MANUAL"
        assert_not_includes block, "DOCUMENTARY_TERMINAL_VALUE_99"
        assert_not_includes block, document.display_s3_uri(KbDocument::KB_BUCKET)
        assert_equal block, rendered
        assert_includes context, "DOC_ONLY_SENTINEL_MANUAL"
        assert_includes context, "DOCUMENTARY_TERMINAL_VALUE_99"
      end
    end
  end

  test "active field problem keeps its own budget when pins and history fill the context" do
    aliases = 5.times.map { |index| "Alias #{index} " + ("A" * 40) }
    session = episode_session(
      goal: "G" * 300,
      facts: {
        "manufacturer" => known_fact("Fuji Yida"),
        "model" => confirmed_fact("unknown_confirmed")
      }
    )
    documents = 6.times.map { |index|
      KbDocument.create!(
        s3_key: "uploads/budget-#{index}-#{SecureRandom.hex(3)}.pdf",
        display_name: "Pinned manual #{index} " + ("N" * 60),
        aliases: aliases
      )
    }
    session.update!(
      document_focus: documents.map { |document|
        {
          "kb_document_id" => document.id,
          "source_uri" => document.display_s3_uri(KbDocument::KB_BUCKET),
          "display_name" => document.display_name,
          "added_at" => FIELD_PROBLEM_NOW.iso8601
        }
      },
      conversation_history: 3.times.map { |index|
        { "role" => "user", "content" => "H" * 280, "ts" => (FIELD_PROBLEM_NOW - index.minutes).iso8601 }
      }
    )

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        block = SessionContextBuilder.field_problem_block(session)
        context = SessionContextBuilder.build(session)

        assert context.start_with?(block)
        assert_operator block.length, :<=, SessionContextBuilder::MAX_PROBLEM_CHARS
        assert_includes block, "do not ask for it again"
        assert_includes block, SessionContextBuilder::PROBLEM_FOOTER
        assert_equal SessionContextBuilder::MAX_CONTEXT_CHARS, context.length
        assert_not_includes block, "Pinned manual"
      end
    end
  end

  test "active field problem is not read outside a private web session" do
    web = episode_session(facts: { "manufacturer" => known_fact("Fuji Yida") })
    whatsapp = episode_session(
      channel: "whatsapp",
      facts: { "manufacturer" => known_fact("Fuji Yida") }
    )

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        assert_includes SessionContextBuilder.field_problem_block(web), "Fuji Yida"
        assert_equal "", SessionContextBuilder.field_problem_block(whatsapp)

        with_shared_session do
          assert_equal "", SessionContextBuilder.field_problem_block(web)
        end
      end
    end
  end

  test "an uncertain photo stays out of generation and a remembered photo fact stays in" do
    uncertain = photo_context("uncertain", "OTIS2000")
    session = episode_session(
      goal: "el freno no suelta",
      facts: { "model" => known_fact("NICE3000", source: "photo") }
    )
    session.update!(active_episode: session.active_episode.merge(
      "active_photo" => { "field_photo_id" => uncertain.field_photo_id, "sha256" => "ab", "correlation_id" => "photo" }
    ))

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        problem = SessionContextBuilder.field_problem_block(session)
        text = SessionContextBuilder.build(session, active_photo_context: uncertain)
        assert_includes problem, "Read from the photo, not stated by the technician: model NICE3000"
        assert_includes text, "model NICE3000"
        assert_not_includes text, "Photo Evidence"
        assert_not_includes text, "OTIS2000"
      end
    end
  end

  test "only a relevant active photo is photo evidence and it stays inside the context cap" do
    session = episode_session(goal: "Nice300 e51")
    relevant = photo_context("relevant", "NICE3000")
    uncertain = photo_context("uncertain", "OTIS2000")
    unrelated = photo_context("unrelated", "ZZ9MODEL")
    session.update!(active_episode: session.active_episode.merge(
      "active_photo" => { "field_photo_id" => relevant.field_photo_id, "sha256" => "ab", "correlation_id" => "photo" }
    ))

    travel_to FIELD_PROBLEM_NOW do
      relevant_text = SessionContextBuilder.build(session, active_photo_context: relevant)
      assert_includes relevant_text, "Photo Evidence for the active episode"
      assert_includes relevant_text, "NICE3000"
      assert_includes relevant_text, "Not stated by the technician."
      assert_not_includes relevant_text, "technician said NICE3000"

      uncertain_session = episode_session(goal: "Nice300 e51")
      uncertain_session.update!(active_episode: uncertain_session.active_episode.merge(
        "active_photo" => { "field_photo_id" => uncertain.field_photo_id, "sha256" => "ab", "correlation_id" => "photo" }
      ))
      assert_not_includes SessionContextBuilder.build(uncertain_session, active_photo_context: uncertain), "Photo Evidence"
      assert_not_includes SessionContextBuilder.build(session, active_photo_context: unrelated), "ZZ9MODEL"
      blank = photo_context(nil, "HIDDEN3000")
      blank_session = episode_session(goal: "Nice300 e51")
      blank_session.update!(active_episode: blank_session.active_episode.merge(
        "active_photo" => { "field_photo_id" => blank.field_photo_id, "sha256" => "ab", "correlation_id" => "photo" }
      ))
      blank_text = SessionContextBuilder.build(blank_session, active_photo_context: blank)
      assert_not_includes blank_text, "Photo Evidence"
      assert_not_includes blank_text, "HIDDEN3000"
      other = photo_context("relevant", "OTHER999")
      assert_not_includes SessionContextBuilder.build(session, active_photo_context: other), "OTHER999"

      long = Object.new
      long.define_singleton_method(:generation_block) { "Photo Evidence for the active episode\n#{"x" * 2500}" }
      long.define_singleton_method(:matches?) { |photo_id| photo_id.to_i == relevant.field_photo_id.to_i }
      capped = SessionContextBuilder.build(session, active_photo_context: long)
      assert_operator capped.length, :<=, SessionContextBuilder::MAX_CONTEXT_CHARS
      assert_includes capped, "Photo Evidence for the active episode"
    end
  end

  test "an invalid active photo does not enter generation context" do
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: accounts(:legacy), sha256: sha,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 8,
      visual_observation: { "manufacturer" => "REJECTED-MFR", "model" => "SECRETMODEL" }
    )
    session = episode_session
    session.update!(active_episode: session.active_episode.merge(
      "active_photo" => { "field_photo_id" => photo.id, "sha256" => sha, "correlation_id" => "photo" }
    ))
    session.add_to_history("user", "qué reviso ahora", correlation_id: "query:1")

    travel_to FIELD_PROBLEM_NOW do
      context = Rag::ActivePhotoContext.resolve(
        episode: Rag::ActiveEpisode.parse(session.active_episode, now: FIELD_PROBLEM_NOW),
        viewer_account: accounts(:legacy)
      )
      text = SessionContextBuilder.build(session, active_photo_context: context)

      assert_equal "invalid", context.status
      assert_not_includes text, "REJECTED-MFR"
      assert_not_includes text, "SECRETMODEL"
      assert_not_includes text, "[FOTO]"
    end
  end

  private

  test "a catalog controller is recognized identity and not a technician statement" do
    session = episode_session(
      goal: "Q2",
      facts: {
        "controller" => known_fact("NICE3000", source: "catalog")
      }
    )

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        block = SessionContextBuilder.field_problem_block(session)
        assert_includes block, "Controller: NICE3000 (catalog)"
        assert_not_includes block, "Controller: NICE3000 (technician)"
      end
    end
  end

  def photo_context(relevance, model)
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: accounts(:legacy), sha256: sha,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 8
    )
    FieldPhotoObservation.persist!(photo, {
      "schema_version" => 1, "prompt_fingerprint" => "ef" * 32, "model_id" => "claude-sonnet-5-5",
      "canonical_component" => "controlador", "manufacturer" => "NICE", "model" => model,
      "subsystem" => "CONTROLLER_LOGIC", "condition" => "GOOD", "visible_text" => [ "E51" ],
      "target_visible" => true, "relevance_to_goal" => relevance
    })
    episode = Rag::ActiveEpisode.open(correlation_id: "photo", now: FIELD_PROBLEM_NOW)
    episode.active_photo = { "field_photo_id" => photo.id }
    Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: accounts(:legacy))
  end

  def episode_session(goal: "Resortes", facts: {}, identifiers: [], conflicts: [], observations: [], rejected: [], updated_at: nil, channel: "web")
    ConversationSession.create!(
      identifier: "#{channel}:field_problem_#{SecureRandom.hex(4)}",
      channel: channel,
      expires_at: 30.days.from_now,
      active_episode: {
        "v" => 1,
        "episode_id" => "ep_field_problem",
        "status" => "active",
        "opened_at" => (FIELD_PROBLEM_NOW - 1.hour).iso8601,
        "updated_at" => (updated_at || (FIELD_PROBLEM_NOW - 5.minutes)).iso8601,
        "goal" => { "text" => goal, "correlation_id" => "query:1", "truncated" => false },
        "facts" => facts,
        "identifiers" => identifiers,
        "conflicts" => conflicts,
        "observations" => observations.presence,
        "rejected" => rejected.presence
      }.compact
    )
  end

  def known_fact(value, source: "user")
    {
      "status" => "known",
      "value" => value,
      "source" => source,
      "correlation_id" => "query:1",
      "at" => FIELD_PROBLEM_NOW.iso8601
    }
  end

  def confirmed_fact(status)
    {
      "status" => status,
      "source" => "user",
      "correlation_id" => "query:1",
      "at" => FIELD_PROBLEM_NOW.iso8601
    }
  end

  def with_companion_flags(episode: true, turn: true)
    keys = %w[FIELD_COMPANION_EPISODE_ENABLED FIELD_COMPANION_TURN_ENABLED]
    previous = keys.index_with { |key| ENV[key] }
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = episode ? "true" : "false"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = turn ? "true" : "false"
    yield
  ensure
    previous.each do |key, old|
      old.nil? ? ENV.delete(key) : ENV[key] = old
    end
  end

  def with_shared_session
    original = SharedSession::ENABLED
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, true)
    yield
  ensure
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, original)
  end
end
