# frozen_string_literal: true

require "test_helper"

class ConversationSessionDocumentFocusTest < ActiveSupport::TestCase
  test "legacy backfill omits a pin without an id and copies the document identity" do
    account = accounts(:legacy)
    document = KbDocument.create!(
      account: account,
      s3_key: "uploads/focus-backfill.pdf",
      display_name: "Backfill Manual",
      aliases: [ "old alias" ]
    )
    stale_uri = "s3://#{KbDocument::KB_BUCKET}/uploads/stale-name.pdf"
    entities = {
      "Stale label" => {
        "source" => "user_pin",
        "kb_document_id" => document.id,
        "source_uri" => stale_uri,
        "canonical_name" => "Stale label",
        "aliases" => [ "copied alias" ],
        "entity_type" => "image_upload",
        "added_at" => "2026-09-01T10:00:00Z"
      },
      "No id" => {
        "source" => "user_pin",
        "source_uri" => "s3://#{KbDocument::KB_BUCKET}/uploads/missing.pdf",
        "added_at" => "2026-09-02T10:00:00Z"
      },
      "Citation" => {
        "source" => "doc_refs_rule8",
        "kb_document_id" => document.id,
        "source_uri" => document.display_s3_uri(KbDocument::KB_BUCKET)
      }
    }

    entries = ConversationSession.document_focus_from_legacy(entities, account: account)

    assert_equal 1, entries.size
    entry = entries.sole
    assert_equal ConversationSession::DOCUMENT_FOCUS_KEYS, entry.keys.sort
    assert_equal document.id, entry["kb_document_id"]
    assert_equal document.display_s3_uri(KbDocument::KB_BUCKET), entry["source_uri"]
    assert_equal "Backfill Manual", entry["display_name"]
    assert_not_equal stale_uri, entry["source_uri"]
  end

  test "legacy backfill skips a private document from another account and keeps a general one" do
    viewer = Account.create!(display_name: "Focus Viewer", slug: "focus-viewer-#{SecureRandom.hex(3)}")
    foreign_account = Account.create!(display_name: "Focus Foreign", slug: "focus-foreign-#{SecureRandom.hex(3)}")
    foreign = KbDocument.create!(
      account: foreign_account,
      s3_key: "uploads/foreign-focus-#{SecureRandom.hex(3)}.pdf",
      display_name: "Foreign",
      aliases: []
    )
    owner = Account.create!(
      display_name: "Focus Owner",
      slug: "focus-owner-#{SecureRandom.hex(3)}",
      danebo_controlled: true
    )
    general = KbDocument.create!(
      account: owner,
      s3_key: "uploads/general-focus-#{SecureRandom.hex(3)}.pdf",
      display_name: "General Manual",
      aliases: []
    )
    index_manual_for_retrieval!(general)
    KnowledgeScopeChange.apply!(
      kb_document: general, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )

    entries = ConversationSession.document_focus_from_legacy(
      {
        "Foreign" => pin_hash(foreign),
        "General" => pin_hash(general)
      },
      account: viewer
    )

    assert_equal [ general.id ], entries.pluck("kb_document_id")
  end

  test "legacy backfill dedupes by id and keeps the newest ten" do
    account = accounts(:legacy)
    documents = 12.times.map { |index|
      KbDocument.create!(
        account: account,
        s3_key: "uploads/cap-#{index}.pdf",
        display_name: "Cap #{index}",
        aliases: []
      )
    }
    entities = documents.each_with_index.to_h { |document, index|
      [ "Doc #{index}", pin_hash(document, added_at: "2026-09-01T10:%02d:00Z" % index) ]
    }
    entities["again"] = pin_hash(documents.first, added_at: "2026-09-01T11:00:00Z")

    entries = ConversationSession.document_focus_from_legacy(entities, account: account)

    ids = entries.pluck("kb_document_id")
    assert_equal ConversationSession::MAX_ENTITIES, ids.size
    assert_equal ids.uniq.size, ids.size
    assert_not_includes ids, documents[1].id
    assert_includes ids, documents.first.id
  end

  test "malformed document focus reads as an empty list" do
    session = web_session
    session.update!(document_focus: { "kb_document_id" => 1 })
    assert_equal [], session.document_focus_entries

    session.update!(document_focus: [ "nope", { "display_name" => "missing id" } ])
    assert_equal [], session.document_focus_entries
  end

  test "web readers ignore active_entities and resolve aliases from the document" do
    document = KbDocument.create!(
      account: accounts(:legacy),
      s3_key: "uploads/web-focus.jpg",
      display_name: "Web Focus",
      aliases: [ "door board" ]
    )
    session = web_session
    session.update!(active_entities: {
      "Hidden" => {
        "source" => "user_pin",
        "kb_document_id" => document.id,
        "source_uri" => "s3://#{KbDocument::KB_BUCKET}/uploads/hidden.pdf",
        "aliases" => [ "should-not-appear" ],
        "entity_type" => "document"
      }
    })

    assert_empty SessionContextBuilder.entity_s3_uris(session)
    assert_not_includes SessionContextBuilder.build(session), "should-not-appear"
    assert_nil Rag::DocumentOverviewResponder.build(
      question: "Web Focus", account: session.account, conv_session: session
    )

    session.pin_kb_document!(document)
    session.reload

    assert_includes SessionContextBuilder.entity_s3_uris(session), document.display_s3_uri(KbDocument::KB_BUCKET)
    context = SessionContextBuilder.build(session)
    assert_includes context, "[image] Web Focus"
    assert_includes context, "door board"
    assert_not_includes context, "should-not-appear"
    assert_equal [ "door board" ], session.document_focus_scope_index.values.sole["aliases"]
    assert_equal [ "image_upload" ], web_entity_sources(session)
    assert_equal [ document.id ], RagController.new.send(:focused_kb_document_ids, session)
  end

  test "a dormant channel still reads the legacy entity hash" do
    session = ConversationSession.create!(
      identifier: "whatsapp:+34600000999",
      channel: "whatsapp",
      account: accounts(:legacy),
      expires_at: 1.hour.from_now
    )
    session.add_entity("wa-manual.pdf", {
      "source" => "user_pin",
      "source_uri" => "s3://#{KbDocument::KB_BUCKET}/uploads/wa-manual.pdf",
      "entity_type" => "document"
    })

    assert_includes SessionContextBuilder.entity_s3_uris(session), "s3://#{KbDocument::KB_BUCKET}/uploads/wa-manual.pdf"
    assert_includes SessionContextBuilder.build(session), "[document] wa-manual.pdf"
    assert_empty session.document_focus_entries
  end

  private

  def web_session
    ConversationSession.create!(
      identifier: "focus-#{SecureRandom.hex(4)}",
      channel: "web",
      account: accounts(:legacy),
      user: users(:one),
      expires_at: 1.hour.from_now
    )
  end

  def pin_hash(document, added_at: "2026-09-01T10:00:00Z")
    {
      "source" => "user_pin",
      "kb_document_id" => document.id,
      "source_uri" => "s3://stale/ignored.pdf",
      "canonical_name" => "Ignored",
      "aliases" => [ "ignored" ],
      "entity_type" => "image_upload",
      "added_at" => added_at
    }
  end

  def web_entity_sources(session)
    QueryOrchestratorService.new("pregunta", conv_session: session, account: session.account).send(:entity_sources)
  end
end
