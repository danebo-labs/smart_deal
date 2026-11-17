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

  test "the flag off does not open a case" do
    disable_history!
    result = open_text(accounts(:legacy), users(:one), SecureRandom.uuid, "sub-off", "hola")

    assert result.disabled?
    assert_equal 0, FieldCase.count
  end

  private

  def open_text(account, user, key, submission, message)
    FieldCases::OpenText.call(
      account:, user:, creation_key: key, client_submission_id: submission, message:
    )
  end
end
