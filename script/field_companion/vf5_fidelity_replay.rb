# frozen_string_literal: true

# Replays the three captured VF5 prompts after restoring page text from the
# local PDF. VF5_FIDELITY_REPLAY=1 sends Haiku 4.5. Without it, this writes
# the corrected prompts and does not call Bedrock. The production model and
# the shared knowledge base are not changed. The assignment file is not reset.

def vf5_fidelity_replay_main
  replay = Rag::CapturedGenerationReplay
  root = Rails.root.join("tmp/field_companion/validation_captures/#{replay::VF5_RUN}")
  output = Rails.root.join("tmp/field_companion/vf5_fidelity_replay")
  spend_path = Rails.root.join("tmp/field_companion/vf5_generator_benchmark/assignment_spend.json")
  pages = vf5_fidelity_pages
  prepared = replay::VF5_TURNS.map { |row|
    original = replay.prepare(
      capture_dir: root.join(row[:request_id]).to_s,
      body_path: row[:body],
      turn: row[:turn],
      request_id: row[:request_id]
    )
    vf5_fidelity_prepare(original, pages)
  }
  preview = prepared.map { |row| vf5_fidelity_preview(row) }
  output.mkpath
  prepared.each do |row|
    output.join("prompt-t#{row.turn}.txt").binwrite(row.prompt)
  end
  Rails.root.join("tmp/field_companion/local_page_text/be7a39a3490c92c8/document_id.txt").write("be7a39a3490c92c8381cb883402760cb07d1")
  unless ENV["VF5_FIDELITY_REPLAY"] == "1"
    puts JSON.generate("status" => "preview", "turns" => preview)
    return 0
  end

  ENV.delete("RAG_ASSIGNMENT_SPEND_PATH")
  spend = Rag::AssignmentSpend.new(path: spend_path, call_cap: replay::CALL_CAP, cost_cap_usd: replay::COST_CAP_USD)
  spend.sync_caps!
  balance = vf5_fidelity_balance(spend)
  puts JSON.generate("status" => "balance", "balance" => balance)
  unless balance["fits"]
    puts JSON.generate("status" => "refused", "reason" => "reserve", "balance" => balance)
    return 2
  end

  vf5_arm_ledger!(spend)
  client = vf5_benchmark_client
  max_attempts = client.instance_variable_get(:@client).config.max_attempts
  unless max_attempts == 1
    puts JSON.generate("status" => "refused", "reason" => "max_attempts", "max_attempts" => max_attempts)
    return 2
  end

  variant = ENV["VF5_FIDELITY_CONTRACT"] == "1" ? "D" : "A"
  route = if ENV["VF5_FIDELITY_INGESTION"] == "1"
    "ingesta"
  elsif ENV["VF5_FIDELITY_ROUTE"] == "vigente"
    "vigente"
  else
    "historico"
  end
  run_id = "vf5-fidelity-#{variant}-#{route}-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
  results = []
  prepared.each do |turn|
    sample = vf5_fidelity_invoke(replay, turn, client, spend, output.join(run_id, "t#{turn.turn}"), run_id, variant)
    results << sample
    break unless sample.status == "returned"
  end
  manifest = {
    "run_id" => run_id,
    "variant" => variant,
    "route" => route,
    "hypothesis" => "The opening role treated explicit user input as an answer source and overrode the check-stays-open rule. That sentence is replaced. The field rule stays where variant C placed it.",
    "model_id" => replay::HAIKU_45,
    "criteria" => replay::CRITERIA,
    "turns" => preview,
    "results" => results.map { |sample| vf5_fidelity_sample(sample) },
    "spend" => spend.snapshot.except("entries")
  }
  directory = output.join(run_id)
  directory.mkpath
  directory.join("manifest.json").write(JSON.generate(manifest))
  puts JSON.generate(manifest)
  results.size == 3 && results.all? { |sample| sample.status == "returned" } ? 0 : 2
end

def vf5_fidelity_pages
  pdf = Rails.root.join("docs/field_companion/fuentes/VF5.pdf")
  directory = Rails.root.join("tmp/field_companion/local_page_text/be7a39a3490c92c8")
  directory.mkpath
  [ 5, 12, 13 ].map { |number|
    raw = IO.popen([ "pdftotext", "-layout", "-f", number.to_s, "-l", number.to_s, pdf.to_s, "-" ], &:read)
    raise "pdftotext #{number}" unless $?.success?

    text = Rag::PageChunkFidelity.strip_running_matter(raw)
    directory.join("p#{number}.txt").write(text)
    text
  }
end

def vf5_fidelity_prepare(original, pages)
  prompt = Rag::PageChunkFidelity.rewrite_search_results(original.prompt, pages)
  prompt = vf5_fidelity_contract(prompt) if ENV["VF5_FIDELITY_CONTRACT"] == "1"
  prompt = vf5_fidelity_current_state(prompt) if ENV["VF5_FIDELITY_ROUTE"] == "vigente" || ENV["VF5_FIDELITY_INGESTION"] == "1"
  prompt = vf5_fidelity_ingested(prompt) if ENV["VF5_FIDELITY_INGESTION"] == "1"
  body = Rag::CapturedGenerationReplay.invoke_body_json(
    prompt: prompt,
    max_tokens: original.max_tokens,
    temperature: original.temperature,
    system: original.system,
    anthropic_version: original.anthropic_version
  )
  original.with(
    prompt: prompt,
    prompt_sha256: Digest::SHA256.hexdigest(prompt),
    body_json: body,
    body_sha256: Digest::SHA256.hexdigest(body)
  )
end

def vf5_fidelity_contract(prompt)
  start = prompt.index("# DOCUMENT IDENTITY ATTRIBUTION")
  raise "attribution marker missing" unless start

  contract = [
    BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT,
    BedrockRagService::DOCUMENT_IDENTITY_CITATION_INSTRUCTIONS
  ].join("\n\n")
  rewritten = "#{prompt[0...start]}#{contract}\n"
  rewritten.sub(
    BedrockRagService::DOCUMENT_IDENTITY_ROLE_SENTENCE,
    BedrockRagService::DOCUMENT_IDENTITY_ROLE_REPLACEMENT
  )
end

def vf5_fidelity_ingested(prompt)
  root = Rails.root.join("tmp/field_companion/local_ingestion")
  page5 = (0..2).map { |index| root.join("chunk-p5-#{index}.txt").read }.join("\n\n")
  page13 = (0..2).map { |index| root.join("chunk-p13-#{index}.txt").read }.join("\n\n")
  prompt.gsub(%r{<content>\n(.*?)\n</content>}m) do |block|
    body = Regexp.last_match(1)
    replacement = if body.include?("Máster y Esclavo") || body.include?("S4 — SAFETY SYSTEM")
      page5
    elsif body.include?("LED STATUS") || body.include?("problema persista") || body.include?("Problemas adicionales")
      page13
    end
    next block unless replacement

    lines = body.lines
    cut = lines.index { |line| line.include?("[SEARCH_ALIASES:") }
    head = cut ? lines[0..cut].join : ""
    "<content>\n#{head}\n#{replacement.strip}\n</content>"
  end
end

def vf5_fidelity_current_state(prompt)
  source = "El LED de fotocélula está encendido"
  prompt.sub(/^Obs: .*$/) { |line|
    body = line.delete_prefix("Obs: ")
    parts = body.split("; ").map { |part| Rag::WorkContextReducer.qualify_generic_led(part, source) }
    "Obs: #{parts.join('; ')}"
  }
end

def vf5_fidelity_invoke(replay, turn, client, spend, directory, run_id, variant)
  sample = replay.run_sample(
    prepared: turn,
    model_id: replay::HAIKU_45,
    client: client,
    spend: spend,
    output_dir: directory,
    run_id: run_id,
    correlation_prefix: "vf5-fidelity:#{variant}",
    attempt_limit: Rag::TransientBackoff.limit
  )
  return sample if sample.status == "returned"

  pause = Rag::TransientBackoff.recovery_pause
  directory.join("checkpoint.json").write(JSON.generate(
    "status" => sample.status,
    "error_class" => sample.error_class,
    "error_message" => sample.error_message,
    "attempts" => sample.attempts,
    "prompt_sha256" => sample.prompt_sha256,
    "recovery_pause_seconds" => pause
  ))
  sleep(pause)
  replay.run_sample(
    prepared: turn,
    model_id: replay::HAIKU_45,
    client: client,
    spend: spend,
    output_dir: directory.join("probe"),
    run_id: run_id,
    correlation_prefix: "vf5-fidelity:#{variant}:probe",
    attempt_limit: 1
  )
end

def vf5_fidelity_preview(turn)
  {
    "turn" => turn.turn,
    "request_id" => turn.request_id,
    "prompt_sha256" => turn.prompt_sha256,
    "body_sha256" => turn.body_sha256,
    "bytes" => turn.prompt.bytesize,
    "temperature" => turn.temperature,
    "max_tokens" => turn.max_tokens,
    "system" => turn.system.nil? ? "absent" : "present"
  }
end

def vf5_fidelity_balance(spend)
  replay = Rag::CapturedGenerationReplay
  snap = spend.snapshot
  remaining_calls = replay::CALL_CAP - snap["attempts"].to_i
  remaining_usd = BigDecimal(replay::COST_CAP_USD) - BigDecimal(snap["committed_usd"]) - BigDecimal(snap["unknown_usd"].to_s.presence || "0") - BigDecimal(snap["held_usd"])
  reserved_calls = 3 + 14
  eval_calls = (3 * Rag::TransientBackoff.limit) + 3
  {
    "attempts" => snap["attempts"],
    "committed_usd" => snap["committed_usd"],
    "unknown_usd" => snap["unknown_usd"],
    "held_usd" => snap["held_usd"],
    "remaining_calls" => remaining_calls,
    "remaining_usd" => format("%.6f", remaining_usd),
    "reserved_calls" => reserved_calls,
    "fits" => remaining_calls >= eval_calls + reserved_calls && remaining_usd >= BigDecimal("0.20")
  }
end

def vf5_arm_ledger!(spend)
  replay = Rag::CapturedGenerationReplay
  snap = spend.snapshot
  remaining_calls = replay::CALL_CAP - snap["attempts"].to_i
  remaining = BigDecimal(replay::COST_CAP_USD) - BigDecimal(snap["committed_usd"]) - BigDecimal(snap["unknown_usd"].to_s.presence || "0") - BigDecimal(snap["held_usd"])
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

def vf5_fidelity_sample(sample)
  {
    "turn" => sample.turn,
    "status" => sample.status,
    "attempts" => sample.attempts,
    "input_tokens" => sample.input_tokens,
    "output_tokens" => sample.output_tokens,
    "latency_ms" => sample.latency_ms,
    "cost_usd" => sample.cost_usd,
    "prompt_sha256" => sample.prompt_sha256,
    "body_sha256" => sample.body_sha256,
    "error_class" => sample.error_class,
    "output_dir" => sample.output_dir
  }
end

unless ENV["VF5_FIDELITY_REPLAY_REQUIRE"] == "1"
  code = vf5_fidelity_replay_main
  exit code unless code.zero?
end
