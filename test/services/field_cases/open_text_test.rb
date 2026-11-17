# frozen_string_literal: true

require "test_helper"
require_relative "../../support/field_case_history_helper"

class FieldCases::OpenTextTest < ActiveSupport::TestCase
  include FieldCaseHistoryHelper

  setup { enable_history! }
  teardown { disable_history! }

  test "the first text opens one case and a repeated submission returns that turn" do
    account = accounts(:legacy)
    user = users(:one)
    key = SecureRandom.uuid
    first = open_text(account, user, key, "sub-once", "El motor suena")
    replay = open_text(account, user, key, "sub-once", "El motor suena")
    changed = open_text(account, user, key, "sub-once", "Otro texto")
    busy = open_text(account, user, key, "sub-next", "Siguiente")

    assert first.created?
    assert_not replay.created?
    assert_equal first.field_case.id, replay.field_case.id
    assert_equal first.turn.id, replay.turn.id
    assert_equal "El motor suena", first.turn.message
    assert_equal [], first.field_case.document_focus
    assert changed.conflict?
    assert_equal :submission_reused, changed.error
    assert busy.conflict?
    assert_equal :case_busy, busy.error
    assert_equal 1, FieldCase.count
    assert_equal 1, FieldTurn.count
    assert_equal "pending", first.turn.reload.status
  end

  test "a rejected admission and a blank message leave no case" do
    account = accounts(:legacy)
    user = users(:one)
    refused = FieldCases::Result.new(:invalid, error: :message)

    assert_no_difference("FieldCase.count") do
      blank = open_text(account, user, SecureRandom.uuid, "sub-blank", "  ")
      assert blank.invalid?
      assert_equal :message, blank.error

      singleton = FieldCases::AdmitTurn.singleton_class
      original = singleton.instance_method(:call)
      singleton.define_method(:call) { |**| refused }
      begin
        rejected = open_text(account, user, SecureRandom.uuid, "sub-rejected", "hola")
        assert rejected.invalid?
        assert_equal :message, rejected.error
        assert_nil rejected.field_case
      ensure
        singleton.define_method(:call, original)
      end
    end
  end

  test "manuals chosen before the first text stay on that case" do
    document = KbDocument.create!(
      account: accounts(:legacy), s3_key: "uploads/2026/thyssen-opening.pdf",
      display_name: "Thyssen", aliases: []
    )
    key = SecureRandom.uuid
    opened = open_text(accounts(:legacy), users(:one), key, "sub-pin", "el motor suena", document_ids: [ document.id.to_s ])
    replay = open_text(accounts(:legacy), users(:one), key, "sub-pin", "el motor suena", document_ids: [])

    assert opened.created?, opened.error.inspect
    assert_equal [ document.id ], opened.field_case.reload.document_focus.pluck("kb_document_id")
    assert_equal [ document.document_uid ], opened.field_case.document_focus.pluck("document_uid")
    assert_not replay.created?
    assert_equal [ document.id ], replay.field_case.reload.document_focus.pluck("kb_document_id")
    assert_equal 1, FieldCase.count
  end

  test "an unknown manual does not leave a case" do
    missing = open_text(accounts(:legacy), users(:one), SecureRandom.uuid, "sub-missing", "hola", document_ids: [ 9_000_000_001 ])
    malformed = open_text(accounts(:legacy), users(:one), SecureRandom.uuid, "sub-bad", "hola", document_ids: [ "no" ])

    assert missing.not_found?
    assert malformed.invalid?
    assert_equal :pins, malformed.error
    assert_equal 0, FieldCase.count
  end

  test "a shared session does not open a case" do
    result = nil
    with_shared_session(true) do
      result = open_text(accounts(:legacy), users(:one), SecureRandom.uuid, "sub-shared", "hola")
    end

    assert result.disabled?
    assert_equal 0, FieldCase.count
  end

  test "an absent or false env still opens a case" do
    [ nil, "false" ].each do |value|
      isolate_env("FIELD_CASE_HISTORY_ENABLED", value) do
        result = open_text(accounts(:legacy), users(:one), SecureRandom.uuid, "sub-#{value}", "hola")
        assert result.created?, result.error.inspect
      end
    end
    assert_equal 2, FieldCase.count
  end

  private

  def open_text(account, user, key, submission, message, document_ids: [])
    FieldCases::OpenText.call(
      account:, user:, creation_key: key, client_submission_id: submission, message:, document_ids:
    )
  end
end
