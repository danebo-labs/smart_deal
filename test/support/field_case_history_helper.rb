# frozen_string_literal: true

module FieldCaseHistoryHelper
  # The env no longer gates history. These helpers keep older tests from
  # leaking a value into the next example.
  def enable_history!
    ENV.delete("FIELD_CASE_HISTORY_ENABLED")
  end

  def disable_history!
    ENV.delete("FIELD_CASE_HISTORY_ENABLED")
  end

  def with_shared_session(enabled)
    original = SharedSession::ENABLED
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, enabled)
    yield
  ensure
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, original)
  end

  def open_case(account: accounts(:legacy), user: users(:one), creation_key: nil)
    result = FieldCases::Create.call(account:, user:, creation_key:)
    assert result.ok?, result.error.inspect
    result.field_case
  end

  def admit(kase, message: "hola", client_submission_id: nil, **extra)
    FieldCases::AdmitTurn.call(
      account: kase.account,
      user: kase.user,
      field_case_id: kase.id,
      client_submission_id: client_submission_id || "sub-#{SecureRandom.hex(8)}",
      message:,
      **extra
    )
  end

  def close_turn(kase, turn, published_text: "respuesta", citations: [ { "page" => 4 } ],
                 state: { "v" => 1 }, outcome: "completed", expected_state_revision: nil,
                 execution_token: nil, attempt: nil, **extra)
    response = extra.key?(:response) ? extra.delete(:response) : {
      "published_text" => published_text,
      "citations" => citations
    }
    FieldCases::CloseTurn.call(
      account: kase.account,
      user: kase.user,
      field_case_id: kase.id,
      turn_id: turn.id,
      attempt: attempt || turn.attempt,
      execution_token: execution_token || turn.execution_token,
      expected_state_revision: expected_state_revision.nil? ? kase.reload.state_revision : expected_state_revision,
      outcome:,
      response:,
      technical_state: extra.key?(:technical_state) ? extra.delete(:technical_state) : state,
      **extra
    )
  end

  def pin(id, name)
    { "kb_document_id" => id, "document_uid" => SecureRandom.uuid, "display_name" => name }
  end

  def field_photo_for(account, sha: SecureRandom.hex(32))
    FieldPhoto.create!(
      account:,
      sha256: sha,
      s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 12
    )
  end

  def colleague
    User.create!(
      email: "colleague-#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      account: accounts(:legacy)
    )
  end
end
