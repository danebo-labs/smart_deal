# frozen_string_literal: true

# Protects every certifier-module controller with a 404 while
# ENV["CERTIFIER_MODULE_ENABLED"] is off (section 2.1) — lets this fase merge
# and deploy to `main` while the module is still incomplete, and gives
# production an instant kill switch with no code deploy.
module CertifierModuleGuard
  extend ActiveSupport::Concern

  included do
    before_action :ensure_certifier_module_enabled!
  end

  private

  def ensure_certifier_module_enabled!
    head :not_found unless CertifierModuleFlag.enabled?
  end
end
