# frozen_string_literal: true

# Interpreter experiment, Haiku 5.5 via the Anthropic Messages API.
# Run with bin/rails runner. Refuses before any network call.
# Does not read ANTHROPIC_API_KEY and does not edit .env.
# INTERPRETER_HAIKU55_EXPERIMENT_REQUIRE=1 loads this file without running.
# INTERPRETER_HAIKU55_EXPERIMENT_AUTHORIZED=1 does not open live calls.

def interpreter_haiku55_experiment_main
  authorized = ENV["INTERPRETER_HAIKU55_EXPERIMENT_AUTHORIZED"] == "1"
  puts JSON.generate(
    "status" => "blocked",
    "reason" => authorized ? "live_calls_closed" : "authorization_absent",
    "live_calls_enabled" => Rag::InterpreterAnthropicExperiment::LIVE_CALLS_ENABLED
  )
  2
end

unless ENV["INTERPRETER_HAIKU55_EXPERIMENT_REQUIRE"] == "1"
  code = interpreter_haiku55_experiment_main
  exit code unless code.zero?
end
