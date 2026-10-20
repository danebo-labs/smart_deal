# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# Local generator experiment on the captured D-histórico turn-1 prompt.
# Four conditions, two samples, no product-code change, no retrieval, no KB
# write. VF5_STATE_CONTINUITY=1 calls Haiku. Without it, this only writes
# prompts, hashes, and diffs. The assignment ledger is never reset.

RESERVE_CALLS = 15
CALL_CAP = 96
COST_CAP = BigDecimal("4")
EXPECTED_PROMPT_SHA = "a3dc05933eaa46bfb7af798f41992660e438e6f3575e50973af4871184564754"
EXPECTED_PDF_SHA = "be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72"
CONTROL_PATH = "tmp/field_companion/vf5_fidelity_replay/vf5-fidelity-D-historico-20261020T202806Z/t1/attempt-1/bodies/b0001.txt"
PDF_PATH = "docs/field_companion/fuentes/VF5.pdf"
SPEND_PATH = "tmp/field_companion/vf5_generator_benchmark/assignment_spend.json"
MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
# Occupies the Obs slot. Turn 1 of D-histórico has no Obs line: the episode
# observations were covered by Goal and assemble_problem printed nothing.
# Goal, Query, chunks, aliases, FIELD_RECORDs, and the contract stay as they
# are. The photocell clause is the check printed under the parent item, not a
# broader procedure. The TEST clause keeps the manual's persistence condition.
STATE_BLOCK = <<~TEXT.chomp
  Reportado por el técnico: El LED de fotocélula está encendido; no observo una obstrucción mecánica; no he revisado la sensibilidad de reapertura; SW4 está en OFF, modo esclavo; no hice mediciones ni reparaciones.
  Comprobaciones documentales pendientes de confirmar: sensibilidad de reapertura #54; funcionamiento de la fotocélula (comprobar que no esté activada); si el problema persiste, desconectar la fotocélula y volver a pulsar el botón de TEST.
TEXT
PAGE_MARK = "[PDF_PAGE: 13]"
ORDER = %w[D E1 E2 E3].freeze

def vf5_state_continuity_main
  ENV["VF5_FIDELITY_REPLAY_REQUIRE"] = "1"
  load Rails.root.join("script/field_companion/vf5_fidelity_replay.rb")
  raise "production" if Rails.env.production?

  control = Rails.root.join(CONTROL_PATH).binread.force_encoding(Encoding::UTF_8)
  sha = Digest::SHA256.hexdigest(control)
  raise "control sha #{sha}" unless sha == EXPECTED_PROMPT_SHA

  pdf_sha = Digest::SHA256.file(Rails.root.join(PDF_PATH)).hexdigest
  raise "pdf sha #{pdf_sha}" unless pdf_sha == EXPECTED_PDF_SHA

  continuation = vf5_state_continuation(control)
  prompts = vf5_state_prompts(control, continuation)
  vf5_state_authorize!(control, prompts, continuation)

  live = ENV["VF5_STATE_CONTINUITY"] == "1"
  run_id = live ? "vf5-state-continuity-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}" : "preview"
  root = Rails.root.join("tmp/field_companion/vf5_state_continuity/#{run_id}")
  root.mkpath
  vf5_state_write_prompts(root, prompts, continuation)
  balance = vf5_state_read_balance
  root.join("balance_before.json").write(JSON.generate(balance))
  manifest = vf5_state_manifest(run_id, prompts, balance, continuation, live)
  root.join("manifest.json").write(JSON.generate(manifest))
  puts JSON.generate("status" => "prepared", "run_id" => run_id, "balance" => balance.except("entries"), "prompts" => manifest["prompts"])
  return 0 unless live

  vf5_state_refuse_budget!(balance)
  code = vf5_state_execute(root, run_id, prompts, balance)
  puts JSON.generate("status" => "finished", "exit" => code, "run_id" => run_id)
  code
end

def vf5_state_continuation(control)
  line = control.lines.find { |item| item.include?("En caso que el problema persista") }
  raise "continuation missing" unless line&.start_with?("– ")
  raise "continuation count" unless control.scan(line.strip).size == 1

  line
end

def vf5_state_prompts(control, continuation)
  {
    "D" => control,
    "E1" => vf5_state_e1(control, continuation),
    "E2" => vf5_state_e2(control),
    "E3" => vf5_state_e2(vf5_state_e1(control, continuation))
  }
end

def vf5_state_e1(prompt, continuation)
  removed = prompt.sub("#{continuation}\n", "")
  raise "e1 remove" if removed == prompt

  anchor = vf5_state_third_script(removed)
  raise "e1 anchor" unless removed.scan(anchor).size == 1

  removed.sub(anchor, "#{anchor}#{continuation}#{PAGE_MARK}\n")
end

def vf5_state_e2(prompt)
  slot = "Identifiers: Fermator VF5+, modo esclavo\n"
  raise "e2 slot" unless prompt.scan(slot).size == 1

  prompt.sub(slot, "#{slot}#{STATE_BLOCK}\n")
end

def vf5_state_third_script(prompt)
  line = prompt.lines.find { |item| item.start_with?("– Comprobar que no hay una obstrucción mecánica en la puerta.") }
  raise "third script" unless line && prompt.scan(line).size == 1

  line
end

def vf5_state_authorize!(control, prompts, continuation)
  raise "e1 reverse" unless vf5_state_reverse_e1(prompts.fetch("E1"), continuation) == control
  raise "e2 reverse" unless vf5_state_reverse_e2(prompts.fetch("E2")) == control
  raise "e3 reverse" unless vf5_state_reverse_e2(vf5_state_reverse_e1(prompts.fetch("E3"), continuation)) == control
  raise "e3 order" unless prompts.fetch("E3") == vf5_state_e1(vf5_state_e2(control), continuation)

  %w[E1 E3].each do |key|
    raise "#{key} page mark" unless prompts[key].scan(PAGE_MARK).size == 1
    raise "#{key} continuation place" unless vf5_state_continuation_after_parent?(prompts[key], continuation)
  end
  %w[D E2].each do |key|
    raise "#{key} page mark" unless prompts[key].exclude?(PAGE_MARK)
    raise "#{key} continuation place" unless vf5_state_continuation_orphaned?(prompts[key], continuation)
  end
  %w[D E1].each { |key| raise "#{key} state" if prompts[key].include?("Reportado por el técnico:") }
  %w[E2 E3].each { |key| raise "#{key} state" unless prompts[key].scan(STATE_BLOCK).size == 1 }

  prompts.each_value do |prompt|
    raise "assistant history" if prompt.lines.any? { |line| line.start_with?("Assistant:") }
    raise "query" unless prompt[/^Query: .*$/] == control[/^Query: .*$/]
    raise "aliases" unless prompt.scan(/^\[SEARCH_ALIASES:.*\]$/) == control.scan(/^\[SEARCH_ALIASES:.*\]$/)
    raise "records" unless prompt.scan(/^FIELD_RECORD:\n.*?^END_FIELD_RECORD/m) == control.scan(/^FIELD_RECORD:\n.*?^END_FIELD_RECORD/m)
    raise "contract" unless prompt[/^# DOCUMENT IDENTITY ATTRIBUTION\n.*\z/m] == control[/^# DOCUMENT IDENTITY ATTRIBUTION\n.*\z/m]
    raise "goal" unless prompt[/^Goal: .*$/] == control[/^Goal: .*$/]
    raise "recent" unless prompt[/^## Recent Conversation\n.*?(?=^## )/m] == control[/^## Recent Conversation\n.*?(?=^## )/m]
    raise "continuation count" unless prompt.scan(continuation.strip).size == 1
    raise "obs label" if prompt.lines.any? { |line| line.start_with?("Obs:") }
  end
end

def vf5_state_reverse_e1(prompt, continuation)
  anchor = vf5_state_third_script(prompt)
  block = "#{anchor}#{continuation}#{PAGE_MARK}\n"
  raise "reverse e1 block" unless prompt.include?(block)

  stripped = prompt.sub(block, anchor)
  aliases = stripped.lines.find { |line| line.include?("LED STATUS apagado") }
  marker = "#{aliases}\n"
  raise "reverse e1 aliases" unless stripped.include?(marker)

  stripped.sub(marker, "#{marker}#{continuation}\n")
end

def vf5_state_reverse_e2(prompt)
  slot = "Identifiers: Fermator VF5+, modo esclavo\n"
  block = "#{slot}#{STATE_BLOCK}\n"
  raise "reverse e2" unless prompt.include?(block)

  prompt.sub(block, slot)
end

def vf5_state_continuation_after_parent?(prompt, continuation)
  anchor = vf5_state_third_script(prompt)
  prompt.include?("#{anchor}#{continuation}#{PAGE_MARK}\n") &&
    prompt.exclude?("fuera de servicio]\n\n#{continuation}")
end

def vf5_state_continuation_orphaned?(prompt, continuation)
  prompt.include?("fuera de servicio]\n\n#{continuation}") &&
    prompt.exclude?("#{vf5_state_third_script(prompt)}#{continuation}")
end

def vf5_state_write_prompts(root, prompts, continuation)
  prompts.each do |key, prompt|
    root.join("prompt-#{key}.txt").binwrite(prompt)
  end
  root.join("continuation.txt").binwrite(continuation)
  root.join("state_block.txt").write(STATE_BLOCK)
  %w[E1 E2 E3].each do |key|
    vf5_state_write_diff(root.join("prompt-D.txt"), root.join("prompt-#{key}.txt"), root.join("diff-#{key}.diff"))
  end
end

def vf5_state_write_diff(left, right, path)
  command = [ "diff", "-u", left.to_s, right.to_s ]
  output, status = Open3.capture2(*command)
  raise "diff #{path}" unless status.success? || status.exitstatus == 1

  path.write(output)
end

def vf5_state_read_balance
  raw = JSON.parse(Rails.root.join(SPEND_PATH).read)
  open = raw["open"].is_a?(Hash) ? raw["open"] : {}
  held = open.values.sum(BigDecimal("0")) { |amount| BigDecimal(amount.to_s) }
  {
    "attempts" => raw["attempts"].to_i,
    "blocked" => raw["blocked"].to_i,
    "priced" => raw["priced"].to_i,
    "committed_usd" => format("%.6f", BigDecimal(raw["committed"].to_s)),
    "unknown_usd" => format("%.6f", BigDecimal(raw["unknown"].to_s)),
    "held_usd" => format("%.6f", held),
    "call_cap" => CALL_CAP,
    "cost_cap_usd" => COST_CAP.to_s("F"),
    "open_holds" => open.size,
    "entries" => raw["entries"].is_a?(Array) ? raw["entries"].size : nil
  }
end

def vf5_state_manifest(run_id, prompts, balance, continuation, live)
  replay = Rag::CapturedGenerationReplay
  {
    "run_id" => run_id,
    "live" => live,
    "head" => `git rev-parse HEAD`.strip,
    "git_status" => `git status --short`,
    "control_path" => CONTROL_PATH,
    "pdf_sha256" => EXPECTED_PDF_SHA,
    "model_id" => MODEL_ID,
    "temperature" => 0.1,
    "max_tokens" => 3000,
    "system" => "absent",
    "anthropic_version" => replay::ANTHROPIC_VERSION,
    "order" => [ ORDER, ORDER ],
    "obs_slot" => "Turn 1 has no Obs: line. The two state lines are inserted after Identifiers, where assemble_problem would have printed Obs. Goal is unchanged.",
    "page_mark" => "E1 and E3 move the continuation under the parent item and add [PDF_PAGE: 13]. That mark is not manual text. It keeps the fragment from being read as page 12.",
    "continuation" => continuation.strip,
    "state_block" => STATE_BLOCK,
    "e2_label" => "intervención diagnóstica con estado enriquecido",
    "balance_before" => balance.except("entries"),
    "prompts" => prompts.transform_values { |prompt|
      body = replay.invoke_body_json(prompt: prompt, max_tokens: 3000, temperature: 0.1, system: nil)
      {
        "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
        "body_sha256" => Digest::SHA256.hexdigest(body),
        "bytes" => prompt.bytesize
      }
    }
  }
end

def vf5_state_refuse_budget!(balance)
  raise "open holds" unless balance["open_holds"].zero?

  remaining_calls = CALL_CAP - balance["attempts"]
  remaining_usd = COST_CAP - BigDecimal(balance["committed_usd"]) - BigDecimal(balance["unknown_usd"]) - BigDecimal(balance["held_usd"])
  worst = (ORDER.size * 2) * (Rag::TransientBackoff.limit + 1)
  raise "call reserve" if remaining_calls < RESERVE_CALLS + worst
  raise "cost reserve" if remaining_usd < BigDecimal("0.50")
end

def vf5_state_execute(root, run_id, prompts, balance)
  results = []
  ENV.delete("RAG_ASSIGNMENT_SPEND_PATH")
  spend = Rag::AssignmentSpend.new(path: Rails.root.join(SPEND_PATH), call_cap: CALL_CAP, cost_cap_usd: COST_CAP)
  vf5_arm_ledger!(spend)
  usable = CALL_CAP - RESERVE_CALLS - balance["attempts"]
  ENV["RAG_LOCAL_PASS_CALL_CAP"] = usable.to_s
  Rag::LocalPassLedger.reset!
  raise "ledger" unless Rag::LocalPassLedger.armed?

  client = vf5_benchmark_client
  max_attempts = client.instance_variable_get(:@client).config.max_attempts
  raise "max_attempts #{max_attempts}" unless max_attempts == 1

  prepared = prompts.transform_values { |prompt| vf5_state_prepared(prompt) }
  queue = (1..2).flat_map { |round| ORDER.map { |key| [ round, key ] } }
  results = []
  failures = 0
  queue.each do |round, key|
    sample_name = "r#{round}-#{key}"
    if failures >= 2 || !vf5_state_room?(spend)
      results << { "sample" => sample_name, "condition" => key, "round" => round, "status" => "not_started", "reason" => failures >= 2 ? "availability" : "reserve" }
      next
    end
    sample = vf5_state_invoke(prepared.fetch(key), client, spend, root.join(sample_name), run_id, sample_name)
    results << vf5_state_sample(sample_name, key, round, sample)
    failures = sample.status == "returned" ? 0 : failures + 1
  end
  returned = results.count { |row| row["status"] == "returned" }
  returned == ORDER.size * 2 ? 0 : 2
rescue Rag::AssignmentSpend::Stop, Rag::LocalPassLedger::Stop => error
  results << { "status" => "stopped", "reason" => error.message }
  2
ensure
  if defined?(results) && results && root
    final_balance = vf5_state_read_balance
    root.join("balance_after.json").write(JSON.generate(final_balance))
    root.join("results.json").write(JSON.generate("results" => results, "balance_after" => final_balance.except("entries")))
  end
end

def vf5_state_room?(spend)
  snap = spend.snapshot
  remaining_calls = CALL_CAP - snap["attempts"].to_i
  remaining_usd = COST_CAP - BigDecimal(snap["committed_usd"]) - BigDecimal(snap["unknown_usd"].to_s) - BigDecimal(snap["held_usd"].to_s)
  remaining_calls >= RESERVE_CALLS + Rag::TransientBackoff.limit + 1 && remaining_usd >= BigDecimal("0.20")
end

def vf5_state_prepared(prompt)
  replay = Rag::CapturedGenerationReplay
  body = replay.invoke_body_json(prompt: prompt, max_tokens: 3000, temperature: 0.1, system: nil)
  replay::Prepared.new(
    turn: 1,
    request_id: "354da85f-c20c-4d36-bb88-45a0c059bc2e",
    prompt: prompt,
    prompt_sha256: Digest::SHA256.hexdigest(prompt),
    system: nil,
    system_sha256: nil,
    temperature: 0.1,
    max_tokens: 3000,
    anthropic_version: replay::ANTHROPIC_VERSION,
    messages: [ { "role" => "user" } ],
    captured_model_id: MODEL_ID,
    correlation_id: nil,
    body_json: body,
    body_sha256: Digest::SHA256.hexdigest(body)
  )
end

def vf5_state_invoke(prepared, client, spend, directory, run_id, sample_name)
  replay = Rag::CapturedGenerationReplay
  sample = replay.run_sample(
    prepared: prepared,
    model_id: MODEL_ID,
    client: client,
    spend: spend,
    output_dir: directory,
    run_id: run_id,
    correlation_prefix: "vf5-state:#{sample_name}",
    attempt_limit: Rag::TransientBackoff.limit
  )
  return sample if sample.status == "returned"
  return sample unless replay.error_kind(sample.error_class) == "transient"

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
    prepared: prepared,
    model_id: MODEL_ID,
    client: client,
    spend: spend,
    output_dir: directory.join("probe"),
    run_id: run_id,
    correlation_prefix: "vf5-state:#{sample_name}:probe",
    attempt_limit: 1
  )
end

def vf5_state_sample(name, key, round, sample)
  {
    "sample" => name,
    "condition" => key,
    "round" => round,
    "status" => sample.status,
    "attempts" => sample.attempts,
    "input_tokens" => sample.input_tokens,
    "output_tokens" => sample.output_tokens,
    "latency_ms" => sample.latency_ms,
    "cost_usd" => sample.cost_usd,
    "prompt_sha256" => sample.prompt_sha256,
    "body_sha256" => sample.body_sha256,
    "error_class" => sample.error_class,
    "error_message" => sample.error_message,
    "output_dir" => sample.output_dir
  }
end

unless ENV["VF5_STATE_CONTINUITY_REQUIRE"] == "1"
  code = vf5_state_continuity_main
  exit code unless code.zero?
end
