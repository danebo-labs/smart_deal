# frozen_string_literal: true

# Safe default: preflight only. Paid execution requires:
#
# GATE9_V1_EXECUTE=true \
# GATE9_V1_MANUAL=/path/manual-24pp.pdf \
# GATE9_V1_SYNC_PDF=/path/manual-3pp.pdf \
# GATE9_V1_PHOTOS=/path/a.jpg,/path/b.jpg,... \
# bin/rails runner script/gate9_v1_validation.rb

abort("Run with: bin/rails runner script/gate9_v1_validation.rb") unless defined?(Rails)

puts JSON.pretty_generate(Gate9V1Validation.new.run!)
