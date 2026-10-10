# frozen_string_literal: true

# Interpreter experiment. Haiku 5.5 and Haiku 4.5 both use the Anthropic
# Messages API (claude-haiku-5-5 and claude-haiku-4-5-20251001).
# This script does not call Bedrock and does not read ANTHROPIC_API_KEY.
# INTERPRETER_HAIKU55_EXPERIMENT_REQUIRE=1 loads this file without running.
# INTERPRETER_HAIKU55_EXPERIMENT_PREPARE=1 writes the matrix and does not
# read a credential or open a socket.
# INTERPRETER_HAIKU55_EXPERIMENT_PROBE_PREPARE=1 writes the four phase-1
# prompt combinations and does not call.
# INTERPRETER_HAIKU55_EXPERIMENT_AUTHORIZED=1 is not enough to call. The
# service approval, the run id, and the frozen quota have to pass as well.

def interpreter_haiku55_experiment_main
  if ENV["INTERPRETER_HAIKU55_EXPERIMENT_PROBE_PREPARE"] == "1"
    root = ENV["INTERPRETER_HAIKU55_EXPERIMENT_ROOT"]
    summary = Rag::InterpreterAnthropicExperiment.prepare_probe(
      evidence_root: root,
      run_id: ENV["INTERPRETER_HAIKU55_EXPERIMENT_RUN_ID"]
    )
    puts JSON.generate(summary.merge("status" => "prepared"))
    return 0
  end

  result = Rag::InterpreterAnthropicExperiment.command(
    prepare: ENV["INTERPRETER_HAIKU55_EXPERIMENT_PREPARE"] == "1",
    authorized: ENV["INTERPRETER_HAIKU55_EXPERIMENT_AUTHORIZED"] == "1",
    evidence_root: ENV["INTERPRETER_HAIKU55_EXPERIMENT_ROOT"],
    run_id: ENV["INTERPRETER_HAIKU55_EXPERIMENT_RUN_ID"]
  )
  puts JSON.generate(result.fetch("output"))
  result.fetch("exit_code")
end

unless ENV["INTERPRETER_HAIKU55_EXPERIMENT_REQUIRE"] == "1"
  code = interpreter_haiku55_experiment_main
  exit code unless code.zero?
end
