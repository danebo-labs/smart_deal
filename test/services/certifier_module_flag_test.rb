# frozen_string_literal: true

require "test_helper"

class CertifierModuleFlagTest < ActiveSupport::TestCase
  test "disabled by default" do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    assert_not CertifierModuleFlag.enabled?
  end

  test "enabled only when the ENV var is exactly the string true" do
    ENV["CERTIFIER_MODULE_ENABLED"] = "true"
    assert CertifierModuleFlag.enabled?
  ensure
    ENV.delete("CERTIFIER_MODULE_ENABLED")
  end

  test "any other value stays disabled" do
    ENV["CERTIFIER_MODULE_ENABLED"] = "1"
    assert_not CertifierModuleFlag.enabled?
  ensure
    ENV.delete("CERTIFIER_MODULE_ENABLED")
  end
end
