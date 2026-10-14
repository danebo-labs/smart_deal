# frozen_string_literal: true

# Exclusive phase 4 web check. Habitual boots do not register this hook.
# A refusal aborts before the server accepts a request.
if ENV["PHASE4_WEB_CHECK"] == "1"
  Rails.application.config.after_initialize do
    Rag::Phase4WebCheck.boot!
  end
end
