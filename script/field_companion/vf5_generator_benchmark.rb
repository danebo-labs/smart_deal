# frozen_string_literal: true

# Replays the three captured VF5 generation prompts on an explicit model id.
# VF5_GENERATOR_BENCHMARK=1 sends them. Without that variable this prints the
# prepared hashes and does not call Bedrock. The production query model is not
# read from BEDROCK_MODEL_ID. The assignment file keeps the 48-call and US$4
# ceiling across processes.

def vf5_generator_benchmark_main
  replay = Rag::CapturedGenerationReplay
  root = ENV["VF5_CAPTURE_ROOT"].presence ||
    Rails.root.join("tmp/field_companion/validation_captures/#{replay::VF5_RUN}").to_s
  output = ENV["VF5_BENCHMARK_OUTPUT"].presence ||
    Rails.root.join("tmp/field_companion/vf5_generator_benchmark").to_s
  spend_path = ENV["VF5_ASSIGNMENT_SPEND"].presence ||
    Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json").to_s
  turns = replay::VF5_TURNS.map { |row|
    replay.prepare(
      capture_dir: File.join(root, row[:request_id]),
      body_path: row[:body],
      turn: row[:turn],
      request_id: row[:request_id]
    )
  }
  preview = turns.map { |turn| vf5_turn_preview(turn) }
  unless ENV["VF5_GENERATOR_BENCHMARK"] == "1"
    puts JSON.generate("status" => "preview", "turns" => preview)
    return 0
  end

  spend = Rag::AssignmentSpend.new(path: spend_path, call_cap: replay::CALL_CAP, cost_cap_usd: replay::COST_CAP_USD)
  vf5_arm_ledger!(spend)
  preflight = vf5_preflight(turns, spend)
  puts JSON.generate("status" => "preflight", "ceilings" => preflight)
  if preflight.any? { |row| row["fits"] == false }
    puts JSON.generate("status" => "refused", "reason" => "ceiling")
    return 2
  end
  client = vf5_benchmark_client
  max_attempts = client.instance_variable_get(:@client).config.max_attempts
  unless max_attempts == 1
    puts JSON.generate("status" => "refused", "reason" => "max_attempts", "max_attempts" => max_attempts)
    return 2
  end

  run_id = "vf5-generator-benchmark-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
  outcome = replay.execute_benchmark(
    turns: turns,
    models: [
      { key: "haiku", ids: [ replay::HAIKU_45 ] },
      { key: "sonnet", ids: [ replay::SONNET_45_GLOBAL, replay::SONNET_45_US ] }
    ],
    client: client,
    spend: spend,
    output_root: File.join(output, run_id),
    run_id: run_id
  )
  manifest = {
    "run_id" => run_id,
    "criteria" => replay::CRITERIA,
    "turns" => preview,
    "results" => outcome["results"].map { |row| vf5_manifest_sample(row) },
    "stop" => outcome["stop"],
    "spend" => outcome["spend"].except("entries"),
    "ledger" => Rag::LocalPassLedger.snapshot
  }
  directory = Pathname(output).join(run_id)
  directory.mkpath
  directory.join("manifest.json").write(JSON.generate(manifest))
  puts JSON.generate(manifest)
  returned = outcome["results"].count { |row| row["sample"].status == "returned" }
  outcome["stop"].nil? && returned == 6 ? 0 : 2
end

def vf5_preflight(turns, spend)
  replay = Rag::CapturedGenerationReplay
  snap = spend.snapshot
  remaining = BigDecimal(replay::COST_CAP_USD) - BigDecimal(snap["committed_usd"]) - BigDecimal(snap["held_usd"])
  models = [ replay::HAIKU_45, replay::SONNET_45_GLOBAL, replay::SONNET_45_US ]
  turns.flat_map { |turn|
    models.map { |model_id|
      ceiling = Rag::LocalPassLedger.price(model_id, turn.prompt.bytesize, turn.max_tokens)
      {
        "turn" => turn.turn,
        "model_id" => model_id,
        "ceiling_usd" => format("%.6f", ceiling),
        "remaining_usd" => format("%.6f", remaining),
        "fits" => ceiling <= remaining
      }
    }
  }
end

def vf5_turn_preview(turn)
  {
    "turn" => turn.turn,
    "request_id" => turn.request_id,
    "prompt_sha256" => turn.prompt_sha256,
    "body_sha256" => turn.body_sha256,
    "system" => turn.system.nil? ? "absent" : turn.system_sha256,
    "temperature" => turn.temperature,
    "max_tokens" => turn.max_tokens,
    "anthropic_version" => turn.anthropic_version,
    "captured_model_id" => turn.captured_model_id,
    "bytes" => turn.prompt.bytesize
  }
end

def vf5_manifest_sample(row)
  sample = row["sample"]
  {
    "key" => row["key"],
    "model_id" => sample.model_id,
    "turn" => sample.turn,
    "status" => sample.status,
    "attempts" => sample.attempts,
    "error_class" => sample.error_class,
    "input_tokens" => sample.input_tokens,
    "output_tokens" => sample.output_tokens,
    "latency_ms" => sample.latency_ms,
    "cost_usd" => sample.cost_usd,
    "prompt_sha256" => sample.prompt_sha256,
    "body_sha256" => sample.body_sha256,
    "output_dir" => sample.output_dir
  }
end

def vf5_arm_ledger!(spend)
  replay = Rag::CapturedGenerationReplay
  snap = spend.snapshot
  remaining_calls = replay::CALL_CAP - snap["attempts"].to_i
  remaining = BigDecimal(replay::COST_CAP_USD) - BigDecimal(snap["committed_usd"]) - BigDecimal(snap["held_usd"])
  raise Rag::AssignmentSpend::Stop, "assignment_spend" if remaining_calls < 1 || remaining <= 0

  ENV["RAG_LOCAL_PASS_GUARD"] = "1"
  ENV["RAG_LOCAL_PASS_CALL_CAP"] = remaining_calls.to_s
  ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = format("%.6f", remaining)
  ENV["AWS_MAX_ATTEMPTS"] = "1"
  Rag::LocalPassLedger.reset!
  Rag::LocalPassLedger.reset_local_process!
  return if Rag::LocalPassLedger.armed?

  raise Rag::AssignmentSpend::Stop, "ledger #{Rag::LocalPassLedger.missing_requirements.join(' ')}"
end

def vf5_benchmark_client
  ENV["AWS_MAX_ATTEMPTS"] = "1"
  probe = Class.new { include AwsClientInitializer }.new
  options = probe.send(:build_aws_client_options).merge(retry_limit: 0, max_attempts: 1)
  sdk = Aws::BedrockRuntime::Client.new(options)
  client = BedrockClient.allocate
  client.instance_variable_set(:@client, sdk)
  client
end

unless ENV["VF5_GENERATOR_BENCHMARK_REQUIRE"] == "1"
  code = vf5_generator_benchmark_main
  exit code unless code.zero?
end
