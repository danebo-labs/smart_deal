# frozen_string_literal: true

# Safe default: preflight only. Paid execution requires:
#
# GATE9_V1_EXECUTE=true \
# GATE9_V1_MODE=manual_only \
# GATE9_V1_MANUAL=/path/manual-24pp.pdf \
# GATE9_V1_BUDGET_USD=1.50 \
# bin/rails runner script/gate9_v1_validation.rb
#
# The default mode remains "full" and also requires GATE9_V1_SYNC_PDF and
# GATE9_V1_PHOTOS. Use "manual_only" for the bounded B.1 revalidation.

abort("Run with: bin/rails runner script/gate9_v1_validation.rb") unless defined?(Rails)

puts JSON.pretty_generate(Gate9V1Validation.new.run!)
