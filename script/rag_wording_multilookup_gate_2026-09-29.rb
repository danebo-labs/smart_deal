# frozen_string_literal: true

# P4 read-only precision gate. Repeats the production retrieve path without
# counterfactuals and without generation. No S3 writes, no ingest, no deploy.
#
# Exit 0 when every RESOLVED row and every historical control holds, every
# BLOCKED row stays BLOCKED with its written cause, and the retrieve budget
# holds. Exit 1 when a RESOLVED row or a control fails. Exit 2 when the
# account, the documents, the knowledge base, or credentials are missing.

ENV["WORDING_MULTILOOKUP_PROBE"] = "require"

require "json"
require "fileutils"
require "digest"
require_relative "rag_wording_multilookup_probe_2026-09-29"

module WordingMultilookupGateRules
  EXPECTED_KB = "Y7RZWMFJSR"
  PRODUCTION_BUCKET = "multimodal-source-destination"
  PINNED_K = 3

  module_function

  def judge(row:, observed:)
    failures = []
    failures << "unmeasured" unless observed[:measured]
    failures.concat(budget_failures(row, observed)) if observed[:measured]
    failures.concat(episode_failures(row, observed))
    if observed[:measured] && row[:expect] != "BLOCKED"
      failures << "uncovered" unless observed[:covered]
      failures << "oracle" unless observed[:oracle_ok]
    end
    failures << "generated" if observed[:generation] != "not_run"

    disposition = if !observed[:measured]
      "DEFERRED"
    elsif row[:expect] == "BLOCKED"
      "BLOCKED"
    elsif failures.empty?
      "RESOLVED"
    else
      "DEFERRED"
    end

    {
      disposition: disposition,
      failures: failures,
      reopen_phase: disposition == "DEFERRED" ? row[:reopen_phase] : nil
    }
  end

  def budget_failures(row, observed)
    calls = Array(observed[:calls])
    uri = observed[:source_uri].to_s
    problems = []
    problems << "retrieve_count" if calls.empty? || calls.size > 2
    problems << "extra_retrieve" if row[:max_calls] && calls.size > row[:max_calls]
    if observed[:first_window_complete] && calls.size != 1
      problems << "extra_rescue"
    end
    if Array(row[:one_call_tokens]).any? &&
        (Array(row[:one_call_tokens]) - Array(observed[:first_window_tokens])).empty? &&
        calls.size != 1
      problems << "extra_rescue"
    end
    calls.each_with_index do |call, index|
      problems << "force_entity_filter" unless call[:force_entity_filter] == true
      problems << "uri" unless Array(call[:entity_s3_uris]) == [ uri ]
      problems << "corpus" if Array(call[:entity_s3_uris]).empty? || Array(call[:entity_s3_uris]).size != 1
      problems << "rescue_k" if index.positive? && call[:number_of_results] != PINNED_K
      next if index.zero?
      next if row[:expected_rescue].blank?

      problems << "rescue_query" unless call[:question].to_s.squish == row[:expected_rescue]
    end
    problems.uniq
  end

  def episode_failures(row, observed)
    expect = row[:episode]
    return [] unless expect

    episode = observed[:episode] || {}
    problems = []
    problems << "episode_decision" if episode[:decision].to_s != expect[:decision].to_s
    if expect.key?(:composed) && expect[:composed].nil?
      problems << "episode_composed" unless episode[:composed].nil?
    elsif expect[:composed_includes]
      text = episode[:composed].to_s
      problems << "episode_composed" unless Array(expect[:composed_includes]).all? { |needle| text.include?(needle) }
    end
    problems << "episode_drag" if expect[:forbids] && episode[:drags]
    problems
  end

  def gate_pass?(rows, knowledge_base_id:, pinned_results:)
    return false unless pinned_results == PINNED_K
    return false unless knowledge_base_id == EXPECTED_KB

    rows.all? do |row|
      if row[:kind] == "plan" && row[:expect] == "BLOCKED"
        row[:disposition] == "BLOCKED" && row[:cause] == row[:expect_cause] && !row[:failures].intersect?(%w[unmeasured generated]) &&
          budget_clean?(row)
      else
        row[:disposition] == "RESOLVED" && Array(row[:failures]).empty?
      end
    end
  end

  def budget_clean?(row)
    Array(row[:failures]).none? { |failure| failure.start_with?("retrieve", "extra_", "force", "uri", "corpus", "rescue") }
  end
end

class WordingMultilookupGate < WordingMultilookupProbe
  Rules = WordingMultilookupGateRules

  def initialize(env: ENV)
    super
    @output_path = env.fetch(
      "RAG_WORDING_GATE_OUTPUT",
      "tmp/pilot_gate/wording_multilookup_gate_2026-09-29.json"
    )
  end

  def run!
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    account = find_account!
    documents = {
      seguridades: find_document!(account, "%SEGURIDADES%"),
      elemont: find_document!(account, "%Montacargas%")
    }
    kb_id = @env["RAG_PROBE_KNOWLEDGE_BASE_ID"].presence || Rules::EXPECTED_KB
    service = BedrockRagService.new(account: account, knowledge_base_id: kb_id)
    kb = service.instance_variable_get(:@knowledge_base_id).to_s
    raise Blocked, "Knowledge Base ID is not configured" if kb.blank?
    raise Blocked, "Knowledge Base #{kb} is not #{Rules::EXPECTED_KB}" if kb != Rules::EXPECTED_KB

    install_tape(service)
    service.singleton_class.prepend(UriTape)
    results = gate_rows.map { |row| measure_row(service, account, documents, row) }
    payload = {
      measured_at: Time.current.utc.iso8601(6),
      knowledge_base_id: kb,
      knowledge_base_bucket: KbDocument::KB_BUCKET,
      pinned_document_results: RagRetrievalProfile::PINNED_DOCUMENT_RESULTS,
      generation: "not_run",
      counterfactual: "not_run",
      documents: documents.transform_values { |document| document_payload(document) },
      rows: results,
      counts: counts(results),
      gate_pass: Rules.gate_pass?(
        results,
        knowledge_base_id: kb,
        pinned_results: RagRetrievalProfile::PINNED_DOCUMENT_RESULTS
      )
    }
    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts results.map { |row| summary_line(row) }.join("\n")
    puts "wrote #{@output_path} gate_pass=#{payload[:gate_pass]} #{payload[:counts].map { |key, value| "#{key}=#{value}" }.join(' ')}"
    payload
  end

  def exit_code(payload)
    payload[:gate_pass] ? 0 : 1
  end

  private

  def counts(results)
    plan = results.select { |row| row[:kind] == "plan" }
    {
      plan_resolved: plan.count { |row| row[:disposition] == "RESOLVED" },
      plan_blocked: plan.count { |row| row[:disposition] == "BLOCKED" },
      plan_deferred: plan.count { |row| row[:disposition] == "DEFERRED" },
      controls_resolved: results.count { |row| row[:kind] == "control" && row[:disposition] == "RESOLVED" },
      controls_deferred: results.count { |row| row[:kind] == "control" && row[:disposition] != "RESOLVED" }
    }
  end

  def summary_line(row)
    evidence = Array(row[:evidence]).join("; ")
    "#{row[:id]} #{row[:disposition]} #{evidence}"
  end

  def measure_row(service, account, documents, row)
    document = documents.fetch(row[:corpus])
    uri = source_uri(document)
    raw = row[:question]
    turn = turn_result(raw, goal: row[:prior_goal], manufacturer: row[:prior_manufacturer])
    effective = retrieval_question(raw, turn)
    clear_gate_tape
    route = gate_route(service, account, uri, effective, raw, retrieval_episode(turn))
    retrieval = nil
    selected = []
    selection_path = nil
    if route
      retrieval = route.pinned_retrieval
      return finish(row, uri, effective, turn, unmeasured: "retrieve_failed") if retrieval.is_a?(Rag::StructuredEvidenceRoute::Outcome)

      selected, selection_path = generation_chunks(route, retrieval)
    else
      profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: effective)
      Thread.current[:wml_phase] = "profile"
      retrieval = service.retrieve_chunks(
        effective,
        entity_s3_uris: [ uri ],
        entity_sources: [ "document" ],
        force_entity_filter: true,
        number_of_results: profile.number_of_results,
        account_id: account.id
      )
      selected = Array(retrieval[:chunks])
      selection_path = "profile_retrieve"
    end

    calls = Array(Thread.current[:wml_gate_calls])
    window = first_window(calls)
    scored = score_mappings(selected, row[:mappings])
    window_scored = score_mappings(window, row[:mappings])
    covered = mapping_covered?(row, scored, selected)
    window_covered = mapping_covered?(row, window_scored, window)
    oracle_ok = covered && line_ok?(row, scored) && page_ok?(row, scored, selected)
    observed = {
      measured: true,
      covered: covered,
      oracle_ok: oracle_ok,
      calls: calls,
      source_uri: uri,
      first_window_complete: window_covered,
      first_window_tokens: tokens_in(window, row[:one_call_tokens]),
      generation: "not_run",
      episode: episode_payload(turn, row)
    }
    verdict = Rules.judge(row: row, observed: observed)
    finish(row, uri, effective, turn, selected: selected, scored: scored, calls: calls, route: route,
      selection_path: selection_path, verdict: verdict, covered: covered, window_covered: window_covered)
  rescue Blocked
    raise
  rescue BedrockRagService::BedrockServiceError, BedrockRagService::MissingKnowledgeBaseError => e
    raise Blocked, e.message if row[:id] == "bornera_in"

    finish(row, uri, raw, turn, unmeasured: e.message)
  end

  def finish(row, uri, effective, turn, selected: [], scored: [], calls: [], route: nil, selection_path: nil,
             verdict: nil, covered: false, window_covered: false, unmeasured: nil)
    verdict ||= Rules.judge(
      row: row,
      observed: {
        measured: false,
        covered: false,
        oracle_ok: false,
        calls: [],
        source_uri: uri,
        first_window_complete: false,
        first_window_tokens: [],
        generation: "not_run",
        episode: episode_payload(turn, row)
      }
    )
    queries = calls.pluck(:question)
    {
      id: row[:id],
      kind: row[:kind],
      question: row[:question],
      effective_question: effective,
      expect: row[:expect],
      expect_cause: row[:expect_cause],
      disposition: verdict[:disposition],
      cause: row[:expect] == "BLOCKED" ? row[:expect_cause] : nil,
      restriction: row[:restriction],
      unlock: row[:unlock],
      reopen_phase: verdict[:reopen_phase],
      failures: verdict[:failures],
      unmeasured_reason: unmeasured,
      covered: covered,
      first_window_covered: window_covered,
      selection_path: selection_path,
      route_selected: route ? "structured_evidence_route" : nil,
      rescue_mode: route&.retrieval_report&.dig(:mode)&.to_s,
      rescued: route&.retrieval_report&.dig(:rescued) == true,
      retrieve_count: calls.size,
      queries: queries,
      calls: calls.map { |call| call.except(:question).merge(question: call[:question]) },
      source_uri: uri,
      mappings: public_mappings(scored),
      pages: selected.map { |chunk| page_of(chunk) }.compact.uniq,
      excerpts: summarize_chunks(selected).pluck(:excerpt),
      generation: "not_run",
      episode: episode_payload(turn, row),
      explicit_lines: selected.flat_map { |chunk| WordingMultilookupDiagnosis.explicit_lines(chunk[:content]) }.first(16),
      evidence: evidence_bits(row, verdict, covered, calls, scored, selected)
    }
  end

  def evidence_bits(row, verdict, covered, calls, scored, selected)
    bits = []
    bits << "calls=#{calls.size}"
    bits << (covered ? "covered" : "uncovered")
    bits.concat(calls.map { |call| call[:question].to_s.squish })
    if scored.any?
      bits.concat(scored.map { |mapping| "#{mapping[:entity_or_designator]}=#{mapping[:value]} page=#{mapping[:page]}" })
    elsif selected.any?
      bits << "pages=#{selected.map { |chunk| page_of(chunk) }.compact.uniq.join(',')}"
    end
    bits << "failures=#{verdict[:failures].join(',')}" if verdict[:failures].any?
    bits << "reopen=#{verdict[:reopen_phase]}" if verdict[:reopen_phase]
    bits
  end

  def score_mappings(chunks, mappings)
    return [] if mappings.blank?

    WordingMultilookupDiagnosis.assess(
      chunks: chunks,
      mappings: mappings,
      reported_answer: nil,
      frontiers: {}
    )[:mappings]
  end

  def mapping_covered?(row, scored, chunks)
    if row[:fact_patterns]
      text = Array(chunks).map { |chunk| chunk[:content].to_s }.join("\n")
      row[:fact_patterns].all? { |pattern| text.match?(pattern) }
    elsif row[:fact_any_chunk]
      Array(chunks).any? { |chunk| row[:fact_any_chunk].call(chunk, page_of(chunk)) }
    else
      scored.any? && scored.all? { |mapping| mapping[:covered] }
    end
  end

  def line_ok?(row, scored)
    patterns = row[:line_patterns]
    return true if patterns.blank?

    scored.each_with_index.all? do |mapping, index|
      mapping[:matched_explicit_evidence].to_s.match?(patterns.fetch(index))
    end
  end

  def page_ok?(row, scored, chunks)
    return true if row[:page].blank?

    wanted = row[:page].to_s
    if scored.any?
      return scored.all? { |mapping| normalize_page(mapping[:page]) == wanted }
    end

    chunks.any? { |chunk| page_of(chunk).to_s == wanted }
  end

  def normalize_page(value)
    page = Integer(value, exception: false)
    return page.to_s if page&.positive?

    text = value.to_s.sub(/\.0\z/, "")
    text.presence
  end

  def first_window(_calls)
    expanded = Array(Thread.current[:wml_expansions]&.first&.dig(:output))
    return expanded if expanded.any?

    Array(Thread.current[:wml_tape]&.first&.dig(:chunks))
  end

  def tokens_in(chunks, tokens)
    Array(tokens).select do |token|
      Array(chunks).any? { |chunk| WordingMultilookupDiagnosis.token_on?(chunk[:content], token) }
    end
  end

  def page_of(chunk)
    metadata = chunk[:metadata].to_h
    value = [
      metadata["page_number"],
      metadata[:page_number],
      metadata["page"],
      metadata[:page],
      metadata["x-amz-bedrock-kb-document-page-number"],
      metadata[:"x-amz-bedrock-kb-document-page-number"]
    ].compact.first
    page = Integer(value, exception: false)
    return page if page&.positive?

    key = metadata["x-amz-bedrock-kb-source-uri"] || chunk[:bedrock_source_uri] || chunk[:location_uri]
    key.to_s.match(/(?:\A|\/)chunk_p(\d{1,4})(?:_|\.)/i)&.captures&.first&.to_i
  end

  def retrieval_question(raw, turn)
    return raw unless Rag::FieldCompanionTurnFlag.enabled?

    turn.composed.presence || raw
  end

  def retrieval_episode(turn)
    return unless Rag::FieldCompanionTurnFlag.enabled?

    turn.state
  end

  def episode_payload(turn, row)
    composed = turn.composed
    forbid = row.dig(:episode, :forbids)
    text = [ composed, turn.state.dig("goal", "text") ].compact.join("\n")
    {
      decision: turn.decision.to_s,
      composed: composed,
      drags: forbid.present? && text.match?(forbid)
    }
  end

  def turn_result(text, goal: nil, manufacturer: nil)
    state = {}
    if goal
      now = Time.current
      episode = Rag::ActiveEpisode.open(correlation_id: "query:prior", now: now)
      episode.assign_goal!(goal, correlation_id: "query:prior")
      if manufacturer
        episode.write_fact!(
          "manufacturer",
          status: "known",
          value: manufacturer,
          source: "user",
          correlation_id: "query:prior",
          at: now.iso8601
        )
      end
      state = episode.to_h
    end
    Rag::ActiveEpisodeTurn.call(
      state: state,
      text: text,
      enabled: true,
      channel: "web",
      shared: false,
      correlation_id: "query:gate"
    )
  end

  # P1 measured these pins in the production KB bucket. A local
  # KNOWLEDGE_BASE_S3_BUCKET must not retarget that filter.
  def source_uri(document)
    key = KbDocument.object_key_for_match(document.s3_key) if document.respond_to?(:s3_key)
    key = document.source_uri.to_s.sub(%r{\As3://[^/]+/}, "") if key.blank? && document.respond_to?(:source_uri)
    "s3://#{Rules::PRODUCTION_BUCKET}/#{key}"
  end

  def gate_route(service, account, uri, effective, raw, episode)
    Rag::StructuredEvidenceRoute.build(
      question: effective,
      account: account,
      entity_s3_uris: [ uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      output_channel: :web,
      rag_service: service,
      generator: silent_generator,
      expander: Rag::SectionNeighborExpander.new,
      episode: episode,
      raw_question: raw
    ).tap { |route| install_expand_tape(route) if route }
  end

  def clear_gate_tape
    clear_tape
    Thread.current[:wml_gate_calls] = []
  end

  module UriTape
    def retrieve_chunks(question, entity_s3_uris: [], entity_sources: [], force_entity_filter: false,
                        number_of_results: nil, account_id: nil, correlation_id: nil, route_taken: nil)
      bag = Thread.current[:wml_gate_calls]
      if bag
        bag << {
          question: question,
          entity_s3_uris: Array(entity_s3_uris).map(&:to_s),
          entity_sources: Array(entity_sources).map(&:to_s),
          force_entity_filter: force_entity_filter,
          number_of_results: number_of_results
        }
      end
      super
    end
  end

  def gate_rows
    elemont = :elemont
    seguridades = :seguridades
    [
      plan("bornera_in", "P2", elemont, "¿Dónde está conectada Seguridad IN en la bornera del tablero?", "RESOLVED",
        mappings: [ borne("Seguridad IN", %w[Seguridad IN], "24") ],
        expected_rescue: "conectada Seguridad IN bornera tablero"),
      plan("out_in", "P2", elemont, "¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?", "RESOLVED",
        mappings: [ borne("Seguridad OUT", %w[Seguridad OUT], "23"), borne("Seguridad IN", %w[Seguridad IN], "24") ]),
      blocked("micros", elemont, "¿Cuáles son los bornes del micro de nivel inferior y del micro de nivel superior?",
        "retrieval/ranking",
        "El rescue ya corrió y la query solo perdió el ?. P1 no midió contrafactual, así que no hay otra query.",
        "Un retrieve medido, k=3, misma URI, force_entity_filter true, de una función determinística que no sea un string por caso, que deje | 30 | con inferior y | 31 | con superior.",
        mappings: [ borne("inferior", %w[inferior], "30"), borne("superior", %w[superior], "31") ]),
      blocked("llamadas", elemont, "¿Cuáles son los bornes de llamada de nivel 1 y nivel 2?",
        "retrieval/ranking",
        "El rescue ya corrió y no trajo la hoja 2. No hay contrafactual medido.",
        "El mismo tipo de retrieve medido, con llamada nivel 1 en 33 y llamada nivel 2 en 34.",
        mappings: [ borne("llamada nivel 1", %w[llamada 1], "33"), borne("llamada nivel 2", %w[llamada 2], "34") ]),
      blocked("sube_baja", elemont, "¿Qué relés corresponden a SUBE y BAJA en este tablero?",
        "route eligibility",
        "La ruta sigue cerrada. reles corresponden SUBE BAJA tablero no juntó K1 con SUBE ni K2 con BAJA. K6 no es la asignación.",
        "Un retrieve medido, k=3, misma URI, force_entity_filter true, que deje las filas explícitas K1–SUBE y K2–BAJA.",
        mappings: [ relay("SUBE", "K1"), relay("BAJA", "K2") ]),
      blocked("t1_t2", elemont, "¿Cómo están configurados T1 y T2?",
        "rescue eligibility/query",
        "Sigue el camino de designador. configurados T1 T2 no trajo modo E ni modo Wu y no se adopta.",
        "Un retrieve medido, con las mismas restricciones, que deje T1 modo E t<3 min y T2 modo Wu t<1 s, sin reemplazar el camino de designador.",
        mappings: [ timer("T1", /modo\s*E\b/i, /(?:<\s*)?3\s*min/i, "modo E, t<3 min"), timer("T2", /modo\s*Wu\b/i, /(?:<\s*)?1\s*s(?:eg(?:undo)?s?)?\b/i, "modo Wu, t<1 s") ]),
      plan("f1_funcion", "P3", seguridades, "En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?", "RESOLVED",
        mappings: f1_f2(%w[F1 F2 EDEL K2]),
        line_patterns: [ /FOTOCELULA EMBARQUE 1/i, /FOTOCELULA EMBARQUE 2/i ],
        page: 25,
        expected_rescue: "EDEL K2 F1 F2",
        one_call_tokens: %w[K2 F1 F2]),
      plan("f1_indican", "P3", seguridades, "¿qué indican F1 y F2?", "RESOLVED",
        mappings: f1_f2(%w[F1 F2]),
        line_patterns: [ /FOTOCELULA EMBARQUE 1/i, /FOTOCELULA EMBARQUE 2/i ],
        page: 25,
        expected_rescue: "F1 F2",
        one_call_tokens: %w[F1 F2]),
      plan("fotocelulas", "P3", seguridades, "En EDEL K2 con dos embarques, ¿qué fotocélulas identifica el manual para cada embarque?", "RESOLVED",
        mappings: f1_f2(%w[F1 F2 EDEL K2]),
        line_patterns: [ /FOTOCELULA EMBARQUE 1/i, /FOTOCELULA EMBARQUE 2/i ],
        page: 25,
        expected_rescue: "EDEL K2",
        one_call_tokens: %w[K2]),
      control("em2000", "P3", seguridades, "EM2000 hidráulico obstáculo",
        fact_patterns: [ /\bCN7\b/, /\bCN8\b/ ]),
      control("em4000", "P3", seguridades, "EM4000 V1 obstáculo",
        fact_patterns: [ /\bXC4\b/, /\bXC7\b/ ]),
      control("mr08_sci", "P3", seguridades, "Falla la serie SCI del MR08",
        fact_patterns: [ /\bSCI\b/, /CN[\s\-]*112/i, /CN[\s\-]*109/i ]),
      control("cerrojos", "P3", seguridades, "EDEL K2 cerrojos exteriores",
        fact_patterns: [ /\b40\b[^\n]{0,40}CERROJOS EXTERIORES/i ]),
      control("seguridad_out", "P2", elemont, "¿A qué borne corresponde Seguridad OUT?",
        mappings: [ borne("Seguridad OUT", %w[Seguridad OUT], "23") ]),
      control("seguridad_in", "P2", elemont, "¿A qué borne corresponde Seguridad IN?",
        mappings: [ borne("Seguridad IN", %w[Seguridad IN], "24") ]),
      control("presostato_out", "P2", elemont, "¿A qué borne corresponde Presostato OUT?",
        mappings: [ borne("Presostato OUT", %w[Presostato OUT], "25") ]),
      control("presostato_in", "P2", elemont, "¿A qué borne corresponde Presostato IN?",
        mappings: [ borne("Presostato IN", %w[Presostato IN], "26") ]),
      control("micro_inferior", "P2", elemont, "¿A qué borne corresponde el micro de nivel inferior?",
        mappings: [ borne("inferior", %w[inferior], "30") ]),
      control("micro_superior", "P2", elemont, "¿A qué borne corresponde el micro de nivel superior?",
        mappings: [ borne("superior", %w[superior], "31") ]),
      control("llamada_1", "P2", elemont, "¿A qué borne corresponde la llamada de nivel 1?",
        mappings: [ borne("llamada nivel 1", %w[llamada 1], "33") ]),
      control("llamada_2", "P2", elemont, "¿A qué borne corresponde la llamada de nivel 2?",
        mappings: [ borne("llamada nivel 2", %w[llamada 2], "34") ]),
      control("sube", "P2", elemont, "Elemont MH, ¿cuál es el relé de SUBE?",
        mappings: [ relay("SUBE", "K1") ]),
      control("baja", "P2", elemont, "¿Y para BAJA cuál es el relé?",
        mappings: [ relay("BAJA", "K2") ],
        prior_goal: "Elemont MH, ¿cuál es el relé de SUBE?",
        prior_manufacturer: "Elemont",
        episode: { decision: "continued_elliptical", composed_includes: [ "MH", "SUBE", "¿Y para BAJA cuál es el relé?" ] }),
      control("t1", "P3", elemont, "¿Qué temporizador es T1?",
        fact_patterns: [ /\bT1\b/, /modo\s*E\b/i, /3\s*min/i ]),
      control("t2", "P3", elemont, "¿Qué temporizador es T2?",
        fact_patterns: [ /\bT2\b/, /modo\s*Wu\b/i, /<\s*1\s*seg/i ]),
      control("foso", "P2", elemont, "¿Cómo se ilumina el foso?",
        max_calls: 1,
        fact_any_chunk: lambda { |chunk, _page|
          text = chunk[:content].to_s
          text.match?(/circuito\s*#?\s*6/i) &&
            text.match?(/10\s*\(\s*L\s*\)/i) &&
            text.match?(/11\s*\(\s*N\s*\)/i) &&
            text.match?(/\b3\b/) &&
            text.match?(/20\s*w/i) &&
            text.match?(/foso/i)
        }),
      control("cadena", "P2", elemont, "¿Cómo reviso la cadena de seguridad?",
        max_calls: 1,
        fact_any_chunk: lambda { |chunk, page|
          page.to_s == "5" && chunk[:content].to_s.match?(/cadena de seguridad/i)
        }),
      control("temporizadores", "episode", elemont, "¿Qué temporizadores tiene este tablero y cómo están configurados?",
        max_calls: 1,
        prior_goal: "¿A qué borne corresponde el presostato?",
        episode: { decision: "continued_self_contained", composed: nil, forbids: /presostato/i },
        fact_patterns: [ /\bT1\b/, /modo\s*E\b/i, /3\s*min/i, /\bT2\b/, /modo\s*Wu\b/i, /<\s*1\s*seg/i ])
    ]
  end

  def plan(id, phase, corpus, question, expect, **)
    row(id, "plan", phase, corpus, question, expect, **)
  end

  def control(id, phase, corpus, question, **)
    row(id, "control", phase, corpus, question, "RESOLVED", **)
  end

  def blocked(id, corpus, question, cause, restriction, unlock, **)
    row(id, "plan", nil, corpus, question, "BLOCKED", expect_cause: cause, restriction: restriction, unlock: unlock, **)
  end

  def row(id, kind, phase, corpus, question, expect, mappings: nil, fact_patterns: nil, fact_any_chunk: nil,
          line_patterns: nil, page: nil, expected_rescue: nil, one_call_tokens: nil, max_calls: nil,
          prior_goal: nil, prior_manufacturer: nil, episode: nil, expect_cause: nil, restriction: nil, unlock: nil)
    {
      id: id,
      kind: kind,
      reopen_phase: phase,
      corpus: corpus,
      question: question,
      expect: expect,
      expect_cause: expect_cause,
      restriction: restriction,
      unlock: unlock,
      mappings: mappings,
      fact_patterns: fact_patterns,
      fact_any_chunk: fact_any_chunk,
      line_patterns: line_patterns,
      page: page,
      expected_rescue: expected_rescue,
      one_call_tokens: one_call_tokens,
      max_calls: max_calls,
      prior_goal: prior_goal,
      prior_manufacturer: prior_manufacturer,
      episode: episode
    }
  end

  def borne(entity, tokens, value)
    { entity: entity, relation: "connection", entity_tokens: tokens, value_label: value, value_tokens: [ value ] }
  end

  def relay(entity, value)
    { entity: entity, relation: "attribution", entity_tokens: [ entity ], value_label: value, value_tokens: [ value ] }
  end

  def timer(entity, mode, bound, label)
    { entity: entity, relation: "configuration", entity_tokens: [ entity ], value_label: label, value_patterns: [ mode, bound ] }
  end

  def f1_f2(excludes)
    %w[F1 F2].map do |entity|
      { entity: entity, relation: "attribution", entity_tokens: [ entity ], open_value: true, value_excludes: excludes }
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__) || ARGV.any? { |arg| File.expand_path(arg) == File.expand_path(__FILE__) rescue false }
  gate = WordingMultilookupGate.new
  begin
    payload = gate.run!
  rescue WordingMultilookupGate::Blocked => e
    warn "BLOCKED: #{e.message}"
    exit 2
  end
  exit gate.exit_code(payload)
end
