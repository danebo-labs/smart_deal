# frozen_string_literal: true

require "test_helper"

class Rag::DocumentDiscoveryTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:climb)
    @monarch = catalog_document("NICE3000")
    @elemont = catalog_document("MH")
    @session = ConversationSession.find_or_create_for(
      identifier: "discovery-#{@account.id}",
      channel: "web",
      account_id: @account.id
    )
    @session.update!(document_focus: [])
  end

  test "Monarch NICE3000 offers that manual and does not select it" do
    result = Rag::DocumentDiscovery.call(
      question: "Es Monarch / NICE3000.",
      viewer_account: @account,
      session: @session
    )

    card = result.cards.sole
    assert_equal @monarch.document_uid, card.document_uid
    assert_equal @monarch.id, card.kb_document_id
    assert_equal "add", result.action
    assert_equal I18n.t("rag.manual_focus_select"), result.label
    assert_empty @session.reload.document_focus_entries
  end

  test "badge 0 offers the single cited manual and leaves it unselected" do
    uri = @elemont.display_s3_uri(KbDocument::KB_BUCKET)
    result = Rag::DocumentDiscovery.call(
      question: "¿Qué reviso si no nivela?",
      viewer_account: @account,
      session: @session,
      doc_refs: [ { "source_uri" => uri }, { "source_uri" => uri } ]
    )

    assert_equal [ @elemont.id ], result.cards.map(&:kb_document_id)
    assert_equal "CITED", result.cards.sole.label
    assert_empty @session.reload.document_focus_entries
  end

  test "a tie between cited manuals offers nothing" do
    other = KbDocument.create!(
      account: @account,
      s3_key: "uploads/discovery/other.pdf",
      document_uid: SecureRandom.uuid,
      display_name: "Otro",
      aliases: []
    )
    result = Rag::DocumentDiscovery.call(
      question: "¿Qué reviso si no nivela?",
      viewer_account: @account,
      session: @session,
      doc_refs: [
        { "source_uri" => @elemont.display_s3_uri(KbDocument::KB_BUCKET) },
        { "source_uri" => other.display_s3_uri(KbDocument::KB_BUCKET) }
      ]
    )

    assert_empty result.cards
  end

  test "a selected Elemont manual stays selected when the question names KONE" do
    assert @session.pin_kb_document!(@elemont)
    calls = 0
    result = Rag::DocumentDiscovery.call(
      question: "No, no es Elemont. Es KONE.",
      viewer_account: @account,
      session: @session,
      retriever: lambda { |*|
        calls += 1
        { chunks: [] }
      }
    )

    assert_equal 0, calls
    assert_equal [ @elemont.id ], @session.reload.document_focus_entries.pluck("kb_document_id")
    assert result.cards.none? { |card| card.kb_document_id == @elemont.id }
  end

  test "Monarch with Elemont selected is a suggestion and not a retrieval" do
    assert @session.pin_kb_document!(@elemont)
    calls = 0
    result = Rag::DocumentDiscovery.call(
      question: "Es Monarch / NICE3000.",
      viewer_account: @account,
      session: @session,
      doc_refs: [ { "source_uri" => @elemont.display_s3_uri(KbDocument::KB_BUCKET) } ],
      retriever: lambda { |*|
        calls += 1
        { chunks: [] }
      }
    )

    assert_equal 0, calls
    assert_equal "replace", result.action
    assert_equal [ @monarch.id ], result.cards.map(&:kb_document_id)
    assert_equal [ @elemont.id ], @session.reload.document_focus_entries.pluck("kb_document_id")
  end

  test "abstention with a focus retrieves outside it and does not return those chunks as cards of the focus" do
    assert @session.pin_kb_document!(@elemont)
    outside_uri = @monarch.display_s3_uri(KbDocument::KB_BUCKET)
    seen = nil
    result = Rag::DocumentDiscovery.call(
      question: "¿Qué es Q2?",
      viewer_account: @account,
      session: @session,
      abstained: true,
      retriever: lambda { |question, top_k|
        seen = [ question, top_k ]
        {
          chunks: [
            { original_source_uri: @elemont.display_s3_uri(KbDocument::KB_BUCKET), content: "dentro" },
            { original_source_uri: outside_uri, content: "afuera" }
          ]
        }
      }
    )

    assert_equal [ "¿Qué es Q2?", Rag::DocumentDiscovery::ABSTENTION_TOP_K ], seen
    assert_equal [ @monarch.id ], result.cards.map(&:kb_document_id)
    assert_equal "OUTSIDE_FOCUS", result.cards.sole.label
    assert_equal [ @elemont.id ], @session.reload.document_focus_entries.pluck("kb_document_id")
  end

  test "an authorized outside search retrieves the technical query" do
    assert @session.pin_kb_document!(@elemont)
    seen = nil
    Rag::DocumentDiscovery.call(
      question: "¿Qué es ROS?",
      viewer_account: @account,
      session: @session,
      abstained: true,
      discovery_query: "ROS Excelsior controlador puertas automáticas",
      allow_outside: true,
      retriever: lambda { |question, top_k|
        seen = [ question, top_k ]
        { chunks: [] }
      }
    )

    assert_equal [ "ROS Excelsior controlador puertas automáticas", Rag::DocumentDiscovery::ABSTENTION_TOP_K ], seen
  end

  test "a blocked outside search still offers an exact designator without retrieving" do
    assert @session.pin_kb_document!(@elemont)
    vf5 = catalog_document("VF5+")
    calls = 0
    result = Rag::DocumentDiscovery.call(
      question: "¿Cómo uso el módulo electrónico VF5?",
      viewer_account: @account,
      session: @session,
      abstained: true,
      allow_outside: false,
      retriever: lambda { |*|
        calls += 1
        { chunks: [] }
      }
    )

    assert_equal 0, calls
    assert_equal [ vf5.id ], result.cards.map(&:kb_document_id)
    assert_equal [ @elemont.id ], @session.reload.document_focus_entries.pluck("kb_document_id")
  end

  private

  def catalog_document(designator)
    entry = Rag::DocumentIdentityCatalog.current.entries.find { |row|
      Array(row.designators).include?(designator)
    }
    KbDocument.create!(
      account: @account,
      s3_key: entry.s3_key,
      document_uid: entry.document_id,
      display_name: entry.display_name,
      aliases: []
    )
  end
end
