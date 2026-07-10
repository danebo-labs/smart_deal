# frozen_string_literal: true

# Host → Account.slug map (single source of truth for tenant routing).
# Required early from production.rb for config.hosts; also loaded by the initializer.
#
# danebo.ai / www.danebo.ai temporarily serve the app (danebo-legacy) until the
# marketing landing is ready; then remove them from proxy.hosts + this map.
module AccountHosts
  PRODUCTION = {
    "danebo.ai"                 => "danebo-legacy",
    "www.danebo.ai"             => "danebo-legacy",
    "elevator.danebo.ai"        => "danebo-legacy",
    "ascensoresclimb.danebo.ai" => "elevadores-climb"
  }.freeze

  # www.example.com / example.com: Rails default integration-test host.
  DEVELOPMENT = PRODUCTION.merge(
    "localhost"        => "danebo-legacy",
    "www.example.com"  => "danebo-legacy",
    "example.com"      => "danebo-legacy"
  ).freeze
end
