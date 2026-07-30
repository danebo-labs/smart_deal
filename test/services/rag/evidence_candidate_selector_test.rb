# frozen_string_literal: true

require "test_helper"

# Fase 6 gate for docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md §6/§7 —
# the nine tests §10 exists to require, plus the two ground-truth PDF cases
# confirmed against SEGURIDADES 1.1-1 (SPM ambiguity, EM66 FAIN/RECOBA split).
class Rag::EvidenceCandidateSelectorTest < ActiveSupport::TestCase
  def analysis_for(question)
    Rag::QueryEntities.analyze(question)
  end

  def chunk(content:, rank:, metadata: {}, uri: "s3://bucket/bulk_chunks/1/doc/chunk_0.txt")
    {
      rank: rank,
      content: content,
      score: 1.0 - (rank * 0.01),
      original_source_uri: nil,
      bedrock_source_uri: nil,
      location_uri: uri,
      metadata: metadata,
      chunk_sha256: Digest::SHA256.hexdigest("#{uri}:#{content}")
    }
  end

  def select(question, chunks, expander: nil)
    Rag::EvidenceCandidateSelector.new(analysis: analysis_for(question), chunks: chunks, expander: expander).select
  end

  # Shape of a real divider page in the SEGURIDADES v5 corpus (page 35, ENIER,
  # `chunk_33.txt`): the ingestion header, a prose caption, and degenerate
  # FIELD_RECORD blocks — but NO "## " heading and NO "**Section:**" line. That
  # absence is the rule the Fase 2 backfill used to find exactly 18 dividers
  # among 97 chunks, and it is what Rag::EvidenceCandidateSelector must agree
  # with. Measured length of the real body: 896 characters.
  def real_divider_body(label: "ENIER")
    <<~BODY
      [DOCUMENT: SEGURIDADES 1.1-1.pdf]
      [SOURCE_URI: s3://bucket/uploads/1/doc/original.pdf]
      [SEARCH_ALIASES: #{label}, MXL1, MIGUEL ANGEL NUÑEZ LUZ]

      **Document:** ALJO Control Level 1B Altius

      Title / cover-style slide displaying the label "#{label}" and the reference "- MXL1".
      A footer credits "MIGUEL ANGEL NUÑEZ LUZ". No technical, safety, electrical, or
      procedural content is present on this page.

      # FIELD-SAFETY EVIDENCE RECORDS

      FIELD_RECORD:
      RECORD_ID: FR-48E7C1E8AABD194D
      SOURCE_SECTION_OR_PAGE: #{label}
      RECORD_TYPE: SCHEMATIC_LABEL
      ACTION: Label reading "#{label}"
      EXPECTED_RESULT: DATA_NOT_AVAILABLE
      EVIDENCE: #{label}
      END_FIELD_RECORD
    BODY
  end

  # §10.1 — etapa 2: an alias-only match (never in the body) is rejected, never
  # silently ignored — ChunkMergerService#with_section_identity prepends
  # section_identity to aliases, so an alias hit alone is not verifiable.
  test "a candidate whose only fabricante match lives in aliases is rejected as metadata_only_match" do
    question = "¿Qué indica el LED ALTIUS?"
    candidate = chunk(
      content: "## OTRO EQUIPO\nCTA | SERIE DISTINTA\n",
      rank: 1,
      metadata: { "aliases" => [ "ALTIUS" ] }
    )

    selection = select(question, [ candidate ])

    assert_equal :insufficient, selection.mode
    assert_equal 1, selection.rejections.size
    assert_equal :metadata_only_match, selection.rejections.first.reason
    assert_equal 2, selection.rejections.first.stage
  end

  # §10.2 — modo inverso: the described function appears without an associated
  # identifier in the same fragment -> :function_without_identifier.
  test "inverse mode rejects a function fragment with no associated identifier" do
    question = "¿Qué conector documenta el obstáculo en la placa?"
    candidate = chunk(
      content: "## Seccion\nEl obstaculo se describe en la parte inferior de la pagina.\n",
      rank: 1
    )

    selection = select(question, [ candidate ])

    assert_equal :insufficient, selection.mode
    assert_equal [ :function_without_identifier ], selection.rejections.map(&:reason)
  end

  # §10.3 — tokibat_dl27_v2: attribution answered, state abstained (F4).
  test "answers attribution and abstains state when the body never documents on/off logic" do
    question = "En TOKIBAT 2007, ¿qué indica el LED DL27 y cuándo se enciende?"
    candidate = chunk(
      content: "## TOKIBAT 2007\nDL27 | SEGURIDAD HUECO\n",
      rank: 1,
      metadata: { "document_id" => "doc-tokibat", "page_number" => 40 }
    )

    selection = select(question, [ candidate ])

    assert_equal :direct, selection.mode
    assert_equal Set[:attribution], selection.answered_relations
    assert_equal Set[:state], selection.abstained_relations
  end

  # §10.4 — em4000_obstaculo_conectores: the board_key barrier. Even though
  # CN7/CN8 (EM2000) are in the retrieved set, no EvidenceContext carrying them
  # ever lands in the EM4000 V1 group.
  test "never merges a sibling board's connectors into another board's group" do
    question = "En EM4000 V1, ¿qué conectores documenta el encabezado del obstáculo en la placa?"
    em4000 = chunk(
      content: "## EM4000 V1 - Obstaculo\nConectores: XC4, XC7 (obstaculo)\n",
      rank: 1,
      metadata: { "document_id" => "doc-em", "page_number" => 33 }
    )
    em2000 = chunk(
      content: "## EM2000 - Obstaculo\nConectores: CN7, CN8 (obstaculo)\n",
      rank: 2,
      metadata: { "document_id" => "doc-em", "page_number" => 31 }
    )

    selection = select(question, [ em4000, em2000 ])

    em4000_context = selection.contexts.find { |c| c.board_key.start_with?("EM4000") }
    em2000_context = selection.contexts.find { |c| c.board_key == "EM2000" }

    assert em4000_context, "expected an EM4000 V1 context to survive"
    assert em2000_context, "expected an EM2000 context to survive"
    assert_not_equal em4000_context.board_key, em2000_context.board_key
    assert_equal %w[XC4 XC7], em4000_context.identifiers.map(&:canonical).sort
    assert_equal %w[CN7 CN8], em2000_context.identifiers.map(&:canonical).sort
  end

  # §10.5 — normalization barrier reused for grouping: EDEL-K2/EDEL-K3 distinct,
  # EM 4000/EM4000 identical, EM4000 V1 a distinct variant of the same model_key.
  test "board_key follows the §3 normalization barrier" do
    selector = Rag::EvidenceCandidateSelector.new(analysis: analysis_for("x"), chunks: [])

    edel_k2 = selector.send(:board_key_for, "EDEL-K2")
    edel_k3 = selector.send(:board_key_for, "EDEL-K3")
    em4000 = selector.send(:board_key_for, "EM4000")
    em_4000_spaced = selector.send(:board_key_for, "EM 4000")
    em4000_v1 = selector.send(:board_key_for, "EM4000 V1")

    assert_not_equal edel_k2, edel_k3
    assert_equal em4000, em_4000_spaced
    assert_not_equal em4000, em4000_v1
    assert em4000_v1.start_with?("EM4000")
  end

  # §10.6 — elecmegon_obstaculo_ambiguo: two documented groups is ambiguity, the
  # threshold-3-to-2 regression this etapa 7 change exists to fix.
  test "two surviving groups is ambiguous, not silently resolved" do
    question = "¿Qué LED indica la serie de obstáculo o fotocélula en las placas Elecmegon?"
    em2000 = chunk(content: "## EM2000 - Obstaculo\nLED: AP (obstaculo)\n", rank: 1)
    em3000 = chunk(content: "## EM3000 - Obstaculo\nLED: CN (obstaculo)\n", rank: 2)

    selection = select(question, [ em2000, em3000 ])

    assert_equal :ambiguous, selection.mode
    assert_equal 2, selection.contexts.map { |c| [ c.section_key, c.board_key ] }.uniq.size
  end

  # §10.7 — divider expansion registers its mechanism and never crosses a
  # neighbor that declares its own, different section.
  test "divider expansion resolves through the injected expander and records its mechanism" do
    question = "En ENIER MXL1, ¿qué serie indica el LED 12?"
    divider = chunk(
      content: real_divider_body,
      rank: 1,
      metadata: { "document_id" => "doc-enier", "page_number" => 3 }
    )
    neighbor_chunk = chunk(
      content: "12 | STOP Y SEGURIDADES HUECO",
      rank: 5,
      metadata: { "document_id" => "doc-enier", "page_number" => 4 }
    )
    fake_expander = Object.new
    fake_expander.define_singleton_method(:neighbor_chunk) do |divider_chunk:, target_page:|
      next nil unless target_page == 4

      { chunk: neighbor_chunk, mechanism: :adjacent_page_interim }
    end

    selection = select(question, [ divider ], expander: fake_expander)

    assert_equal :direct, selection.mode
    assert_equal 1, selection.expansions.size
    assert_equal :adjacent_page_interim, selection.expansions.first.mechanism
    assert_equal 4, selection.expansions.first.page_number
    assert_equal 1, selection.contexts.size
    assert_equal 4, selection.contexts.first.page_number
  end

  # §10.8 — insufficient always carries a non-empty audit trail: never an
  # absence when the data existed in a candidate chunk that was rejected.
  test "insufficient mode always carries non-empty rejections" do
    question = "En EDEL-K3, ¿qué indican los LEDs 37, 39 y 41?"
    candidate = chunk(content: "## OTRO MANUAL\nNo relacionado.\n", rank: 1)

    selection = select(question, [ candidate ])

    assert_equal :insufficient, selection.mode
    assert_empty selection.contexts
    assert_not_empty selection.rejections
  end

  # §10.9 — the generator never receives more than MAX_CONTEXTS, even when more
  # candidates in the same group survive.
  test "caps contexts at MAX_CONTEXTS even with more surviving candidates" do
    question = "¿Qué indica el LED SPM?"
    chunks = (1..7).map do |rank|
      chunk(content: "## HIDRA - TPR50\nSPM | SERIE PUERTAS CABINA - EXTERIORES\n", rank: rank)
    end

    selection = select(question, chunks)

    assert_equal :direct, selection.mode
    assert_equal Rag::EvidenceCandidateSelector::MAX_CONTEXTS, selection.contexts.size
  end

  # Etapa 4 — asymmetric fabricante gate: high confidence excludes a body that
  # never names the hypothesized family; low confidence never excludes anything
  # (the H2 loop this gate exists to avoid).
  test "family gate excludes only at high confidence, never at low confidence" do
    question = "¿Qué indica el LED SPM?"
    base_analysis = analysis_for(question)
    candidate = chunk(content: "## OTRA MARCA\nSPM | SERIE X\n", rank: 1)

    low_confidence = base_analysis.with(manufacturer: "ALTIUS", confidence: { manufacturer: 0.4 })
    permissive = Rag::EvidenceCandidateSelector.new(analysis: low_confidence, chunks: [ candidate ]).select
    assert_equal :direct, permissive.mode

    high_confidence = base_analysis.with(manufacturer: "ALTIUS", confidence: { manufacturer: 0.9 })
    strict = Rag::EvidenceCandidateSelector.new(analysis: high_confidence, chunks: [ candidate ]).select
    assert_equal :insufficient, strict.mode
    assert_equal :family_mismatch, strict.rejections.first.reason
  end

  # Ground truth (PDF-confirmed): SPM is documented in two sections with two
  # distinct series (p9 CARLOS SILVA vs p88-91 SISTEL) — a generic SPM question
  # must be ambiguous with exactly two groups.
  test "a generic SPM question is ambiguous across the two documented sections" do
    question = "¿A qué serie corresponde el LED SPM?"
    carlos_silva = chunk(
      content: "## HIDRA - TPR50\nSPM | SERIE PUERTAS CABINA - EXTERIORES\n",
      rank: 1,
      metadata: { "section_identity" => "CARLOS SILVA", "canonical_name" => "SEGURIDADES 1.1-1", "page_number" => 9 }
    )
    sistel = chunk(
      content: "## SISTEL - MODELO X\nSPM | SERIE DE PUERTAS\n",
      rank: 2,
      metadata: { "section_identity" => "SISTEL", "canonical_name" => "SEGURIDADES 1.1-1", "page_number" => 89 }
    )

    selection = select(question, [ carlos_silva, sistel ])

    assert_equal :ambiguous, selection.mode
    assert_equal 2, selection.contexts.map { |c| [ c.section_key, c.board_key ] }.uniq.size
  end

  # Ground truth: naming TPR50 explicitly (the fixture's tpr50_spm case) resolves
  # directly once only that section's evidence is in play.
  test "naming TPR50 explicitly resolves direct" do
    question = "En el modelo TPR50 de Carlos Silva, ¿a qué serie corresponde el LED SPM?"
    carlos_silva = chunk(
      content: "## HIDRA - TPR50\nSPM | SERIE PUERTAS CABINA - EXTERIORES\n",
      rank: 1,
      metadata: { "section_identity" => "CARLOS SILVA", "canonical_name" => "SEGURIDADES 1.1-1", "page_number" => 9 }
    )

    selection = select(question, [ carlos_silva ])

    assert_equal :direct, selection.mode
  end

  # Ground truth: pages 46 and 79 are the same plate "EM66 — PLACA EKM 1000" in
  # two different sections (FAIN, RECOBA) — they must not merge into one group.
  test "the same plate label in two different sections never merges" do
    question = "¿Qué indica el LED X1?"
    fain = chunk(
      content: "## EM66 - PLACA EKM 1000\nX1 | SERIE TEST FAIN\n",
      rank: 1,
      metadata: { "section_identity" => "FAIN", "page_number" => 46 }
    )
    recoba = chunk(
      content: "## EM66 - PLACA EKM 1000\nX1 | SERIE TEST RECOBA\n",
      rank: 2,
      metadata: { "section_identity" => "RECOBA", "page_number" => 79 }
    )

    selection = select(question, [ fain, recoba ])

    assert_equal :ambiguous, selection.mode
    section_keys = selection.contexts.map(&:section_key)
    assert_includes section_keys, "FAIN"
    assert_includes section_keys, "RECOBA"
  end

  # ---------------------------------------------------------------------------
  # Fase 6 backend — resto de la lista de docs/RAG_PRECISION_V2_PLAN_2026-07-29.md
  # §5 Fase 6 (ground truth: script/fixtures/rag_seguridades_pilot_10q_v2.json).
  # ---------------------------------------------------------------------------

  # altius_d8_d11 — el fragmento de D8 nunca arrastra la fila de D9/D10, aunque
  # las cuatro compartan chunk (penalizado: "confunde con D9/D10").
  test "ALTIUS D8 resolves to its own row without mixing with D9/D10/D11" do
    question = "En ALTIUS, ¿qué serie indica el LED D8?"
    body = "## ALTIUS\nD8 | SERIE SEGURIDAD LIMITADOR\nD9 | SEGURIDAD HUECO\n" \
      "D10 | SEGURIDAD CABINA\nD11 | SERIE CERRADURAS CABINA\n"

    selection = select(question, [ chunk(content: body, rank: 1) ])

    assert_equal :direct, selection.mode
    excerpt = selection.contexts.first.evidence_excerpt
    assert_includes excerpt, "SERIE SEGURIDAD LIMITADOR"
    assert_not_includes excerpt, "SEGURIDAD HUECO"
    assert_not_includes excerpt, "CERRADURAS CABINA"
  end

  test "ALTIUS D11 resolves to its own row without mixing with D8/D9/D10" do
    question = "En ALTIUS, ¿qué serie indica el LED D11?"
    body = "## ALTIUS\nD8 | SERIE SEGURIDAD LIMITADOR\nD9 | SEGURIDAD HUECO\n" \
      "D10 | SEGURIDAD CABINA\nD11 | SERIE CERRADURAS CABINA\n"

    selection = select(question, [ chunk(content: body, rank: 1) ])

    assert_equal :direct, selection.mode
    excerpt = selection.contexts.first.evidence_excerpt
    assert_includes excerpt, "SERIE CERRADURAS CABINA"
    assert_not_includes excerpt, "SERIE SEGURIDAD LIMITADOR"
  end

  # cta_sr8p_sph — dos placas de nombre visualmente parecido (penalizado:
  # "confunde con CR8PH2/M8PC/CR10P") nunca comparten board_key ni se mezclan
  # en una sola respuesta: la salida segura ante dos placas con el mismo LED
  # es ambigüedad, no una fusión.
  test "SR8P and a visually similar sibling board never merge into one answer" do
    question = "En la placa SR8P de CTA, ¿qué serie indica el LED SPH?"
    # No internal ". " here: FRAGMENT_SPLIT_PATTERN treats a period followed by
    # whitespace as a sentence boundary, which would split "CAB. EXT." apart.
    sr8p = chunk(content: "## SR8P - CTA\nSPH | SERIE PUERTAS CAB EXT CERRADA\n", rank: 1)
    cr8ph2 = chunk(content: "## CR8PH2 - CTA\nSPH | SERIE DISTINTA\n", rank: 2)

    selection = select(question, [ sr8p, cr8ph2 ])

    assert_equal :ambiguous, selection.mode
    board_keys = selection.contexts.map(&:board_key)
    assert_equal 2, board_keys.uniq.size

    sr8p_context = selection.contexts.find { |c| c.evidence_excerpt.include?("CAB EXT CERRADA") }
    cr8ph2_context = selection.contexts.find { |c| c.evidence_excerpt.include?("SERIE DISTINTA") }
    assert sr8p_context, "expected the SR8P context to keep its own series"
    assert cr8ph2_context, "expected the CR8PH2 context to keep its own series"
    assert_not_equal sr8p_context.board_key, cr8ph2_context.board_key
  end

  # em2000_leds_seguridad — penalizado: "mezcla con LEDs EM3000" (\bSPE\b). SPE
  # pertenece a EM3000 (fotocélula), nunca al obstáculo de EM2000 (AP).
  test "EM2000 obstacle question never surfaces EM3000's SPE" do
    question = "¿Qué LED indica la serie de obstáculo en la placa EM2000?"
    em2000 = chunk(content: "## EM2000 - Obstaculo\nLED: AP (obstaculo)\n", rank: 1)
    em3000 = chunk(content: "## EM3000 - Fotocelula\nLED: SPE (fotocelula tension)\n", rank: 2)

    selection = select(question, [ em2000, em3000 ])

    assert_equal :direct, selection.mode
    assert_equal 1, selection.contexts.size
    assert_equal %w[AP], selection.contexts.first.identifiers.map(&:canonical)
    assert_not_includes selection.contexts.flat_map { |c| c.identifiers.map(&:canonical) }, "SPE"
  end

  # tpr50_spm — penalizado: "confunde con TPR60 PP". PP nunca aparece en el
  # cuerpo de TPR50, así que el candidato TPR60 se rechaza por
  # identifier_not_in_evidence en vez de contaminar la respuesta.
  test "TPR50 SPM question never surfaces TPR60's PP" do
    question = "En el modelo TPR50 de Carlos Silva, ¿a qué serie corresponde el LED SPM?"
    tpr50 = chunk(
      content: "## HIDRA - TPR50\nSPM | SERIE PUERTAS CABINA - EXTERIORES\n",
      rank: 1,
      metadata: { "section_identity" => "CARLOS SILVA", "canonical_name" => "SEGURIDADES 1.1-1", "page_number" => 9 }
    )
    tpr60 = chunk(
      content: "## HIDRA - TPR60\nPP | SERIE PUERTAS CABINA\n",
      rank: 2,
      metadata: { "section_identity" => "CARLOS SILVA", "canonical_name" => "SEGURIDADES 1.1-1", "page_number" => 15 }
    )

    selection = select(question, [ tpr50, tpr60 ])

    assert_equal :direct, selection.mode
    assert_equal 1, selection.contexts.size
    assert_equal %w[SPM], selection.contexts.first.identifiers.map(&:canonical)
    assert_equal [ :identifier_not_in_evidence ], selection.rejections.map(&:reason)
  end

  # edel_k3_leds — penalizado: "copia series de EDEL-K2". Con ambas placas
  # retrievadas, el resultado seguro es ambigüedad (dos board_key distintos),
  # nunca una fusión donde el 37 de K3 muestre la serie de K2 o viceversa.
  test "EDEL-K2 never contaminates EDEL-K3's own series for the shared numeric codes" do
    question = "En EDEL-K3, ¿qué indican los LEDs 37, 39 y 41?"
    edel_k3 = chunk(
      content: "## EDEL-K3\n37 | PUERTAS HUECO\n39 | PUERTAS CABINA\n41 | CERROJOS CABINA Y EXTERIORES\n",
      rank: 1,
      metadata: { "document_id" => "doc-edel", "page_number" => 26 }
    )
    edel_k2 = chunk(
      content: "## EDEL-K2\n37 | SEGURIDADES HUECO\n39 | PUERTAS EXTERIORES\n41 | CERROJOS CABINA\n",
      rank: 2,
      metadata: { "document_id" => "doc-edel", "page_number" => 20 }
    )

    selection = select(question, [ edel_k3, edel_k2 ])

    assert_equal :ambiguous, selection.mode
    board_keys = selection.contexts.map(&:board_key)
    assert_equal 2, board_keys.uniq.size

    k3_context = selection.contexts.find { |c| c.board_key.start_with?("EDELK3") }
    k2_context = selection.contexts.find { |c| c.board_key.start_with?("EDELK2") }
    assert_includes k3_context.evidence_excerpt, "PUERTAS HUECO"
    assert_includes k2_context.evidence_excerpt, "SEGURIDADES HUECO"
    assert_not_equal k3_context.board_key, k2_context.board_key
  end

  # enier_mxl1_leds — penalizado: "asigna series de otros LEDs" (mezcla con
  # PRESOSTATO/TOPE FOSO/TOPE HUIDA). Las filas vecinas de la misma placa no
  # contaminan el LED preguntado.
  test "ENIER MXL1 LED 12 never surfaces a neighboring row's series" do
    question = "En ENIER MXL1, ¿qué serie indica el LED 12 y qué serie indica el LED 19?"
    body = "## ENIER MXL1\n8 | PRESOSTATO\n12 | STOP Y SEGURIDADES HUECO\n19 | TOPE FOSO\n21 | TOPE HUIDA\n"

    selection = select(question, [ chunk(content: body, rank: 1) ])

    assert_equal :direct, selection.mode
    excerpt = selection.contexts.first.evidence_excerpt
    assert_includes excerpt, "STOP Y SEGURIDADES HUECO"
    assert_not_includes excerpt, "PRESOSTATO"
    assert_not_includes excerpt, "TOPE FOSO"
    assert_not_includes excerpt, "TOPE HUIDA"
  end

  # altius_d8 (rag_seguridades_rubric.json v3.2) — mismo mecanismo de
  # abstención que DL27/Thyssen: la atribución de serie se responde, el estado
  # nunca documentado se abstiene explícitamente (F4), en vez de inventarse.
  test "ALTIUS answers attribution and abstains state when the body never documents on/off logic" do
    question = "En ALTIUS, ¿a qué serie corresponde el LED D8 y cuándo se enciende?"
    candidate = chunk(content: "## ALTIUS\nD8 | SERIE SEGURIDAD LIMITADOR\n", rank: 1)

    selection = select(question, [ candidate ])

    assert_equal :direct, selection.mode
    assert_equal Set[:attribution], selection.answered_relations
    assert_equal Set[:state], selection.abstained_relations
  end

  # thyssen_serie_e_leds — el documento nunca declara lógica normal/fallo para
  # L9/L8/L7 (fixture: "se abstiene de normal/fallo"); la atribución de serie
  # se responde, pero el estado se abstiene explícitamente (F4).
  test "Thyssen Serie E answers attribution and abstains state for L9" do
    question = "En Thyssen Serie E, ¿qué indica el LED L9 y cuándo se enciende?"
    candidate = chunk(content: "## Thyssen Serie E\nL9 | SEGURIDADES PRINCIPALES\n", rank: 1)

    selection = select(question, [ candidate ])

    assert_equal :direct, selection.mode
    assert_equal Set[:attribution], selection.answered_relations
    assert_equal Set[:state], selection.abstained_relations
  end

  # ---------------------------------------------------------------------------
  # Detección de divisoria — la regla debe coincidir con la que produjo la
  # metadata que este selector consume (Fase 2 §3.2). Medida sobre los 97 chunks
  # reales de SEGURIDADES 1.1-1: 18/18 divisorias, cero falsos positivos.
  # ---------------------------------------------------------------------------

  test "a real divider page is recognized despite carrying FIELD_RECORD blocks and no heading" do
    selector = Rag::EvidenceCandidateSelector.new(analysis: analysis_for("x"), chunks: [])
    body = real_divider_body

    assert_operator body.length, :>, 400, "the real divider body is ~900 chars, not under 400"
    assert_includes body, "FIELD_RECORD:", "the real divider does carry FIELD_RECORD blocks"
    assert_nil body.lines.find { |line| line.strip.start_with?("## ") }, "a divider declares no '## ' heading"
    assert selector.send(:divider_chunk?, body)
  end

  # Negative control: a content page declares both markers and must never be
  # expanded away — expansion is repair for a cover slide, not for real evidence.
  test "a content page is never treated as a divider" do
    selector = Rag::EvidenceCandidateSelector.new(analysis: analysis_for("x"), chunks: [])
    content = <<~BODY
      [DOCUMENT: SEGURIDADES 1.1-1.pdf]
      **Document:** ALJO Control Level 1B Altius | PIPELINE_INJECTED
      **Section:** S7 — DIAGRAM | S4 — SAFETY SYSTEM
      **Page:** 36

      ## Diagrama de conexiones — Placa MXL1 (Cadena de Seguridades)

      | LED | SERIE |
      |-----|-------|
      | 12 | SERIE STOP Y SEGURIDADES HUECO |
    BODY

    assert_not selector.send(:divider_chunk?, content)
  end

  # A page that declares "**Section:**" but no "## " heading is still content,
  # not a divider — both conditions must hold, matching the Fase 2 rule exactly.
  test "a page declaring only Section is not a divider" do
    selector = Rag::EvidenceCandidateSelector.new(analysis: analysis_for("x"), chunks: [])

    assert_not selector.send(:divider_chunk?, "**Section:** S4 — SAFETY SYSTEM\nContenido sin encabezado.\n")
  end

  # ---------------------------------------------------------------------------
  # Generalización (plan Fase 0.5, punto 7 del refactor): fabricante, modelo y
  # códigos que no existían cuando se escribieron las reglas. El selector no
  # tiene ninguna rama por fabricante (ver test/architecture/no_hardcoded_
  # equipment_test.rb) — estos casos deben resolverse con el mismo mecanismo
  # genérico que ALTIUS/EM4000/TPR50, sin agregar conocimiento nuevo al código.
  # ---------------------------------------------------------------------------

  test "generalization: a never-seen manufacturer/model/code resolves direct" do
    question = "En NOVARIS QT9000, ¿qué serie indica el LED ZK5?"
    candidate = chunk(content: "## NOVARIS QT9000\nZK5 | SERIE PRUEBA GENERALIZACION\n", rank: 1)

    selection = select(question, [ candidate ])

    assert_equal :direct, selection.mode
    assert_equal %w[ZK5], selection.contexts.first.identifiers.map(&:canonical)
  end

  test "generalization: a fictional sibling board never contaminates the fictional target" do
    question = "En NOVARIS QT9000, ¿qué serie indica el LED ZK5?"
    qt9000 = chunk(content: "## NOVARIS QT9000\nZK5 | SERIE PRUEBA GENERALIZACION\n", rank: 1)
    qt9100 = chunk(content: "## NOVARIS QT9100\nZK6 | SERIE OTRA\n", rank: 2)

    selection = select(question, [ qt9000, qt9100 ])

    assert_equal :direct, selection.mode
    assert_not_includes selection.contexts.flat_map { |c| c.identifiers.map(&:canonical) }, "ZK6"
  end

  test "generalization: the same fictional code in two fictional sections is ambiguous, not merged" do
    question = "¿Qué serie indica el LED ZK5 en NOVARIS QT9000?"
    planta_norte = chunk(
      content: "## NOVARIS QT9000\nZK5 | SERIE A\n", rank: 1,
      metadata: { "section_identity" => "PLANTA NORTE" }
    )
    planta_sur = chunk(
      content: "## NOVARIS QT9000\nZK5 | SERIE B\n", rank: 2,
      metadata: { "section_identity" => "PLANTA SUR" }
    )

    selection = select(question, [ planta_norte, planta_sur ])

    assert_equal :ambiguous, selection.mode
    assert_equal 2, selection.contexts.map(&:section_key).uniq.size
  end
end
