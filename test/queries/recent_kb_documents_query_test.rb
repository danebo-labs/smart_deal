# frozen_string_literal: true

require "test_helper"

class RecentKbDocumentsQueryTest < ActiveSupport::TestCase
  setup do
    KbDocument.delete_all
    @account = accounts(:legacy)
    @other_account = accounts(:climb)
  end

  test "returns the most recent N rows on page 0 and reports has_more=false when fewer than per_page+1" do
    3.times { |i| create_doc("uploads/2026-04/k#{i}.pdf", "k#{i}") }

    docs, has_more = RecentKbDocumentsQuery.page(0, per_page: 5, account: @account)
    assert_equal 3, docs.size
    assert_not has_more, "fewer than per_page rows must report no further pages"
  end

  test "exactly per_page rows reports has_more=false (boundary)" do
    5.times { |i| create_doc("uploads/b/p#{i}.pdf", "p#{i}") }

    docs, has_more = RecentKbDocumentsQuery.page(0, per_page: 5, account: @account)
    assert_equal 5, docs.size
    assert_not has_more, "boundary: count == per_page must NOT trigger another page"
  end

  test "more than per_page rows trims to per_page and reports has_more=true" do
    7.times { |i| create_doc("uploads/m/r#{i}.pdf", "r#{i}") }

    docs, has_more = RecentKbDocumentsQuery.page(0, per_page: 5, account: @account)
    assert_equal 5, docs.size
    assert has_more
  end

  test "ordering is created_at DESC (newest first)" do
    older   = create_doc("uploads/o.pdf", "older", created_at: 2.days.ago)
    newer   = create_doc("uploads/n.pdf", "newer", created_at: 1.day.ago)
    newest  = create_doc("uploads/x.pdf", "newest", created_at: Time.current)

    docs, _has_more = RecentKbDocumentsQuery.page(0, per_page: 10, account: @account)
    assert_equal [ newest, newer, older ], docs
  end

  test "negative or non-numeric page coerces to 0 (no negative offsets)" do
    create_doc("uploads/z.pdf", "z")
    docs, = RecentKbDocumentsQuery.page(-3, per_page: 5, account: @account)
    assert_equal 1, docs.size
    docs2, = RecentKbDocumentsQuery.page("not-a-number", per_page: 5, account: @account)
    assert_equal 1, docs2.size
  end

  test "uses a single SELECT (no separate COUNT)" do
    7.times { |i| create_doc("uploads/c/c#{i}.pdf", "c#{i}") }

    queries = []
    cb = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /\A\s*SELECT/i && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(cb, "sql.active_record") do
      RecentKbDocumentsQuery.page(0, per_page: 5, account: @account)
    end

    assert_equal 0, queries.count { |q| q =~ /\bCOUNT\(/i }, "must NOT issue a COUNT(*) — limit(per_page+1) handles has_more"
  end

  test "returns only documents for the requested account" do
    legacy = create_doc("uploads/legacy/manual.pdf", "Legacy")
    climb = create_doc("uploads/climb/manual.pdf", "Climb", account: @other_account)

    legacy_docs, = RecentKbDocumentsQuery.page(0, per_page: 10, account: @account)
    climb_docs, = RecentKbDocumentsQuery.page(0, per_page: 10, account: @other_account)

    assert_includes legacy_docs, legacy
    assert_not_includes legacy_docs, climb
    assert_includes climb_docs, climb
    assert_not_includes climb_docs, legacy
  end

  private

  def create_doc(s3_key, display_name, account: @account, **attrs)
    KbDocument.create!({ s3_key: s3_key, display_name: display_name, account: account }.merge(attrs))
  end
end
