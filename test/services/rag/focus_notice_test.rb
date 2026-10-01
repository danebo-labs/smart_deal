# frozen_string_literal: true

require "test_helper"

class Rag::FocusNoticeTest < ActiveSupport::TestCase
  Suggestion = Struct.new(:manufacturer, :model_tokens)

  setup do
    @account = accounts(:climb)
    @session = ConversationSession.create!(
      identifier: "focus-notice-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:two),
      account: @account
    )
  end

  test "a different brand is shown and the pin stays" do
    document = pinned_manual("schindler.pdf", "Manual Schindler")
    before = @session.document_focus.deep_dup

    notice = with_catalog(document, brands: [ "Schindler" ]) do
      Rag::FocusNotice.pin_conflict(session: @session, suggestion: Suggestion.new("otis", []))
    end

    assert_equal "Indicaste Otis. El manual enfocado es de Schindler y sigue enfocado.", notice.message
    assert_equal "otis", notice.manufacturer
    assert_equal before, @session.reload.document_focus
  end

  test "the same brand is not a pin conflict" do
    document = pinned_manual("otis.pdf", "Manual Otis")

    notice = with_catalog(document, brands: [ "Otis" ]) do
      Rag::FocusNotice.pin_conflict(session: @session, suggestion: Suggestion.new("otis", []))
    end

    assert_nil notice
  end

  test "a blank document brand does not conflict" do
    document = pinned_manual("blank.pdf", "Manual")

    notice = with_catalog(document, brands: []) do
      Rag::FocusNotice.pin_conflict(session: @session, suggestion: Suggestion.new("otis", []))
    end

    assert_nil notice
    assert_equal 1, @session.reload.document_focus_entries.size
  end

  test "a different model is shown when both sides name one and the pin stays" do
    document = pinned_manual("otis-model.pdf", "Manual Otis")

    notice = with_catalog(document, brands: [ "Otis" ], designators: [ "X1" ]) do
      Rag::FocusNotice.pin_conflict(session: @session, suggestion: Suggestion.new("otis", [ "Y9" ]))
    end

    assert_equal "Indicaste Otis Y9. El manual enfocado no coincide con ese modelo y sigue enfocado.", notice.message
    assert_equal 1, @session.reload.document_focus_entries.size
  end

  test "a model on only one side does not conflict" do
    document = pinned_manual("otis-one-side.pdf", "Manual Otis")

    notice = with_catalog(document, brands: [ "Otis" ], designators: [ "X1" ]) do
      Rag::FocusNotice.pin_conflict(session: @session, suggestion: Suggestion.new("otis", []))
    end

    assert_nil notice
  end

  test "identity conflict shows both names and does not write the episode or the pin" do
    document = pinned_manual("kept.pdf", "Manual")
    @session.update!(active_episode: {
      "facts" => { "manufacturer" => { "status" => "known", "value" => "OTIS", "source" => "user" } },
      "conflicts" => [ { "fact" => "manufacturer", "user" => "OTIS", "photo" => "KONE" } ]
    })
    before = @session.document_focus.deep_dup

    notice = Rag::FocusNotice.identity_conflict(session: @session)

    assert_includes notice.message, "OTIS"
    assert_includes notice.message, "KONE"
    assert_equal "OTIS", @session.reload.active_episode.dig("facts", "manufacturer", "value")
    assert_equal "user", @session.active_episode.dig("facts", "manufacturer", "source")
    assert_equal before, @session.document_focus
    assert document.persisted?
  end

  private

  def pinned_manual(key, name)
    document = KbDocument.create!(
      account: @account,
      s3_key: "manuals/focus-notice/#{key}",
      display_name: name,
      aliases: []
    )
    @session.pin_kb_document!(document)
    document
  end

  def with_catalog(document, brands:, designators: [])
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        {
          "account_id" => @account.id.to_s,
          "document_id" => document.document_uid,
          "s3_key" => document.s3_key,
          "display_name" => document.display_name,
          "brands" => brands,
          "designators" => designators,
          "confirmed" => false
        }
      ]
    })
    Rag::DocumentIdentityCatalog.with_catalog(catalog) { yield }
  end
end
