# frozen_string_literal: true

require 'test_helper'

class EntityExtractorServiceTest < ActiveSupport::TestCase
  def build_session
    ConversationSession.create!(
      identifier: "entity-extract-#{SecureRandom.hex(4)}",
      channel:    "whatsapp",
      expires_at: 30.minutes.from_now
    )
  end

  test 'registers entities from doc_refs primary path' do
    session = build_session
    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri" => "s3://multimodal-source-destination/uploads/2026-03-24/circuito_.jpeg",
      "canonical_name" => "circuito_",
      "aliases" => [ "enclosure view A", "car top junction box wiring", "safety chain terminal enclosure" ],
      "doc_type" => "diagram"
    } ]
    service.extract_and_update([], user_message: "qué es", doc_refs: doc_refs)
    session.reload
    entity = session.active_entities["circuito_"]
    assert_not_nil entity
    assert_equal "haiku_doc_refs", entity["extraction_method"]
    assert_includes entity["aliases"], "enclosure view A"
    assert_includes entity["aliases"], "circuito_.jpeg"
    assert_equal "circuito_.jpeg", entity["wa_filename"]
  end

  test 'registers from doc_refs with multiple documents' do
    session = build_session
    service = EntityExtractorService.new(session)
    doc_refs = [
      {
        "source_uri" => "s3://bucket/a/first.pdf",
        "canonical_name" => "First Doc",
        "aliases" => [ "alias one" ],
        "doc_type" => "pdf"
      },
      {
        "source_uri" => "s3://bucket/b/second.jpeg",
        "canonical_name" => "Second Doc",
        "aliases" => [],
        "doc_type" => "image"
      }
    ]
    service.extract_and_update([], user_message: "compare", doc_refs: doc_refs)
    session.reload
    assert_equal 2, session.entity_count
    assert session.active_entities.key?("First Doc")
    assert session.active_entities.key?("Second Doc")
    assert_equal "first.pdf", session.active_entities["First Doc"]["wa_filename"]
    assert_equal "second.jpeg", session.active_entities["Second Doc"]["wa_filename"]
  end

  # ─── primary_canonical_names / persist gating ──────────────────────────────
  # When the KB returns multiple chunks, only the doc whose name/aliases best
  # match the user query is persisted to TechnicianDocument. Secondary hits go
  # to session context only (not the global document store).

  test 'only persists the primary doc when two doc_refs are returned for one query' do
    TechnicianDocument.delete_all
    session = build_session
    service = EntityExtractorService.new(session)

    # Simulates "que es electromagnetic disc brake?" returning two KB hits:
    # the disc brake photo (primary) and a drum brake 3D diagram (secondary).
    doc_refs = [
      {
        "source_uri"     => "s3://bucket/uploads/wa_disc_brake.jpeg",
        "canonical_name" => "Elevator brake assembly unit",
        "aliases"        => [ "Electromagnetic disc brake", "BIMORE brake component",
                              "Traction machine brake module" ],
        "doc_type"       => "datasheet"
      },
      {
        "source_uri"     => "s3://bucket/uploads/wa_drum_brake.jpeg",
        "canonical_name" => "Elevator Drum Brake Assembly",
        "aliases"        => [ "Solenoid Operated Drum Brake", "Spring-Applied Solenoid-Released Brake",
                              "Electromechanical Brake Components" ],
        "doc_type"       => "diagram"
      }
    ]

    service.extract_and_update(
      [],
      user_message: "que es Electromagnetic disc brake",
      doc_refs: doc_refs
    )
    session.reload

    # Both entities are added to session (for RAG context)
    assert_equal 2, session.entity_count

    # Only the primary doc (disc brake) is persisted to TechnicianDocument
    assert_equal 1, TechnicianDocument.count, "Secondary KB result must NOT be persisted"
    assert TechnicianDocument.find_by("LOWER(canonical_name) = LOWER(?)", "elevator brake assembly unit"),
           "Primary doc must be persisted"
  end

  test 'persists BOTH docs when query explicitly references two distinct components' do
    TechnicianDocument.delete_all
    session = build_session
    service = EntityExtractorService.new(session)

    doc_refs = [
      {
        "source_uri"     => "s3://bucket/uploads/wa_brake.jpeg",
        "canonical_name" => "Electromagnetic Disc Brake",
        "aliases"        => [ "disc brake", "BIMORE brake" ],
        "doc_type"       => "datasheet"
      },
      {
        "source_uri"     => "s3://bucket/uploads/wa_governor.jpeg",
        "canonical_name" => "Centrifugal Overspeed Governor",
        "aliases"        => [ "governor device", "overspeed governor" ],
        "doc_type"       => "diagram"
      }
    ]

    service.extract_and_update(
      [],
      user_message: "como interactuan el electromagnetic brake y el overspeed governor",
      doc_refs: doc_refs
    )
    session.reload

    assert_equal 2, session.entity_count
    assert_equal 2, TechnicianDocument.count, "Both explicitly referenced docs must be persisted"
  end

  # ─── source_uri-based collapse ──────────────────────────────────────────────
  # Haiku sometimes emits MULTIPLE canonical_names for a single physical file.
  # Bedrock retrieval metadata carries the authoritative s3_uri — we use it to
  # (1) backfill doc_refs whose source_uri is blank, and (2) collapse duplicates
  # into a single session entity and a single TechnicianDocument row.

  test 'collapses multiple doc_refs pointing to the same physical file (Bedrock metadata URI)' do
    TechnicianDocument.delete_all
    session = build_session
    service = EntityExtractorService.new(session)

    s3_uri = "s3://multimodal-source-destination/uploads/2026-04-15/wa_20260415_171242_0.jpeg"

    # Haiku invents two canonical_names for the same physical brake image.
    doc_refs = [
      {
        "source_uri"     => "",
        "canonical_name" => "Elevator brake assembly unit",
        "aliases"        => [ "Electromagnetic disc brake", "BIMORE brake component" ],
        "doc_type"       => "datasheet"
      },
      {
        "source_uri"     => "",
        "canonical_name" => "Elevator Drum Brake Assembly Annotated 3D Component Diagram",
        "aliases"        => [ "Drum Brake Assembly Diagram", "Brake Arm Spring Housing Detail" ],
        "doc_type"       => "diagram"
      }
    ]

    # Bedrock returns a SINGLE chunk (one physical file) — its metadata carries
    # the real s3_uri (NOT extracted from chunk text, which may be
    # PIPELINE_INJECTED).
    all_retrieved = [
      {
        content:  "# S0 DOCUMENT IDENTIFICATION ... | File: PIPELINE_INJECTED | ...",
        location: { uri: s3_uri, bucket: "multimodal-source-destination", key: "uploads/2026-04-15/wa_20260415_171242_0.jpeg", type: "s3" },
        metadata: { "x-amz-bedrock-kb-source-uri" => s3_uri }
      }
    ]

    service.extract_and_update(
      [],
      user_message:  "que es Electromagnetic disc brake ?",
      all_retrieved: all_retrieved,
      doc_refs:      doc_refs
    )
    session.reload

    assert_equal 1, session.entity_count, "Two doc_refs for same s3_uri must collapse to ONE session entity"
    assert_equal 1, TechnicianDocument.count, "Two doc_refs for same s3_uri must produce ONE TechnicianDocument"

    entity = session.active_entities.values.first
    assert_equal s3_uri, entity["source_uri"]
  end

  test 'second query for same document (different aliases) does NOT insert a new TechnicianDocument' do
    TechnicianDocument.delete_all
    session = build_session
    s3_uri  = "s3://bucket/uploads/2026-04-15/wa_20260415_171242_0.jpeg"

    all_retrieved = [
      {
        content:  "brake chunk",
        location: { uri: s3_uri, bucket: "bucket", key: "uploads/2026-04-15/wa_20260415_171242_0.jpeg", type: "s3" },
        metadata: { "x-amz-bedrock-kb-source-uri" => s3_uri }
      }
    ]

    # Query 1 — Haiku uses canonical "Elevator brake assembly unit".
    EntityExtractorService.new(session).extract_and_update(
      [],
      user_message:  "que es Electromagnetic disc brake ?",
      all_retrieved: all_retrieved,
      doc_refs:      [ { "source_uri" => "", "canonical_name" => "Elevator brake assembly unit",
                         "aliases" => [ "Electromagnetic disc brake" ], "doc_type" => "datasheet" } ]
    )

    assert_equal 1, TechnicianDocument.count

    # Query 2 — same physical doc, but Haiku uses a DIFFERENT canonical_name.
    EntityExtractorService.new(session.reload).extract_and_update(
      [],
      user_message:  "que es BIMORE brake component ?",
      all_retrieved: all_retrieved,
      doc_refs:      [ { "source_uri" => "", "canonical_name" => "Elevator Drum Brake Assembly Diagram",
                         "aliases" => [ "BIMORE brake component", "disc brake" ], "doc_type" => "diagram" } ]
    )

    session.reload
    assert_equal 1, session.entity_count, "Second query must merge into the existing session entity"
    assert_equal 1, TechnicianDocument.count, "Second query must NOT insert a new TechnicianDocument row"
    assert_equal 2, TechnicianDocument.first.interaction_count, "Existing row must be bumped, not replaced"
  end

  test 'secondary doc_ref already present in session does NOT get persisted to TechnicianDocument on a later query' do
    # Regression: previously, when a secondary (lower-scoring) doc_ref landed
    # in the session on query N as "session-only", on query N+1 it was found
    # via existing_key lookup and unconditionally persisted to TechnicianDocument,
    # bypassing the primary-only gate. Now the gate applies uniformly.
    TechnicianDocument.delete_all
    session = build_session

    primary_uri   = "s3://bucket/uploads/wa_disc_brake.jpeg"
    secondary_uri = "s3://bucket/uploads/wa_drum_brake.jpeg"

    doc_refs = [
      {
        "source_uri"     => primary_uri,
        "canonical_name" => "Elevator brake assembly unit",
        "aliases"        => [ "Electromagnetic disc brake", "BIMORE brake component" ],
        "doc_type"       => "datasheet"
      },
      {
        "source_uri"     => secondary_uri,
        "canonical_name" => "Elevator Drum Brake Assembly",
        "aliases"        => [ "Solenoid Operated Drum Brake", "Spring-Applied Solenoid-Released Brake" ],
        "doc_type"       => "diagram"
      }
    ]

    # Query 1: primary is persisted, secondary is session-only.
    EntityExtractorService.new(session).extract_and_update(
      [], user_message: "que es Electromagnetic disc brake ?", doc_refs: doc_refs
    )
    assert_equal 1, TechnicianDocument.count
    assert TechnicianDocument.find_by(source_uri: primary_uri)
    assert_nil TechnicianDocument.find_by(source_uri: secondary_uri),
               "Secondary doc must NOT be in TechnicianDocument after query 1"

    # Query 2: same doc_refs. The secondary entity is NOW in the session, so
    # existing_key lookup hits — but it's still secondary for THIS query's
    # scoring, so it must NOT be persisted.
    EntityExtractorService.new(session.reload).extract_and_update(
      [], user_message: "que es Electromagnetic disc brake ?", doc_refs: doc_refs.deep_dup
    )

    assert_equal 1, TechnicianDocument.count,
                 "Secondary session entity must NOT be promoted into TechnicianDocument on a later query"
    assert_nil TechnicianDocument.find_by(source_uri: secondary_uri),
               "Secondary doc must still NOT be in TechnicianDocument after query 2"
    assert_equal 2, TechnicianDocument.find_by(source_uri: primary_uri).interaction_count,
                 "Primary row must be bumped on the second query"
  end

  test 'prefers Bedrock metadata URI over URI that may appear in chunk content' do
    TechnicianDocument.delete_all
    session = build_session
    service = EntityExtractorService.new(session)

    trustworthy_uri = "s3://bucket/uploads/real_file.jpeg"

    # Chunk content contains a PIPELINE_INJECTED placeholder — we must IGNORE
    # it and use the metadata field, which is always authoritative.
    all_retrieved = [
      {
        content:  "| ORIGINAL_FILE_NAME | PIPELINE_INJECTED |",
        location: { uri: trustworthy_uri, bucket: "bucket", key: "uploads/real_file.jpeg", type: "s3" },
        metadata: { "x-amz-bedrock-kb-source-uri" => trustworthy_uri }
      }
    ]

    service.extract_and_update(
      [],
      user_message:  "qué es?",
      all_retrieved: all_retrieved,
      doc_refs:      [ { "source_uri" => "", "canonical_name" => "Brake Unit",
                         "aliases" => [ "brake" ], "doc_type" => "photo" } ]
    )
    session.reload

    assert_equal trustworthy_uri, session.active_entities.values.first["source_uri"]
  end

  test 'persists primary doc even when source_uri is unresolved (Bedrock 0 citations path)' do
    # Reproduces the exact production failure: Bedrock returns 0 citations so
    # backfill_source_uris_from_citations is a no-op and source_uri stays "".
    # primary_canonical_names must use canonical_name (never nil) not source_uri.
    TechnicianDocument.delete_all
    session = build_session
    service = EntityExtractorService.new(session)

    doc_refs = [
      {
        "source_uri"     => "",   # Haiku always sets to "" per RULE 8; backfill didn't run
        "canonical_name" => "Elevator brake assembly unit",
        "aliases"        => [ "Electromagnetic disc brake", "BIMORE brake component",
                              "Traction machine brake module", "Elevator safety brake",
                              "Disc brake manual release", "Spring-applied electromagnetic brake" ],
        "doc_type"       => "datasheet"
      },
      {
        "source_uri"     => "",   # also unresolved
        "canonical_name" => "Elevator Drum Brake Assembly",
        "aliases"        => [ "Solenoid Operated Drum Brake", "Spring-Applied Solenoid-Released Brake",
                              "Brake Arm Spring Housing", "Electromechanical Brake Components" ],
        "doc_type"       => "diagram"
      }
    ]

    service.extract_and_update(
      [],
      user_message:  "que es Electromagnetic disc brake ?",
      all_retrieved: [],   # 0 citations — triggers the bug path
      doc_refs:      doc_refs
    )
    session.reload

    assert_equal 2, session.entity_count, "Both entities must be in session for context"
    assert_equal 1, TechnicianDocument.count, "Only the primary doc must be persisted"
    assert TechnicianDocument.find_by("LOWER(canonical_name) = LOWER(?)", "elevator brake assembly unit"),
           "The disc brake (primary) must be the persisted doc"
  end

  test 'persists all docs when query is too short to discriminate (safe fallback)' do
    TechnicianDocument.delete_all
    session = build_session
    service = EntityExtractorService.new(session)

    doc_refs = [
      {
        "source_uri"     => "s3://bucket/uploads/wa_a.jpeg",
        "canonical_name" => "Doc Alpha",
        "aliases"        => [],
        "doc_type"       => "diagram"
      },
      {
        "source_uri"     => "s3://bucket/uploads/wa_b.jpeg",
        "canonical_name" => "Doc Beta",
        "aliases"        => [],
        "doc_type"       => "diagram"
      }
    ]

    service.extract_and_update([], user_message: "que es", doc_refs: doc_refs)
    session.reload

    # No meaningful query terms → safe fallback → persist all
    assert_equal 2, TechnicianDocument.count, "Short query must not suppress any doc"
  end

  test 'falls back to citation filenames when doc_refs nil' do
    session = build_session
    service = EntityExtractorService.new(session)
    numbered = [ { filename: "circuito_.jpeg", number: 1 } ]
    service.extract_and_update(numbered, user_message: "qué es", doc_refs: nil)
    session.reload
    entity = session.active_entities["circuito_.jpeg"]
    assert_not_nil entity
    assert_equal "filename_only", entity["extraction_method"]
    assert_equal "citation_filename_fallback", entity["source"]
  end

  test 'falls back to user message filenames when no citations' do
    session = build_session
    service = EntityExtractorService.new(session)
    service.extract_and_update(
      [],
      user_message: "info sobre circuito_.jpeg",
      answer:       "Es un diagrama.",
      doc_refs:     nil
    )
    session.reload
    entity = session.active_entities["circuito_.jpeg"]
    assert_not_nil entity
    assert_equal "filename_from_text", entity["extraction_method"]
    assert_equal "user_message_filename", entity["source"]
  end

  test 'does nothing when no results answer' do
    session = build_session
    service = EntityExtractorService.new(session)
    service.extract_and_update(
      [],
      user_message: "info sobre circuito_.jpeg",
      answer:       "No se encontró información sobre tu consulta.",
      doc_refs:     nil
    )
    session.reload
    assert_equal({}, session.active_entities)
  end

  test 'skips doc_ref with blank canonical_name' do
    session = build_session
    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri" => "s3://bucket/x.pdf",
      "canonical_name" => "",
      "aliases" => [ "orphan" ],
      "doc_type" => "pdf"
    } ]
    service.extract_and_update([], user_message: "q", doc_refs: doc_refs)
    session.reload
    assert_equal 0, session.entity_count
  end

  test 'extracts wa_filename from source_uri' do
    session = build_session
    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri" => "s3://bucket/uploads/2026-03-24/circuito_.jpeg",
      "canonical_name" => "Circuit diagram",
      "aliases" => [],
      "doc_type" => "diagram"
    } ]
    service.extract_and_update([], user_message: "q", doc_refs: doc_refs)
    session.reload
    entity = session.active_entities["Circuit diagram"]
    assert_equal "circuito_.jpeg", entity["wa_filename"]
    assert_includes entity["aliases"], "circuito_.jpeg"
  end

  test 'extract_and_update is a no-op when session is nil' do
    service = EntityExtractorService.new(nil)
    assert_nothing_raised do
      service.extract_and_update([ { filename: "a.pdf" } ], user_message: "q")
    end
  end

  test 'extract_and_update stores truncated detected_from' do
    session   = build_session
    service   = EntityExtractorService.new(session)
    long_msg  = "a" * 200
    citations = [ { number: 1, filename: "doc.pdf" } ]
    service.extract_and_update(citations, user_message: long_msg, doc_refs: nil)
    session.reload
    detected = session.active_entities["doc.pdf"]["detected_from"]
    assert detected.length <= 100
  end

  test 'falls back does NOT register when answer is nil' do
    session = build_session
    service = EntityExtractorService.new(session)
    service.extract_and_update([], user_message: "Que es schema.pdf ?", answer: nil, doc_refs: nil)
    session.reload
    assert_equal 0, session.entity_count
  end

  test 'citation path skips already-present keys' do
    session = build_session
    session.add_entity("existing.pdf", { "source" => "citation_filename_fallback" })
    session.reload
    original_added_at = session.active_entities["existing.pdf"]["added_at"]

    service   = EntityExtractorService.new(session)
    citations = [ { number: 1, filename: "existing.pdf" } ]
    service.extract_and_update(citations, user_message: "again", doc_refs: nil)
    session.reload

    assert_equal original_added_at, session.active_entities["existing.pdf"]["added_at"]
  end

  test 'citation path skips blank and Document filenames' do
    session = build_session
    service = EntityExtractorService.new(session)
    citations = [
      { number: 1, filename: "" },
      { number: 2, filename: "Document" }
    ]
    service.extract_and_update(citations, user_message: "q", doc_refs: nil)
    session.reload
    assert_equal 0, session.entity_count
  end

  test 'promotes pending placeholder entity when doc_refs wa_filename matches' do
    session = build_session
    session.add_entity_with_aliases(
      "wa_20260325_210519_0",
      [ "wa_20260325_210519_0.jpeg" ],
      "source"            => "image_upload",
      "doc_type"          => "field_image",
      "wa_filename"       => "wa_20260325_210519_0.jpeg",
      "extraction_method" => "pending_first_query"
    )
    session.reload
    assert session.active_entities.key?("wa_20260325_210519_0")

    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/uploads/2026-03-25/wa_20260325_210519_0.jpeg",
      "canonical_name" => "Junction Box Car Top DRG 6061-05-014",
      "aliases"        => [ "junction box", "car top", "safety circuit" ],
      "doc_type"       => "diagram"
    } ]
    service.extract_and_update([], user_message: "que es junction box?", doc_refs: doc_refs)
    session.reload

    assert_not session.active_entities.key?("wa_20260325_210519_0"),
           "Old placeholder key should be removed"
    assert session.active_entities.key?("Junction Box Car Top DRG 6061-05-014"),
           "Entity should be promoted to semantic canonical name"

    entity = session.active_entities["Junction Box Car Top DRG 6061-05-014"]
    assert_equal "haiku_doc_refs", entity["extraction_method"]
    assert_equal "diagram", entity["doc_type"]
    assert_equal "wa_20260325_210519_0.jpeg", entity["wa_filename"]
    assert_includes entity["aliases"], "junction box"
    assert_includes entity["aliases"], "car top"
    assert_includes entity["aliases"], "wa_20260325_210519_0.jpeg"
  end

  test 'promotes pending entity preserving wa when Haiku invents s3 URI with pdf basename' do
    session = build_session
    session.add_entity_with_aliases(
      "wa_20260326_012702_0",
      [ "wa_20260326_012702_0.jpeg" ],
      "source"            => "image_upload",
      "doc_type"          => "field_image",
      "wa_filename"       => "wa_20260326_012702_0.jpeg",
      "extraction_method" => "pending_first_query"
    )
    session.reload

    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://unknown-bucket/Junction Box Car Top.pdf",
      "canonical_name" => "Junction Box Car Top",
      "aliases"        => [ "junction box", "car top" ],
      "doc_type"       => "diagram"
    } ]
    service.extract_and_update([], user_message: "que es junction box?", doc_refs: doc_refs)
    session.reload

    entity = session.active_entities["Junction Box Car Top"]
    assert_equal "wa_20260326_012702_0.jpeg", entity["wa_filename"]
  end

  test 'promotes pending entity via fallback when source_uri is not a real filename' do
    session = build_session
    session.add_entity_with_aliases(
      "wa_20260326_012702_0",
      [ "wa_20260326_012702_0.jpeg" ],
      "source"            => "image_upload",
      "doc_type"          => "field_image",
      "wa_filename"       => "wa_20260326_012702_0.jpeg",
      "extraction_method" => "pending_first_query"
    )
    session.reload

    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "junction box car top",
      "canonical_name" => "Junction Box Car Top",
      "aliases"        => [ "junction box", "car top", "DRG 6061-05-014" ],
      "doc_type"       => "diagram"
    } ]
    service.extract_and_update([], user_message: "que es junction box?", doc_refs: doc_refs)
    session.reload

    assert_not session.active_entities.key?("wa_20260326_012702_0"),
           "Old placeholder should be removed"
    assert session.active_entities.key?("Junction Box Car Top"),
           "Entity should be promoted via pending fallback"

    entity = session.active_entities["Junction Box Car Top"]
    assert_equal "haiku_doc_refs", entity["extraction_method"]
    assert_equal "wa_20260326_012702_0.jpeg", entity["wa_filename"]
    assert_includes entity["aliases"], "junction box"
    assert_includes entity["aliases"], "wa_20260326_012702_0.jpeg"
  end

  test 'creates new entity when doc_refs wa_filename does not match any existing' do
    session = build_session
    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/uploads/2026-03-25/other_doc.pdf",
      "canonical_name" => "Motor Controller Schematic",
      "aliases"        => [ "motor controller", "schematic" ],
      "doc_type"       => "manual"
    } ]
    service.extract_and_update([], user_message: "que es motor controller?", doc_refs: doc_refs)
    session.reload

    assert session.active_entities.key?("Motor Controller Schematic")
    entity = session.active_entities["Motor Controller Schematic"]
    assert_equal "haiku_doc_refs", entity["extraction_method"]
    assert_includes entity["aliases"], "other_doc.pdf"
  end

  # ============================================
  # 3.3 — first_answer_summary stored in entity
  # ============================================

  test 'stores first_answer_summary in entity metadata when answer is provided' do
    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/junction_box.pdf",
      "canonical_name" => "Junction Box Car Top",
      "aliases"        => [],
      "doc_type"       => "diagram"
    } ]
    answer = "The Junction Box Car Top is mounted on the car top and contains the safety chain relay."
    service.extract_and_update([], user_message: "qué es?", doc_refs: doc_refs, answer: answer)
    session.reload

    entity = session.active_entities["Junction Box Car Top"]
    assert_not_nil entity["first_answer_summary"]
    assert_includes entity["first_answer_summary"], "safety chain relay"
  end

  test 'first_answer_summary is truncated to 200 chars' do
    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/manual.pdf",
      "canonical_name" => "Big Manual",
      "aliases"        => [],
      "doc_type"       => "manual"
    } ]
    long_answer = "x" * 500
    service.extract_and_update([], user_message: "info", doc_refs: doc_refs, answer: long_answer)
    session.reload

    summary = session.active_entities["Big Manual"]["first_answer_summary"]
    assert_equal 200, summary.length
  end

  test 'first_answer_summary is absent when answer is blank' do
    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/doc.pdf",
      "canonical_name" => "Doc",
      "aliases"        => [],
      "doc_type"       => "manual"
    } ]
    service.extract_and_update([], user_message: "info", doc_refs: doc_refs, answer: nil)
    session.reload

    entity = session.active_entities["Doc"]
    assert_nil entity["first_answer_summary"]
  end

  # ============================================
  # 3.4 — persist_to_technician_documents called
  # ============================================

  test 'persist_to_technician_documents creates TechnicianDocument on doc_refs registration' do
    TechnicianDocument.delete_all
    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/junction_box.pdf",
      "canonical_name" => "Junction Box Car Top",
      "aliases"        => [ "junction box" ],
      "doc_type"       => "diagram"
    } ]

    service.extract_and_update([], user_message: "qué es?", doc_refs: doc_refs)

    td = TechnicianDocument.find_by(
      identifier:     session.identifier,
      channel:        session.channel,
      canonical_name: "Junction Box Car Top"
    )
    assert_not_nil td, "Expected TechnicianDocument to be created"
    assert_equal "s3://bucket/junction_box.pdf", td.source_uri
    assert_includes td.aliases, "junction box"
  end

  test 'doc_refs without source_uri still sets wa_filename from session resolved_uri' do
    TechnicianDocument.delete_all
    session = build_session
    wa_file   = "wa_20260327_160921_0.jpeg"
    s3_uri    = "s3://multimodal-source-destination/uploads/2026-03-27/#{wa_file}"
    session.add_entity_with_aliases(
      "placeholder_stem",
      [ wa_file ],
      "source"            => "image_upload",
      "doc_type"          => "field_image",
      "wa_filename"       => wa_file,
      "source_uri"        => s3_uri,
      "extraction_method" => "pending_first_query"
    )
    session.reload

    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "",
      "canonical_name" => "Orona elevator controller PCB main processor board photograph",
      "aliases"        => [],
      "doc_type"       => "field_image"
    } ]

    service.extract_and_update([], user_message: "qué es esto?", doc_refs: doc_refs)
    session.reload

    entity = session.active_entities["Orona elevator controller PCB main processor board photograph"]
    assert_not_nil entity
    assert_equal wa_file, entity["wa_filename"]
    assert_equal s3_uri, entity["source_uri"]

    td = TechnicianDocument.find_by(
      identifier:     session.identifier,
      channel:        session.channel,
      canonical_name: "Orona elevator controller PCB main processor board photograph"
    )
    assert_not_nil td
    assert_equal wa_file, td.wa_filename
    assert_equal s3_uri, td.source_uri
  end

  test 'already-promoted entity (haiku_doc_refs) preserves source_uri on follow-up doc_ref with empty uri' do
    TechnicianDocument.delete_all
    session = build_session
    wa_file = "wa_20260327_160921_0.jpeg"
    s3_uri  = "s3://multimodal-source-destination/uploads/2026-03-27/#{wa_file}"
    canonical = "Orona elevator controller PCB main processor board photograph"

    # Simulate entity already promoted to haiku_doc_refs (not in PROMOTABLE_METHODS)
    session.add_entity_with_aliases(
      canonical,
      [ wa_file ],
      "source"            => "doc_refs_rule8",
      "doc_type"          => "field_image",
      "wa_filename"       => wa_file,
      "source_uri"        => s3_uri,
      "extraction_method" => "haiku_doc_refs"
    )
    session.reload

    service = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "",
      "canonical_name" => canonical,
      "aliases"        => [ "Orona CPU board" ],
      "doc_type"       => "field_image"
    } ]

    service.extract_and_update([], user_message: "dame los torques", doc_refs: doc_refs)
    session.reload

    entity = session.active_entities[canonical]
    assert_equal s3_uri, entity["source_uri"]
    assert_equal wa_file, entity["wa_filename"]

    td = TechnicianDocument.find_by(identifier: session.identifier, channel: session.channel, canonical_name: canonical)
    assert_not_nil td
    assert_equal s3_uri,  td.source_uri
    assert_equal wa_file, td.wa_filename
  end

  test 'canonical match takes priority over oldest_pending — no cross-entity corruption' do
    TechnicianDocument.delete_all
    session = build_session

    orona_file = "wa_20260327_160921_0.jpeg"
    orona_uri  = "s3://multimodal-source-destination/uploads/2026-03-27/#{orona_file}"
    purple_file = "wa_20260327_163952_0.jpeg"
    purple_uri  = "s3://multimodal-source-destination/uploads/2026-03-27/#{purple_file}"

    # Orona already promoted to haiku_doc_refs (not promotable)
    session.add_entity_with_aliases(
      "Orona PCB",
      [ orona_file ],
      "source"            => "doc_refs_rule8",
      "wa_filename"       => orona_file,
      "source_uri"        => orona_uri,
      "extraction_method" => "haiku_doc_refs"
    )
    # Purple PCB still pending (chunk_aliases — promotable)
    session.add_entity_with_aliases(
      "purple_stem",
      [ purple_file ],
      "source"            => "image_upload",
      "wa_filename"       => purple_file,
      "source_uri"        => purple_uri,
      "extraction_method" => "chunk_aliases"
    )
    session.reload

    service = EntityExtractorService.new(session)
    # Haiku returns doc_ref only for Orona, with empty source_uri
    doc_refs = [ {
      "source_uri"     => "",
      "canonical_name" => "Orona PCB",
      "aliases"        => [],
      "doc_type"       => "field_image"
    } ]

    service.extract_and_update([], user_message: "dame los torques", doc_refs: doc_refs)
    session.reload

    # Purple PCB must remain untouched — not promoted with Orona's data
    purple_entity = session.active_entities["purple_stem"]
    assert_not_nil purple_entity, "Purple PCB entity must still exist under its own key"
    assert_equal purple_uri,  purple_entity["source_uri"]
    assert_equal purple_file, purple_entity["wa_filename"]
    assert_equal "chunk_aliases", purple_entity["extraction_method"]

    # Orona must have correct source_uri
    orona_entity = session.active_entities["Orona PCB"]
    assert_not_nil orona_entity
    assert_equal orona_uri, orona_entity["source_uri"]
  end

  # ─── backfill_source_uris_from_citations — PIPELINE_INJECTED coverage ────────

  test 'backfill: single doc_ref + single citation assigns URI directly' do
    TechnicianDocument.delete_all
    session = build_session
    service = EntityExtractorService.new(session)

    doc_refs = [ {
      "source_uri"     => "",
      "canonical_name" => "Foremcaro 6118/81 Electrical Schematic",
      "aliases"        => [ "Esquema Eléctrico Elevador", "Planta U150" ],
      "doc_type"       => "schematic"
    } ]

    citation = {
      content:  "# S0 — Foremcaro 6118/81 Electrical Schematic ...",
      location: { uri: "s3://bucket/uploads/2026-03-27/Esquema SOPREL.pdf", type: "s3" },
      metadata: {}
    }

    service.extract_and_update([], user_message: "Qué es el Esquema Eléctrico?",
                               doc_refs: doc_refs, all_retrieved: [ citation ])
    session.reload

    entity = session.active_entities["Foremcaro 6118/81 Electrical Schematic"]
    assert_not_nil entity
    assert_equal "s3://bucket/uploads/2026-03-27/Esquema SOPREL.pdf", entity["source_uri"]

    td = TechnicianDocument.find_by(canonical_name: "Foremcaro 6118/81 Electrical Schematic")
    assert_not_nil td
    assert_equal "s3://bucket/uploads/2026-03-27/Esquema SOPREL.pdf", td.source_uri
  end

  test 'backfill: chunk content match resolves PIPELINE_INJECTED filename mismatch' do
    TechnicianDocument.delete_all
    session = build_session
    service = EntityExtractorService.new(session)

    doc_refs = [
      { "source_uri" => "", "canonical_name" => "Doc Alpha",
        "aliases" => [ "alpha manual" ], "doc_type" => "manual" },
      { "source_uri" => "", "canonical_name" => "Doc Beta",
        "aliases" => [ "beta schematic" ], "doc_type" => "schematic" }
    ]

    citations = [
      { content:  "**Document:** Doc Alpha | **File:** PIPELINE_INJECTED\nalpha manual details here",
        location: { uri: "s3://bucket/uploads/file_alpha_xyz.pdf", type: "s3" },
        metadata: {} },
      { content:  "**Document:** Doc Beta | **File:** PIPELINE_INJECTED\nbeta schematic details here",
        location: { uri: "s3://bucket/uploads/file_beta_xyz.pdf", type: "s3" },
        metadata: {} }
    ]

    service.extract_and_update([], user_message: "info",
                               doc_refs: doc_refs, all_retrieved: citations)
    session.reload

    alpha = session.active_entities["Doc Alpha"]
    beta  = session.active_entities["Doc Beta"]

    assert_equal "s3://bucket/uploads/file_alpha_xyz.pdf", alpha&.dig("source_uri")
    assert_equal "s3://bucket/uploads/file_beta_xyz.pdf",  beta&.dig("source_uri")
  end

  test 'backfill: skips refs that already have a real source_uri' do
    session = build_session
    service = EntityExtractorService.new(session)

    original_uri = "s3://bucket/real.pdf"
    doc_refs = [ {
      "source_uri"     => original_uri,
      "canonical_name" => "Real Doc",
      "aliases"        => [],
      "doc_type"       => "manual"
    } ]
    citation = {
      content:  "Real Doc content here",
      location: { uri: "s3://bucket/other.pdf", type: "s3" },
      metadata: {}
    }

    service.extract_and_update([], user_message: "info",
                               doc_refs: doc_refs, all_retrieved: [ citation ])
    session.reload

    entity = session.active_entities["Real Doc"]
    assert_equal original_uri, entity["source_uri"]
  end

  test 'persist failure does not raise and entity is still registered' do
    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/motor.pdf",
      "canonical_name" => "Motor Controller",
      "aliases"        => [],
      "doc_type"       => "manual"
    } ]

    original = TechnicianDocument.method(:upsert_from_entity)
    TechnicianDocument.define_singleton_method(:upsert_from_entity) { |**_| raise "DB down" }

    begin
      assert_nothing_raised { service.extract_and_update([], user_message: "info", doc_refs: doc_refs) }
      session.reload
      assert session.active_entities.key?("Motor Controller"), "Entity must still be registered"
    ensure
      TechnicianDocument.define_singleton_method(:upsert_from_entity) { |**kwargs| original.call(**kwargs) }
    end
  end

  # ─── enrich_kb_document on doc_refs path ─────────────────────────────────────

  test 'enrich_kb_document updates display_name and merges aliases into KbDocument' do
    kb = KbDocument.create!(
      s3_key: "uploads/2026-04-10/wa_20260410_174231_0.jpeg",
      display_name: "wa 20260410 174231 0",
      aliases: []
    )

    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://multimodal-source-destination/uploads/2026-04-10/wa_20260410_174231_0.jpeg",
      "canonical_name" => "Gearless Traction Machine",
      "aliases"        => [ "sheave assembly", "brake caliper" ],
      "doc_type"       => "field_image"
    } ]

    service.extract_and_update([], user_message: "que es esto?", doc_refs: doc_refs)

    kb.reload
    assert_equal "Gearless Traction Machine", kb.display_name
    assert_includes kb.aliases, "sheave assembly"
    assert_includes kb.aliases, "brake caliper"
  end

  test 'enrich_kb_document caps aliases at 15 entries' do
    kb = KbDocument.create!(
      s3_key: "uploads/2026-04-10/many_aliases.jpeg",
      display_name: "old name",
      aliases: (1..10).map { |i| "existing alias #{i}" }
    )

    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/uploads/2026-04-10/many_aliases.jpeg",
      "canonical_name" => "Dense Document",
      "aliases"        => (1..10).map { |i| "new alias #{i}" },
      "doc_type"       => "manual"
    } ]

    service.extract_and_update([], user_message: "info", doc_refs: doc_refs)

    kb.reload
    assert kb.aliases.size <= 15
  end

  test 'enrich_kb_document is a no-op when source_uri is blank' do
    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "",
      "canonical_name" => "Unknown Doc",
      "aliases"        => [ "something" ],
      "doc_type"       => "manual"
    } ]
    # Should not raise even though no KbDocument can be found
    assert_nothing_raised { service.extract_and_update([], user_message: "info", doc_refs: doc_refs) }
  end

  test 'enrich_kb_document is a no-op when no matching KbDocument row exists' do
    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://bucket/nonexistent_key.pdf",
      "canonical_name" => "Phantom Doc",
      "aliases"        => [ "ghost" ],
      "doc_type"       => "manual"
    } ]
    assert_nothing_raised { service.extract_and_update([], user_message: "info", doc_refs: doc_refs) }
  end

  test 'enrich_kb_document promotes canonical to display_name and stores prior stem in aliases' do
    kb = KbDocument.create!(
      s3_key: "uploads/2026-04-10/Esquema SOPREL.pdf",
      display_name: "Esquema SOPREL",
      aliases: [ "Esquema SOPREL" ]
    )

    session  = build_session
    service  = EntityExtractorService.new(session)
    doc_refs = [ {
      "source_uri"     => "s3://multimodal-source-destination/uploads/2026-04-10/Esquema SOPREL.pdf",
      "canonical_name" => "Foremcaro 6118/81 — Colegio Sta. Doroteia",
      "aliases"        => [ "Esquema Eléctrico" ],
      "doc_type"       => "schematic"
    } ]

    service.extract_and_update([], user_message: "que es Esquema SOPREL?", doc_refs: doc_refs)

    kb.reload
    assert_equal "Foremcaro 6118/81 — Colegio Sta. Doroteia", kb.display_name,
                 "Haiku canonical must win and become display_name"
    assert_includes kb.aliases, "Esquema SOPREL",
                    "Prior display_name must be preserved as alias so resolver still matches it"
    assert_includes kb.aliases, "Esquema Eléctrico"
  end
end
