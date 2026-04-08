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
end
