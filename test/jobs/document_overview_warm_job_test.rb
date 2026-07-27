# frozen_string_literal: true

require "test_helper"

class DocumentOverviewWarmJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  def with_fake_builder
    calls = []
    orig = Rag::DocumentOverviewBuilder.method(:call)
    Rag::DocumentOverviewBuilder.define_singleton_method(:call) { |**kwargs| calls << kwargs; nil }
    yield calls
  ensure
    Rag::DocumentOverviewBuilder.define_singleton_method(:call, orig)
  end

  def make_account
    Account.create!(display_name: "Warm Job Co", slug: "warm-job-#{SecureRandom.hex(4)}")
  end

  test "enqueues on the default queue" do
    assert_enqueued_with(job: DocumentOverviewWarmJob, queue: "default") do
      DocumentOverviewWarmJob.perform_later(account_id: 1, kb_document_id: 2)
    end
  end

  test "does nothing when the kb_document belongs to another account" do
    account = make_account
    other_account = make_account
    doc = KbDocument.create!(account: other_account, s3_key: "uploads/x.pdf", display_name: "X")

    with_fake_builder do |calls|
      DocumentOverviewWarmJob.perform_now(account_id: account.id, kb_document_id: doc.id)
      assert_empty calls
    end
  end

  test "calls the builder with allow_cold_build true for a document owned by the account" do
    account = make_account
    doc = KbDocument.create!(account: account, s3_key: "uploads/x.pdf", display_name: "X")

    with_fake_builder do |calls|
      DocumentOverviewWarmJob.perform_now(account_id: account.id, kb_document_id: doc.id)
      assert_equal 1, calls.size
      assert_equal account, calls.first[:account]
      assert_equal doc, calls.first[:kb_document]
      assert_equal true, calls.first[:allow_cold_build]
    end
  end
end
