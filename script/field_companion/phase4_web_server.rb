#!/usr/bin/env ruby
# frozen_string_literal: true

# Thin start for the phase 4 web check. Does not boot Rails. The process
# must already export PHASE4_WEB_CHECK=1 and the isolated contract. Those
# values stay out of .env. The authoritative gate is Rag::Phase4WebCheck.boot!
# after Puma loads the app; the checks here exit before a socket exists.

root = File.expand_path("../..", __dir__)

def refuse(reason)
  warn "phase4 web check refused: #{reason}"
  exit 1
end

def activation_in_dotenv?(text)
  text.to_s.each_line.any? do |line|
    stripped = line.strip
    next false if stripped.empty? || stripped.start_with?("#")

    stripped.sub(/\Aexport\s+/, "").match?(/\APHASE4_WEB_CHECK\s*=/)
  end
end

refuse("activation_absent") unless ENV["PHASE4_WEB_CHECK"] == "1"

env_path = File.join(root, ".env")
if File.file?(env_path) && activation_in_dotenv?(File.read(env_path))
  refuse("activation_in_dotenv")
end

refuse("aws_retry_mode") unless ENV["AWS_RETRY_MODE"] == "standard"
refuse("aws_max_attempts") unless ENV["AWS_MAX_ATTEMPTS"] == "1"
refuse("web_concurrency") unless ENV["WEB_CONCURRENCY"] == "0"
refuse("solid_queue_in_puma") unless ENV["SOLID_QUEUE_IN_PUMA"].to_s.strip.empty?

Dir.chdir(root)
exec("bundle", "exec", "puma", "-C", "config/puma_phase4_web_check.rb")
