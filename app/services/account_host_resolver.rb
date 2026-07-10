# frozen_string_literal: true

# Resolves the Account for a request Host header via AccountHosts maps.
class AccountHostResolver
  def self.host_map
    Rails.env.production? ? AccountHosts::PRODUCTION : AccountHosts::DEVELOPMENT
  end

  def self.allowed_hosts
    host_map.keys
  end

  def self.account_for(host)
    slug = host_map[host.to_s]
    return nil if slug.blank?

    Account.find_by(slug: slug)
  end
end
