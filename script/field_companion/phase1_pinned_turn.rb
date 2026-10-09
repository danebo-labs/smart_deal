# frozen_string_literal: true

# Phase 1 pinned turn. Reads the environment, calls the service, prints.
# Refuses unless PHASE1_PINNED_TURN_AUTHORIZED=1. Does not edit .env and
# does not run Journey A. PHASE1_PINNED_TURN_REQUIRE=1 loads without running.

def phase1_pinned_turn_main
  return 2 unless Rag::Phase1PinnedTurn.authorized?

  snapshot = Rag::Phase1PinnedTurn.connect_isolated!
  account = Account.find_by(id: 1)
  user = User.find_by(email: Rag::Phase1PinnedTurn::HISTORICAL_USER_EMAIL)
  document = KbDocument.find_by(account_id: account&.id, document_uid: Rag::Phase1PinnedTurn::DOCUMENT_UID)
  result = Rag::Phase1PinnedTurn.call(
    account: account,
    user: user,
    document: document,
    message: "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta y cómo se relaciona con las demás seguridades?",
    connections: snapshot
  )
  puts({ "status" => result.status, "reason" => result.reason, "session_id" => result.session_id, "ledger" => result.ledger }.to_json)
  result.status == "ok" ? 0 : 2
end

unless ENV["PHASE1_PINNED_TURN_REQUIRE"] == "1"
  if ENV["PHASE1_PINNED_TURN_AUTHORIZED"] == "1"
    code = phase1_pinned_turn_main
    exit code unless code.zero?
  else
    warn "phase 1 pinned turn refused without PHASE1_PINNED_TURN_AUTHORIZED=1"
    exit 2
  end
end
