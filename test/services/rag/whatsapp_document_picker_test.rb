# frozen_string_literal: true

require "test_helper"

module Rag
  class WhatsappDocumentPickerTest < ActiveSupport::TestCase
    # Render contracts:
    #   - :recent → single page, no `+`/`-` even when 9 items.
    #   - :all    → paginates by PAGE_SIZE (=20); shows page indicator + the
    #               nav lines that actually have a neighbour.
    #   - empty   → localized placeholder + bare nav (back + word-only home).

    setup do
      KbDocument.delete_all
      TechnicianDocument.delete_all
    end

    test "list(:all) paginates by PAGE_SIZE and returns the requested page slice" do
      total = WhatsappDocumentPicker::PAGE_SIZE + 5
      total.times do |i|
        KbDocument.create!(
          s3_key:       format("doc-%03d.pdf", i),
          display_name: format("Doc %03d", i)
        )
      end

      page1 = WhatsappDocumentPicker.list(source: :all, page: 1)
      page2 = WhatsappDocumentPicker.list(source: :all, page: 2)

      assert_equal WhatsappDocumentPicker::PAGE_SIZE, page1.items.size
      assert_equal 5,                                  page2.items.size
      assert_equal 1,                                  page1.page
      assert_equal 2,                                  page2.page
      assert_equal 2,                                  page1.total_pages
      assert_equal total,                              page1.total_count
      assert_equal "Doc 000",                          page1.items.first.label
      assert_equal "Doc 020",                          page2.items.first.label
    end

    test "list(:all) clamps out-of-range page to last page" do
      3.times { |i| KbDocument.create!(s3_key: "k-#{i}", display_name: "Doc #{i}") }
      page = WhatsappDocumentPicker.list(source: :all, page: 99)
      assert_equal 1, page.page
      assert_equal 1, page.total_pages
      assert_equal 3, page.items.size
    end

    test "list(:all) returns a single empty page when catalog is empty" do
      page = WhatsappDocumentPicker.list(source: :all, page: 1)
      assert_equal 0, page.items.size
      assert_equal 1, page.total_pages
      assert_equal 0, page.total_count
    end

    test "list(:recent) is single-page even with more than RECENT_LIMIT rows" do
      to = "whatsapp:+56911112222"
      (WhatsappDocumentPicker::RECENT_LIMIT + 4).times do |i|
        TechnicianDocument.create!(
          identifier:     to,
          channel:        "whatsapp",
          canonical_name: "Recent #{i}",
          last_used_at:   i.minutes.ago
        )
      end

      page = WhatsappDocumentPicker.list(source: :recent, page: 1)
      assert_equal WhatsappDocumentPicker::RECENT_LIMIT, page.items.size
      assert_equal 1, page.total_pages, ":recent must never advertise pagination"
    end

    test "render(:all) shows page indicator + only the nav lines with a neighbour (page 1 of N)" do
      (WhatsappDocumentPicker::PAGE_SIZE + 2).times do |i|
        KbDocument.create!(s3_key: "k-#{i}", display_name: "Doc #{format('%02d', i)}")
      end
      page = WhatsappDocumentPicker.list(source: :all, page: 1)
      msg  = WhatsappDocumentPicker.render(page: page, source: :all, locale: :es)

      assert_match(/Página 1\/2/, msg)
      assert_match(/^\+ - siguiente página$/, msg)
      assert_no_match(/página anterior/, msg, "no `-` line on the first page")
      assert_match(/^0 - atrás$/, msg)
      assert_match(/^inicio - reiniciar$/, msg)
      assert_match(/^1 - Doc 00$/, msg)
      assert_match(/^20 - Doc 19$/, msg, "per-page numbering goes 1..PAGE_SIZE")
    end

    test "render(:all) on the last page hides `+` and shows `-`" do
      (WhatsappDocumentPicker::PAGE_SIZE + 2).times do |i|
        KbDocument.create!(s3_key: "k-#{i}", display_name: "Doc #{i}")
      end
      page = WhatsappDocumentPicker.list(source: :all, page: 2)
      msg  = WhatsappDocumentPicker.render(page: page, source: :all, locale: :es)

      assert_match(/Página 2\/2/, msg)
      assert_no_match(/siguiente página/, msg, "no `+` line on the last page")
      assert_match(/^- - página anterior$/, msg)
    end

    test "render(:all) with a single page shows no page indicator and no `+`/`-`" do
      3.times { |i| KbDocument.create!(s3_key: "k-#{i}", display_name: "Doc #{i}") }
      page = WhatsappDocumentPicker.list(source: :all, page: 1)
      msg  = WhatsappDocumentPicker.render(page: page, source: :all, locale: :es)

      assert_no_match(/Página/, msg, "single page → no page indicator")
      assert_no_match(/siguiente página|página anterior/, msg)
      assert_match(/^0 - atrás$/, msg)
    end

    test "render(:recent) never emits page indicator nor `+`/`-`" do
      to = "whatsapp:+56911112222"
      (WhatsappDocumentPicker::RECENT_LIMIT + 4).times do |i|
        TechnicianDocument.create!(
          identifier:     to,
          channel:        "whatsapp",
          canonical_name: "Recent #{i}",
          last_used_at:   i.minutes.ago
        )
      end
      page = WhatsappDocumentPicker.list(source: :recent, page: 1)
      msg  = WhatsappDocumentPicker.render(page: page, source: :recent, locale: :es)

      assert_no_match(/Página \d+\/\d+/, msg)
      assert_no_match(/siguiente página|página anterior/, msg)
    end

    test "render(empty page) emits placeholder + bare nav (back + home)" do
      page = WhatsappDocumentPicker.list(source: :all, page: 1)
      msg  = WhatsappDocumentPicker.render(page: page, source: :all, locale: :es)

      assert_includes msg, "No hay archivos disponibles en esta lista."
      assert_match(/^0 - atrás$/, msg)
      assert_match(/^inicio - reiniciar$/, msg)
      assert_no_match(/siguiente página|página anterior|Página/, msg)
    end

    test "render uses the back-to-answer label when origin is :faceted_cached" do
      KbDocument.create!(s3_key: "k.pdf", display_name: "Single")
      page = WhatsappDocumentPicker.list(source: :all, page: 1)
      msg  = WhatsappDocumentPicker.render(
        page: page, source: :all, locale: :es,
        origin: WhatsappPostResetState::ORIGIN_FACETED_CACHED
      )
      assert_match(/^0 - volver al resultado$/, msg)
    end
  end
end
