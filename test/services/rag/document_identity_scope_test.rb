# frozen_string_literal: true

require "test_helper"

class Rag::DocumentIdentityScopeTest < ActiveSupport::TestCase
  POISON = [ "BM/B1", "61:U/N", "XB21", "00 71", "6 ± 1 mm" ].freeze
  CEA15_BODY = "En la placa CEA15 el código 8 es alta temperatura en el motor.".freeze
  PREAMBLE = Rag::DocumentIdentityScope::PREAMBLE

  test "a catalog manufacturer is not a needle and keeps the procedure" do
    body = "Ajuste el freno antes de energizar."
    manual = chunk("manual", body, canonical_name: "Manual seleccionado")
    state = {
      "v" => 1,
      "episode_id" => "ep-catalog",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "manufacturer" => { "value" => "MONARCH", "status" => "known", "source" => "catalog" },
        "controller" => { "value" => "NICE3000", "status" => "known", "source" => "catalog" }
      }
    }

    assert_empty Rag::DocumentIdentityScope.needles(state)
    result = Rag::DocumentIdentityScope.apply([ manual ], state, focus_uris: [])
    assert_equal body, result.chunks.sole[:content]
  end

  test "labels by canonical name and by section identity" do
    by_name = chunk("manual", CEA15_BODY, canonical_name: "Manual CEA15")
    by_section = chunk(
      "door",
      "Ajuste de puerta.",
      canonical_name: "Operador de puerta",
      section_identity: "Elemont"
    )

    result = Rag::DocumentIdentityScope.apply(
      [ by_name, by_section ],
      episode(identifiers: %w[CEA15])
    )

    assert_equal "THIS JOB'S EQUIPMENT: Manual CEA15", result.labels[0]
    assert_equal "THIS JOB'S EQUIPMENT: Operador de puerta", result.labels[1]
    assert_equal CEA15_BODY, result.chunks[0][:content]
    assert_equal "Ajuste de puerta.", result.chunks[1][:content]
  end

  test "labels by original filename" do
    named = chunk("file", "cuerpo", canonical_name: "sin marca", original_filename: "Elemont-MH.pdf")

    result = Rag::DocumentIdentityScope.apply([ named ], episode(identifiers: []))

    assert_equal "THIS JOB'S EQUIPMENT: sin marca", result.labels[0]
    assert_equal "cuerpo", result.chunks[0][:content]
  end

  test "does not match by alias or search aliases and removes the foreign body" do
    aliased = chunk(
      "foreign",
      "Cortocircuitar BM/B1. [SEARCH_ALIASES: Elemont MH CEA15]",
      canonical_name: "Monarch 3000",
      original_filename: "manual-monarch.pdf",
      section_identity: "Door machine",
      aliases: "Elemont, MH, CEA15"
    )

    result = Rag::DocumentIdentityScope.apply([ aliased ], episode(identifiers: %w[MH CEA15]))

    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Monarch 3000", result.labels[0]
    assert_equal "Manual: Monarch 3000\nPage: 1\nSection: Door machine", result.chunks[0][:content]
    assert_not_includes result.chunks[0][:content], "BM/B1"
    assert_not_includes result.chunks[0][:content], "SEARCH_ALIASES"
  end

  test "MH matches MH and does not match MHX" do
    source = chunk("mh", "cuerpo del plano MH", canonical_name: "Plano MH")
    kept = Rag::DocumentIdentityScope.apply([ source ], episode(identifiers: %w[MH]))
    rejected = Rag::DocumentIdentityScope.apply(
      [ chunk("mhx", "cuerpo MHX", canonical_name: "Plano MHX") ],
      episode(identifiers: %w[MH])
    )

    assert_equal "THIS JOB'S EQUIPMENT: Plano MH", kept.labels.first
    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Plano MHX", rejected.labels.first
    assert_equal "cuerpo del plano MH", source[:content]
    assert_equal "Manual: Plano MHX\nPage: 1\nSection: DATA_NOT_AVAILABLE", rejected.chunks.first[:content]
  end

  test "CEA15 does not match CEA15P" do
    plus = Rag::DocumentIdentityScope.apply(
      [ chunk("plus", "texto CEA15P", canonical_name: "Manual CEA15P") ],
      episode(identifiers: %w[CEA15])
    )

    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Manual CEA15P", plus.labels[0]
    assert_not_includes plus.chunks[0][:content], "texto CEA15P"
  end

  test "no match still uses the scoped path with identity only" do
    question = "pregunta"
    chunks = [
      chunk(
        "mono", "Cortocircuitar BM/B1.",
        canonical_name: "Monarch", page: 84, section_identity: "Door commissioning"
      )
    ]
    service = BedrockRagService.new(account: accounts(:legacy))
    service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: chunks, retrieval_trace: {} } }
    generator = Object.new
    calls = []
    generator.define_singleton_method(:query) do |prompt, **|
      calls << prompt
      "El resultado recuperado pertenece al manual Monarch. [1]"
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    result = nil
    with_flag("true") do
      result = service.send(
        :document_identity_scope_result,
        question,
        episode: episode(identifiers: %w[CEA15]),
        response_locale: :es,
        entity_s3_uris: [],
        entity_sources: [],
        force_entity_filter: false,
        account_id: 1,
        user_id: nil,
        conversation_session_id: nil,
        correlation_id: "c"
      )
    end

    assert_equal "document_identity_scope", result[:generation_mode]
    assert_equal 1, Thread.current[:document_identity_scope]["labels"]
    assert_equal 1, Thread.current[:document_identity_scope]["other_equipment"]
    assert_equal "document_identity", Thread.current[:document_identity_scope]["path"]
    assert_includes calls.first, "Manual: Monarch"
    assert_includes calls.first, "Page: 84"
    assert_includes calls.first, "Section: Door commissioning"
    assert_not_includes calls.first, "Cortocircuitar BM/B1"
  end

  test "a known model matches that manual and strips other equipment" do
    mono = chunk("mono", "Igualar la tensión de los resortes MonoSpace.", canonical_name: "KONE MonoSpace")
    yida = chunk("yida", "Paso 11. Suplemento de 2,5 mm.", canonical_name: "Fuji Yida", page: 53)
    spt = chunk(
      "spt", "Ajuste del resorte según el manual SPT.",
      canonical_name: "Manual chino", original_filename: "spt-zh.pdf", section_identity: "SPT"
    )

    result = Rag::DocumentIdentityScope.apply(
      [ mono, yida, spt ],
      model_episode("MonoSpace")
    )

    assert_equal "THIS JOB'S EQUIPMENT: KONE MonoSpace", result.labels[0]
    assert_equal "Igualar la tensión de los resortes MonoSpace.", result.chunks[0][:content]
    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Fuji Yida", result.labels[1]
    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Manual chino", result.labels[2]
    assert_not_includes result.chunks[1][:content], "2,5 mm"
    assert_not_includes result.chunks[1][:content], "Paso 11"
    assert_not_includes result.chunks[2][:content], "manual SPT"
    assert_includes result.chunks[1][:content], "Manual: Fuji Yida"
  end

  test "an inherited manufacturer is not a needle after a later model declaration" do
    episode = model_episode(
      "MonoSpace",
      manufacturer: "Fuji Yida",
      model_correlation_id: "query:turn",
      manufacturer_correlation_id: "query:prior"
    )
    yida = chunk("yida", "Paso 11. Suplemento de 2,5 mm.", canonical_name: "Fuji Yida", page: 58)

    assert_equal [ "MonoSpace" ], Rag::DocumentIdentityScope.needles(episode)
    result = Rag::DocumentIdentityScope.apply([ yida ], episode)

    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Fuji Yida", result.labels[0]
    assert_not_includes result.chunks[0][:content], "2,5 mm"
    assert_not_includes result.chunks[0][:content], "Paso 11"
  end

  test "an inherited identifier cannot keep a foreign chunk as this job" do
    episode = model_episode(
      "MonoSpace",
      manufacturer: "Fuji Yida",
      model_correlation_id: "query:turn",
      manufacturer_correlation_id: "query:prior",
      identifiers: [ { "value" => "CEA15", "source" => "user", "correlation_id" => "query:prior" } ]
    )
    foreign = chunk("cea", "Paso 11. Suplemento de 2,5 mm en CEA15.", canonical_name: "Manual CEA15")
    mono = chunk("mono", "Igualar la tensión MonoSpace.", canonical_name: "KONE MonoSpace")

    assert_equal [ "MonoSpace" ], Rag::DocumentIdentityScope.needles(episode)
    result = Rag::DocumentIdentityScope.apply([ foreign, mono ], episode)

    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Manual CEA15", result.labels[0]
    assert_not_includes result.chunks[0][:content], "2,5 mm"
    assert_equal "THIS JOB'S EQUIPMENT: KONE MonoSpace", result.labels[1]
    assert_includes result.chunks[1][:content], "Igualar la tensión MonoSpace."
  end

  test "an identifier from the model turn still matches" do
    episode = model_episode(
      "MonoSpace",
      model_correlation_id: "query:turn",
      identifiers: [ { "value" => "CEA15", "source" => "user", "correlation_id" => "query:turn" } ]
    )
    kept = chunk("cea", "Código 8 en CEA15.", canonical_name: "Manual CEA15")

    assert_includes Rag::DocumentIdentityScope.needles(episode), "CEA15"
    result = Rag::DocumentIdentityScope.apply([ kept ], episode)

    assert_equal "THIS JOB'S EQUIPMENT: Manual CEA15", result.labels[0]
    assert_equal "Código 8 en CEA15.", result.chunks[0][:content]
  end

  test "unknown manufacturer does not retrieve" do
    with_flag("true") do
      assert_not Rag::DocumentIdentityScope.applicable?(episode(manufacturer_status: "unknown_confirmed"))
      service = BedrockRagService.allocate
      service.define_singleton_method(:retrieve_chunks) { flunk "retrieve_chunks" }
      assert_nil service.send(
        :document_identity_scope_result,
        "pregunta",
        episode: episode(manufacturer_status: "unknown_confirmed"),
        response_locale: :es,
        entity_s3_uris: [],
        entity_sources: [],
        force_entity_filter: false,
        account_id: 1,
        user_id: nil,
        conversation_session_id: nil,
        correlation_id: "c"
      )
    end
  end

  test "flag off does not retrieve" do
    with_flag(nil) do
      assert_not Rag::DocumentIdentityScope.applicable?(episode)
      service = BedrockRagService.allocate
      service.define_singleton_method(:retrieve_chunks) { flunk "retrieve_chunks" }
      assert_nil service.send(
        :document_identity_scope_result,
        "pregunta",
        episode: episode,
        response_locale: :es,
        entity_s3_uris: [],
        entity_sources: [],
        force_entity_filter: false,
        account_id: 1,
        user_id: nil,
        conversation_session_id: nil,
        correlation_id: "c"
      )
    end
  end

  test "the catalog stays loaded and is not consulted" do
    catalog = Rag::DocumentIdentityCatalog.load
    assert catalog.loaded?
    assert catalog.entries.any?

    with_flag("true") do
      Rag::DocumentIdentityCatalog.with_catalog(
        Rag::DocumentIdentityCatalog.new({ "documents" => [] }, loaded: false)
      ) do
        assert Rag::DocumentIdentityScope.applicable?(episode)
        result = Rag::DocumentIdentityScope.apply(
          [ chunk("mh", "cuerpo", canonical_name: "Elemont MH") ],
          episode(identifiers: %w[MH])
        )
        assert_equal "THIS JOB'S EQUIPMENT: Elemont MH", result.labels[0]
      end
    end
  end

  test "generation context removes a foreign body and keeps a matching body" do
    chunks = [
      chunk("mono", "Cortocircuitar BM/B1.", canonical_name: "Monarch"),
      chunk("cea", CEA15_BODY, canonical_name: "Manual CEA15")
    ]
    question = "¿Qué reviso?"
    service = BedrockRagService.new(account: accounts(:legacy))
    applied = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[CEA15]))
    on = service.send(
      :document_identity_generation_prompt, question, applied.chunks, labels: applied.labels,
      response_locale: :es, session_context: nil, output_channel: :web
    )

    assert_includes on, PREAMBLE
    assert_not_includes on, "Cortocircuitar BM/B1."
    assert_includes on, CEA15_BODY
    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Monarch", applied.labels[0]
    assert_equal "THIS JOB'S EQUIPMENT: Manual CEA15", applied.labels[1]
    assert_includes on, "Manual: Monarch"
    assert_includes on, "Page: 1"
  end

  test "eight retrieved chunks stay ordered while foreign procedures lose their bodies" do
    bodies = [
      "Cortocircuitar BM/B1 y BM/B2.",
      "Contacto 61:U/N. Desconecte XB21 y XB24. Falta 00 71 y 00 73.",
      "La distancia es de 6 ± 1 mm y el hueco de 270 mm.",
      CEA15_BODY,
      "Plano Elemont MH.",
      "Puerta Elemont.",
      "Maniobra Elemont.",
      "Manual Elemont."
    ]
    names = [
      "Monarch", "KONE", "BLT", "Manual CEA15",
      "Elemont MH", "Puerta Elemont", "Maniobra Elemont", "Manual Elemont"
    ]
    chunks = names.zip(bodies).map { |name, body| chunk(name, body, canonical_name: name) }
    question = "Elemont MH con placa CEA15, falla en puerta 1."
    service = BedrockRagService.new(account: accounts(:legacy))
    applied = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[MH CEA15]))
    prompt = service.send(
      :document_identity_generation_prompt, question, applied.chunks, labels: applied.labels,
      response_locale: :es, session_context: nil, output_channel: :web
    )

    assert_equal 8, applied.chunks.size
    assert_equal bodies.last(5), applied.chunks.pluck(:content).last(5)
    assert_equal 5, applied.labels.count { |line| line.to_s.start_with?("THIS JOB'S EQUIPMENT:") }
    assert_equal 3, applied.labels.count { |line| line.to_s.start_with?("REFERENCE ONLY — OTHER EQUIPMENT:") }
    assert_equal 8, prompt.scan("<source>").size
    bodies.first(3).each { |body| assert_not_includes prompt, body }
    bodies.last(5).each { |body| assert_includes prompt, body }
    POISON.each { |token| assert_not_includes prompt, token }
    assert_equal %w[Monarch KONE BLT], applied.chunks.first(3).map { |chunk| chunk[:content][/Manual: (.+)/, 1] }
  end

  test "scope on retrieves the same result count and a technical failure uses retrieve_and_generate" do
    question = "pregunta"
    retrieved = {
      chunks: [ chunk("mh", "Procedimiento Elemont MH.", canonical_name: "Elemont MH") ],
      retrieval_trace: { "ok" => true }
    }
    service = BedrockRagService.new(account: accounts(:legacy))
    seen = {}
    service.define_singleton_method(:retrieve_chunks) do |_question, **kwargs|
      seen.replace(kwargs)
      retrieved
    end
    rag_calls = 0
    service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
    service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
      rag_calls += 1
      output = Struct.new(:text).new("Respuesta del camino de hoy.")
      Struct.new(:output, :citations, :session_id).new(output, [], "sess-today")
    end
    raiser = Object.new
    raiser.define_singleton_method(:query) { |_prompt, **_kwargs| raise Timeout::Error, "read timeout" }
    service.instance_variable_set(:@document_identity_generator, raiser)

    with_flag("true") do
      result = service.query(question, episode: episode(identifiers: %w[MH]), output_channel: :web)
      assert_includes result[:answer], "Respuesta del camino de hoy."
    end

    assert_equal 1, rag_calls
    assert_equal RagRetrievalProfile.new(entity_sources: [], question: question).number_of_results, seen[:number_of_results]
    assert_equal 8, seen[:number_of_results]
    assert_equal true, Thread.current[:document_identity_scope]["fallback"]
    assert_equal "retrieve_and_generate", Thread.current[:document_identity_scope]["path"]
  end

  test "a blank generation falls back to retrieve_and_generate" do
    question = "pregunta"
    retrieved = {
      chunks: [ chunk("mh", "Procedimiento Elemont MH.", canonical_name: "Elemont MH") ],
      retrieval_trace: { "ok" => true }
    }
    service = BedrockRagService.new(account: accounts(:legacy))
    service.define_singleton_method(:retrieve_chunks) { |*, **| retrieved }
    rag_calls = 0
    service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
    service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
      rag_calls += 1
      output = Struct.new(:text).new("Respuesta del camino de hoy.")
      Struct.new(:output, :citations, :session_id).new(output, [], "sess-today")
    end
    blank = Object.new
    blank.define_singleton_method(:query) { |_prompt, **_kwargs| "" }
    service.instance_variable_set(:@document_identity_generator, blank)

    with_flag("true") do
      result = service.query(question, episode: episode(identifiers: %w[MH]), output_channel: :web)
      assert_includes result[:answer], "Respuesta del camino de hoy."
    end

    assert_equal 1, rag_calls
    assert_equal true, Thread.current[:document_identity_scope]["fallback"]
  end

  test "focus keeps the selected Elemont procedure when the work says KONE" do
    uri = "s3://bucket/elemont.pdf"
    body = "En Elemont revisar el contacto de nivelación BM/B1."
    selected = chunk("elemont", body, canonical_name: "Elemont montacargas")
    selected[:metadata]["original_source_uri"] = uri
    kone = episode(identifiers: [])
    kone["facts"]["manufacturer"]["value"] = "KONE"

    result = Rag::DocumentIdentityScope.apply([ selected ], kone, focus_uris: [ uri ])

    assert_equal body, result.chunks[0][:content]
    assert_equal "THIS JOB'S EQUIPMENT: Elemont montacargas", result.labels[0]
  end

  test "a selected VF5 chunk is not described as unselected when the work says KONE" do
    vf5_uri = "s3://bucket/vf5.pdf"
    elemont_uri = "s3://bucket/elemont.pdf"
    vf5 = chunk("vf5", "Procedimiento VF5 de puertas.", canonical_name: "Fermator VF5")
    elemont = chunk("elemont", "Procedimiento Elemont de nivelación.", canonical_name: "Elemont")
    vf5[:metadata]["original_source_uri"] = vf5_uri
    elemont[:metadata]["original_source_uri"] = elemont_uri
    kone = episode(identifiers: [])
    kone["facts"]["manufacturer"]["value"] = "KONE"
    focus = [ vf5_uri, elemont_uri ]

    result = Rag::DocumentIdentityScope.apply([ vf5, elemont ], kone, focus_uris: focus)
    context = Rag::DocumentIdentityScope.generation_context(result.chunks, result.labels)

    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Fermator VF5", result.labels[0]
    assert_equal "reference_only", result.applicability[0]
    assert_not_includes result.chunks[0][:content], "Procedimiento VF5"
    assert_includes result.chunks[1][:content], "Procedimiento Elemont"
    assert_equal "THIS JOB'S EQUIPMENT: Elemont", result.labels[1]
    assert_equal "neutral", result.applicability[1]
    assert_equal focus, [ vf5_uri, elemont_uri ]
    assert_not_includes context, "no está seleccionado"
    assert_not_includes context, "Procedimiento VF5"
  end

  test "a chunk outside the selected documents is not promoted" do
    selected_uri = "s3://bucket/elemont.pdf"
    outside = chunk("kone", "Procedimiento KONE secreto BM/B1.", canonical_name: "Manual KONE")
    outside[:metadata]["original_source_uri"] = "s3://bucket/kone.pdf"

    result = Rag::DocumentIdentityScope.apply(
      [ outside ],
      episode(identifiers: []),
      focus_uris: [ selected_uri ]
    )

    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Manual KONE", result.labels[0]
    assert_not_includes result.chunks[0][:content], "BM/B1"
  end

  test "foreign manufacturer chunks cannot create manual fact" do
    n0_contract!("N4")
    yida_body = "Paso 11. Ajusta el interruptor de zona de nivelación Yida a 2,5 mm."
    blt_body = "E18 fallo de nivelación. Compruebe el encoder BLT."
    chunks = [
      chunk("yida", yida_body, canonical_name: "Fuji Yida Guía del Usuario Ascensor", page: 97),
      chunk("blt", blt_body, canonical_name: "Código de Avería BLT Ascensor", page: 4)
    ]
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: chunks, retrieval_trace: {} } }
    generator = Object.new
    generator.define_singleton_method(:query) do |_prompt, **|
      "Según Fuji Yida ajusta la zona a 2,5 mm [1]. El código E18 de BLT indica encoder [2]."
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    result = nil
    with_flag("true") do
      result = service.send(
        :document_identity_scope_result,
        "no nivela en planta 3",
        episode: orona_known_episode,
        response_locale: :es,
        entity_s3_uris: [],
        entity_sources: [],
        force_entity_filter: false,
        account_id: accounts(:legacy).id,
        user_id: nil,
        conversation_session_id: nil,
        correlation_id: "n0-foreign-citation"
      )
    end

    cited = [ result[:citations], result[:retrieved_citations] ].flatten.compact.map { |item| JSON.generate(item.as_json) }
    assert cited.none? { |blob| blob.include?("Fuji Yida") }, "reference-only Yida chunk is still citable"
    assert cited.none? { |blob| blob.include?("BLT") }, "reference-only BLT chunk is still citable"
    segments = Rag::ProvenanceSegmenter.call(
      answer: result[:answer],
      citations: result[:citations],
      visual_observation: nil
    )
    assert segments.none? { |segment| segment["band"] == "MANUAL_FACT" }
  end

  test "photo equipment identity makes a foreign manual reference-only" do
    identity = orona_identity
    yida = chunk("yida", "Paso 11. Ajusta el interruptor Yida a 2,5 mm.", canonical_name: "Fuji Yida Guía del Usuario Ascensor", page: 97)
    blt = chunk("blt", "E18 fallo de nivelación. Compruebe el encoder BLT.", canonical_name: "Código de Avería BLT Ascensor", page: 4)

    result = Rag::DocumentIdentityScope.apply([ yida, blt ], identity)
    context = Rag::DocumentIdentityScope.generation_context(result.chunks, result.labels)

    assert_equal :no_compatible, result.status
    assert result.labels.all? { |label| label.start_with?("REFERENCE ONLY — OTHER EQUIPMENT:") }
    assert_equal [ "reference_only", "reference_only" ], result.applicability
    [ yida, blt ].each_with_index do |source, index|
      assert_not_includes result.chunks[index][:content], source[:content]
    end
    assert_not_includes context, "2,5 mm"
    assert_not_includes context, "encoder BLT"
    assert_includes context, "Manual: Fuji Yida"
    assert_includes context, "Manual: Código de Avería BLT Ascensor"
  end

  test "a compatible Orona manual keeps its body" do
    body = "En PBCM-V3 revisar el sensor de nivelación de la placa Orona."
    manual = chunk("orona", body, canonical_name: "Manual Orona PBCM-V3")

    result = Rag::DocumentIdentityScope.apply([ manual ], orona_identity)

    assert_equal :scoped, result.status
    assert_equal "THIS JOB'S EQUIPMENT: Manual Orona PBCM-V3", result.labels[0]
    assert_equal "compatible", result.applicability[0]
    assert_equal body, result.chunks[0][:content]
  end

  test "unknown identity keeps the open body" do
    body = "Procedimiento genérico de nivelación."
    manual = chunk("manual", body, canonical_name: "Manual seleccionado")
    state = {
      "v" => 1,
      "episode_id" => "ep-open",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "fault_code" => { "value" => "E18", "status" => "known", "source" => "user" }
      },
      "identifiers" => []
    }

    assert_nil Rag::EquipmentIdentity.from_episode(state)
    assert_not Rag::DocumentIdentityScope.applicable?(state)
    result = Rag::DocumentIdentityScope.apply([ manual ], state, focus_uris: [])

    assert_nil result.status
    assert_equal :not_required, result.reason
    assert_equal body, result.chunks.sole[:content]
  end

  test "an unrelated photo identity does not require the policy" do
    body = "Procedimiento de otro manual."
    manual = chunk("manual", body, canonical_name: "Fuji Yida")

    assert_not Rag::DocumentIdentityScope.applicable?(nil)
    result = Rag::DocumentIdentityScope.apply([ manual ], nil)

    assert_nil result.status
    assert_equal body, result.chunks.sole[:content]
  end

  test "a pinned Fuji manual is reference-only for Orona and focus stays put" do
    fuji_uri = "s3://bucket/fuji.pdf"
    outside_uri = "s3://bucket/orona.pdf"
    body = "Paso 11. Suplemento Yida de 2,5 mm."
    fuji = chunk("fuji", body, canonical_name: "Fuji Yida Guía del Usuario Ascensor")
    outside = chunk("orona", "Procedimiento Orona PBCM-V3 secreto.", canonical_name: "Manual Orona PBCM-V3")
    fuji[:metadata]["original_source_uri"] = fuji_uri
    outside[:metadata]["original_source_uri"] = outside_uri
    focus = [ fuji_uri ]

    result = Rag::DocumentIdentityScope.apply([ fuji, outside ], orona_identity, focus_uris: focus)

    assert_equal [ fuji_uri ], focus
    assert_equal :no_compatible, result.status
    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Fuji Yida Guía del Usuario Ascensor", result.labels[0]
    assert_not_includes result.chunks[0][:content], "2,5 mm"
    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Manual Orona PBCM-V3", result.labels[1]
    assert_not_includes result.chunks[1][:content], "secreto"
  end

  test "a selected neutral document stays this job" do
    uri = "s3://bucket/elemont.pdf"
    body = "En Elemont revisar el contacto de nivelación BM/B1."
    selected = chunk("elemont", body, canonical_name: "Elemont montacargas")
    selected[:metadata]["original_source_uri"] = uri
    kone = episode(identifiers: [])
    kone["facts"]["manufacturer"]["value"] = "KONE"

    result = Rag::DocumentIdentityScope.apply([ selected ], kone, focus_uris: [ uri ])

    assert_equal :scoped, result.status
    assert_equal "neutral", result.applicability[0]
    assert_equal body, result.chunks[0][:content]
    assert_equal "THIS JOB'S EQUIPMENT: Elemont montacargas", result.labels[0]
  end

  test "text path derives the same policy needles from the live episode" do
    state = orona_known_episode
    identity = Rag::EquipmentIdentity.from_episode(state)

    assert identity.known?
    assert_equal "Orona", identity.manufacturer
    assert_equal Rag::DocumentIdentityScope.needles(state), Rag::DocumentIdentityScope.needles(identity)
    assert_includes identity.facts.pluck("source"), "photo"

    body = "Revisar PBCM-V3 en la placa Orona."
    manual = chunk("orona", body, canonical_name: "Manual Orona PBCM-V3")
    from_episode = Rag::DocumentIdentityScope.apply([ manual ], state)
    from_identity = Rag::DocumentIdentityScope.apply([ manual ], identity)

    assert_equal from_episode.status, from_identity.status
    assert_equal from_episode.labels, from_identity.labels
    assert_equal body, from_identity.chunks[0][:content]
  end

  test "controller and catalog facts do not make identity known" do
    catalog = {
      "v" => 1,
      "episode_id" => "ep-catalog-only",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "manufacturer" => { "value" => "MONARCH", "status" => "known", "source" => "catalog" },
        "controller" => { "value" => "NICE3000", "status" => "known", "source" => "user" }
      },
      "identifiers" => [ { "value" => "CEA15", "source" => "catalog" } ]
    }
    identity = Rag::EquipmentIdentity.from_episode(catalog)

    assert_nil identity
    assert_empty Rag::DocumentIdentityScope.needles(catalog)
    with_flag("true") do
      assert_not Rag::DocumentIdentityScope.applicable?(catalog)
    end
  end

  test "an old manufacturer is not a needle beside the current photo model" do
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "Fuji",
      needles: [ "Fuji", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Fuji", "source" => "user", "correlation_id" => "query:prior" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:1" }
      ]
    )
    fuji = chunk("fuji", "Paso 11. Suplemento de 2,5 mm.", canonical_name: "Fuji Yida")

    assert_equal [ "PBCM-V3" ], Rag::DocumentIdentityScope.needles(identity)
    result = Rag::DocumentIdentityScope.apply([ fuji ], identity)

    assert_equal :no_compatible, result.status
    assert_nil result.reason
    assert_not_includes result.chunks[0][:content], "2,5 mm"
  end

  test "inherited KONE is not united with the current Orona photo" do
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "KONE",
      needles: [ "KONE", "Orona", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "KONE", "source" => "user", "correlation_id" => "query:prior" },
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "photo:1" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:1" }
      ]
    )
    kone = chunk("kone", "Procedimiento KONE de nivelación.", canonical_name: "Manual KONE")
    orona = chunk("orona", "Procedimiento de la placa Orona.", canonical_name: "Manual Orona")

    needles = Rag::DocumentIdentityScope.needles(identity)
    assert_includes needles, "Orona"
    assert_includes needles, "PBCM-V3"
    assert_not_includes needles, "KONE"
    result = Rag::DocumentIdentityScope.apply([ kone, orona ], identity)

    assert_nil result.reason
    assert_equal "REFERENCE ONLY — OTHER EQUIPMENT: Manual KONE", result.labels[0]
    assert_equal "THIS JOB'S EQUIPMENT: Manual Orona", result.labels[1]
    assert_not_includes result.chunks[0][:content], "Procedimiento KONE"
    assert_includes result.chunks[1][:content], "Procedimiento de la placa Orona."
  end

  test "current KONE and Orona are not a compatibility union" do
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "KONE",
      needles: [ "KONE", "Orona", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "KONE", "source" => "user", "correlation_id" => "turn:current" },
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "turn:current" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "turn:current" }
      ]
    )
    kone = chunk("kone", "Procedimiento KONE de nivelación.", canonical_name: "Manual KONE")
    orona = chunk("orona", "Procedimiento de la placa Orona.", canonical_name: "Manual Orona")

    needles = Rag::DocumentIdentityScope.needles(identity)
    assert_equal [ "PBCM-V3" ], needles
    result = Rag::DocumentIdentityScope.apply([ kone, orona ], identity)

    assert_equal :conflicting_current_identity, result.reason
    assert_equal [ "KONE", "Orona" ], result.excluded_labels
    assert_equal :no_compatible, result.status
    assert result.labels.all? { |label| label.start_with?("REFERENCE ONLY") }
    assert_not_includes result.chunks[0][:content], "Procedimiento KONE"
    assert_not_includes result.chunks[1][:content], "Procedimiento de la placa Orona."
  end

  test "a recorded user manufacturer conflict is not resolved by the later photo model" do
    _episode, identities = recorded_kone_orona_conflict
    kone = chunk("kone", "Procedimiento KONE de nivelación.", canonical_name: "Manual KONE")
    orona = chunk(
      "orona",
      "Procedimiento de la placa Orona PBCM-V3.",
      canonical_name: "Manual Orona PBCM-V3"
    )
    identities.each do |identity|
      assert_empty Rag::DocumentIdentityScope.needles(identity)
      result = Rag::DocumentIdentityScope.apply([ kone, orona ], identity)

      assert_equal :no_compatible, result.status
      assert_equal :conflicting_current_identity, result.reason
      assert_equal [ "KONE", "Orona" ], result.excluded_labels
      assert_equal "reference_only", result.chunks[0][:identity_applicability]
      assert_equal "reference_only", result.chunks[1][:identity_applicability]
      assert result.labels.all? { |label| label.start_with?("REFERENCE ONLY") }
      assert_not_includes result.chunks[0][:content], "Procedimiento KONE"
      assert_not_includes result.chunks[1][:content], "Procedimiento de la placa"
    end
  end

  test "an explicit manufacturer conflict keeps a selected model-only manual reference-only" do
    _episode, identities = recorded_kone_orona_conflict
    uri = "s3://bucket/pbcm-v3.pdf"
    body = "Paso 4. Ajuste el contacto de la placa a 2 mm."
    selected = chunk("pbcm", body, canonical_name: "Manual PBCM-V3")
    selected[:metadata]["original_source_uri"] = uri
    focus = [ uri ]

    identities.each do |identity|
      result = Rag::DocumentIdentityScope.apply([ selected ], identity, focus_uris: focus)

      assert_equal [ uri ], focus
      assert_equal :no_compatible, result.status
      assert_equal :conflicting_current_identity, result.reason
      assert_equal [ "reference_only" ], result.applicability
      assert result.labels[0].start_with?("REFERENCE ONLY")
      assert_not_includes result.labels[0], "THIS JOB"
      assert_not_includes result.chunks[0][:content], "Paso 4"
      assert_not_includes result.chunks[0][:metadata].values.join(" "), "Orona"
      assert_not_includes result.chunks[0][:metadata].values.join(" "), "KONE"
    end
  end

  test "a disabled scope with known identity is unavailable and still falls open" do
    question = "no nivela"
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { flunk "retrieve_chunks" }
    rag_calls = 0
    service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
    service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
      rag_calls += 1
      output = Struct.new(:text).new("Respuesta del camino abierto.")
      Struct.new(:output, :citations, :session_id).new(output, [], nil)
    end

    result = nil
    with_flag(nil) do
      result = service.query(question, episode: orona_known_episode, output_channel: :web)
    end

    assert_equal "unavailable", Thread.current[:document_identity_scope]["status"]
    assert_equal "scope_disabled", Thread.current[:document_identity_scope]["reason"]
    assert_equal 1, rag_calls
    assert_includes result[:answer], "Respuesta del camino abierto."
  end

  test "no compatible classification still falls through to open retrieve_and_generate" do
    question = "no nivela"
    yida_body = "Paso 11. Ajusta el interruptor Yida a 2,5 mm."
    chunks = [ chunk("yida", yida_body, canonical_name: "Fuji Yida Guía del Usuario Ascensor", page: 97) ]
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: chunks, retrieval_trace: {} } }
    service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
    rag_calls = 0
    service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
      rag_calls += 1
      output = Struct.new(:text).new("Respuesta del camino abierto.")
      Struct.new(:output, :citations, :session_id).new(output, [], nil)
    end
    generator = Object.new
    generator.define_singleton_method(:query) { |_prompt, **| "Sin manual compatible. [1]" }
    service.define_singleton_method(:document_identity_generator) { generator }

    result = nil
    with_flag("true") do
      result = service.query(
        question,
        equipment_identity: orona_identity,
        episode: episode(identifiers: []),
        output_channel: :web
      )
    end

    assert_equal "no_compatible", Thread.current[:document_identity_scope]["status"]
    assert_equal true, Thread.current[:document_identity_scope]["fallback"]
    assert_equal 1, rag_calls
    assert_includes result[:answer], "Respuesta del camino abierto."
  end

  test "a supplied identity is used after the episode changes" do
    episode_b = episode(identifiers: [])
    episode_b["facts"]["manufacturer"]["value"] = "OTIS"
    episode_b["facts"]["manufacturer"]["source"] = "user"
    seen = nil
    yida = chunk("yida", "Paso Yida.", canonical_name: "Fuji Yida")
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) do |*, **|
      { chunks: [ yida ], retrieval_trace: {} }
    end
    original_apply = Rag::DocumentIdentityScope.method(:apply)
    Rag::DocumentIdentityScope.define_singleton_method(:apply) do |chunks, identity, focus_uris: []|
      seen = identity
      original_apply.call(chunks, identity, focus_uris: focus_uris)
    end
    generator = Object.new
    generator.define_singleton_method(:query) { |_prompt, **| "clasificado [1]" }
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
    service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
      output = Struct.new(:text).new("abierto")
      Struct.new(:output, :citations, :session_id).new(output, [], nil)
    end

    with_flag("true") do
      service.query("no nivela", equipment_identity: orona_identity, episode: episode_b, output_channel: :web)
    end

    assert_equal "Orona", seen.manufacturer
    assert_includes seen.needles, "PBCM-V3"
    assert_not_includes Rag::DocumentIdentityScope.needles(seen), "OTIS"
  ensure
    Rag::DocumentIdentityScope.define_singleton_method(:apply) { |*args, **kwargs| original_apply.call(*args, **kwargs) } if original_apply
  end

  test "a corrected brand is not a needle and a catalog fact is not a needle" do
    corrected = episode(identifiers: [])
    corrected["episode_id"] = "ep-corrected"
    corrected["facts"]["manufacturer"]["value"] = "KONE"
    corrected["facts"]["manufacturer"]["correlation_id"] = "q2"
    catalog = {
      "v" => 1,
      "facts" => {
        "manufacturer" => {
          "value" => "Monarch", "status" => "known", "source" => "catalog", "correlation_id" => "q"
        }
      },
      "identifiers" => []
    }
    photo = episode(identifiers: [])
    photo["facts"]["manufacturer"]["source"] = "photo"

    assert_equal [ "KONE" ], Rag::DocumentIdentityScope.needles(corrected)
    assert_not_includes Rag::DocumentIdentityScope.needles(corrected), "Elemont"
    assert_empty Rag::DocumentIdentityScope.needles(catalog)
    assert_equal [ "Elemont" ], Rag::DocumentIdentityScope.needles(photo)
  end

  private

  def strip_scope(prompt, labels)
    text = prompt.sub("#{PREAMBLE}\n", "")
    labels.reduce(text) { |body, label| label.present? ? body.sub("#{label}\n", "") : body }
  end

  def model_episode(model, manufacturer: nil, model_correlation_id: "query:turn", manufacturer_correlation_id: "query:prior", identifiers: [])
    facts = {
      "model" => {
        "value" => model,
        "status" => "known",
        "source" => "user",
        "correlation_id" => model_correlation_id
      }
    }
    if manufacturer
      facts["manufacturer"] = {
        "value" => manufacturer,
        "status" => "known",
        "source" => "user",
        "correlation_id" => manufacturer_correlation_id
      }
    end
    {
      "v" => 1,
      "episode_id" => "ep-model",
      "updated_at" => Time.current.iso8601,
      "facts" => facts,
      "identifiers" => identifiers
    }
  end

  def orona_identity
    Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "Orona", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "photo:orona" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:orona" }
      ]
    )
  end

  def orona_known_episode
    {
      "v" => 1,
      "episode_id" => "ep-orona",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "manufacturer" => {
          "value" => "Orona",
          "status" => "known",
          "source" => "photo",
          "correlation_id" => "photo:orona"
        },
        "model" => {
          "value" => "PBCM-V3",
          "status" => "known",
          "source" => "photo",
          "correlation_id" => "photo:orona"
        }
      },
      "identifiers" => []
    }
  end

  def episode(identifiers: %w[MH CEA15], manufacturer_status: "known")
    {
      "v" => 1,
      "episode_id" => "ep-test",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "manufacturer" => {
          "value" => "Elemont",
          "status" => manufacturer_status,
          "source" => "user"
        }
      },
      "identifiers" => identifiers.map { |value| { "value" => value, "source" => "user" } }
    }
  end

  def recorded_kone_orona_conflict
    previous = ENV.fetch("FIELD_COMPANION_EPISODE_ENABLED", nil)
    session = ConversationSession.create!(
      identifier: "web:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy)
    )
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    session.record_user_turn!(
      "Cómo se ajustan los resortes de la fijación de cables ?",
      user_id: users(:one).id, correlation_id: "query:1"
    )
    owner = session.live_episode_id
    session.record_assistant_turn!(
      "… ¿Qué marca y modelo es el equipo?",
      user_id: users(:one).id, correlation_id: "query:2", expected_episode_id: owner
    )
    session.record_user_turn!("KONE", user_id: users(:one).id, correlation_id: "query:123")
    applied = session.record_photo_observation!(
      photo_value: {
        manufacturer: "Orona", model_visible: "PBCM-V3",
        target_visible: true, relevance_to_goal: "relevant"
      },
      field_photo_id: 42,
      sha256: "plate",
      correlation_id: "photo:456",
      expected_episode_id: owner
    )

    assert_equal :applied, applied
    episode = Rag::ActiveEpisode.parse(session.reload.active_episode)
    assert_equal "KONE", episode.fact("manufacturer")["value"]
    assert_equal "user", episode.fact("manufacturer")["source"]
    assert_equal "query:123", episode.fact("manufacturer")["correlation_id"]
    assert_equal "PBCM-V3", episode.fact("model")["value"]
    assert_equal "photo", episode.fact("model")["source"]
    assert_equal "photo:456", episode.fact("model")["correlation_id"]
    recorded = episode.conflicts.find { |row| row["fact"] == "manufacturer" }
    assert_equal "KONE", recorded["user"]
    assert_equal "Orona", recorded["photo"]
    assert_equal "photo:456", recorded["correlation_id"]

    before = episode.to_h
    snapshot = Rag::PhotoRetrievalSnapshot.capture(
      episode: episode,
      question: "qué reviso en esta placa",
      observation: {
        "manufacturer" => "Orona",
        "model_visible" => "PBCM-V3",
        "relevance_to_goal" => "relevant"
      },
      correlation_id: "photo:456"
    )
    assert_equal before, episode.to_h
    identities = [ snapshot.equipment_identity, Rag::EquipmentIdentity.from_episode(episode) ]
    identities.each do |identity|
      assert_equal "KONE", identity.conflicts.sole["user"]
      assert_equal "Orona", identity.conflicts.sole["photo"]
      assert_equal "photo:456", identity.conflicts.sole["correlation_id"]
    end
    [ episode, identities ]
  ensure
    if previous.nil?
      ENV.delete("FIELD_COMPANION_EPISODE_ENABLED")
    else
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous
    end
  end

  def chunk(document_id, content, account_id: "1", canonical_name: document_id, page: 1,
            section_identity: nil, original_filename: nil, aliases: nil)
    metadata = {
      "account_id" => account_id,
      "document_id" => document_id,
      "canonical_name" => canonical_name,
      "page_number" => page
    }
    metadata["section_identity"] = section_identity if section_identity
    metadata["original_filename"] = original_filename if original_filename
    metadata["aliases"] = aliases if aliases
    {
      rank: 1,
      content: content,
      metadata: metadata,
      chunk_sha256: Digest::SHA256.hexdigest(content)
    }
  end

  def with_flag(value)
    original = ENV.fetch("DOCUMENT_IDENTITY_SCOPE_ENABLED", nil)
    if value.nil?
      ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    else
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    else
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = original
    end
  end
end
