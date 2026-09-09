# frozen_string_literal: true

require "test_helper"
require "rake"

# Assigning the owner of a company's issuer identity is an explicit operation.
# These tests exist so the onboarding command in the closure stays honest: it
# must refuse the wrong pair instead of silently creating a cross-tenant link.
class CertifierSettingsOwnerTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:legacy)
    @user    = users(:one)

    # Own Rake application, restored afterwards, so loading the task file does
    # not leave the shared one holding a half-populated task list.
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/certifier.rake")
  end

  teardown do
    Rake.application = @previous_rake
  end

  def invoke(name, *args)
    task = Rake::Task[name]
    task.reenable
    task.invoke(*args)
  end

  test "assigns the owner of an account" do
    invoke("certifier:settings_owner", @account.slug, @user.email)

    assert_equal @user.id, @account.reload.certifier_settings_user_id
  end

  # The cross-tenant pair is the mistake worth failing loudly on.
  test "refuses a user from another account" do
    assert_raises(SystemExit) { invoke("certifier:settings_owner", @account.slug, users(:two).email) }

    assert_nil @account.reload.certifier_settings_user_id
  end

  test "refuses an unknown account or user" do
    assert_raises(SystemExit) { invoke("certifier:settings_owner", "no-such-account", @user.email) }
    assert_raises(SystemExit) { invoke("certifier:settings_owner", @account.slug, "nobody@example.com") }
    assert_nil @account.reload.certifier_settings_user_id
  end

  test "refuses missing arguments" do
    assert_raises(SystemExit) { invoke("certifier:settings_owner", @account.slug, "") }
  end

  test "clearing the owner leaves the configuration read-only" do
    @account.update!(certifier_settings_user: @user)

    invoke("certifier:settings_owner:clear", @account.slug)

    @account.reload
    assert_nil @account.certifier_settings_user_id
    assert_not @account.certifier_settings_manager?(@user)
  end
end
