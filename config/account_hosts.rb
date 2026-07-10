# frozen_string_literal: true

# Host → Account.slug map (single source of truth for tenant routing).
# Required early from production.rb for config.hosts; also loaded by the initializer.
module AccountHosts
  PRODUCTION = {
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
