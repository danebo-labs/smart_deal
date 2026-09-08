# frozen_string_literal: true

# Rails-native kill switch for the certifier module (Fase 2 of
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md, section 2.1). No gem:
# flipping ENV["CERTIFIER_MODULE_ENABLED"] off in production hides the nav
# entry and 404s the module's controllers with zero deploy — the rollback
# plan's primary mechanism, not `git revert`/`reset`.
module CertifierModuleFlag
  module_function

  def enabled?
    ENV["CERTIFIER_MODULE_ENABLED"] == "true"
  end
end
