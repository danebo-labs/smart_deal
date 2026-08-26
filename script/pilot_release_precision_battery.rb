# frozen_string_literal: true

# Batería de precisión del Paso 6 — gate de liberación del piloto Gonzalo
# (docs/PLAN_LIBERACION_PILOTO_2026-08-25.md). Retrieval top-K sobre 60
# preguntas estratificadas por marca (gratis: retrieve_chunks no genera fila
# en bedrock_queries) + generación completa sobre el subconjunto de 20 (gasta
# crédito real), evaluada con Rag::BenchmarkRubricEvaluator sin modificar.
#
# Orquestador de un solo uso: sigue el precedente real de este repo
# (RagSeguridadesBenchmark vive en script/, no en app/services — sólo la
# lógica genuinamente reusable entre baterías merecería un service, y aquí la
# única candidata, "¿este chunk es del documento esperado?", son ~10 líneas).
#
# Modos:
#   DRY_RUN=1  -> sólo fases (a) resolución + (b) retrieval de las 60. US$0.
#                 Con PILOT_BATTERY_DUMP_CONTENT=1 además imprime el contenido
#                 real de los chunks del subconjunto de 20, para ajustar la
#                 rúbrica contra lo efectivamente indexado antes de gastar
#                 crédito (Fase 2.5 del plan).
#   (default)  -> corrida completa: (a)+(b)+(c)+(d). (c) es la única fase que
#                 gasta crédito, con freno de presupuesto.
class PilotReleasePrecisionBattery
  def initialize(env: ENV)
    @env = env
    @dry_run = env["DRY_RUN"] == "1"
    @dump_content = env["PILOT_BATTERY_DUMP_CONTENT"] == "1"
    @account_id = Integer(env.fetch("PILOT_BATTERY_ACCOUNT_ID", "3"))
    @top_k = Integer(env.fetch("PILOT_BATTERY_TOP_K", "5"))
    @budget_ceiling_usd = Float(env.fetch("PILOT_BATTERY_BUDGET_CEILING", "2.5"))
    questions_path = env.fetch(
      "PILOT_BATTERY_QUESTIONS",
      Rails.root.join("script/fixtures/pilot_release_precision_battery_questions.json").to_s
    )
    rubric_path = env.fetch(
      "PILOT_BATTERY_RUBRIC",
      Rails.root.join("script/fixtures/pilot_release_precision_battery_rubric.json").to_s
    )
    @questions = JSON.parse(File.read(questions_path))
    @rubric = JSON.parse(File.read(rubric_path))
  end

  def run!
    # QueryOrchestratorService#skip_routing? es true por defecto (sin esta
    # var), lo que garantiza KNOWLEDGE_BASE_QUERY siempre. Si alguna sesión
    # futura la prendió en producción, abortar antes de gastar nada: con
    # routing activo una pregunta podría desviarse a Text-to-SQL.
    if ENV["QUERY_ROUTING_ENABLED"] == "true"
      raise "QUERY_ROUTING_ENABLED=true en este entorno — la batería asume KNOWLEDGE_BASE_QUERY siempre. Abortando antes de gastar crédito."
    end

    account = Account.find(@account_id)
    resolved = resolve_identities!(account)
    retrieval = run_retrieval(account, resolved)

    payload = {
      "run_id" => "pilot_release_precision_battery:#{SecureRandom.uuid}",
      "mode" => @dry_run ? "dry_run_retrieval_only" : "full",
      "account_id" => @account_id,
      "top_k" => @top_k,
      "started_at" => Time.current.utc.iso8601(6),
      "retrieval" => retrieval
    }

    unless @dry_run
      # TrackBedrockQueryJob crea la fila BedrockQuery real de forma async vía
      # Solid Queue en el contenedor worker, no en el web donde corre este
      # script — sin esto el freno de presupuesto leería un total
      # desactualizado (precedente: script/rag_quality_benchmark.rb).
      ActiveJob::Base.queue_adapter = :inline

      generation, budget_usd = run_generation(account)
      evaluation = Rag::BenchmarkRubricEvaluator.new(
        rubric: @rubric,
        payload: { "run_id" => payload["run_id"], "results" => generation }
      ).evaluate

      payload["generation"] = generation
      payload["evaluation"] = evaluation
      payload["budget_usd"] = budget_usd
      payload["gate"] = gate_verdict(retrieval, evaluation)
    end

    payload["finished_at"] = Time.current.utc.iso8601(6)
    puts JSON.pretty_generate(payload)
    payload
  end

  private

  # Fase (a): SHA-256 -> BulkUploadAsset -> KbDocument. Aborta fuerte y barato
  # (sin llamadas a Bedrock) ante cualquier ambigüedad o estado inesperado, en
  # vez de dejar pasar una identidad sin verificar a las fases que sí cuestan.
  def resolve_identities!(account)
    shas = @questions.map { |q| q.fetch("expected_sha256") }.uniq
    assets = BulkUploadAsset
      .where(sha256: shas)
      .where.not(kb_document_id: nil)
      .joins(:kb_document)
      .where(kb_document: { account_id: account.id })
      .includes(:kb_document)
      .to_a
    by_sha = assets.group_by(&:sha256)

    @questions.each_with_object({}) do |q, resolved|
      id = q.fetch("id")
      sha = q.fetch("expected_sha256")
      matches = by_sha[sha] || []
      if matches.empty?
        raise "#{id}: SHA-256 #{sha[0, 12]} no resuelve a ningún BulkUploadAsset de la cuenta #{account.id}"
      end

      complete = matches.select { |a| a.status == "complete" }
      if complete.empty?
        raise "#{id}: SHA-256 #{sha[0, 12]} resuelve pero ningún asset está status=complete (#{matches.map(&:status).uniq})"
      end

      kb_document_ids = complete.map(&:kb_document_id).uniq
      if kb_document_ids.size > 1
        raise "#{id}: SHA-256 #{sha[0, 12]} resuelve a #{kb_document_ids.size} kb_documents distintos — ambiguo"
      end

      resolved[id] = complete.first.kb_document
    end
  end

  # Fase (b): retrieval de las 60 — gratis, retrieve_chunks no genera fila en
  # bedrock_queries. Compara por doc_sha256 en el metadata del chunk (viaja en
  # el mismo namespace que el SHA-256 de scope.json, ver
  # batch_results_parser_service.rb#sidecar_metadata), más robusto que URIs.
  # Registra rank para las 60 preguntas, no sólo un booleano — el propio Paso
  # 6 exige poder "analizar" un fallo agregado.
  def run_retrieval(account, resolved)
    service = BedrockRagService.new(account: account)
    @questions.map do |q|
      id = q.fetch("id")
      expected_sha = q.fetch("expected_sha256")
      kb_document = resolved.fetch(id)

      result = service.retrieve_chunks(
        q.fetch("question"),
        number_of_results: @top_k,
        account_id: account.id,
        correlation_id: "pilot_battery_retrieval:#{id}"
      )
      chunks = Array(result[:chunks])

      if @dry_run && @dump_content && q["generation_subset"]
        puts "=== #{id} (#{q['brand']}) — esperado: #{kb_document.display_name} (kb_document##{kb_document.id}) ==="
        chunks.each { |c| puts "--- rank #{c[:rank]} score=#{c[:score]} ---\n#{c[:content]}\n" }
      end

      hit = chunks.find { |c| chunk_matches_sha?(c, expected_sha) }

      {
        "id" => id,
        "brand" => q.fetch("brand"),
        "generation_subset" => !!q["generation_subset"],
        "expected_kb_document_id" => kb_document.id,
        "expected_display_name" => kb_document.display_name,
        "rank" => hit && hit[:rank],
        "hit_in_top_k" => !hit.nil?,
        "top_k" => @top_k
      }
    end
  end

  def chunk_matches_sha?(chunk, expected_sha)
    metadata = chunk[:metadata].to_h
    doc_sha = metadata["doc_sha256"] || metadata[:doc_sha256]
    doc_sha.to_s == expected_sha
  end

  # Fase (c): generación completa de las 20 — gasta crédito real. Cascada
  # completa de producción vía QueryOrchestratorService (el mismo punto de
  # entrada real, no una réplica parcial) sin pin de documento: debe ejercer
  # retrieval real a nivel de cuenta, no fijado a un documento. El aislamiento
  # multi-tenant es incondicional (BedrockRagService exige `account:` y
  # siempre aplica el filtro account_id), así que no hay riesgo de fuga.
  def run_generation(account)
    start_id = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i
    aborted = false

    results = @questions.select { |q| q["generation_subset"] }.map do |q|
      id = q.fetch("id")
      next result_row(id: id, budget_aborted: true) if aborted

      spent = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_id).sum(&:cost) }
      if spent >= @budget_ceiling_usd
        aborted = true
        next result_row(id: id, budget_aborted: true)
      end

      outcome = QueryOrchestratorService.new(
        q.fetch("question"),
        account: account,
        entity_s3_uris: [],
        force_entity_filter: false,
        response_locale: :es,
        output_channel: :web,
        correlation_id: "pilot_battery_gen:#{id}"
      ).execute

      result_row(
        id: id,
        answer: outcome[:answer].to_s,
        citations: Array(outcome[:citations]),
        generation_mode: outcome[:generation_mode] || "bedrock_retrieve_and_generate",
        budget_aborted: false
      )
    rescue StandardError => e
      result_row(id: id, budget_aborted: false, error: "#{e.class}: #{e.message}")
    end

    final_spent = ActiveRecord::Base.uncached { BedrockQuery.where("id > ?", start_id).sum(&:cost) }
    [ results, final_spent.round(4) ]
  end

  def result_row(id:, budget_aborted:, answer: "", citations: [], generation_mode: nil, error: nil)
    {
      "id" => id,
      "answer" => answer,
      "citations" => citations,
      "generation_mode" => generation_mode,
      "budget_aborted" => budget_aborted,
      "error" => error
    }.compact
  end

  # Tasa de aprobación de casos (no score/max_score agregado): `passed` en
  # BenchmarkRubricEvaluator es la única métrica binaria de corrección; un
  # promedio de score puede esconder respuestas incompletas compensadas por
  # crédito `optional`, inaceptable como gate de liberación.
  def gate_verdict(retrieval, evaluation)
    total = retrieval.size
    hits = retrieval.count { |r| r["hit_in_top_k"] }
    retrieval_rate = total.zero? ? 0.0 : (hits.to_f / total)

    cases = evaluation.fetch("summary").fetch("cases")
    passed = evaluation.fetch("summary").fetch("passed")
    generation_rate = cases.zero? ? 0.0 : (passed.to_f / cases)

    {
      "retrieval_hits" => hits,
      "retrieval_total" => total,
      "retrieval_rate" => retrieval_rate.round(4),
      "retrieval_threshold" => 0.85,
      "retrieval_pass" => retrieval_rate >= 0.85,
      "generation_passed" => passed,
      "generation_cases" => cases,
      "generation_rate" => generation_rate.round(4),
      "generation_threshold" => 0.80,
      "generation_pass" => generation_rate >= 0.80,
      "overall_pass" => (retrieval_rate >= 0.85) && (generation_rate >= 0.80)
    }
  end
end

PilotReleasePrecisionBattery.new.run! unless ENV["PILOT_BATTERY_LIBRARY_ONLY"] == "1"
