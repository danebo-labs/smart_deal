# frozen_string_literal: true

# P1 read-only diagnosis. Measures wording and multi-lookup coverage on the
# same pin the 28-sep probe used. No S3 writes, no ingest, no deploy.
# Generation runs only when every requested mapping is already in
# selected_generation_chunks and the reported answer might fail to say it.
#
# Exit 0 when every row was measured. Exit 1 when a row could not be measured.
# Exit 2 when the account, the documents, or credentials are missing.

require "json"
require "fileutils"
require "set"

module WordingMultilookupDiagnosis
  ABSENT_ANSWER = "no generada; evidencia ausente"
  CAUSE_ORDER = [
    "query analysis",
    "route eligibility",
    "retrieval/ranking",
    "rescue eligibility/query",
    "expansion",
    "evidence selection/coverage",
    "source/chunk representation",
    "synthesis"
  ].freeze
  PROXIMITY = 160

  # Closed class of function words. The counterfactual keeps every other
  # token of the current turn, in order. Chosen once, before any retrieve.
  FUNCTION_WORDS = %w[
    a al como con cual cuales de del donde el en es esta estan este
    la las lo los o para por que se son un una y
  ].freeze

  module_function

  def anchor_phrase(text)
    tokens = I18n.transliterate(text.to_s).scan(/[[:alnum:]]+/)
    tokens.reject { |token| FUNCTION_WORDS.include?(token.downcase) }.join(" ")
  end

  def explicit_assignment_line?(line)
    return false if line.blank?
    return false if line.match?(/\A[\s|:\-]+\z/)
    return false if line.match?(/\A\[(?:DOCUMENT|SOURCE_URI|SEARCH_ALIASES):/i)
    return false if line.match?(/\A(ACTION|EVIDENCE|EXPECTED_RESULT|SOURCE_SECTION|RECORD_ID|RECORD_TYPE|FIELD_RECORD|END_FIELD_RECORD|UNCERTAINTY)\b/i)

    line.match?(/\A\s*\|(?:[^|\n]*\|){2,}/) ||
      line.match?(/\A\s*[-*]?\s*[A-Za-z0-9][A-Za-z0-9._-]{0,12}\s*\|\s*\S/)
  end

  def explicit_lines(content)
    content.to_s.lines.map(&:strip).select { |line| explicit_assignment_line?(line) }
  end

  def assess(chunks:, mappings:, reported_answer:, frontiers:)
    scored = mappings.map { |mapping| score_mapping(chunks, mapping, mappings) }
    if scored.any? { |mapping| !mapping[:covered] }
      losses = scored.reject { |mapping| mapping[:covered] }.map do |mapping|
        first_loss(frontiers.merge(mapping_frontier(mapping, frontiers)))
      end
      primary = earliest(losses)
      contributing = losses.uniq - [ primary ]
      if scored.any? { |mapping| mapping[:contradicting_line].present? } && primary != "source/chunk representation"
        contributing << "source/chunk representation"
      end
      return {
        mappings: scored,
        primary_cause: primary,
        contributing_causes: contributing,
        reported_answer: ABSENT_ANSWER
      }
    end

    expressed = scored.all? { |mapping| expresses?(reported_answer, mapping) }
    contributing = []
    if scored.any? { |mapping| mapping[:contradicting_line].present? }
      contributing << "source/chunk representation"
    end
    {
      mappings: scored,
      primary_cause: expressed ? "none" : "synthesis",
      contributing_causes: contributing,
      reported_answer: reported_answer.to_s
    }
  end

  def score_mapping(chunks, mapping, siblings)
    match = nil
    Array(chunks).each do |chunk|
      explicit_lines(chunk[:content]).each do |line|
        next unless line_covers?(line, mapping, siblings)

        match = { line: line, chunk: chunk }
        break
      end
      break if match
    end

    metadata = match ? match[:chunk][:metadata].to_h.stringify_keys : {}
    conflict = contradicting_line(chunks, mapping)
    {
      entity: mapping[:entity],
      entity_or_designator: mapping[:entity],
      entity_tokens: mapping[:entity_tokens],
      open_value: mapping[:open_value],
      value_tokens: mapping[:value_tokens],
      value_patterns: mapping[:value_patterns],
      value_excludes: mapping[:value_excludes],
      value_label: mapping[:value_label],
      requested_relation: mapping[:relation],
      matched_explicit_evidence: match&.dig(:line),
      value: match ? displayed_value(match[:line], mapping) : oracle_value(mapping),
      covered: !match.nil?,
      page: metadata["page_number"],
      chunk_sha256: match&.dig(:chunk, :chunk_sha256),
      contradicting: conflict.present? && match.nil?,
      contradicting_line: conflict
    }
  end

  def expresses?(answer, mapping)
    return open_expressed?(answer, mapping) if mapping[:open_value]

    text = answer.to_s
    return false if text.blank? || text == ABSENT_ANSWER
    return false unless entity_on?(text, mapping) && value_on?(text, mapping)

    entity_at = token_positions(text, mapping[:entity_tokens].last)
    value_at = value_positions(text, mapping)
    return false if entity_at.empty? || value_at.empty?

    entity_at.any? { |left| value_at.any? { |right| (left - right).abs <= PROXIMITY } }
  end

  def open_expressed?(answer, mapping)
    text = answer.to_s
    entity = Array(mapping[:entity_tokens]).last
    value = mapping[:value].to_s
    return false if text.blank? || text == ABSENT_ANSWER || entity.blank? || value.blank?

    words = I18n.transliterate(value).scan(/[[:alnum:]]+/).select { |word| word.length >= 4 }
    words = [ entity ] if words.empty?
    entity_at = token_positions(text, entity)
    return false if entity_at.empty?

    words.any? do |word|
      token_positions(text, word).any? { |pos| entity_at.any? { |left| (left - pos).abs <= PROXIMITY } }
    end
  end

  def first_loss(obs)
    return nil if obs[:selected_covered]

    in_window = obs[:initial_covered] || obs[:expanded_covered] || obs[:rescued_covered] || obs[:merged_covered]
    if in_window
      if obs[:initial_covered] && obs[:expanded_covered] == false && !obs[:rescued_covered] && !obs[:merged_covered]
        return "expansion"
      end

      return "evidence selection/coverage"
    end

    if obs[:analysis_lost] && !obs[:counterfactual_covered]
      return "query analysis"
    end

    if (obs[:contradicting_in_selected] || obs[:contradicting]) && !obs[:counterfactual_covered]
      return "source/chunk representation"
    end

    return "route eligibility" unless obs[:route_selected]

    if obs[:counterfactual_covered]
      return obs[:rescue_mode].present? ? "rescue eligibility/query" : "route eligibility"
    end

    if obs[:rescue_ran] && !obs[:rescue_query_identical]
      return "retrieval/ranking"
    end

    return "rescue eligibility/query" if obs[:rescue_mode].present?

    "retrieval/ranking"
  end

  def earliest(causes)
    causes.compact.min_by { |cause| CAUSE_ORDER.index(cause) || CAUSE_ORDER.length } || "retrieval/ranking"
  end

  def line_covers?(line, mapping, siblings)
    return false unless entity_on?(line, mapping)
    return open_assignment(line, mapping).present? if mapping[:open_value]
    return false unless value_on?(line, mapping)

    nearer_than_siblings?(line, mapping, siblings)
  end

  def entity_on?(text, mapping)
    Array(mapping[:entity_tokens]).all? { |token| token_on?(text, token) }
  end

  def value_on?(text, mapping)
    return open_assignment(text, mapping).present? if mapping[:open_value]

    tokens = Array(mapping[:value_tokens])
    patterns = Array(mapping[:value_patterns])
    return false if tokens.empty? && patterns.empty?

    tokens.all? { |token| token_on?(text, token) } &&
      patterns.all? { |pattern| I18n.transliterate(text.to_s).match?(pattern) }
  end

  def nearer_than_siblings?(line, mapping, siblings)
    entity_at = token_pos(line, mapping[:entity_tokens].last)
    value_at = value_pos(line, mapping)
    return false if entity_at.nil? || value_at.nil?

    Array(siblings).all? do |other|
      next true if other.equal?(mapping) || other[:entity] == mapping[:entity]
      next true unless value_on?(line, other) && entity_on?(line, other)

      other_at = value_pos(line, other)
      next true if other_at.nil?

      (value_at - entity_at).abs <= (other_at - entity_at).abs
    end
  end

  def open_assignment(line, mapping)
    cells = line.to_s.split("|").map(&:strip).reject(&:empty?)
    entity = mapping[:entity_tokens].last
    index = cells.index { |cell| token_on?(cell, entity) }
    return nil unless index

    excluded = Array(mapping[:value_excludes]).map { |token| I18n.transliterate(token).downcase }
    others = cells.each_with_index.reject do |cell, cell_index|
      next true if cell_index == index

      words = I18n.transliterate(cell).scan(/[[:alnum:]]+/).map(&:downcase)
      words.all? { |word| excluded.include?(word) }
    end
    return nil if others.empty?

    others.min_by { |_cell, cell_index| (cell_index - index).abs }.first
  end

  def displayed_value(line, mapping)
    return open_assignment(line, mapping) if mapping[:open_value]

    mapping[:value_label]
  end

  def oracle_value(mapping)
    mapping[:open_value] ? nil : mapping[:value_label]
  end

  def contradicting_line(chunks, mapping)
    return nil if mapping[:open_value] || Array(mapping[:value_tokens]).empty?

    explicit_lines_of(chunks).find do |line|
      entity_on?(line, mapping) && !value_on?(line, mapping) && other_value_token?(line, mapping)
    end
  end

  def explicit_lines_of(chunks)
    Array(chunks).flat_map { |chunk| explicit_lines(chunk[:content]) }
  end

  def other_value_token?(line, mapping)
    expected = Array(mapping[:value_tokens]).map { |token| I18n.transliterate(token).downcase }
    I18n.transliterate(line.to_s).scan(/[[:alnum:]]+/).any? do |token|
      next false if expected.include?(token.downcase)
      next true if token.match?(/\A\d{1,3}\z/) && expected.any? { |item| item.match?(/\A\d+\z/) }
      next true if token.match?(/\AK\d+\z/i) && expected.any? { |item| item.match?(/\AK\d+\z/i) }

      false
    end
  end

  def mapping_frontier(mapping, frontiers)
    detail = Array(frontiers[:per_mapping]).find { |row| row[:entity] == mapping[:entity_or_designator] } || {}
    hits = Array(frontiers[:counterfactual_hits])
    {
      selected_covered: mapping[:covered],
      analysis_lost: detail.fetch(:analysis_lost, frontiers[:analysis_lost]),
      initial_covered: detail[:initial_covered],
      expanded_covered: detail[:expanded_covered],
      rescued_covered: detail[:rescued_covered],
      merged_covered: detail[:merged_covered],
      counterfactual_covered: hits.include?(mapping[:entity_or_designator]),
      contradicting_in_selected: mapping[:contradicting]
    }
  end

  def token_on?(text, token)
    token_positions(text, token).any?
  end

  def token_pos(text, token)
    token_positions(text, token).first
  end

  def token_positions(text, token)
    want = I18n.transliterate(token.to_s)
    token_spans(text).select { |word, _offset| word.casecmp?(want) }.map(&:last)
  end

  def value_pos(text, mapping)
    value_positions(text, mapping).first
  end

  def value_positions(text, mapping)
    if mapping[:open_value]
      assigned = open_assignment(text, mapping)
      return [] if assigned.blank?

      index = I18n.transliterate(text.to_s).index(I18n.transliterate(assigned))
      return index ? [ index ] : []
    end

    token = Array(mapping[:value_tokens]).first
    return token_positions(text, token) if token

    pattern = Array(mapping[:value_patterns]).first
    return [] unless pattern

    folded = I18n.transliterate(text.to_s)
    positions = []
    folded.scan(pattern) { positions << Regexp.last_match.begin(0) }
    positions
  end

  def token_spans(text)
    folded = I18n.transliterate(text.to_s)
    spans = []
    folded.scan(/[[:alnum:]]+/) { spans << [ Regexp.last_match(0), Regexp.last_match.begin(0) ] }
    spans
  end

  def identifier_missing?(identifiers, mapping)
    expected = Array(mapping[:entity_tokens]).select { |token| identifier_shaped?(token) }
    return false if expected.empty?

    canonicals = Array(identifiers).map { |identifier| identifier.canonical.to_s }
    expected.any? do |token|
      canonicals.exclude?(token.delete("-._").upcase)
    end
  end

  def identifier_shaped?(token)
    core = token.to_s
    return false unless core.match?(/\A[A-Z0-9]+(?:[-._][A-Z0-9]+)*\z/)

    compact = core.delete("-._")
    compact.length.between?(2, 12) && !compact.match?(/\A\d+(?:V|A|ER|DO)\z/)
  end
end

class WordingMultilookupProbe
  class Blocked < StandardError; end

  PinnedDocument = Struct.new(:id, :display_name, :s3_key, :source_uri, keyword_init: true) do
    def display_s3_uri(_bucket)
      source_uri
    end
  end

  PRIOR_GOAL = "¿A qué borne corresponde el presostato?"
  CASES = [
    {
      id: 1,
      corpus: :elemont,
      question: "¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?",
      mappings: [
        { entity: "Seguridad OUT", relation: "connection", entity_tokens: %w[Seguridad OUT], value_label: "23", value_tokens: %w[23] },
        { entity: "Seguridad IN", relation: "connection", entity_tokens: %w[Seguridad IN], value_label: "24", value_tokens: %w[24] }
      ]
    },
    {
      id: 2,
      corpus: :elemont,
      question: "¿Dónde está conectada Seguridad IN en la bornera del tablero?",
      mappings: [
        { entity: "Seguridad IN", relation: "connection", entity_tokens: %w[Seguridad IN], value_label: "24", value_tokens: %w[24] }
      ]
    },
    {
      id: 3,
      corpus: :elemont,
      question: "¿A qué borne corresponde el micro de nivel inferior?",
      mappings: [
        { entity: "inferior", relation: "connection", entity_tokens: %w[inferior], value_label: "30", value_tokens: %w[30] }
      ]
    },
    {
      id: 4,
      corpus: :elemont,
      question: "¿A qué borne corresponde el micro de nivel superior?",
      mappings: [
        { entity: "superior", relation: "connection", entity_tokens: %w[superior], value_label: "31", value_tokens: %w[31] }
      ]
    },
    {
      id: 5,
      corpus: :elemont,
      question: "¿Cuáles son los bornes del micro de nivel inferior y del micro de nivel superior?",
      mappings: [
        { entity: "inferior", relation: "connection", entity_tokens: %w[inferior], value_label: "30", value_tokens: %w[30] },
        { entity: "superior", relation: "connection", entity_tokens: %w[superior], value_label: "31", value_tokens: %w[31] }
      ]
    },
    {
      id: 6,
      corpus: :elemont,
      question: "¿A qué borne corresponde la llamada de nivel 1?",
      mappings: [
        { entity: "llamada nivel 1", relation: "connection", entity_tokens: %w[llamada 1], value_label: "33", value_tokens: %w[33] }
      ]
    },
    {
      id: 7,
      corpus: :elemont,
      question: "¿A qué borne corresponde la llamada de nivel 2?",
      mappings: [
        { entity: "llamada nivel 2", relation: "connection", entity_tokens: %w[llamada 2], value_label: "34", value_tokens: %w[34] }
      ]
    },
    {
      id: 8,
      corpus: :elemont,
      question: "¿Cuáles son los bornes de llamada de nivel 1 y nivel 2?",
      mappings: [
        { entity: "llamada nivel 1", relation: "connection", entity_tokens: %w[llamada 1], value_label: "33", value_tokens: %w[33] },
        { entity: "llamada nivel 2", relation: "connection", entity_tokens: %w[llamada 2], value_label: "34", value_tokens: %w[34] }
      ]
    },
    {
      id: 9,
      corpus: :elemont,
      question: "Elemont MH, ¿cuál es el relé de SUBE?",
      mappings: [
        { entity: "SUBE", relation: "attribution", entity_tokens: %w[SUBE], value_label: "K1", value_tokens: %w[K1] }
      ]
    },
    {
      id: 10,
      corpus: :elemont,
      question: "¿Y para BAJA cuál es el relé?",
      mappings: [
        { entity: "BAJA", relation: "attribution", entity_tokens: %w[BAJA], value_label: "K2", value_tokens: %w[K2] }
      ]
    },
    {
      id: 11,
      corpus: :elemont,
      question: "¿Qué relés corresponden a SUBE y BAJA en este tablero?",
      mappings: [
        { entity: "SUBE", relation: "attribution", entity_tokens: %w[SUBE], value_label: "K1", value_tokens: %w[K1] },
        { entity: "BAJA", relation: "attribution", entity_tokens: %w[BAJA], value_label: "K2", value_tokens: %w[K2] }
      ]
    },
    {
      id: 12,
      corpus: :elemont,
      question: "¿Cómo están configurados T1 y T2?",
      mappings: [
        { entity: "T1", relation: "configuration", entity_tokens: %w[T1], value_label: "modo E, t<3 min", value_patterns: [ /modo\s*E\b/i, /(?:<\s*)?3\s*min/i ] },
        { entity: "T2", relation: "configuration", entity_tokens: %w[T2], value_label: "modo Wu, t<1 s", value_patterns: [ /modo\s*Wu\b/i, /(?:<\s*)?1\s*s(?:eg(?:undo)?s?)?\b/i ] }
      ]
    },
    {
      id: 13,
      corpus: :seguridades,
      question: "En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?",
      mappings: [
        { entity: "F1", relation: "attribution", entity_tokens: %w[F1], open_value: true, value_excludes: %w[F1 F2 EDEL K2] },
        { entity: "F2", relation: "attribution", entity_tokens: %w[F2], open_value: true, value_excludes: %w[F1 F2 EDEL K2] }
      ]
    },
    {
      id: 14,
      corpus: :seguridades,
      question: "¿qué indican F1 y F2?",
      mappings: [
        { entity: "F1", relation: "attribution", entity_tokens: %w[F1], open_value: true, value_excludes: %w[F1 F2] },
        { entity: "F2", relation: "attribution", entity_tokens: %w[F2], open_value: true, value_excludes: %w[F1 F2] }
      ]
    },
    {
      id: 15,
      corpus: :seguridades,
      question: "En EDEL K2 con dos embarques, ¿qué fotocélulas identifica el manual para cada embarque?",
      mappings: [
        { entity: "F1", relation: "attribution", entity_tokens: %w[F1], open_value: true, value_excludes: %w[F1 F2 EDEL K2] },
        { entity: "F2", relation: "attribution", entity_tokens: %w[F2], open_value: true, value_excludes: %w[F1 F2 EDEL K2] }
      ]
    }
  ].freeze

  def self.autorun?
    return false if ENV["WORDING_MULTILOOKUP_PROBE"] == "require"

    mine = File.expand_path(__FILE__)
    return true if File.expand_path($PROGRAM_NAME) == mine

    ARGV.any? do |arg|
      File.expand_path(arg) == mine
    rescue StandardError
      false
    end
  end

  def initialize(env: ENV)
    @env = env
    @output_path = env.fetch(
      "RAG_WORDING_PROBE_OUTPUT",
      "tmp/pilot_gate/wording_multilookup_probe_2026-09-29.json"
    )
  end

  def run!
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    account = find_account!
    documents = {
      seguridades: find_document!(account, "%SEGURIDADES%"),
      elemont: find_document!(account, "%Montacargas%")
    }
    service = BedrockRagService.new(account: account, knowledge_base_id: @env["RAG_PROBE_KNOWLEDGE_BASE_ID"].presence)
    raise Blocked, "Knowledge Base ID is not configured" if service.instance_variable_get(:@knowledge_base_id).blank?

    install_tape(service)
    results = CASES.map { |probe| measure_case(service, account, documents, probe) }
    payload = {
      measured_at: Time.current.utc.iso8601(6),
      counterfactual_function: {
        name: "anchor_phrase",
        definition: "Transliterate the current turn, drop the closed function-word list, keep every other token in order. No oracle values. No historical identifiers.",
        function_words: WordingMultilookupDiagnosis::FUNCTION_WORDS
      },
      prior_goal_text: PRIOR_GOAL,
      knowledge_base_id: service.instance_variable_get(:@knowledge_base_id),
      knowledge_base_bucket: KbDocument::KB_BUCKET,
      episode_flag_enabled: Rag::FieldCompanionEpisodeFlag.enabled?,
      documents: documents.transform_values { |document| document_payload(document) },
      cases: results,
      unmeasured: results.count { |row| !row[:measured] }
    }
    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(payload))
    puts results.map { |row| summary_line(row) }.join("\n")
    puts "wrote #{@output_path} unmeasured=#{payload[:unmeasured]}"
    payload
  end

  def exit_code(payload)
    payload[:unmeasured].zero? && payload[:cases].all? { |row| measured_row?(row) } ? 0 : 1
  end

  private

  def summary_line(row)
    covered = Array(row[:mappings]).map { |mapping| "#{mapping[:entity_or_designator]}=#{mapping[:covered] ? 'yes' : 'no'}" }.join(",")
    "#{row[:id]} #{row[:primary_cause]} [#{Array(row[:contributing_causes]).join('|')}] #{covered}"
  end

  def measured_row?(row)
    row[:measured] &&
      row[:primary_cause].present? &&
      row[:contributing_causes].is_a?(Array) &&
      row[:selected_generation_chunks].is_a?(Array) &&
      row[:mappings].is_a?(Array) &&
      row[:mappings].any?
  end

  def measure_case(service, account, documents, probe)
    document = documents.fetch(probe[:corpus])
    uri = source_uri(document)
    raw = probe[:question]
    effective = production_effective_question(raw)
    analysis = Rag::QueryEntities.analyze(effective)
    clear_tape
    route = build_route(service, account, uri, effective, raw)
    retrieval = nil
    selected = []
    expanded_initial = []
    selection_path = nil
    if route
      retrieval = route.pinned_retrieval
      return unmeasured(probe, raw, effective, "retrieve_failed") if retrieval.is_a?(Rag::StructuredEvidenceRoute::Outcome)

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

    calls = Array(Thread.current[:wml_tape])
    expansions = Array(Thread.current[:wml_expansions])
    initial_call = calls.find { |call| call[:phase] != "counterfactual" }
    rescue_call = calls.select { |call| call[:phase] != "counterfactual" && call[:phase] != "profile" }[1]
    expanded_initial = Array(expansions.first&.dig(:output))
    merged = route ? Array(retrieval[:chunks]) : Array(selected)
    frontiers = frontier_snapshot(route, effective, analysis, probe[:mappings], calls, expansions, selected, merged)
    scored_selected = WordingMultilookupDiagnosis.assess(
      chunks: selected,
      mappings: probe[:mappings],
      reported_answer: nil,
      frontiers: frontiers
    )
    counterfactual = nil
    if needs_counterfactual?(frontiers, scored_selected)
      counterfactual = run_counterfactual(service, uri, account, effective, initial_call)
      bodies = Array(counterfactual.delete(:recovered_chunk_bodies))
      hits = recovered_entities(bodies, probe[:mappings])
      frontiers = frontiers.merge(counterfactual_hits: hits, counterfactual_covered: hits.any?)
      scored_selected = WordingMultilookupDiagnosis.assess(
        chunks: selected,
        mappings: probe[:mappings],
        reported_answer: nil,
        frontiers: frontiers
      )
    end

    reported = scored_selected[:reported_answer]
    generation = { status: "not_run" }
    if scored_selected[:mappings].all? { |mapping| mapping[:covered] }
      generation = generate_once(route, service, account, uri, effective, raw, retrieval, selected)
      reported_text = generation[:reported_answer]
      scored_selected = WordingMultilookupDiagnosis.assess(
        chunks: selected,
        mappings: probe[:mappings],
        reported_answer: reported_text,
        frontiers: frontiers
      )
      reported = scored_selected[:reported_answer]
      if reported_text.blank? || (generation[:status] == "abstained" && generation[:raw_answer_excerpt].blank?)
        return unmeasured(probe, raw, effective, "generation_failed")
      end
    end

    predicate_route = route || predicate_route(service, account, uri, effective, raw)
    legacy = legacy_cover(predicate_route, legacy_window(route, expanded_initial, selected))
    row_mappings = public_mappings(scored_selected[:mappings])
    {
      id: probe[:id],
      measured: true,
      raw_question: raw,
      effective_question: effective,
      episode_empty: episode_measurement(raw),
      episode_prior_goal: (episode_measurement(raw, goal: PRIOR_GOAL) if prior_goal_question?(raw)),
      route_selected: route ? "structured_evidence_route" : nil,
      selection_path: selection_path,
      identifiers: analysis.identifiers.map { |identifier| identifier_payload(identifier) },
      requested_relation: analysis.requested_relation.map(&:to_s).sort,
      initial_retrieval_query: initial_call&.dig(:question),
      initial_number_of_results: initial_call&.dig(:number_of_results),
      retrieved_chunks: summarize_chunks(initial_call&.dig(:chunks)),
      expanded_chunks: summarize_chunks(route ? expanded_initial : []),
      rescue_eligible: frontiers[:rescue_mode].present?,
      rescue_query: frontiers[:rescue_query_text],
      rescue_query_detail: frontiers[:rescue_query_detail],
      rescued_chunks: summarize_chunks(rescue_call&.dig(:chunks)),
      selected_generation_chunks: summarize_chunks(selected),
      legacy_explicit_row_covered: legacy[:predicate],
      legacy_explicit_row_line: legacy[:line],
      counterfactual: counterfactual,
      mappings: row_mappings,
      primary_cause: scored_selected[:primary_cause],
      contributing_causes: scored_selected[:contributing_causes],
      reported_answer: reported,
      generation: generation.except(:reported_answer)
    }
  rescue Blocked
    raise
  rescue BedrockRagService::BedrockServiceError, BedrockRagService::MissingKnowledgeBaseError => e
    raise Blocked, e.message if probe[:id] == 1

    unmeasured(probe, probe[:question], probe[:question], e.message)
  end

  def needs_counterfactual?(frontiers, scored)
    return false if scored[:mappings].all? { |mapping| mapping[:covered] }
    return false if frontiers[:rescue_ran] && !frontiers[:rescue_query_identical]

    true
  end

  def run_counterfactual(service, uri, account, effective, initial_call)
    phrase = WordingMultilookupDiagnosis.anchor_phrase(effective)
    initial = initial_call&.dig(:question).to_s
    if phrase.blank? || phrase.squish.casecmp?(initial.squish)
      return { ran: false, reason: "identical_string", query: phrase, k: 3, force_entity_filter: true, source_uri: uri, chunks: [] }
    end

    Thread.current[:wml_phase] = "counterfactual"
    result = service.retrieve_chunks(
      phrase,
      entity_s3_uris: [ uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      number_of_results: RagRetrievalProfile::PINNED_DOCUMENT_RESULTS,
      account_id: account.id
    )
    {
      ran: true,
      reason: "ran",
      function: "anchor_phrase",
      query: phrase,
      k: RagRetrievalProfile::PINNED_DOCUMENT_RESULTS,
      force_entity_filter: true,
      source_uri: uri,
      chunks: summarize_chunks(result[:chunks]),
      recovered_chunk_bodies: Array(result[:chunks])
    }
  end

  def recovered_entities(chunks, mappings)
    WordingMultilookupDiagnosis.assess(
      chunks: chunks,
      mappings: mappings,
      reported_answer: nil,
      frontiers: { route_selected: true }
    )[:mappings].select { |mapping| mapping[:covered] }.pluck(:entity_or_designator)
  end

  def generate_once(route, service, account, uri, effective, raw, retrieval, selected)
    generator_route = route || predicate_route(service, account, uri, effective, raw)
    generator_route.instance_variable_set(:@generator, AiProvider.new)
    generator_route.instance_variable_set(:@preserve_rescue_window, true) if route.nil?
    payload = retrieval.is_a?(Hash) ? retrieval : { chunks: selected }
    payload = payload.merge(chunks: selected) if route.nil?
    outcome = generator_route.complete_from_retrieval(payload, preexpanded: true, preexpanded_expansions: [])
    result = outcome.respond_to?(:result) ? outcome.result : nil
    answer = result.is_a?(Hash) ? result[:answer].to_s : ""
    raw_answer = result.is_a?(Hash) ? result.dig(:diagnostics, :raw_answer).to_s : ""
    {
      status: outcome.respond_to?(:status) ? outcome.status.to_s : "unknown",
      reported_answer: answer,
      raw_answer_excerpt: raw_answer.gsub(/\s+/, " ").slice(0, 500)
    }
  end

  def frontier_snapshot(route, effective, analysis, mappings, calls, expansions, selected, merged)
    report = route&.retrieval_report || {}
    mode = report[:mode]
    query_text = nil
    detail = nil
    if route && mode
      query_text = route.send(:rescue_query, mode)
      detail = {
        mode: mode.to_s,
        construction: rescue_construction(route, mode, query_text),
        text: query_text,
        identical_to_initial: route.send(:same_retrieval_query?, query_text, effective)
      }
    end
    initial_chunks = Array(calls.find { |call| call[:phase] != "counterfactual" }&.dig(:chunks))
    rescue_chunks = Array(calls.select { |call| %w[production route].include?(call[:phase].to_s) }[1]&.dig(:chunks))
    expanded = Array(expansions.first&.dig(:output))
    initial_covered = coverage_flags(initial_chunks, mappings)
    expanded_covered = coverage_flags(expanded, mappings)
    rescued_covered = coverage_flags(rescue_chunks, mappings)
    merged_covered = coverage_flags(merged, mappings)
    selected_flags = coverage_flags(selected, mappings)
    skipped = rescue_skip_reason(route, mode, query_text, effective, expanded)
    {
      route_selected: !route.nil?,
      rescue_mode: mode&.to_s,
      rescue_ran: report[:rescued] == true,
      rescue_query_text: query_text,
      rescue_query_detail: detail,
      rescue_query_identical: detail ? detail[:identical_to_initial] : false,
      rescue_skipped_reason: skipped,
      analysis_lost: mappings.any? { |mapping| WordingMultilookupDiagnosis.identifier_missing?(analysis.identifiers, mapping) },
      initial_covered_by: initial_covered,
      expanded_covered_by: expanded_covered,
      rescued_covered_by: rescued_covered,
      merged_covered_by: merged_covered,
      selected_covered_by: selected_flags,
      counterfactual_hits: [],
      per_mapping: mappings.map { |mapping|
        entity = mapping[:entity]
        {
          entity: entity,
          analysis_lost: WordingMultilookupDiagnosis.identifier_missing?(analysis.identifiers, mapping),
          initial_covered: initial_covered.include?(entity),
          expanded_covered: expanded.present? ? expanded_covered.include?(entity) : nil,
          rescued_covered: rescue_chunks.present? ? rescued_covered.include?(entity) : false,
          merged_covered: merged_covered.include?(entity)
        }
      }
    }
  end

  def coverage_flags(chunks, mappings)
    return [] if chunks.blank?

    WordingMultilookupDiagnosis.assess(
      chunks: chunks,
      mappings: mappings,
      reported_answer: nil,
      frontiers: {}
    )[:mappings].select { |mapping| mapping[:covered] }.pluck(:entity_or_designator)
  end

  def rescue_skip_reason(route, mode, query_text, effective, expanded)
    return nil unless route && mode
    return nil if route.retrieval_report[:rescued]

    identical = route.send(:same_retrieval_query?, query_text, effective)
    covered = route.send(:rescue_covered?, expanded, mode)
    return "predicate" if covered
    return "identical_query" if identical

    "not_launched"
  end

  def rescue_construction(route, mode, query_text)
    case mode
    when :mapping
      "mapping_rescue_query"
    when :designator
      base = route.send(:rescue_base_text)
      return "rescue_base_text" if base.include?("\n")

      span = route.send(:designator_span, base)
      span.present? && query_text == span ? "designator_span" : "designator_rescue_query"
    else
      nil
    end
  end

  def generation_chunks(route, retrieval)
    expanded = route.send(:scope_identity, retrieval[:chunks])
    ambiguity = route.send(:detect_family_ambiguity, expanded)
    route.instance_variable_set(:@ambiguity, ambiguity)
    exact = route.send(:exact_designator_lookup?)
    route.instance_variable_set(:@exact_lookup, exact)
    if route.instance_variable_get(:@preserve_rescue_window)
      [ expanded, "preserve_rescue_window" ]
    elsif exact
      compact = route.send(:compact_designator_chunks, expanded)
      if compact.present?
        [ compact, "compact_designator" ]
      else
        route.instance_variable_set(:@exact_lookup, false)
        [ route.send(:select_generation_chunks, expanded, ambiguity: ambiguity), "select_generation_chunks" ]
      end
    else
      [ route.send(:select_generation_chunks, expanded, ambiguity: ambiguity), "select_generation_chunks" ]
    end
  end

  def build_route(service, account, uri, effective, raw)
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
      raw_question: raw
    ).tap { |route| install_expand_tape(route) if route }
  end

  def predicate_route(service, account, uri, effective, raw)
    Rag::StructuredEvidenceRoute.new(
      question: effective,
      account: account,
      entity_s3_uris: [ uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: service,
      generator: silent_generator,
      raw_question: raw
    )
  end

  def silent_generator
    generator = Object.new
    generator.define_singleton_method(:query) { |*| raise "probe must not generate" }
    generator
  end

  def legacy_window(route, expanded_initial, selected)
    route && expanded_initial.present? ? expanded_initial : selected
  end

  def legacy_cover(route, chunks)
    needles = route.send(:mapping_overlap_tokens, route.send(:rescue_base_text))
    anchors = (needles & Rag::StructuredEvidenceRoute::MAPPING_ANCHORS).to_a
    shorts = needles.select { |token| token.length <= 3 }.to_a
    borne = route.send(:rescue_base_text).match?(RagRetrievalProfile::BORNE_TERMINAL_PATTERN)
    line = nil
    Array(chunks).each do |chunk|
      route.send(:explicit_lines, chunk[:content]).each do |candidate|
        overlap = (route.send(:mapping_overlap_tokens, candidate) & needles).to_a
        next if overlap.empty?
        next if borne && !candidate.match?(/\d/)
        next if anchors.any? && (anchors & overlap).empty?
        next if shorts.any? && (shorts & overlap).empty?

        line = candidate
        break
      end
      break if line
    end
    { predicate: route.send(:explicit_row_covered?, chunks), line: line }
  end

  def production_effective_question(raw)
    return raw unless Rag::FieldCompanionEpisodeFlag.enabled?

    episode_measurement(raw)[:effective]
  end

  def prior_goal_question?(text)
    normalized = Rag::FollowupQueryRewriter.normalize_label(text.to_s)
    normalized.match?(/\b(?:esta|este)\b/) || text.to_s.match?(/est[áa]n/i)
  end

  def episode_measurement(text, goal: nil)
    state = {}
    if goal
      episode = Rag::ActiveEpisode.open(correlation_id: "query:prior", now: Time.current)
      episode.assign_goal!(goal, correlation_id: "query:prior")
      state = episode.to_h
    end
    result = Rag::ActiveEpisodeTurn.call(
      state: state,
      text: text,
      enabled: true,
      channel: "web",
      shared: false,
      analysis: :failed,
      correlation_id: "query:probe"
    )
    {
      decision: result.decision.to_s,
      composed: result.composed,
      effective: result.composed.presence || text,
      goal: goal
    }
  end

  def public_mappings(scored)
    scored.map do |mapping|
      {
        entity_or_designator: mapping[:entity_or_designator],
        requested_relation: mapping[:requested_relation],
        matched_explicit_evidence: mapping[:matched_explicit_evidence],
        value: mapping[:value],
        covered: mapping[:covered],
        page: mapping[:page],
        chunk_sha256: mapping[:chunk_sha256],
        contradicting_line: mapping[:contradicting_line]
      }
    end
  end

  def identifier_payload(identifier)
    {
      raw: identifier.raw,
      canonical: identifier.canonical,
      shape: identifier.shape.to_s,
      position: identifier.position.to_s
    }
  end

  def summarize_chunks(chunks)
    Array(chunks).map do |chunk|
      metadata = chunk[:metadata].to_h.stringify_keys
      content = chunk[:content].to_s
      {
        rank: chunk[:rank],
        page: metadata["page_number"],
        chunk_sha256: chunk[:chunk_sha256],
        excerpt: content.gsub(/\s+/, " ").slice(0, 240),
        explicit_lines: WordingMultilookupDiagnosis.explicit_lines(content)
      }
    end
  end

  def unmeasured(probe, raw, effective, reason)
    {
      id: probe[:id],
      measured: false,
      raw_question: raw,
      effective_question: effective,
      route_selected: nil,
      identifiers: [],
      requested_relation: [],
      initial_retrieval_query: nil,
      retrieved_chunks: [],
      expanded_chunks: [],
      rescue_eligible: false,
      rescue_query: nil,
      rescued_chunks: [],
      selected_generation_chunks: [],
      mappings: [],
      primary_cause: nil,
      contributing_causes: [],
      reported_answer: nil,
      unmeasured_reason: reason
    }
  end

  def clear_tape
    Thread.current[:wml_tape] = []
    Thread.current[:wml_expansions] = []
    Thread.current[:wml_phase] = "production"
  end

  def install_tape(service)
    service.singleton_class.prepend(RetrieveTape)
  end

  def install_expand_tape(route)
    route.singleton_class.prepend(ExpandTape)
  end

  module RetrieveTape
    def retrieve_chunks(question, entity_s3_uris: [], entity_sources: [], force_entity_filter: false,
                        number_of_results: nil, account_id: nil, correlation_id: nil, route_taken: nil)
      result = super
      tape = Thread.current[:wml_tape]
      if tape
        tape << {
          phase: Thread.current[:wml_phase] || "production",
          question: question,
          number_of_results: number_of_results,
          force_entity_filter: force_entity_filter,
          chunks: result.is_a?(Hash) ? Array(result[:chunks]) : []
        }
      end
      result
    end
  end

  module ExpandTape
    def expand_dividers(retrieved_chunks)
      chunks, expansions = super
      bag = Thread.current[:wml_expansions]
      if bag
        bag << {
          phase: Thread.current[:wml_phase] || "production",
          input: retrieved_chunks,
          output: chunks,
          expansions: expansions
        }
      end
      [ chunks, expansions ]
    end
  end

  def find_account!
    slug = @env["RAG_PROBE_ACCOUNT_SLUG"].presence || "danebo-legacy"
    account = Account.find_by(slug: slug)
    account ||= Account.find_by(id: Integer(@env["RAG_PROBE_ACCOUNT_ID"], exception: false)) if @env["RAG_PROBE_ACCOUNT_ID"]
    return account if account

    raise Blocked, "Account #{slug} was not found."
  end

  def find_document!(account, term)
    key = @env["RAG_PROBE_DOCUMENT_KEY_#{term.delete('%').upcase}"].presence
    scope = KbDocument.where(account_id: account.id)
    document = if key
      scope.find_by(s3_key: key)
    else
      scope.where("display_name ILIKE :term OR s3_key ILIKE :term", term: term).order(:id).first
    end
    return document if document

    identity = identity_for(term)
    return identity if identity

    raise Blocked, "No document matched #{term} for account #{account.id}."
  end

  def identity_for(term)
    needle = term.delete("%").downcase
    path = Rails.root.join("config/document_identities.yml")
    entries = YAML.safe_load_file(path).fetch("documents")
    entry = entries.find do |row|
      row["display_name"].to_s.downcase.include?(needle) || row["s3_key"].to_s.downcase.include?(needle)
    end
    return unless entry

    key = entry.fetch("s3_key")
    PinnedDocument.new(
      id: nil,
      display_name: entry["display_name"],
      s3_key: key,
      source_uri: "s3://#{KbDocument::KB_BUCKET}/#{key}"
    )
  end

  def source_uri(document)
    document.display_s3_uri(KbDocument::KB_BUCKET)
  end

  def document_payload(document)
    {
      id: document.id,
      display_name: document.display_name,
      s3_key: document.s3_key,
      source_uri: source_uri(document)
    }
  end
end

if WordingMultilookupProbe.autorun?
  probe = WordingMultilookupProbe.new
  begin
    payload = probe.run!
  rescue WordingMultilookupProbe::Blocked => e
    warn "BLOCKED: #{e.message}"
    exit 2
  end
  exit probe.exit_code(payload)
end
