# frozen_string_literal: true

require "set"

module Rag
  # docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md §6 (API) and §7 (eight
  # deterministic stages). Closed spec: gaps found while implementing are called
  # out in comments as corrections, not silent local decisions.
  #
  #   Rag::EvidenceCandidateSelector.new(analysis:, chunks:, expander: nil).select
  #     => Rag::EvidenceSelection
  class EvidenceCandidateSelector
    SELECTOR_VERSION = "evidence_candidate_selector_v1"

    # §5: discovery top_k is MAX_RESULTS (20); this selector narrows it down to
    # MAX_CONTEXTS (<=5) before anything reaches the generator.
    DISCOVERY_RESULTS = RagRetrievalProfile::MAX_RESULTS
    MAX_CONTEXTS = 5

    # §7 etapa 7: the ambiguity threshold is 2 surviving groups, not 3.
    AMBIGUOUS_GROUP_THRESHOLD = 2

    # §7 etapa 5, divider detection. Uses the SAME structural rule that produced
    # the metadata this selector consumes — a divider declares neither a "## "
    # heading nor a "**Section:**" line
    # (docs/RAG_SEGURIDADES_METADATA_BACKFILL_FASE2_DECISION_2026-07-29.md §3.2).
    # Measured over all 97 chunks of SEGURIDADES 1.1-1: exactly 18/18 dividers,
    # zero false positives, zero false negatives.
    #
    # The design's original predicate (heading REQUIRED, no "|", no
    # FIELD_RECORD, body < 400 chars) matched 0/18 real dividers: it inverted
    # the heading condition, and "FIELD_RECORD:" appears in 11 of the 18
    # dividers and in 79/79 content pages, so it discriminates nothing.
    SECTION_MARKER = "**Section:**"
    MAX_NEIGHBOR_PAGES = 2 # §9 risk 4: cap neighbor GETs per divider

    HEADING_LINE = /\A##\s+(.+)\z/

    # §4 label terms, excluding PLACA. PLACA labels a board/location name (the
    # "known" entity a question is scoped to), never the component identifier a
    # direct question already names or an inverse question is looking for — see
    # `identifier_mode` below.
    COMPONENT_LABEL_STEMS = %w[LED SERIE BORNE TERMINAL CONECTOR PIN].freeze

    STATE_PATTERN = /\b(?:encendid[oa]?s?|apagad[oa]?s?|fallo|aver[ií]a|normal|on|off)\b/i.freeze
    CONNECTION_PATTERN = /\b(?:conector(?:es)?|borne(?:s)?|terminal(?:es)?|cablead[oa]s?|CN[-\s]?\d+|XC[-\s]?\d+)\b/i.freeze

    # §4/§7 etapa 3 gap: the design does not give an algorithm for extracting
    # "el término de función" an inverse question describes. These are the
    # generic (not per-document) words filtered out before what remains is
    # treated as the function description to match against the body — question
    # words that name relations, connectives or the identifiers/labels already
    # covered elsewhere never carry function meaning on their own.
    FUNCTION_STOPWORDS = %w[
      que cual cuales quien quienes para con indica indican corresponde
      corresponden identifica identifican senala senalan documenta documentan
      encuentra encuentran cuando donde
    ].freeze

    def initialize(analysis:, chunks:, expander: nil)
      @analysis = analysis
      @chunks = Array(chunks)
      @expander = expander
      @target_identifiers = target_identifiers
      @identifier_mode = @target_identifiers.any? ? :named : :function
    end

    def select
      rejections = []
      expansions = []
      survivors = []

      @chunks.each do |chunk|
        outcome = evaluate(chunk)
        if outcome[:context]
          survivors << outcome[:context]
          expansions << outcome[:expansion] if outcome[:expansion]
        else
          rejections << outcome[:rejection]
        end
      end

      groups = survivors.group_by { |context| [ context.section_key, context.board_key ] }
      result_mode = if groups.size >= AMBIGUOUS_GROUP_THRESHOLD
        :ambiguous
      elsif groups.size == 1
        :direct
      else
        :insufficient
      end

      contexts = survivors.sort_by(&:rank).first(MAX_CONTEXTS)
      answered, abstained = relations_summary(result_mode, groups)

      EvidenceSelection.new(
        mode: result_mode,
        contexts: contexts,
        answered_relations: answered,
        abstained_relations: abstained,
        rejections: rejections,
        expansions: expansions,
        selector_version: SELECTOR_VERSION
      )
    end

    private

    # Etapa 1 (scope) is already resolved upstream — nothing to do here.

    def evaluate(chunk)
      body = chunk[:content].to_s

      return rejection(chunk, 2, :metadata_only_match) if metadata_only_match?(chunk, body)

      primary = @identifier_mode == :function ? evaluate_inverse(chunk, body) : evaluate_direct(chunk, body)
      return finalize(chunk, primary[:context]) if primary[:context]

      if primary[:divider_check] && @expander && divider_chunk?(body)
        expansion_result = attempt_expansion(chunk)
        return expansion_result if expansion_result

        return rejection(chunk, 5, :divider_expansion_failed)
      end

      rejection(chunk, 3, primary[:reason] || :relation_gate_failed)
    end

    # Etapa 4, applied to whatever survived etapas 2+3: asymmetric family gate.
    # confidence >= 0.7 (only reachable from metadata, never from the question
    # per §4) excludes a body that never names the hypothesized family; low
    # confidence never excludes anything (the H2 loop this etapa exists to avoid).
    def finalize(chunk, context)
      return rejection(chunk, 4, :family_mismatch) if family_excluded?(chunk)

      { context: context }
    end

    def family_excluded?(chunk)
      confidence = @analysis.confidence.is_a?(Hash) ? @analysis.confidence[:manufacturer].to_f : 0.0
      return false if confidence < 0.7

      hypothesis = @analysis.manufacturer.to_s
      return false if hypothesis.blank?

      !chunk[:content].to_s.match?(/#{Regexp.escape(hypothesis)}/i)
    end

    # Etapa 2: a candidate whose only match for a question identifier lives in
    # `metadata`/`aliases` is rejected outright — ChunkMergerService#with_section_identity
    # prepends section_identity to a chunk's aliases, so an alias hit alone is
    # never verifiable against the page itself (design §7 etapa 2).
    def metadata_only_match?(chunk, body)
      alias_text = Array(stringified_metadata(chunk)["aliases"]).join(" ")
      return false if alias_text.blank?

      alias_keys = QueryEntities.identifiers(alias_text).map { |identifier| normalized_key(identifier.raw) }
      return false if alias_keys.empty?

      question_keys = @analysis.identifiers.map { |identifier| normalized_key(identifier.raw) }
      return false if (alias_keys & question_keys).empty?

      body_keys = QueryEntities.identifiers(body).map { |identifier| normalized_key(identifier.raw) }
      (question_keys & body_keys).empty?
    end

    # Etapa 3, modo directo: the body must contain an identifier the question
    # names AND a phrase/record answering at least one requested relation — bare
    # presence of the code is not enough (design §7 etapa 3).
    def evaluate_direct(chunk, body)
      fragments = Rag::AnswerSafetyProcessor.fragments(body)
      found_any = false

      @target_identifiers.each do |identifier|
        fragment, evidence_identifier = find_identifier_in_body(identifier, body, fragments)
        next unless fragment

        found_any = true
        next unless responds_to_relation?(fragment)

        return { context: build_context(chunk, body, fragment, [ evidence_identifier ], gate: :direct) }
      end

      { reason: found_any ? :relation_not_documented : :identifier_not_in_evidence, divider_check: true }
    end

    # QueryEntities.identifiers excludes a bare numeric token (§4's guard against
    # "p. 31"/"24 V" reading as identifiers on the QUESTION side). A table row's
    # own identifier column often carries no adjacent label term in the BODY
    # ("12 | STOP Y SEGURIDADES HUECO"), so once a target identifier is already
    # known from the question, a bare numeric match against body text is
    # accepted directly — never invented, only confirmed against a target the
    # question already named.
    def find_identifier_in_body(target, body, fragments)
      target_key = normalized_key(target.raw)
      match = QueryEntities.identifiers(body).find { |identifier| normalized_key(identifier.raw) == target_key }
      if match
        fragment = fragments.find { |candidate| candidate.match?(/\b#{Regexp.escape(match.raw)}\b/i) }
        return [ fragment, match ] if fragment
      end

      return [ nil, nil ] unless target.shape == :numeric

      pattern = /(?<![\p{L}\p{N}])#{Regexp.escape(target.raw)}(?![\p{L}\p{N}])/
      fragment = fragments.find { |candidate| candidate.match?(pattern) }
      fragment ? [ fragment, target ] : [ nil, nil ]
    end

    # Etapa 3, modo inverso: the body must contain the described function AND at
    # least one identifier in :labelled position, extracted from that same
    # evidence fragment — never generated. A function fragment without an
    # associated identifier is rejected with :function_without_identifier.
    def evaluate_inverse(chunk, body)
      keywords = function_keywords
      fragments = Rag::AnswerSafetyProcessor.fragments(body)
      matching = fragments.select { |fragment| function_match?(fragment, keywords) }
      return { reason: :function_not_documented, divider_check: true } if matching.empty?

      matching.each do |fragment|
        labelled = QueryEntities.identifiers(fragment).select { |identifier| identifier.position == :labelled }
        next if labelled.empty?

        return { context: build_context(chunk, body, fragment, labelled, gate: :inverse) }
      end

      { reason: :function_without_identifier, divider_check: true }
    end

    def function_match?(fragment, keywords)
      return false if keywords.empty?

      folded = strip_diacritics(fragment).downcase
      keywords.any? { |keyword| folded.include?(keyword) }
    end

    # See FUNCTION_STOPWORDS: leftover content words (>= 4 chars) from the raw
    # question, once identifiers, label terms and generic verbs are excluded.
    def function_keywords
      question = @analysis.question.to_s
      identifier_words = @analysis.identifiers.map { |identifier| strip_diacritics(identifier.raw).downcase }

      question.scan(/\p{L}+/)
        .map { |word| strip_diacritics(word).downcase }
        .reject { |word| word.length < 4 }
        .reject { |word| label_or_board_term?(word) }
        .reject { |word| FUNCTION_STOPWORDS.include?(word) }
        .reject { |word| identifier_words.include?(word) }
        .uniq
    end

    def label_or_board_term?(word)
      (COMPONENT_LABEL_STEMS + %w[PLACA]).any? do |stem|
        folded = strip_diacritics(stem).downcase
        word == folded || word == "#{folded}s" || word == "#{folded}es"
      end
    end

    # §7 etapa 3 gap: the design does not give an automatic "answers the
    # relation" detector. A fragment that only repeats the bare code (e.g. a
    # heading line) is rejected; one with descriptive content beyond the
    # identifier itself passes. Generic word-count floor, not a per-page rule.
    def responds_to_relation?(fragment)
      fragment.to_s.split(/\s+/).reject(&:empty?).length >= 3
    end

    # Etapa 5: only triggered when a chunk passed identity but failed etapa 3 and
    # is divider-shaped. Re-runs etapa 3 on the authorized neighbor; a neighbor
    # that also fails is rejected — expansion is repair, not a license to hand
    # back the divider itself.
    def attempt_expansion(divider_chunk)
      page = stringified_metadata(divider_chunk)["page_number"].presence&.to_i
      return nil unless page

      neighbor_pages(page).each do |neighbor_page|
        neighbor = @expander.neighbor_chunk(divider_chunk: divider_chunk, target_page: neighbor_page)
        next unless neighbor

        neighbor_chunk = neighbor[:chunk]
        neighbor_body = neighbor_chunk[:content].to_s
        reevaluated = @identifier_mode == :function ? evaluate_inverse(neighbor_chunk, neighbor_body) : evaluate_direct(neighbor_chunk, neighbor_body)
        next unless reevaluated[:context]

        finalized = finalize(neighbor_chunk, reevaluated[:context])
        next unless finalized[:context]

        expansion = EvidenceSelection::Expansion.new(
          chunk_sha256: divider_chunk[:chunk_sha256],
          neighbor_chunk_sha256: neighbor_chunk[:chunk_sha256],
          mechanism: neighbor[:mechanism],
          page_number: neighbor_page
        )
        return { context: finalized[:context], expansion: expansion }
      end

      nil
    end

    def neighbor_pages(page)
      [ page - 1, page + 1 ].select(&:positive?).first(MAX_NEIGHBOR_PAGES)
    end

    def divider_chunk?(body)
      heading_label(body).blank? && body.exclude?(SECTION_MARKER)
    end

    # Etapa 6: composite key (section_key, board_key). section_key falls back
    # from section_identity metadata to the chunk's own "## " heading to nil;
    # board_key is model_key+variant (§3) of the board name the chunk itself
    # declares, so sibling boards on the same page never share a group.
    def build_context(chunk, body, fragment, matched_identifiers, gate:)
      metadata = stringified_metadata(chunk)
      heading = heading_label(body)
      section_key = metadata["section_identity"].presence || heading
      board_key = board_key_for(board_name_from(heading, matched_identifiers))
      canonical_name = metadata["canonical_name"].presence
      label = heading.presence || canonical_name || metadata["document_id"]

      EvidenceSelection::EvidenceContext.new(
        section_key: section_key,
        board_key: board_key,
        label: label,
        breadcrumb: [ label, section_key, canonical_name ].compact.uniq,
        document_id: metadata["document_id"].presence,
        source_uri: metadata["original_source_uri"].presence || chunk[:location_uri],
        page_number: metadata["page_number"].presence&.to_i,
        evidence_excerpt: fragment.to_s.strip.first(200),
        identifiers: matched_identifiers,
        relations_covered: relations_covered_for(fragment),
        chunk_sha256: chunk[:chunk_sha256],
        rank: chunk[:rank] || Float::INFINITY,
        match_reason: gate
      )
    end

    # A heading mixes the board name with free descriptive text ("EM2000 -
    # Obstaculo", "EM4000 V1 - Obstaculo") in either manufacturer-first or
    # model-first order (both conventions exist in this corpus — compare
    # AmbiguousModelResponder#heading_label's own splitting heuristics). Rather
    # than guess which side is the model, every identifier found in the heading
    # joins the board name: distinct headings almost never share their full
    # identifier set, and siblings that DO (a manufacturer heading repeated
    # across boards) still differ once the model identifier is included.
    def board_name_from(heading, matched_identifiers)
      return matched_identifiers.first&.raw if heading.blank?

      heading_identifiers = QueryEntities.identifiers(heading).map(&:raw)
      heading_identifiers.presence&.join(" ") || heading
    end

    def board_key_for(source)
      return "unknown" if source.blank?

      normalized = QueryEntities.normalize(source)
      [ normalized.model_key, normalized.variant ].compact.join("|")
    end

    def relations_covered_for(fragment)
      covered = Set[:attribution, :location] # a surviving context always names its identifier and its own page/board
      covered << :state if fragment.match?(STATE_PATTERN)
      covered << :connection if fragment.match?(CONNECTION_PATTERN)
      covered
    end

    # Only meaningful in :direct mode — with >= 2 groups the technician has not
    # chosen yet, so nothing is answered or abstained; with 0 groups §2.2's
    # `insufficient_reason` (Fase 3, from `rejections`) carries the explanation.
    def relations_summary(result_mode, groups)
      return [ Set.new, Set.new ] unless result_mode == :direct

      requested = @analysis.requested_relation
      return [ Set.new, Set.new ] if requested.blank?

      covered = groups.values.flatten.each_with_object(Set.new) { |context, set| set.merge(context.relations_covered) }
      [ requested & covered, requested - covered ]
    end

    # A question names its target component ("el LED SPM") when a :labelled
    # identifier survives after excluding board/location names introduced by
    # "placa X" — those name the equipment the question is scoped to, never the
    # component whose meaning is being asked or sought (design §1 F3;
    # QueryEntities::LABEL_STEMS folds PLACA in with LED/SERIE/… for its own
    # extraction purposes, but the two play different roles here). Modo directo
    # matches ONLY against these — a bare mention of the equipment name itself
    # (e.g. "ENIER MXL1" in "En ENIER MXL1, ¿qué serie indica el LED 12?") must
    # never satisfy the gate in place of the actual identifier being asked about.
    def target_identifiers
      board_named = @analysis.question.to_s.scan(/\bplacas?\b\s+([\p{L}\p{N}][\p{L}\p{N}\-\._]*)/i).flatten
      @analysis.identifiers.select do |identifier|
        identifier.position == :labelled && board_named.none? { |raw| raw.casecmp?(identifier.raw) }
      end
    end

    def normalized_key(raw)
      QueryEntities.normalize(raw).key
    end

    def heading_label(body)
      line = body.to_s.lines.map(&:strip).find { |candidate| candidate.match?(HEADING_LINE) }
      return nil unless line

      line.sub(HEADING_LINE, '\1').strip.presence
    end

    def stringified_metadata(chunk)
      (chunk[:metadata] || chunk["metadata"] || {}).to_h.stringify_keys
    end

    def strip_diacritics(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "")
    end

    def rejection(chunk, stage, reason)
      { rejection: EvidenceSelection::Rejection.new(chunk_sha256: chunk[:chunk_sha256], stage: stage, reason: reason) }
    end
  end
end
