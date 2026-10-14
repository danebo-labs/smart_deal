# frozen_string_literal: true

# Exclusive Puma config for the phase 4 web check.
# Single process. Does not load config/puma.rb and does not start Solid Queue.
# bin/rails server -C is dev caching, not this file. Start it with puma -C.

workers 0

threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)

environment "development"

plugin :tmp_restart

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
