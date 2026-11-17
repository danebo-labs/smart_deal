# frozen_string_literal: true

require "test_helper"
require_relative "../support/field_case_history_helper"

class FieldCaseTest < ActiveSupport::TestCase
  include FieldCaseHistoryHelper

  setup { enable_history! }
  teardown { disable_history! }

  test "a case cannot belong to a user from another account" do
    assert_raises(ActiveRecord::RecordInvalid) do
      FieldCase.create!(
        account: accounts(:climb),
        user: users(:one),
        episode_id: FieldCase.generate_episode_id,
        mode: "resumable",
        opened_at: Time.current,
        last_activity_at: Time.current,
        schema_version: 1,
        state_revision: 0,
        last_sequence: 0,
        technical_state: {},
        document_focus: []
      )
    end
  end

  test "a pending turn cannot store a response" do
    kase = open_case
    turn = admit(kase).turn

    assert_raises(ActiveRecord::StatementInvalid) do
      FieldTurn.transaction(requires_new: true) do
        turn.update_columns(response: { "published_text" => "tarde" }, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    assert_nil turn.reload.response
    assert_equal "pending", turn.status
  end

  test "an imported partial turn can be stored without a published answer" do
    kase = open_case
    turn = FieldTurn.create!(
      field_case: kase,
      sequence: 1,
      client_submission_id: "hist-1",
      input_digest: "a" * 64,
      correlation_id: "query:#{SecureRandom.uuid}",
      kind: "text",
      message: "consulta vieja",
      attachment: {},
      status: "historical_partial",
      phase: "imported",
      attempt: 1,
      execution_token: SecureRandom.uuid,
      base_state_revision: 0,
      admitted_at: Time.current,
      completed_at: Time.current
    )

    assert_equal "historical_partial", turn.status
    assert_nil turn.response
  end
end
