# frozen_string_literal: true

# Resolves per-account visual branding (logo/favicon/apple-touch icon paths,
# display name, wordmark visibility) for layouts and auth views.
#
# Static assets by convention (app/assets/images/accounts/<slug>/…,
# public/brands/<slug>/…) — no Active Storage, no DB lookups beyond the
# +branded+ flag on the already-resolved Account (see
# ApplicationController#current_account). Falls back to the default Danebo
# assets whenever +branded+ is false.
class AccountBranding
  DEFAULT_LOGO_PATH        = "logo_mobile.png"
  DEFAULT_DESKTOP_LOGO_PATH = "logo_desktop2.jpg"
  DEFAULT_FAVICON_PATH     = "favicon.png"
  DEFAULT_APPLE_TOUCH_HREF = "/icon-180.png"
  DEFAULT_DISPLAY_NAME     = "Danebo"
  DEFAULT_LOGO_ALT         = "danebo.ai"

  def self.for(account)
    new(account)
  end

  def initialize(account)
    @account = account
  end

  delegate :branded?, to: :account

  def display_name
    branded? ? account.display_name : DEFAULT_DISPLAY_NAME
  end

  # Nav bar, mobile auth panel, KB sidebar — all share one asset per account.
  def logo_path
    branded? ? "accounts/#{slug}/logo.png" : DEFAULT_LOGO_PATH
  end

  # Desktop (lg+) auth split panel uses a distinct default asset from Danebo;
  # branded accounts reuse the single generated logo everywhere.
  def desktop_logo_path
    branded? ? logo_path : DEFAULT_DESKTOP_LOGO_PATH
  end

  def favicon_path
    branded? ? "accounts/#{slug}/favicon.png" : DEFAULT_FAVICON_PATH
  end

  def apple_touch_href
    branded? ? "/brands/#{slug}/icon-180.png" : DEFAULT_APPLE_TOUCH_HREF
  end

  def logo_alt
    branded? ? display_name : DEFAULT_LOGO_ALT
  end

  # Danebo's "danebo" + ".ai" text wordmark sits next to the logo image on
  # several surfaces. Branded accounts hide it — their logo already carries
  # the brand name.
  def show_danebo_wordmark?
    !branded?
  end

  private

  attr_reader :account

  def slug
    account.slug
  end
end
