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
    slug = host_map[host.to_s] || dev_tunnel_fallback_slug
    return nil if slug.blank?

    Account.find_by(slug: slug)
  end

  # Opt-in escape hatch for phone testing over an HTTPS tunnel (ngrok,
  # localhost.run): the tunnel's hostname is never in AccountHosts::DEVELOPMENT
  # (it changes every session), so without this every request 404s. Only fires
  # in development, and only when explicitly set for that session — never a
  # silent default, and structurally unreachable in production regardless of
  # env vars leaking in (host_map is already PRODUCTION there).
  def self.dev_tunnel_fallback_slug
    return nil unless Rails.env.development?

    ENV["DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG"]
  end
  private_class_method :dev_tunnel_fallback_slug
end
