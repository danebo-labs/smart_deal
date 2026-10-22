# frozen_string_literal: true

require "test_helper"

class Rag::EvidenceRecordContextTest < ActiveSupport::TestCase
  NARRATIVE = "La puerta se re-abre sola. Comprobar la sensibilidad del #54."
  LABEL = "THIS JOB'S EQUIPMENT: Módulo electrónico VF5+ Fermator"

  test "documentary candidate keeps the passage and drops a terminal record block" do
    context = Rag::DocumentIdentityScope.generation_context(
      [ chunk(passage), chunk(second_passage) ],
      [ LABEL, LABEL ],
      records: false
    )

    assert_includes context, NARRATIVE
    assert_includes context, "En caso que el problema persista"
    assert_includes context, LABEL
    assert_includes context, "<source>\n1\n</source>"
    assert_includes context, "<source>\n2\n</source>"
    assert_not_includes context, "FIELD_RECORD"
    assert_not_includes context, "FIELD-SAFETY EVIDENCE RECORDS"
    assert_not_includes context, "TROUBLESHOOTING_STEP"
  end

  test "the default context keeps the records" do
    context = Rag::DocumentIdentityScope.generation_context([ chunk(passage) ], [ LABEL ])

    assert_includes context, NARRATIVE
    assert_includes context, "FIELD_RECORD"
    assert_includes context, "FIELD-SAFETY EVIDENCE RECORDS"
    assert_includes context, "<source>\n1\n</source>"
  end

  test "a plan chunk keeps records and TOPOLOGY_EDGE when the candidate is requested" do
    body = "#{NARRATIVE}\n\n#{records('TOPOLOGY_EDGE', 'A -> B')}"
    chunk = chunk(body)
    prompt = prompt_for("la puerta se reabre sola", [ chunk ], omit_evidence_records: true)

    assert_includes prompt.user, "FIELD-SAFETY EVIDENCE RECORDS"
    assert_includes prompt.user, "RECORD_TYPE: TOPOLOGY_EDGE"
    assert_includes prompt.user, "A -> B"
    assert_equal body, chunk[:content]
  end

  test "a passage made only of records stays intact" do
    only = records("TROUBLESHOOTING_STEP", "Comprobar el #54.")
    context = Rag::DocumentIdentityScope.generation_context([ chunk(only) ], [ LABEL ], records: false)

    assert_includes context, "FIELD_RECORD"
    assert_includes context, "FIELD-SAFETY EVIDENCE RECORDS"
    assert_includes context, LABEL
  end

  test "narrative after the records keeps the original passage" do
    body = "#{passage}\nSigue el texto impreso de la página.\n"
    context = Rag::DocumentIdentityScope.generation_context([ chunk(body) ], [], records: false)

    assert_includes context, "Sigue el texto impreso de la página."
    assert_includes context, "FIELD_RECORD"
    assert_includes context, NARRATIVE
  end

  test "the documentary prompt omits records and leaves citation chunks unchanged" do
    body = passage
    evidence = chunk(body)
    original = evidence[:content].dup
    prompt = prompt_for("¿qué sigue?", [ evidence ], omit_evidence_records: true)
    citations = service.send(:document_identity_citation_records, [ evidence ])

    assert_nil prompt.system
    assert_includes prompt.user, NARRATIVE
    assert_includes prompt.user, "<source>\n1\n</source>"
    assert_includes prompt.user, LABEL
    assert_includes prompt.user, "lines in FIELD_RECORD are extraction annotations"
    results = prompt.user[/Results:.*\n# LANGUAGE AND TONE/m]
    assert_not_includes results, "FIELD_RECORD"
    assert_not_includes results, "FIELD-SAFETY EVIDENCE RECORDS"
    assert_equal original, evidence[:content]
    assert_includes citations.sole[:content], "FIELD_RECORD"
    assert_includes citations.sole[:content], "Comprobar la sensibilidad del #54."

    Rag::CitationAttributionGuard.new(question: "¿qué sigue?", citations: citations).call("Siguiente comprobación [1].")
    Rag::AnswerSafetyProcessor.new(locale: :es).call("Siguiente comprobación [1].", evidence: citations)

    assert_equal original, evidence[:content]
    assert_equal original, citations.sole[:content]
  end

  test "the documentary prompt keeps records unless the candidate is requested" do
    prompt = prompt_for("¿qué sigue?", [ chunk(passage) ], omit_evidence_records: false)

    assert_includes prompt.user, "FIELD_RECORD"
    assert_includes prompt.user, NARRATIVE
  end

  private

  def passage
    "#{NARRATIVE}\n\n#{records('TROUBLESHOOTING_STEP', 'Comprobar la sensibilidad del #54.')}"
  end

  def second_passage
    "En caso que el problema persista, desconectar la fotocélula.\n\n#{records('TROUBLESHOOTING_STEP', 'Desconectar la fotocélula.')}"
  end

  def records(type, action)
    <<~TEXT
      # FIELD-SAFETY EVIDENCE RECORDS

      FIELD_RECORD:
      RECORD_ID: FR-001
      SOURCE_SECTION_OR_PAGE: 8.2
      RECORD_TYPE: #{type}
      ACTION: #{action}
      EXPECTED_RESULT: DATA_NOT_AVAILABLE
      EVIDENCE: #{action}
      END_FIELD_RECORD
    TEXT
  end

  def chunk(body)
    { content: body, metadata: { "page_number" => "12", "canonical_name" => "VF5" } }
  end

  def service
    @service ||= BedrockRagService.allocate
  end

  def prompt_for(question, chunks, omit_evidence_records:)
    service.send(
      :document_identity_generation_prompt,
      question,
      chunks,
      response_locale: :es,
      session_context: "Goal: La puerta se reabre sola",
      output_channel: :web,
      labels: [ LABEL ],
      omit_evidence_records: omit_evidence_records
    )
  end
end
