# frozen_string_literal: true

require "test_helper"
require "digest"

class BedrockGenerationPromptTest < ActiveSupport::TestCase
  PRE_CHANGE_SHA256 = "ba6e7e51f03c6d72e4b64b4d575baa6353be222c77845423dc79678a7ff985bc"
  # Grounded prompt length before the assignment-conflict sentences, partial contract on.
  PREVIOUS_GROUNDED_CHARS = 11_801

  def prompt
    @prompt ||= with_partial_contract("true") do
      BedrockRagService.load_generation_prompt_template
    end
  end

  test "treats retrieved chunks as evidence candidates" do
    assert_includes prompt, "evidence candidates, not automatically validated facts"
    assert_includes prompt, "Use only information explicitly stated"
    assert_not_includes prompt, "TRUST THE CHUNKS"
    assert_not_includes prompt, "already-validated content"
  end

  test "preserves documentary modality" do
    assert_includes prompt, '"may" is not "must"'
    assert_match(/"check" is\s+not "stop"/, prompt)
    assert_includes prompt, "a mentioned standard is not a mandatory certificate"
  end

  test "does not authorize inferred procedures or industry estimates" do
    assert_includes prompt, "only when explicitly documented"
    assert_includes prompt, "Do not rank probable causes without documentary support"
    assert_not_includes prompt, "approximate industry estimate"
    assert_not_includes prompt, "LOTO"
    assert_not_includes prompt, "estimated man-hours"
  end

  test "limits field verification to observed uncertainty" do
    assert_match(/identify the exact\s+uncertain datum as REQUIRES_FIELD_VERIFICATION/, prompt)
    assert_includes prompt, "never authorizes"
    assert_includes prompt, "PPE rule"
    assert_includes prompt, "stop condition"
  end

  test "requires explicit documentary stop conditions" do
    assert_includes prompt, "include only conditions"
    assert_includes prompt, "explicitly associates with stopping"
    assert_not_includes prompt, "If the site does not match the documentation, STOP"
  end

  test "requires explicit connector pairs and documented LED logic" do
    assert_includes prompt, 'physical connection claim ("component → connector/terminal")'
    assert_includes prompt, "same evidence fragment explicitly names both endpoints as a pair"
    assert_includes prompt, "does not define its on/off logic"
    assert_match(
      /LED-label-only case, include DATA_NOT_AVAILABLE after the prose that identifies the missing on\/off logic/,
      prompt
    )
  end

  # Fase 6b: the model's own reading of a line's position stays banned, and the
  # single carved-out exception is a TOPOLOGY_EDGE record written by ingestion
  # before the model ever sees the page — never something the model infers.
  test "still forbids the model's own reading of a line's position" do
    assert_match(/YOUR OWN\s+reading of a line's position is never evidence/, prompt)
  end

  test "licenses a connection claim only through a traced TOPOLOGY_EDGE record" do
    assert_match(/RECORD_TYPE: TOPOLOGY_EDGE record/, prompt)
    assert_includes prompt, "traced from the drawing before indexing"
    assert_match(/Reproduce its ACTION\s+pair verbatim/, prompt)
    assert_includes prompt, "the diagram's traced connection line"
  end

  test "requires a vision-derived edge to carry its own confirmation qualifier" do
    assert_match(/record's DERIVATION is vision, add that it was read from the image and must be\s+confirmed against the complete diagram/, prompt)
  end

  # I-29 (Gate A-bis): 16% of the measured T1 edges are an "open series" where
  # the traced conductor also runs through an intermediate device the pair
  # never names — reporting only the two endpoints must not read as "this is
  # the whole circuit."
  test "forbids presenting a TOPOLOGY_EDGE pair as the complete circuit" do
    assert_match(
      /not a claim that those are the only two components on that\s+run/,
      prompt
    )
    assert_includes prompt, "never present it as the complete circuit or the whole series"
  end

  test "forbids chaining, inverting, or inventing a TOPOLOGY_EDGE pair" do
    assert_includes prompt, "Never merge two TOPOLOGY_EDGE records into a"
    assert_includes prompt, "chain, never invert one, and never create one for a pair no TOPOLOGY_EDGE record"
    assert_includes prompt, "names — for those, say the diagram shows the wiring and it must be confirmed against"
  end

  test "the TOPOLOGY_EDGE paragraph appears exactly once" do
    assert_equal 1, prompt.scan("RECORD_TYPE: TOPOLOGY_EDGE record").size
  end

  test "flag off restores the pre-change template sha256" do
    disabled_prompt = with_partial_contract(nil) do
      BedrockRagService.load_generation_prompt_template
    end

    assert_equal PRE_CHANGE_SHA256, Digest::SHA256.hexdigest(disabled_prompt)
    assert_not_includes disabled_prompt, BedrockRagService::PARTIAL_ABSTENTION_PROMPT_PREFIX
  end

  test "allows only the fixed safe glossary and forbids inferred device roles" do
    assert_includes prompt, "NO = normally"
    assert_includes prompt, "NC = normally"
    assert_includes prompt, "PTC ="
    assert_includes prompt, "NTC ="
    assert_includes prompt, "does not prove its operating role"
  end

  test "surfaces contradictions and blocks undocumented interventions" do
    assert_includes prompt, "leave the conflict unresolved"
    assert_includes prompt, "must not become an intervention procedure"
  end

  test "treats a heading that disagrees with its own table as a discrepancy" do
    assert_includes prompt, "when the conflict sits inside a single fragment"
    assert_includes prompt, "State both readings explicitly"
  end

  test "an explicit row outranks a loose number drawn beside a label" do
    assert_match(
      /A loose number, or a number drawn beside a label, is not\s+an explicit assignment/,
      prompt
    )
    assert_match(
      /an explicit row\s+\(terminal to function, or the equivalent cell\) has greater authority than that\s+proximity alone/,
      prompt
    )
    assert_match(/has greater authority than that\s+proximity alone/, grounded_prompt)
  end

  test "two incompatible explicit rows stay an unresolved conflict" do
    assert_match(
      /Two incompatible explicit rows stay unresolved: say the available\s+documentation contains incompatible assignments, cite both, and do not choose one/,
      prompt
    )
    assert_includes prompt, "leave the conflict unresolved"
    assert_includes prompt, "Never choose one silently"
    assert_includes prompt, "as are two incompatible explicit rows there"
    assert_includes grounded_prompt, "contains incompatible assignments"
  end

  test "presostato extract stays explicit rows and the prompt does not resolve it" do
    fixture = Rails.root.join("test/fixtures/files/elemont/chunk_p1_2_current.txt").read
    rows = [
      "| 14 | PRESOSTATO IN |",
      "| 15 | PRESOSTATO OUT |",
      "| 24 | PRESOSTATO IN |",
      "| 25 | PRESOSTATO OUT |"
    ]

    rows.each do |row|
      assert_includes fixture, row
      assert_match(/\A\| .+ \| .+ \|/, row)
    end
    assert_not_includes prompt, "PRESOSTATO"
    assert_not_includes prompt, "| 14 |"
    assert_not_includes prompt, "14/15"
    assert_includes prompt, "Two incompatible explicit rows stay unresolved"
  end

  test "a documented procedure is not replaced by the assignment rule" do
    grounded = grounded_prompt

    assert_includes prompt, "Do not replace a procedure the retrieved text already documents."
    assert_includes grounded, "Do not replace a procedure the retrieved text already documents."
    assert_includes grounded, "Cite a procedure as this equipment's fact only when its manual documents it for this component and this function."
    assert_includes grounded, "Do not apply one fixed sequence to every question"
    [ "cadena de seguridad", "foso", "K1", "K2", "Seguridad", "Micro", "Llamada", "Presostato", "H4" ].each do |term|
      assert_not_includes grounded, term, term
    end
  end

  test "does not say the table always wins" do
    [ prompt, grounded_prompt ].each do |rendered|
      assert_no_match(/table always wins/i, rendered)
      assert_no_match(/the table always wins/i, rendered)
      assert_no_match(/always (?:choose|prefer) the table/i, rendered)
      assert_no_match(/la tabla (?:siempre )?gana/i, rendered)
      assert_no_match(/gana siempre/i, rendered)
    end
  end

  test "assignment conflict wording stays within 1.05 of the previous grounded prompt" do
    assert_operator grounded_prompt.length, :<=, (PREVIOUS_GROUNDED_CHARS * 1.05).floor
  end

  test "forbids transplanting a sibling board's wiring onto the model asked about" do
    assert_includes prompt, "use only evidence\n  about that model"
    assert_includes prompt, "is not evidence for the model asked about"
    assert_includes prompt, "any other retrieved chunk that names a different"
    grounded = BedrockRagService.load_generation_prompt_template(grounded_synthesis: true)
    assert_includes grounded, "is not evidence for the model asked about"
  end

  test "grounded synthesis names the manual voice, power state, and internal-note source" do
    grounded = grounded_prompt
    strict = prompt

    assert_includes grounded, "Según el manual"
    assert_includes grounded, "Como verificación de campo"
    assert_includes grounded, "never placed before energizing"
    assert_includes grounded, "Copy numbers exactly"
    assert_includes grounded, "cite that manual and page as the note's source"
    assert_includes grounded, "la nota interna, citando <manual> p. N"
    assert_includes grounded, "not as this equipment's manufacturer instruction"
    assert_includes grounded, "from another manufacturer and does not transfer"
    assert_includes grounded, "it is not evidence of the page's manufacturer or model"
    [ "Según el manual", "Como verificación de campo", "never placed before energizing",
      "cite that manual and page as the note's source",
      "from another manufacturer and does not transfer",
      "it is not evidence of the page's manufacturer or model" ].each do |line|
      assert_not_includes strict, line
    end
  end

  test "grounded synthesis opens as a field companion and allows only observation" do
    grounded = grounded_prompt

    assert_includes grounded, "Open with what the technician can check or do next, anchored on this equipment's cited fact or the allowed layer-3 orientation"
    assert_includes grounded, "name the gap when exact manufacturer guidance is unavailable"
    assert_equal 1, grounded.scan("Open with").size
    assert_includes grounded, "what the manual states, what is inference, and what is unconfirmed"
    assert_includes grounded, "At most one next measurement or photo"
    assert_includes grounded, 'Never open with "La documentación recuperada" or "No encontré"'
    assert_includes grounded, "no mandatory headings"
    assert_includes grounded, "asimetría, posición relativa, roscas, tuercas, resortes"
    assert_includes grounded, "holgura visible, corrosión, deformación"
    assert_includes grounded, "hardware faltante o suelto"
    assert_includes grounded, "herramienta obvia por la forma del elemento"
    assert_includes grounded, "Still forbidden unless the retrieved chunks contain it"
    assert_includes grounded, "número de vueltas, tensión objetivo, tolerancias, setpoints, bypasses"
    assert_not_includes prompt, "asimetría, posición relativa"
    assert_not_includes prompt, "what the technician can check or do next"
  end

  test "grounded no match keeps safe layer three guidance when the exact procedure is missing" do
    grounded = grounded_prompt
    strict = prompt
    line = "Missing an exact model or manufacturer procedure limits specificity"

    assert_includes grounded, line
    assert_includes grounded, "does not suppress the allowed layer-3 observations and safe component-specific checks"
    assert_includes grounded, "Give that useful orientation before the knowledge boundary"
    assert_includes grounded, "never invent a manufacturer value, torque, tolerance, setpoint, bypass, critical sequence"
    assert_not_includes strict, line
    strict_without_partial = with_partial_contract(nil) do
      BedrockRagService.load_generation_prompt_template(grounded_synthesis: false)
    end
    assert_equal PRE_CHANGE_SHA256, Digest::SHA256.hexdigest(strict_without_partial)
  end

  # Fase 3 Rama Generación (holdout v1 `holdout_sibling_ne300_p36` /
  # `holdout_otis_es_ambiguous`): the model ignored the top-scored, model-specific
  # chunk and answered from a differently-named chunk instead.
  test "requires fidelity to the named model's own chunk over any other retrieved chunk" do
    assert_includes prompt, "treat it as the primary source for that model"
    assert_includes prompt, "say so instead of\n  supplying the fact from elsewhere"
  end

  # Fase 3 Rama Generación (holdout v1 `holdout_em4000_v2_absent`): the model
  # silently substituted the only documented version instead of declaring the
  # requested version absent.
  test "declares a version mismatch instead of silently substituting a documented version" do
    assert_includes prompt, "only the\n  other version is documented and the requested one does not appear"
    assert_includes prompt, "Never answer as if"
  end

  # Fase 3 Rama Generación (holdout v1 `holdout_arca_p36_torque`): the model cited a
  # corrupted FIELD_RECORD annotation instead of the chunk's own correct table.
  test "prefers the document's printed table over a FIELD_RECORD block for the same fact" do
    assert_includes prompt, "use the printed table's value"
    assert_includes prompt, "can duplicate or\n  misspell what the table states correctly"
  end

  test "uses output_format_instructions as the single output contract" do
    assert_includes prompt, "$output_format_instructions$"
    # F1: the custom <DOC_REFS> block is retired — its XML parser collided with the
    # native citation format and returned canned "Sorry" responses.
    assert_not_includes prompt, "<DOC_REFS>"
    assert_not_includes prompt, "</DOC_REFS>"
    assert_not_includes prompt, "Reference rules:"
  end

  test "places output_format_instructions last as the sole trailing contract" do
    trimmed = prompt.rstrip
    assert trimmed.end_with?("$output_format_instructions$"),
           "output_format_instructions must be the final directive in the prompt"
  end

  test "keeps concise output rules" do
    assert_includes prompt, "at most three logical sections"
    assert_includes prompt, "No markdown tables"
    assert_includes prompt, "Do not add a generic safety closing"
  end

  private

  def grounded_prompt
    with_partial_contract("true") do
      BedrockRagService.load_generation_prompt_template(grounded_synthesis: true)
    end
  end

  def with_partial_contract(value)
    original = ENV.fetch("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil)
    if value.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = original
    end
  end
end
