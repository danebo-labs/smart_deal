# frozen_string_literal: true

module Rag
  # Deterministic exhaustive functional-test answer (benchmark plan Fase 7).
  #
  # Renders every retrieved FUNCTIONAL_TEST record as a three-line block:
  #
  #   Prueba: <heading + discriminator>
  #   Acción: <documentary action, verbatim>
  #   Resultado esperado: <documentary result, verbatim — DATA_NOT_AVAILABLE kept>
  #
  # Blocks are separated by one blank line. The answer contains ONLY blocks —
  # the benchmark evaluator parses every paragraph as an entry.
  class FunctionalTestRenderer < DeterministicRenderer
    def generation_mode
      "deterministic_functional_tests"
    end

    private

    def number_of_results
      FULL_SCOPE_CANDIDATES
    end

    # A record qualifies when the DOCUMENT itself presents it under a test
    # heading ("Prueba…", "Test…", "2.4.x Prueba…") or as the continuation of
    # one. This is language-generic — the same signal the ingestion contract
    # uses for typing — NOT a manual-specific rule: FUNCTIONAL_TEST records
    # that live under component-description or operation headings (e.g.
    # "Controles de tierra", "Operaciones en la Plataforma") describe behavior,
    # not a pre-use test checklist, and rendering them would reassign actions
    # between sections.
    TEST_HEADING = /\b(?:prueba|test)\b/i
    CONTINUATION_HEADING = /\(continuación de página anterior\)/i

    # Natural ledger order is already rank → physical order (chunks arrive
    # sorted by rank; records preserve in-chunk order).
    def select_records(ledger)
      ledger.records.select do |record|
        record.type == "FUNCTIONAL_TEST" &&
          (record.source.match?(TEST_HEADING) || record.source.match?(CONTINUATION_HEADING))
      end
    end

    def render(records)
      heading_seen = Hash.new(0)

      records.map do |record|
        heading_seen[record.source] += 1
        occurrence = heading_seen[record.source]
        title = occurrence > 1 ? "#{record.source} (#{occurrence})" : record.source

        [
          "#{label(:test_label)}: #{title}",
          "#{label(:action_label)}: #{record.action}",
          "#{label(:expected_result_label)}: #{record.expected_result}"
        ].join("\n")
      end.join("\n\n")
    end
  end
end
