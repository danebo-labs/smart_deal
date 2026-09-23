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
    session = build_session
    session.add_entity('manual.pdf', { 'source' => 'retrieve_result' })

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Session Focus'
    assert_includes context, '[document] manual.pdf'
  end

  test 'labels image_upload entities as [image]' do
    session = build_session
    session.add_entity('wa_photo.jpg', { 'source' => 'image_upload' })

    context = SessionContextBuilder.build(session)

    assert_includes context, '[image] wa_photo.jpg'
  end

  test 'prefers entity_type over pin provenance when labeling session focus' do
    session = build_session
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
    session = build_session
    session.add_entity('doc.pdf',    { 'source' => 'retrieve_result' })
    session.add_entity('photo.jpg',  { 'source' => 'image_upload' })

    context = SessionContextBuilder.build(session)

    assert_includes context, '[document] doc.pdf'
    assert_includes context, '[image] photo.jpg'
  end

  test 'caps aliases per entity in prompt context' do
    session = build_session
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
    session = build_session
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
    session = build_session
    session.add_entity('doc.pdf', { 'source' => 'retrieve_result' })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris extracts s3:// URIs from active entities' do
    session = build_session
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
    session = build_session
    session.add_entity('doc.pdf', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 'https://example.com/doc.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris rejects fabricated unknown-bucket URIs' do
    session = build_session
    session.add_entity('Junction Box', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://unknown-bucket/unknown-path/junction_box.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris rejects placeholder-bucket URIs' do
    session = build_session
    session.add_entity('Doc', {
      'source'     => 'doc_refs_rule8',
      'source_uri' => 's3://placeholder/doc.pdf'
    })

    assert_equal [], SessionContextBuilder.entity_s3_uris(session)
  end

  test 'entity_s3_uris keeps real URIs alongside fabricated ones' do
    session = build_session
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
    session = build_session
    session.add_entity('Doc A', { 'source' => 'doc_refs_rule8', 'source_uri' => 's3://bucket/same.pdf' })
    session.add_entity_with_aliases('Doc A alias', [], { 'source' => 'doc_refs_rule8', 'source_uri' => 's3://bucket/same.pdf' })

    uris = SessionContextBuilder.entity_s3_uris(session)

    assert_equal 1, uris.size
  end

  # ============================================
  # 3.3 — first_answer_summary in Session Focus
  # ============================================

  test 'includes summary note when entity has first_answer_summary' do
    session = build_session
    session.add_entity('Junction Box Car Top', {
      'source'               => 'doc_refs_rule8',
      'first_answer_summary' => 'Contains safety chain relay and door zone contacts.'
    })

    context = SessionContextBuilder.build(session)

    assert_includes context, 'Summary: Contains safety chain relay'
  end

  test 'omits summary note when entity has no first_answer_summary' do
    session = build_session
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

    session = build_session
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
    session = build_session
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
    session = ConversationSession.create!(
      identifier: "web:scb_cap_#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      active_entities: {
        "Elemont Montacargas Hidraulico Modelo MH" => {
          "source" => "user_pin",
          "entity_type" => "document",
          "canonical_name" => "Elemont Montacargas Hidraulico Modelo MH",
          "aliases" => aliases,
          "added_at" => "2026-09-16T10:51:51-03:00"
        }
      },
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
          ## Active Field Problem (technician-stated job state, not documentary evidence)
          Goal: Puerta 1
          Manufacturer: Elemont (technician)
          Fault code: technician confirmed no code is shown; do not ask for it again.
          These facts identify the job. Procedures, values, terminals and code meanings still come only from retrieved evidence. If the current question names different equipment, ignore this block.
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
        assert_includes block, "Identifiers typed by the technician: MH, CEA15"
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
    session.add_entity("DOC_ONLY_SENTINEL_MANUAL", {
      "source" => "user_pin",
      "entity_type" => "document",
      "source_uri" => "s3://manuals/sentinel.pdf",
      "first_answer_summary" => "DOCUMENTARY_TERMINAL_VALUE_99"
    })

    travel_to FIELD_PROBLEM_NOW do
      with_companion_flags do
        block = SessionContextBuilder.field_problem_block(session)
        context = SessionContextBuilder.build(session)
        footer_at = context.index(SessionContextBuilder::PROBLEM_FOOTER)
        rendered = context[0, footer_at + SessionContextBuilder::PROBLEM_FOOTER.length]

        assert_not_includes block, "DOC_ONLY_SENTINEL_MANUAL"
        assert_not_includes block, "DOCUMENTARY_TERMINAL_VALUE_99"
        assert_not_includes block, "s3://manuals/sentinel.pdf"
        assert_equal block, rendered
        assert_includes context, "DOC_ONLY_SENTINEL_MANUAL"
        assert_includes context, "DOCUMENTARY_TERMINAL_VALUE_99"
      end
    end
  end

  test "active field problem keeps its own budget when pins and history fill the context" do
    aliases = 5.times.map { |index| "Alias #{index} " + ("A" * 40) }
    entities = 6.times.to_h do |index|
      [
        "Pinned manual #{index} " + ("N" * 60),
        {
          "source" => "user_pin",
          "entity_type" => "document",
          "aliases" => aliases,
          "first_answer_summary" => "S" * 240,
          "added_at" => FIELD_PROBLEM_NOW.iso8601
        }
      ]
    end
    session = episode_session(
      goal: "G" * 300,
      facts: {
        "manufacturer" => known_fact("Fuji Yida"),
        "model" => confirmed_fact("unknown_confirmed")
      }
    )
    session.update!(
      active_entities: entities,
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

  private

  def episode_session(goal: "Resortes", facts: {}, identifiers: [], conflicts: [], updated_at: nil, channel: "web")
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
        "conflicts" => conflicts
      }
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
