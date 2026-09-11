# frozen_string_literal: true

require 'test_helper'

class KbDocumentResolverTest < ActiveSupport::TestCase
  setup do
    KbDocument.delete_all
    @account = accounts(:legacy)
    @other_account = accounts(:climb)
  end

  test 'returns empty for blank question' do
    assert_equal [], KbDocumentResolver.resolve(nil, account: @account)
    assert_equal [], KbDocumentResolver.resolve("", account: @account)
    assert_equal [], KbDocumentResolver.resolve("   ", account: @account)
  end

  test 'resolves by whole-word display_name match' do
    kb = KbDocument.create!(
      s3_key: "uploads/2026-04-10/Esquema SOPREL.pdf",
      display_name: "Esquema SOPREL",
      aliases: [],
      account: @account
    )

    matches = KbDocumentResolver.resolve("que es el Esquema SOPREL.pdf ?", account: @account)
    assert_equal [ kb.id ], matches.map(&:id)
  end

  test 'resolves by whole-word alias match' do
    kb = KbDocument.create!(
      s3_key: "uploads/2026-04-10/wa_20260410_174231_0.jpeg",
      display_name: "Foremcaro 6118/81",
      aliases: [ "SOPREL", "Portas de Patamar" ],
      account: @account
    )

    matches = KbDocumentResolver.resolve("tienes info de SOPREL?", account: @account)
    assert_equal [ kb.id ], matches.map(&:id)
  end

  test 'does not match on substring (word boundary enforced)' do
    KbDocument.create!(
      s3_key: "uploads/2026-04-10/soprelado.pdf",
      display_name: "Soprelado",
      aliases: [],
      account: @account
    )

    assert_empty KbDocumentResolver.resolve("what is SOPREL?", account: @account)
  end

  test 'ranks by number of distinct tokens matched' do
    one_match = KbDocument.create!(
      s3_key: "uploads/2026-04-10/esquema_generico.pdf",
      display_name: "Esquema Generico",
      aliases: [],
      account: @account
    )
    two_match = KbDocument.create!(
      s3_key: "uploads/2026-04-10/Esquema SOPREL.pdf",
      display_name: "Esquema SOPREL",
      aliases: [],
      account: @account
    )

    matches = KbDocumentResolver.resolve("que es Esquema SOPREL?", account: @account)
    assert_equal two_match.id, matches.first.id
    assert_includes matches.map(&:id), one_match.id
  end

  test 'caps results at MAX_MATCHES' do
    6.times do |i|
      KbDocument.create!(
        s3_key: "uploads/2026-04-10/doc_#{i}.pdf",
        display_name: "Foremcaro Variant #{i}",
        aliases: [],
        account: @account
      )
    end

    matches = KbDocumentResolver.resolve("Foremcaro info", account: @account)
    assert_equal KbDocumentResolver::MAX_MATCHES, matches.size
  end

  test 'ignores short/stopword-only queries' do
    KbDocument.create!(
      s3_key: "uploads/2026-04-10/any.pdf",
      display_name: "Any Document",
      aliases: [],
      account: @account
    )

    assert_empty KbDocumentResolver.resolve("que es esto", account: @account)
  end

  test 'does not return another account document' do
    other = KbDocument.create!(
      s3_key: "uploads/2026-04-10/other_soprel.pdf",
      display_name: "Esquema SOPREL",
      aliases: [],
      account: @other_account
    )

    assert_empty KbDocumentResolver.resolve("Esquema SOPREL", account: @account)
    assert_equal [ other.id ], KbDocumentResolver.resolve("Esquema SOPREL", account: @other_account).map(&:id)
  end

  test 'tokenize rejects stopwords and sub-minimum tokens' do
    tokens = KbDocumentResolver.tokenize("que es el Esquema SOPREL pdf?")
    assert_includes tokens, "esquema"
    assert_includes tokens, "soprel"
    assert_not_includes tokens, "que"
    assert_not_includes tokens, "el"
    assert_not_includes tokens, "es"
  end

  test 'tokenize includes a 3-char token only when it is uppercase-specific or digit-bearing' do
    tokens = KbDocumentResolver.tokenize("La tarjeta MPK 708A en un BL6")
    assert_includes tokens, "mpk"
    assert_includes tokens, "708a"
    assert_includes tokens, "bl6"
  end

  test 'tokenize drops a lowercase 3-char token below MIN_TOKEN' do
    tokens = KbDocumentResolver.tokenize("hay que revisar los bornes del equipo")
    assert_not_includes tokens, "los"
    assert_not_includes tokens, "del"
  end

  test 'specific_token? is true for digit-bearing tokens regardless of case' do
    assert KbDocumentResolver.specific_token?("708A")
    assert KbDocumentResolver.specific_token?("mpdk136")
    assert KbDocumentResolver.specific_token?("BL6")
  end

  test 'specific_token? is true for all-uppercase non-brand tokens' do
    assert KbDocumentResolver.specific_token?("MPK")
    assert KbDocumentResolver.specific_token?("LCE")
    assert KbDocumentResolver.specific_token?("WEG")
  end

  test 'specific_token? is false for brand names even fully uppercase' do
    assert_not KbDocumentResolver.specific_token?("KONE")
    assert_not KbDocumentResolver.specific_token?("OTIS")
  end

  test 'specific_token? is false for lowercase non-digit tokens' do
    assert_not KbDocumentResolver.specific_token?("kone")
    assert_not KbDocumentResolver.specific_token?("esquema")
  end

  test 'specific_token? is false for Title-case tokens (not fully uppercase)' do
    assert_not KbDocumentResolver.specific_token?("Thyssen")
  end

  test 'resolve_scoped returns score and original-case matched tokens' do
    kb = KbDocument.create!(
      s3_key: "uploads/2026-04-10/mpk_708a.pdf",
      display_name: "Tarjeta MPK 708A",
      aliases: [],
      account: @account
    )

    matches = KbDocumentResolver.resolve_scoped(
      "Que significa el codigo de error de la tarjeta MPK 708A?", account: @account
    )

    assert_equal 1, matches.size
    match = matches.first
    assert_equal kb.id, match.document.id
    assert_equal match.matched_tokens.size, match.score
    assert_includes match.matched_tokens, "MPK"
    assert_includes match.matched_tokens, "708A"
  end

  test 'resolve delegates to resolve_scoped and returns plain documents' do
    kb = KbDocument.create!(
      s3_key: "uploads/2026-04-10/Esquema SOPREL.pdf",
      display_name: "Esquema SOPREL",
      aliases: [],
      account: @account
    )

    matches = KbDocumentResolver.resolve("que es el Esquema SOPREL.pdf ?", account: @account)
    assert_equal [ kb ], matches
  end
end
