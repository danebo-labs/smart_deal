# frozen_string_literal: true

require "test_helper"

class RecentKbDocumentsQueryTest < ActiveSupport::TestCase
  setup do
    KbDocument.delete_all
  end

  test "returns the most recent N rows on page 0 and reports has_more=false when fewer than per_page+1" do
    3.times { |i| KbDocument.create!(s3_key: "uploads/2026-04/k#{i}.pdf", display_name: "k#{i}") }

    docs, has_more = RecentKbDocumentsQuery.page(0, per_page: 5)
    assert_equal 3, docs.size
    assert_not has_more, "fewer than per_page rows must report no further pages"
  end

  test "exactly per_page rows reports has_more=false (boundary)" do
    5.times { |i| KbDocument.create!(s3_key: "uploads/b/p#{i}.pdf", display_name: "p#{i}") }

    docs, has_more = RecentKbDocumentsQuery.page(0, per_page: 5)
    assert_equal 5, docs.size
    assert_not has_more, "boundary: count == per_page must NOT trigger another page"
  end

  test "more than per_page rows trims to per_page and reports has_more=true" do
    7.times { |i| KbDocument.create!(s3_key: "uploads/m/r#{i}.pdf", display_name: "r#{i}") }

    docs, has_more = RecentKbDocumentsQuery.page(0, per_page: 5)
    assert_equal 5, docs.size
    assert has_more
  end

  test "ordering is created_at DESC (newest first)" do
    older   = KbDocument.create!(s3_key: "uploads/o.pdf", display_name: "older",   created_at: 2.days.ago)
    newer   = KbDocument.create!(s3_key: "uploads/n.pdf", display_name: "newer",   created_at: 1.day.ago)
    newest  = KbDocument.create!(s3_key: "uploads/x.pdf", display_name: "newest",  created_at: Time.current)

    docs, _has_more = RecentKbDocumentsQuery.page(0, per_page: 10)
    assert_equal [ newest, newer, older ], docs
  end

  test "negative or non-numeric page coerces to 0 (no negative offsets)" do
    KbDocument.create!(s3_key: "uploads/z.pdf", display_name: "z")
    docs, = RecentKbDocumentsQuery.page(-3, per_page: 5)
    assert_equal 1, docs.size
    docs2, = RecentKbDocumentsQuery.page("not-a-number", per_page: 5)
    assert_equal 1, docs2.size
  end

  test "uses a single SELECT (no separate COUNT)" do
    7.times { |i| KbDocument.create!(s3_key: "uploads/c/c#{i}.pdf", display_name: "c#{i}") }

    queries = []
    cb = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /\A\s*SELECT/i && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(cb, "sql.active_record") do
      RecentKbDocumentsQuery.page(0, per_page: 5)
    end

    assert_equal 0, queries.count { |q| q =~ /\bCOUNT\(/i }, "must NOT issue a COUNT(*) — limit(per_page+1) handles has_more"
  end
end
