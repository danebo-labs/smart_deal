# frozen_string_literal: true

module Rag
  # Deterministic exhaustive functional-test answer (benchmark plan Fase 7).
  #
  # Renders every retrieved FUNCTIONAL_TEST record as one prose paragraph
  # (CG-D19): the heading plus discriminator, the documentary action verbatim,
  # and the documentary result verbatim said as a sentence. A record whose
  # result is DATA_NOT_AVAILABLE says in words that the manual documents no
  # result; the marker itself never reaches the technician.
  #
  # Paragraphs are separated by one blank line. The answer contains ONLY
  # paragraphs: the benchmark evaluator parses every paragraph as an entry
  # with the same localized sentence templates (rag.deterministic.*).
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

        if record.expected_result == DATA_NOT_AVAILABLE
          copy(:test_entry_without_result, title: title, action: sentence(record.action))
        else
          copy(:test_entry, title: title, action: sentence(record.action), result: sentence(record.expected_result))
        end
      end.join("\n\n")
    end
  end
end
