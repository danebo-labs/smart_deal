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
end
