# frozen_string_literal: true

# Gate 9R — Final manual onboarding run.
#
# FASE II (preflight $0):
#   GATE9_FINAL_MANUAL=/abs/manual.pdf \
#   BEDROCK_RERANKER_ENABLED=false QUERY_ROUTING_ENABLED=false \
#   bin/rails runner script/gate9_final_manual.rb
#
# FASE III (corrida pagada):
#   GATE9_FINAL_EXECUTE=true GATE9_FINAL_MANUAL=/abs/manual.pdf \
#   GATE9_FINAL_BUDGET_USD=<MAX> GATE9_FINAL_MAX_RETRY_PAGES=1 \
#   ANTHROPIC_API_KEY=<ws_key> \
#   BEDROCK_RERANKER_ENABLED=false QUERY_ROUTING_ENABLED=false \
#   bin/rails runner script/gate9_final_manual.rb
#   # Resume: re-run the identical command (state present ⇒ no resubmit).
#
# FASE IV (veredicto offline $0):
#   GATE9_FINAL_VERDICT=pass bin/rails runner script/gate9_final_manual.rb
#
# This certification run is NOT launched from /bulk_uploads or web/chat. Those
# production paths index into the KB; this harness intentionally never does.

abort("Run with: bin/rails runner script/gate9_final_manual.rb") unless defined?(Rails)

begin
  Gate9FinalManual.new.run!
rescue Gate9FinalManual::PreflightError => e
  abort "PREFLIGHT ERROR: #{e.message}"
rescue Gate9FinalManual::GateFailure => e
  abort "GATE FAILURE: #{e.message}"
rescue Gate9FinalManual::AbortError => e
  abort "ABORT: #{e.message}"
end
