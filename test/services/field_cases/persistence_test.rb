# frozen_string_literal: true

require "test_helper"
require_relative "../../support/field_case_history_helper"

class FieldCases::PersistenceTest < ActiveSupport::TestCase
  include FieldCaseHistoryHelper
  include ActiveJob::TestHelper

  setup { enable_history! }
  teardown { disable_history! }

  test "history stays on for a personal session when the env is absent or false" do
    [ nil, "false", "FALSE", "TRUE", "1", "true" ].each do |value|
      isolate_env("FIELD_CASE_HISTORY_ENABLED", value) do
        assert FieldCaseHistoryFlag.enabled?(shared_session: false), value.inspect
        assert_not FieldCaseHistoryFlag.enabled?(shared_session: true), value.inspect
      end
    end
  end

  test "a new case starts with no pins and a repeated creation key returns it" do
    account = accounts(:legacy)
    user = users(:one)
    key = SecureRandom.uuid
    first = FieldCases::Create.call(account:, user:, creation_key: key)
    pins = [ pin(11, "CEA15+"), pin(12, "Monarch") ]
    assert FieldCases::Pins.call(account:, user:, field_case_id: first.field_case.id, pins:).ok?

    second = FieldCases::Create.call(account:, user:, creation_key: key)
    fresh = FieldCases::Create.call(account:, user:)

    assert first.created?
    assert_not second.created?
    assert_equal first.field_case.id, second.field_case.id
    assert_equal [ 11, 12 ], second.field_case.reload.document_focus.pluck("kb_document_id")
    assert_equal [], fresh.field_case.document_focus
    assert_not_equal first.field_case.episode_id, fresh.field_case.episode_id
    assert_equal 0, fresh.field_case.state_revision
    assert_nil fresh.field_case.title
  end

  test "pins stay on their own case" do
    account = accounts(:legacy)
    user = users(:one)
    first = open_case
    second = open_case
    left = [ pin(3, "Manual A"), pin(4, "Manual B") ]
    right = [ pin(9, "Manual C") ]

    assert FieldCases::Pins.call(account:, user:, field_case_id: first.id, pins: left).ok?
    assert FieldCases::Pins.call(account:, user:, field_case_id: second.id, pins: right).ok?

    assert_equal [ 3, 4 ], first.reload.document_focus.pluck("kb_document_id")
    assert_equal [ "Manual A", "Manual B" ], first.document_focus.pluck("display_name")
    assert_equal [ 9 ], second.reload.document_focus.pluck("kb_document_id")
    assert first.document_focus.none? { |entry| entry.values.any? { |value| value.to_s.match?(/X-Amz-|https?:/i) } }
    assert_equal 0, first.state_revision
  end

  test "a technician cannot read or pin another technician or another account" do
    owner_case = open_case
    other_case = open_case(account: accounts(:climb), user: users(:two))
    other_user = colleague
    FieldCases::Pins.call(
      account: accounts(:legacy), user: users(:one), field_case_id: owner_case.id, pins: [ pin(1, "Solo") ]
    )

    assert_empty FieldCases::Read.list(account: accounts(:legacy), user: other_user).payload.fetch("cases")
    assert FieldCases::Read.fetch(account: accounts(:legacy), user: other_user, field_case_id: owner_case.id).not_found?
    assert FieldCases::Read.turn(
      account: accounts(:legacy), user: other_user, field_case_id: owner_case.id, turn_id: 1
    ).not_found?
    assert FieldCases::Pins.call(
      account: accounts(:legacy), user: other_user, field_case_id: owner_case.id, pins: [ pin(8, "Ajeno") ]
    ).not_found?
    assert_equal [ 1 ], owner_case.reload.document_focus.pluck("kb_document_id")

    listed = FieldCases::Read.list(account: accounts(:climb), user: users(:two)).payload.fetch("cases")
    assert_equal [ other_case.id ], listed.pluck("id")
    assert FieldCases::Read.fetch(account: accounts(:legacy), user: users(:one), field_case_id: other_case.id).not_found?
    assert FieldCases::AdmitTurn.call(
      account: accounts(:legacy), user: other_user, field_case_id: owner_case.id,
      client_submission_id: "sub-foreign", message: "no"
    ).not_found?
  end

  test "the same submission key replays and a different input conflicts before a busy rejection" do
    kase = open_case
    first = admit(kase, message: "lectura KP-VS", client_submission_id: "sub-same")
    replay = admit(kase, message: "lectura KP-VS", client_submission_id: "sub-same")
    changed = admit(kase, message: "otra lectura", client_submission_id: "sub-same")
    busy = admit(kase, message: "siguiente", client_submission_id: "sub-next")

    assert first.ok?
    assert replay.ok?
    assert_equal first.turn.id, replay.turn.id
    assert_equal 1, kase.reload.last_sequence
    assert_equal 1, kase.field_turns.count
    assert changed.conflict?
    assert_equal :submission_reused, changed.error
    assert_equal "lectura KP-VS", first.turn.reload.message
    assert busy.conflict?
    assert_equal :case_busy, busy.error
    assert_equal first.turn.id, busy.turn.id
    assert_equal 1, kase.field_turns.count
  end

  test "case A and case B each keep their own pending turn" do
    case_a = open_case
    case_b = open_case
    pending_a = admit(case_a, message: "caso A", client_submission_id: "sub-a")
    pending_b = admit(case_b, message: "caso B", client_submission_id: "sub-b")

    assert pending_a.ok?
    assert pending_b.ok?
    assert_equal [ "caso A" ], case_a.field_turns.order(:sequence).pluck(:message)
    assert_equal [ "caso B" ], case_b.field_turns.order(:sequence).pluck(:message)
    assert_equal 1, pending_a.turn.sequence
    assert_equal 1, pending_b.turn.sequence
    assert_not_equal pending_a.turn.correlation_id, pending_b.turn.correlation_id
  end

  test "pins do not change while a turn is pending and a read only case does not admit" do
    kase = open_case
    admit(kase, client_submission_id: "sub-busy")
    blocked = FieldCases::Pins.call(
      account: accounts(:legacy), user: users(:one), field_case_id: kase.id, pins: [ pin(5, "Tarde") ]
    )
    kase.update!(mode: "read_only")
    refused = admit(kase, message: "nuevo", client_submission_id: "sub-after")

    assert blocked.conflict?
    assert_equal :case_busy, blocked.error
    assert_equal [], kase.reload.document_focus
    assert_equal "pending", kase.field_turns.sole.status
    assert refused.conflict?
    assert_equal :not_resumable, refused.error
  end

  test "a photo from another account is rejected and the same key with another photo conflicts" do
    kase = open_case
    own = field_photo_for(accounts(:legacy))
    foreign = field_photo_for(accounts(:climb))
    missing = admit(kase, kind: "photo", message: "", field_photo_id: foreign.id, client_submission_id: "sub-photo")
    admitted = admit(kase, kind: "photo", message: "que es esto", field_photo_id: own.id, client_submission_id: "sub-photo")
    other = field_photo_for(accounts(:legacy))
    changed = admit(kase, kind: "photo", message: "que es esto", field_photo_id: other.id, client_submission_id: "sub-photo")

    assert missing.invalid?
    assert admitted.ok?
    assert_equal 1, kase.field_turns.count
    assert_equal own.id, admitted.turn.field_photo_id
    assert_equal own.sha256, admitted.turn.attachment["sha256"]
    assert changed.conflict?
    assert_equal :submission_reused, changed.error
    assert_equal own.id, admitted.turn.reload.field_photo_id
  end

  test "closing stores one result and a later candidate keeps that result and revision" do
    case_a = open_case
    case_b = open_case
    FieldCases::Pins.call(
      account: accounts(:legacy), user: users(:one), field_case_id: case_a.id,
      pins: [ pin(21, "Manual A"), pin(22, "Manual A2") ]
    )
    pending_b = admit(case_b, message: "trabajo B", client_submission_id: "sub-b")
    turn = admit(case_a, message: "trabajo A", client_submission_id: "sub-a").turn
    citations = [ { "document_uid" => SecureRandom.uuid, "page" => 12, "marker" => "A" } ]
    state = { "goal" => { "text" => "Freno de cabina" }, "marker" => "A" }
    winner = close_turn(
      case_a, turn,
      published_text: "A",
      citations:,
      state:,
      prompt_reply: "A corto",
      checkpoint: { "card" => "A" }
    )
    late = close_turn(
      case_a, turn,
      published_text: "B",
      citations: [ { "page" => 99, "marker" => "B" } ],
      state: { "marker" => "B" },
      checkpoint: { "card" => "B" },
      prompt_reply: "B corto",
      expected_state_revision: 0
    )
    stored = FieldCases::Read.turn(
      account: accounts(:legacy), user: users(:one), field_case_id: case_a.id, turn_id: turn.id
    )

    assert winner.ok?
    assert late.lost?
    assert_equal "A", stored.payload.dig("turn", "response", "published_text")
    assert_equal citations, stored.payload.dig("turn", "response", "citations")
    assert_equal "A corto", stored.payload.dig("turn", "prompt_reply")
    assert_equal "A", stored.payload.dig("turn", "checkpoint", "card")
    assert_equal 1, stored.payload.dig("turn", "result_state_revision")
    assert_equal 1, stored.payload.dig("case", "state_revision")
    assert_equal "A", stored.payload.dig("case", "technical_state", "marker")
    assert_equal "Freno de cabina", case_a.reload.title
    assert_equal [ 21, 22 ], case_a.document_focus.pluck("kb_document_id")
    assert_equal "pending", pending_b.turn.reload.status
    assert_equal 0, case_b.reload.state_revision
    assert_not stored.payload.fetch("turn").key?("execution_token")
    assert_not stored.payload.fetch("turn").key?("input_digest")
  end

  test "a stale revision, attempt or token does not publish" do
    kase = open_case
    turn = admit(kase, client_submission_id: "sub-stale").turn

    revision = close_turn(kase, turn, expected_state_revision: 4, published_text: "no")
    attempt = close_turn(kase, turn, attempt: 2, published_text: "no")
    token = close_turn(kase, turn, execution_token: SecureRandom.uuid, published_text: "no")

    assert revision.lost?
    assert attempt.lost?
    assert token.lost?
    assert_equal "pending", turn.reload.status
    assert_nil turn.response
    assert_equal 0, kase.reload.state_revision
  end

  test "a failed close keeps the previous technical state and rejects a late success" do
    kase = open_case
    kase.update!(technical_state: { "marker" => "keep" })
    turn = admit(kase, client_submission_id: "sub-fail").turn
    failed = close_turn(
      kase, turn,
      outcome: "failed",
      response: nil,
      technical_state: nil,
      failure_code: "technical",
      failure_stage: "technical"
    )
    late = close_turn(
      kase, turn,
      published_text: "tarde",
      state: { "marker" => "late" },
      expected_state_revision: 0
    )
    reloaded = FieldCases::Read.turn(
      account: accounts(:legacy), user: users(:one), field_case_id: kase.id, turn_id: turn.id
    )

    assert failed.ok?
    assert late.lost?
    assert_equal "failed", reloaded.payload.dig("turn", "status")
    assert_equal "technical", reloaded.payload.dig("turn", "failure_code")
    assert_nil reloaded.payload.dig("turn", "response")
    assert_equal "keep", reloaded.payload.dig("case", "technical_state", "marker")
    assert_equal 1, reloaded.payload.dig("case", "state_revision")
  end

  test "turns reload in sequence with pending, completed and failed rows" do
    kase = open_case
    first = admit(kase, message: "uno", client_submission_id: "sub-1").turn
    close_turn(kase, first, published_text: "listo", citations: [ { "page" => 2 } ])
    second = admit(kase, message: "dos", client_submission_id: "sub-2").turn
    close_turn(kase, second, outcome: "failed", response: nil, technical_state: nil, failure_code: "vision")
    third = admit(kase, message: "tres", client_submission_id: "sub-3")
    assert third.ok?

    page = FieldCases::Read.fetch(
      account: accounts(:legacy), user: users(:one), field_case_id: kase.id, limit: 2
    )
    rest = FieldCases::Read.fetch(
      account: accounts(:legacy), user: users(:one), field_case_id: kase.id,
      after_sequence: page.payload.fetch("next_after_sequence"), limit: 2
    )

    assert_equal [ 1, 2 ], page.payload.fetch("turns").pluck("sequence")
    assert_equal [ "completed", "failed" ], page.payload.fetch("turns").pluck("status")
    assert_equal "listo", page.payload.dig("turns", 0, "response", "published_text")
    assert_equal [ { "page" => 2 } ], page.payload.dig("turns", 0, "response", "citations")
    assert_equal [ 3 ], rest.payload.fetch("turns").pluck("sequence")
    assert_equal "pending", rest.payload.dig("turns", 0, "status")
    assert_nil rest.payload.fetch("next_after_sequence")
  end

  test "case pages follow activity and break ties by id" do
    older = open_case
    newer = open_case
    same_time = Time.zone.parse("2026-11-16 15:00:00")
    older.update!(last_activity_at: same_time)
    newer.update!(last_activity_at: same_time)
    first_id, second_id = [ older.id, newer.id ].sort.reverse

    page = FieldCases::Read.list(account: accounts(:legacy), user: users(:one), limit: 1)
    follow = FieldCases::Read.list(
      account: accounts(:legacy), user: users(:one), cursor: page.payload.fetch("next_cursor"), limit: 1
    )

    assert_equal [ first_id ], page.payload.fetch("cases").pluck("id")
    assert_equal [ second_id ], follow.payload.fetch("cases").pluck("id")
    assert_nil follow.payload.fetch("next_cursor")
  end

  test "oversized or signed state and an oversized message do not write" do
    kase = open_case
    turn = admit(kase, client_submission_id: "sub-size").turn
    huge = close_turn(kase, turn, state: { "blob" => "x" * 40_000 })
    signed = close_turn(kase, turn, state: { "note" => "https://bucket.s3.amazonaws.com/a?X-Amz-Signature=abc" })
    long_message = admit(kase, message: "m" * (ConversationSession::USER_TEXT_MAX_CHARS + 1), client_submission_id: "sub-long")

    assert huge.invalid?
    assert signed.invalid?
    assert long_message.invalid?
    assert_equal "pending", turn.reload.status
    assert_nil turn.response
    assert_equal({}, kase.reload.technical_state)
    assert_equal 1, kase.field_turns.count
  end

  test "admission and close do not enqueue jobs" do
    kase = open_case
    assert_no_enqueued_jobs do
      turn = admit(kase, client_submission_id: "sub-job").turn
      close_turn(kase, turn, published_text: "sin job")
    end
  end

  test "a shared session refuses create, read, admit, close and pins without writing" do
    kase = open_case
    turn = admit(kase, client_submission_id: "sub-flag").turn
    account = accounts(:legacy)
    user = users(:one)
    before = FieldCase.count

    created = listed = fetched = admitted = closed = pinned = nil
    with_shared_session(true) do
      created = FieldCases::Create.call(account:, user:)
      listed = FieldCases::Read.list(account:, user:)
      fetched = FieldCases::Read.fetch(account:, user:, field_case_id: kase.id)
      admitted = admit(kase, message: "apagado", client_submission_id: "sub-off")
      closed = close_turn(kase, turn, published_text: "apagado")
      pinned = FieldCases::Pins.call(account:, user:, field_case_id: kase.id, pins: [ pin(1, "No") ])
    end

    assert created.disabled?
    assert listed.disabled?
    assert fetched.disabled?
    assert admitted.disabled?
    assert closed.disabled?
    assert pinned.disabled?
    assert_equal before, FieldCase.count
    assert_equal "pending", turn.reload.status
    assert_nil turn.response
    assert_equal [], kase.reload.document_focus
  end
end
