# frozen_string_literal: true

require "test_helper"

class AccountHostResolverTest < ActiveSupport::TestCase
  test "resolves production hosts to account slugs" do
    assert_equal accounts(:legacy), AccountHostResolver.account_for("elevator.danebo.ai")
    assert_equal accounts(:legacy), AccountHostResolver.account_for("danebo.ai")
    assert_equal accounts(:legacy), AccountHostResolver.account_for("www.danebo.ai")
    assert_equal accounts(:climb), AccountHostResolver.account_for("ascensoresclimb.danebo.ai")
    assert_equal accounts(:pilot), AccountHostResolver.account_for("piloto.danebo.ai")
  end

  # A host in the map that kamal-proxy does not terminate TLS for is unreachable;
  # a host in proxy.hosts with no mapping 404s on every request. Asserted against
  # the example because the real config/deploy.yml is gitignored.
  test "every production host is declared in the Kamal proxy host list" do
    proxy_hosts = YAML.load_file(Rails.root.join("config/deploy.yml.example")).dig("proxy", "hosts")

    assert_equal AccountHosts::PRODUCTION.keys.sort, proxy_hosts.sort
  end

  test "resolves localhost to danebo-legacy in non-production" do
    assert_equal accounts(:legacy), AccountHostResolver.account_for("localhost")
  end

  test "resolves Rails default test host to danebo-legacy" do
    assert_equal accounts(:legacy), AccountHostResolver.account_for("www.example.com")
  end

  test "returns nil for unknown host" do
    assert_nil AccountHostResolver.account_for("chat.danebo.ai")
    assert_nil AccountHostResolver.account_for("evil.example.com")
  end

  test "allowed_hosts matches active map keys" do
    assert_includes AccountHostResolver.allowed_hosts, "danebo.ai"
    assert_includes AccountHostResolver.allowed_hosts, "www.danebo.ai"
    assert_includes AccountHostResolver.allowed_hosts, "elevator.danebo.ai"
    assert_includes AccountHostResolver.allowed_hosts, "ascensoresclimb.danebo.ai"
    assert_includes AccountHostResolver.allowed_hosts, "localhost"
    assert_not_includes AccountHostResolver.allowed_hosts, "chat.danebo.ai"
  end

  test "host_map uses PRODUCTION keys only when stubbed as production map" do
    original = AccountHostResolver.method(:host_map)
    AccountHostResolver.define_singleton_method(:host_map) { AccountHosts::PRODUCTION }
    begin
      assert_equal "danebo-legacy", AccountHostResolver.host_map["elevator.danebo.ai"]
      assert_nil AccountHostResolver.host_map["localhost"]
    ensure
      AccountHostResolver.define_singleton_method(:host_map, original)
    end
  end
end
