# frozen_string_literal: true

require "test_helper"

# The issuer identity of a company (a company is an account) and who is allowed
# to edit it.
class AccountCertifierSettingsTest < ActiveSupport::TestCase
  setup do
    @configured   = accounts(:climb)
    @unconfigured = accounts(:legacy)
  end

  test "certifier_identified? needs both the name and the MINVU role" do
    assert @configured.certifier_identified?
    assert_not @unconfigured.certifier_identified?

    @unconfigured.certifier_name = "Solo nombre"
    assert_not @unconfigured.certifier_identified?, "a name without a MINVU role is not an identity"
  end

  test "certifier_logo? reflects the stored key" do
    assert @configured.certifier_logo?
    assert_not @unconfigured.certifier_logo?
  end

  test "only the designated user manages the settings" do
    owner    = users(:two)
    outsider = User.create!(email: "third-#{SecureRandom.hex(4)}@example.com", password: "password123", account: @configured)

    assert @configured.certifier_settings_manager?(owner)
    assert_not @configured.certifier_settings_manager?(outsider), "a colleague of the same company is not the owner"
    assert_not @configured.certifier_settings_manager?(nil)
  end

  # An account with nobody assigned is read-only for everyone: the first visitor
  # does not get to claim the company's identity.
  test "an account without a designated user has no manager at all" do
    assert_nil @unconfigured.certifier_settings_user_id
    assert_not @unconfigured.certifier_settings_manager?(users(:one))
  end

  test "rejects a designated user from another account" do
    @configured.certifier_settings_user = users(:one)

    assert_not @configured.valid?
    assert_includes @configured.errors.attribute_names, :certifier_settings_user
  end

  # Removing the designated user degrades the account to read-only instead of
  # blocking the delete or leaving a dangling pointer.
  test "deleting the designated user nullifies the reference" do
    owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", password: "password123", account: @configured)
    @configured.update!(certifier_settings_user: owner)

    owner.destroy!

    assert_nil @configured.reload.certifier_settings_user_id
  end

  # Old accounts predate this configuration entirely.
  test "an unconfigured account is valid and its reports still work" do
    assert @unconfigured.valid?
    assert_predicate certification_reports(:torre_amunategui), :persisted?
  end
end
