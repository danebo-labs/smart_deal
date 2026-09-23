# frozen_string_literal: true

require "test_helper"
require "rake"

class FieldCompanionResetTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("field_companion:reset_active_episode")
    @task = Rake::Task["field_companion:reset_active_episode"]
    @account = accounts(:legacy)
    @user = users(:one)
    @user.update!(account: @account)
    @session = ConversationSession.create!(
      account: @account,
      user: @user,
      identifier: "reset-test",
      channel: "web",
      expires_at: 1.day.from_now,
      conversation_history: [ { "role" => "user", "content" => "keep me" } ],
      active_entities: { "manual" => { "source" => "user_pin" } },
      active_episode: { "v" => 1, "episode_id" => "ep_reset_me" }
    )
    @other = ConversationSession.create!(
      account: accounts(:pilot),
      user: users(:two),
      identifier: "other-account",
      channel: "web",
      expires_at: 1.day.from_now,
      active_episode: { "v" => 1, "episode_id" => "ep_keep_me" }
    )
    @original_apply = ENV.delete("APPLY")
  end

  teardown do
    @task.reenable
    @original_apply.nil? ? ENV.delete("APPLY") : ENV["APPLY"] = @original_apply
  end

  test "dry run reports the exact scope and changes nothing" do
    output = capture_io { @task.invoke(@account.slug, @user.email) }.first

    assert_includes output, "DRY RUN"
    assert_equal "ep_reset_me", @session.reload.active_episode["episode_id"]
    assert_equal "ep_keep_me", @other.reload.active_episode["episode_id"]
  end

  test "apply clears only active_episode for the matching account user and is idempotent" do
    history = @session.conversation_history.deep_dup
    entities = @session.active_entities.deep_dup
    expires_at = @session.expires_at
    updated_at = @session.updated_at
    ENV["APPLY"] = "true"

    first = capture_io { @task.invoke(@account.slug, @user.email) }.first
    @task.reenable
    second = capture_io { @task.invoke(@account.slug, @user.email) }.first

    @session.reload
    assert_includes first, "RESET: cleared active_episode in 1 session(s)"
    assert_includes second, "RESET: cleared active_episode in 0 session(s)"
    assert_equal({}, @session.active_episode)
    assert_equal history, @session.conversation_history
    assert_equal entities, @session.active_entities
    assert_equal expires_at, @session.expires_at
    assert_equal updated_at, @session.updated_at
    assert_equal "ep_keep_me", @other.reload.active_episode["episode_id"]
  end
end
