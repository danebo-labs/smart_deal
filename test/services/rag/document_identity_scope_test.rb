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

  test "no compatible manual generates companion guidance without the foreign procedure" do
    question = "pregunta"
    chunks = [
      chunk(
        "mono", "Cortocircuitar BM/B1.",
        canonical_name: "Monarch", page: 84, section_identity: "Door commissioning"
      )
    ]
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
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
    assert_equal "no_compatible", result[:equipment_identity_status]
    assert_equal 1, Thread.current[:document_identity_scope]["labels"]
    assert_equal 1, Thread.current[:document_identity_scope]["other_equipment"]
    assert_equal "document_identity", Thread.current[:document_identity_scope]["path"]
    assert_includes calls.first, "# FIELD COMPANION"
    assert_includes calls.first, "Monarch"
    assert_not_includes calls.first, "Cortocircuitar BM/B1"
    assert_not_includes calls.first, "Page: 84"
    assert_equal [], result[:citations]
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
      result = service.send(
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
      assert_equal "unavailable", result[:equipment_identity_status]
      assert_equal "scope_disabled", result[:equipment_identity_reason]
      assert_equal false, Thread.current[:document_identity_scope]["fallback"]
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
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
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
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
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

  test "scope on retrieves the same result count and a technical failure stays closed" do
    question = "pregunta"
    retrieved = {
      chunks: [ chunk("mh", "Procedimiento Elemont MH.", canonical_name: "Elemont MH") ],
      retrieval_trace: { "ok" => true }
    }
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
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

    result = nil
    with_flag("true") do
      result = service.query(question, episode: episode(identifiers: %w[MH]), output_channel: :web)
    end

    assert_equal 0, rag_calls
    assert_equal "unavailable", result[:equipment_identity_status]
    assert_equal "generation_timeout", result[:equipment_identity_reason]
    assert_not_includes result[:answer], "Respuesta del camino de hoy."
    assert_not_includes result[:answer], "Procedimiento Elemont"
    assert_equal RagRetrievalProfile.new(entity_sources: [], question: question).number_of_results, seen[:number_of_results]
    assert_equal 8, seen[:number_of_results]
    assert_equal false, Thread.current[:document_identity_scope]["fallback"]
    assert_equal "document_identity", Thread.current[:document_identity_scope]["path"]
  end

  test "a blank generation stays closed" do
    question = "pregunta"
    retrieved = {
      chunks: [ chunk("mh", "Procedimiento Elemont MH.", canonical_name: "Elemont MH") ],
      retrieval_trace: { "ok" => true }
    }
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
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

    result = nil
    with_flag("true") do
      result = service.query(question, episode: episode(identifiers: %w[MH]), output_channel: :web)
    end

    assert_equal 0, rag_calls
    assert_equal "unavailable", result[:equipment_identity_status]
    assert_equal "generation_blank", result[:equipment_identity_reason]
    assert_equal false, Thread.current[:document_identity_scope]["fallback"]
    assert_not_includes result[:answer], "Respuesta del camino de hoy."
    assert_not_includes result[:answer], "Procedimiento Elemont"
  end

  # The title states no model designator. The pin compensates for that missing
  # identity. It does not stay neutral because the word is absent from
  # KbDocumentResolver::BRANDS.
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

  # Fermator is reference-only because the metadata names a different known brand.
  # Elemont stays this job because that title has no model designator.
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

  test "a pinned explicit ZEPHYR manual is not this job for known ORBITA" do
    uri = "s3://bucket/zephyr.pdf"
    body = "Enviar la cabina al piso inferior. Q-731 = fallo de puerta."
    selected = pinned_manual("ZEPHYR QX-77", body, uri)
    focus = [ uri ]

    result = Rag::DocumentIdentityScope.apply(
      [ selected ], job_identity("ORBITA", "LM-5"), focus_uris: focus
    )
    context = Rag::DocumentIdentityScope.generation_context(result.chunks, result.labels)

    assert_equal [ uri ], focus
    assert_equal :no_compatible, result.status
    assert_equal [ "reference_only" ], result.applicability
    assert result.labels[0].start_with?("REFERENCE ONLY — OTHER EQUIPMENT:")
    assert_not_includes result.labels[0], "THIS JOB"
    assert_not_includes result.chunks[0][:content], "Enviar la cabina"
    assert_not_includes result.chunks[0][:content], "Q-731"
    assert_not_includes context, "THIS JOB'S EQUIPMENT:"
    assert_not_includes context, body
  end

  test "a pinned explicit ZEPHYR manual is not this job for known Orona" do
    uri = "s3://bucket/zephyr.pdf"
    body = "Enviar la cabina al piso inferior."
    selected = pinned_manual("ZEPHYR QX-77", body, uri)

    result = Rag::DocumentIdentityScope.apply([ selected ], orona_identity, focus_uris: [ uri ])

    assert_equal :no_compatible, result.status
    assert_equal [ "reference_only" ], result.applicability
    assert_not_includes result.labels[0], "THIS JOB"
    assert_not_includes result.chunks[0][:content], "Enviar la cabina"
  end

  test "a pinned manual without an equipment designator stays neutral" do
    uri = "s3://bucket/nivelacion.pdf"
    body = "Revisar el contacto de nivelación."
    selected = pinned_manual("Manual de nivelación", body, uri)

    result = Rag::DocumentIdentityScope.apply(
      [ selected ], job_identity("ORBITA", "LM-5"), focus_uris: [ uri ]
    )

    assert_equal :scoped, result.status
    assert_equal [ "neutral" ], result.applicability
    assert_equal "THIS JOB'S EQUIPMENT: Manual de nivelación", result.labels[0]
    assert_equal body, result.chunks[0][:content]
  end

  test "a pinned manual whose designator matches the known model stays applicable" do
    uri = "s3://bucket/orbita.pdf"
    body = "Procedimiento de rescate ORBITA LM-5."
    selected = pinned_manual("ORBITA LM-5", body, uri)

    result = Rag::DocumentIdentityScope.apply(
      [ selected ], job_identity("ORBITA", "LM-5"), focus_uris: [ uri ]
    )

    assert_equal :scoped, result.status
    assert_equal [ "compatible" ], result.applicability
    assert_equal "THIS JOB'S EQUIPMENT: ORBITA LM-5", result.labels[0]
    assert_equal body, result.chunks[0][:content]
  end

  test "an unpinned explicit ZEPHYR manual stays reference-only for known ORBITA" do
    body = "Enviar la cabina al piso inferior."
    selected = chunk("zephyr", body, canonical_name: "ZEPHYR QX-77", section_identity: "ZEPHYR QX-77")

    result = Rag::DocumentIdentityScope.apply([ selected ], job_identity("ORBITA", "LM-5"))

    assert_equal :no_compatible, result.status
    assert_equal [ "reference_only" ], result.applicability
    assert_not_includes result.chunks[0][:content], "Enviar la cabina"
  end

  test "unknown identity does not treat a pinned designator as a known-identity rejection" do
    uri = "s3://bucket/zephyr.pdf"
    body = "Enviar la cabina al piso inferior."
    selected = pinned_manual("ZEPHYR QX-77", body, uri)
    unknown = {
      "v" => 1,
      "episode_id" => "ep-unknown",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "fault_code" => { "value" => "E18", "status" => "known", "source" => "user" }
      },
      "identifiers" => []
    }

    [ nil, unknown ].each do |identity|
      result = Rag::DocumentIdentityScope.apply([ selected ], identity, focus_uris: [ uri ])

      assert_equal :scoped, result.status
      assert_equal [ "neutral" ], result.applicability
      assert_equal body, result.chunks[0][:content]
      assert_equal "1", result.chunks[0][:metadata]["account_id"]
    end
  end

  test "pin applicability keeps chunk order and does not rewrite account metadata" do
    zephyr_uri = "s3://bucket/zephyr.pdf"
    body = "Enviar la cabina al piso inferior."
    orbita_uri = "s3://bucket/orbita.pdf"
    zephyr = pinned_manual("ZEPHYR QX-77", body, zephyr_uri)
    orbita = pinned_manual("ORBITA LM-5", "Procedimiento ORBITA.", orbita_uri)
    focus = [ zephyr_uri, orbita_uri ]

    result = Rag::DocumentIdentityScope.apply(
      [ zephyr, orbita ], job_identity("ORBITA", "LM-5"), focus_uris: focus
    )

    assert_equal [ zephyr_uri, orbita_uri ], focus
    assert_equal [ "reference_only", "compatible" ], result.applicability
    assert_equal "1", result.chunks[0][:metadata]["account_id"]
    assert_equal "1", result.chunks[1][:metadata]["account_id"]
    assert_not_includes result.chunks[0][:content], "Enviar la cabina"
    assert_equal "Procedimiento ORBITA.", result.chunks[1][:content]
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

  # Same missing-designator case as the Elemont pin above. Fermator VF5 in the
  # sibling test is reference-only because its metadata names another brand.
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

  test "a disabled scope with known identity is unavailable and does not fall open" do
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

    assert_equal "unavailable", result[:equipment_identity_status]
    assert_equal "scope_disabled", result[:equipment_identity_reason]
    assert_equal false, Thread.current[:document_identity_scope]["fallback"]
    assert_equal 0, rag_calls
    assert_not_includes result[:answer], "Respuesta del camino abierto."
  end

  test "no compatible classification does not fall through to open retrieve_and_generate" do
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

    assert_equal "no_compatible", result[:equipment_identity_status]
    assert_equal false, Thread.current[:document_identity_scope]["fallback"]
    assert_equal 0, rag_calls
    assert_not_includes result[:answer], "Respuesta del camino abierto."
    assert_not_includes result[:answer], yida_body
    cited = [ result[:citations], result[:retrieved_citations] ].flatten.compact
    assert cited.none? { |item| JSON.generate(item.as_json).include?("Fuji Yida") }
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

  test "a compatible Orona manual stays scoped and citable" do
    body = "En PBCM-V3 revisar el sensor de nivelación de la placa Orona. X17 es la entrada de nivelación."
    manual = chunk("orona", body, canonical_name: "Manual Orona PBCM-V3")
    service = closed_identity_service(chunks: [ manual ])
    rag_calls = 0
    service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
      rag_calls += 1
      flunk "open retrieve_and_generate"
    end
    seen_prompt = nil
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      seen_prompt = prompt
      "Revisar el sensor de la placa. X17 es la entrada de nivelación. [1]"
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    result = nil
    with_flag("true") do
      result = service.query("no nivela", equipment_identity: orona_identity, output_channel: :web)
    end

    assert_equal 0, rag_calls
    assert_equal "scoped", result[:equipment_identity_status]
    assert_includes seen_prompt, body
    assert_not_includes seen_prompt, "# FIELD COMPANION"
    assert_includes result[:answer], "Revisar el sensor"
    assert_includes result[:answer], "X17 es la entrada de nivelación"
    cited = [ result[:citations], result[:retrieved_citations] ].flatten.compact.map { |item| JSON.generate(item.as_json) }
    assert cited.any? { |blob| blob.include?("Manual Orona PBCM-V3") }
    assert cited.any? { |blob| blob.include?(body) }
  end

  test "a known compatible manual can still publish its measurement instruction" do
    body = "Revisa el voltaje en los terminales principales con un multímetro."
    manual = chunk("orona", body, canonical_name: "Manual Orona PBCM-V3")
    service = closed_identity_service(chunks: [ manual ])
    generator = Object.new
    generator.define_singleton_method(:query) do |_prompt, **|
      "#{body} [1]"
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    result = nil
    with_flag("true") do
      result = service.query("no nivela", equipment_identity: orona_identity, output_channel: :web)
    end

    assert_equal "scoped", result[:equipment_identity_status]
    assert_nil result[:applicability_violation]
    assert_includes result[:answer], "multímetro"
    assert_includes result[:answer], "terminales"
  end

  test "known identity and an empty retrieval is no_compatible without an open fallback" do
    service = closed_identity_service(chunks: [])
    rag_calls = 0
    seen_prompt = nil
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      seen_prompt = prompt
      "Quiero separar si la cabina queda pasada o corta.\n¿Qué hace al llegar a planta 3?"
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    result = nil
    with_flag("true") do
      result = service.query("no nivela en planta 3", equipment_identity: orona_identity, output_channel: :web)
    end

    assert_equal 0, rag_calls
    assert_equal "no_compatible", result[:equipment_identity_status]
    assert_equal false, Thread.current[:document_identity_scope]["fallback"]
    assert_includes seen_prompt, "# FIELD COMPANION"
    assert_includes seen_prompt, "No compatible manufacturer manual was found."
    assert_includes result[:answer], "pasada o corta"
    assert_not_includes result[:answer], I18n.t("rag.data_not_available", locale: :es)
    assert_not_includes result[:answer], I18n.t("rag.uncited_technical_answer", locale: :es)
    assert_equal [], result[:citations]
    assert_equal [], result[:retrieved_citations]
  end

  test "known identity and a retrieval timeout is unavailable without an open fallback" do
    assert_identity_retrieval_failure(Timeout::Error.new("read timeout"), "retrieval_timeout")
  end

  test "known identity and a Bedrock retrieval error is unavailable without an open fallback" do
    error = BedrockRagService::BedrockServiceError.new("Failed to retrieve Knowledge Base chunks: boom")
    assert_identity_retrieval_failure(error, "retrieval_error")
  end

  test "unknown identity retrieves once and generates directly" do
    body = "Referencia de otro manual."
    evidence = chunk("otro", body, canonical_name: "Manual ajeno")
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    retrieve_calls = 0
    rag_calls = 0
    prompts = []
    service.define_singleton_method(:retrieve_chunks) do |*, **|
      retrieve_calls += 1
      { chunks: [ evidence ], retrieval_trace: {} }
    end
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      prompts << prompt
      "El manual ajeno no está confirmado para este equipo. Mirar la placa. [1]"
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    result = nil
    with_flag("true") do
      result = service.query("no nivela", episode: { "v" => 1, "facts" => {}, "identifiers" => [] }, output_channel: :web)
    end

    assert_equal 1, retrieve_calls
    assert_equal 0, rag_calls
    assert_includes prompts.sole, "# FIELD COMPANION"
    assert_includes prompts.sole, "The equipment identity is not confirmed."
    assert_includes prompts.sole, "Manual ajeno, p. 1"
    assert_not_includes prompts.sole, "UNCONFIRMED REFERENCE"
    assert_not_includes prompts.sole, body
    assert_not_includes prompts.sole, "APPLICABILITY_BLOCK"
    assert_includes result[:answer], "no está confirmado"
    assert_nil result[:equipment_identity_status]
    assert_nil result[:generation_mode]
  end

  test "a pinned foreign manual stays selected and is not a citation" do
    original_authorize = nil
    fuji_uri = "s3://bucket/fuji.pdf"
    focus = [ fuji_uri ]
    body = "Paso 11. Suplemento Yida de 2,5 mm."
    fuji = chunk("fuji", body, canonical_name: "Fuji Yida Guía del Usuario Ascensor")
    fuji[:metadata]["original_source_uri"] = fuji_uri
    service = closed_identity_service(chunks: [ fuji ])
    rag_calls = 0
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }
    generator = Object.new
    generator.define_singleton_method(:query) { |_prompt, **| "Según Yida el suplemento es 2,5 mm [1]." }
    service.define_singleton_method(:document_identity_generator) { generator }
    original_authorize = Rag::KnowledgeScopePolicy.method(:authorize_retrieval_set)
    allowed_set = Data.define(:status, :uris) do
      def denied? = false
    end
    Rag::KnowledgeScopePolicy.define_singleton_method(:authorize_retrieval_set) do |uris, **|
      allowed_set.new(status: :allow, uris: Array(uris))
    end

    result = nil
    with_flag("true") do
      result = service.query(
        "no nivela",
        equipment_identity: orona_identity,
        entity_s3_uris: focus,
        force_entity_filter: true,
        output_channel: :web
      )
    end

    assert_equal [ fuji_uri ], focus
    assert_equal 0, rag_calls
    assert_equal "no_compatible", result[:equipment_identity_status]
    assert_not_includes result[:answer], body
    cited = [ result[:citations], result[:retrieved_citations], result[:doc_refs] ].flatten.compact
    assert cited.none? { |item| JSON.generate(item.as_json).include?("Fuji Yida") }
    segments = Rag::ProvenanceSegmenter.call(answer: result[:answer], citations: result[:citations])
    assert segments.none? { |segment| segment["band"] == "MANUAL_FACT" }
  ensure
    if original_authorize
      Rag::KnowledgeScopePolicy.define_singleton_method(:authorize_retrieval_set) do |*args, **kwargs|
        original_authorize.call(*args, **kwargs)
      end
    end
  end

  test "an explicit manufacturer conflict does not fall open" do
    _episode, identities = recorded_kone_orona_conflict
    chunks = [
      chunk("kone", "Procedimiento KONE de nivelación.", canonical_name: "Manual KONE"),
      chunk("orona", "Procedimiento de la placa Orona.", canonical_name: "Manual Orona")
    ]
    service = closed_identity_service(chunks: chunks)
    rag_calls = 0
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }
    seen_prompt = nil
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      seen_prompt = prompt
      "Hay una inconsistencia entre el fabricante indicado y el leído en la foto. ¿Puedes mostrarme la placa del controlador?"
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    result = nil
    with_flag("true") do
      result = service.query("qué reviso", equipment_identity: identities.first, output_channel: :web)
    end

    assert_equal 0, rag_calls
    assert_equal "no_compatible", result[:equipment_identity_status]
    assert_equal "conflicting_current_identity", result[:equipment_identity_reason]
    assert_includes seen_prompt, "technician said KONE"
    assert_includes seen_prompt, "the photo shows Orona"
    assert_includes seen_prompt, "do not choose a manufacturer"
    assert_includes result[:answer], "inconsistencia"
    assert_not_includes result[:answer], "Procedimiento KONE"
    assert_not_includes result[:answer], "Procedimiento de la placa"
    assert_equal [], result[:citations]
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

  test "text-only known equipment without a compatible manual continues with guidance" do
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "KONE",
      needles: [ "KONE" ],
      facts: [
        { "slot" => "manufacturer", "value" => "KONE", "source" => "user", "correlation_id" => "query:door" }
      ]
    )
    session_context = <<~TEXT
      ## Active Field Problem
      Goal: la puerta no cierra
      ## Recent Conversation
      User: la puerta no cierra
      Assistant: Hola. ¿Qué está pasando con el equipo?
    TEXT
    service = closed_identity_service(chunks: [])
    seen_prompt = nil
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      seen_prompt = prompt
      "No tengo un manual KONE compatible para un procedimiento del fabricante.\nQuiero separar si el operador recibe la orden de cierre o si la hoja ni intenta moverse.\n¿La hoja se mueve cuando llamas?"
    end
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| flunk "open retrieve_and_generate" }

    result = nil
    with_flag("true") do
      result = service.query(
        "la puerta no cierra",
        equipment_identity: identity,
        session_context: session_context,
        output_channel: :web
      )
    end

    assert_equal "no_compatible", result[:equipment_identity_status]
    assert_includes seen_prompt, "la puerta no cierra"
    assert_includes seen_prompt, "KONE"
    assert_includes seen_prompt, "Follow-up: yes."
    assert_includes seen_prompt, "One main question"
    assert_not_includes seen_prompt, "Accepted visual observation:"
    assert_includes result[:answer], "Quiero separar"
    assert_includes result[:answer], "¿La hoja se mueve"
    assert_not_includes result[:answer], "X17"
    assert_not_includes result[:answer], I18n.t("rag.data_not_available", locale: :es)
    assert_equal [], result[:citations]
  end

  test "no compatible guidance keeps a visual identifier and drops an invented value" do
    yida_body = "Paso 11. Ajusta el interruptor Yida a 2,5 mm."
    session_context = <<~TEXT
      ## Active Field Problem
      Goal: no nivela en planta 3
      ## Photo Evidence (this turn)
      - Manufacturer: Orona
      - Model: PBCM-V3
      - Subsystem: CONTROLLER_LOGIC
      - Visible text/codes: X17
      - Condition: GOOD
    TEXT
    service = closed_identity_service(chunks: [
      chunk("yida", yida_body, canonical_name: "Fuji Yida Guía del Usuario Ascensor", page: 97)
    ])
    seen_prompt = nil
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      seen_prompt = prompt
      <<~ANSWER
        En la foto se identifica Orona PBCM-V3 y se ve X17.
        X17 es la entrada de nivelación.
        Para acotar la nivelación quiero separar si queda pasada o corta.
        El terminal X19 va a 24 V y el código E18 indica encoder.
        ¿Qué hace la cabina al llegar a planta 3?
      ANSWER
    end
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| flunk "open retrieve_and_generate" }

    result = nil
    with_flag("true") do
      result = service.query(
        "no nivela en planta 3",
        equipment_identity: orona_identity,
        session_context: session_context,
        response_locale: :es,
        output_channel: :web
      )
    end

    assert_equal "no_compatible", result[:equipment_identity_status]
    assert_includes seen_prompt, "Orona"
    assert_includes seen_prompt, "PBCM-V3"
    assert_includes seen_prompt, "CONTROLLER_LOGIC"
    assert_includes seen_prompt, "X17"
    assert_includes seen_prompt, "no nivela en planta 3"
    assert_not_includes seen_prompt, yida_body
    assert_includes result[:answer], "Orona PBCM-V3"
    assert_includes result[:answer], "X17"
    assert_includes result[:answer], "pasada o corta"
    assert_includes result[:answer], "planta 3"
    assert_not_includes result[:answer], "entrada de nivelación"
    assert_not_includes result[:answer], "X19"
    assert_not_includes result[:answer], "24 V"
    assert_not_includes result[:answer], "E18"
    assert_not_includes result[:answer], yida_body
    assert_not_includes result[:answer], I18n.t("rag.uncited_technical_answer", locale: :es)
    assert_not_includes result[:answer], I18n.t("rag.data_not_available", locale: :es)
    assert_equal [], result[:citations]
    observation = FieldPhotoObservation.from_analysis(
      parsed: {
        "canonical_component" => "Placa controladora",
        "manufacturer" => "Orona",
        "model" => "PBCM-V3",
        "subsystem" => "CONTROLLER_LOGIC",
        "condition" => "GOOD",
        "visible_text" => [ "X17" ]
      },
      model_id: "claude-sonnet-5-5",
      target_visible: true,
      relevance_to_goal: "relevant"
    )
    segments = Rag::ProvenanceSegmenter.call(
      answer: result[:answer],
      citations: result[:citations],
      visual_observation: observation
    )
    assert_includes segments.pluck("band"), "VISUAL_OBSERVATION"
    assert_includes segments.pluck("band"), "DANEBO_GUIDANCE"
    assert segments.none? { |segment| segment["band"] == "MANUAL_FACT" }
  end

  test "a companion answer that is only an absence marker stays unavailable" do
    service = closed_identity_service(chunks: [])
    generator = Object.new
    generator.define_singleton_method(:query) { |_prompt, **| "DATA_NOT_AVAILABLE" }
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| flunk "open retrieve_and_generate" }

    result = nil
    with_flag("true") do
      result = service.query("no nivela", equipment_identity: orona_identity, output_channel: :web)
    end

    assert_equal "unavailable", result[:equipment_identity_status]
    assert_equal "generation_blank", result[:equipment_identity_reason]
    assert_not_includes result[:answer], "DATA_NOT_AVAILABLE"
  end

  test "known identity scope is durable and does not copy chunk text" do
    secret = "Cortocircuitar BM/B1 secreto"
    chunks = [ chunk("mono", secret, canonical_name: "Monarch") ]
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: chunks, retrieval_trace: {} } }
    generator = Object.new
    generator.define_singleton_method(:query) { |_prompt, **| "Sin procedimiento de este equipo." }
    service.define_singleton_method(:document_identity_generator) { generator }
    events = []
    result = nil

    with_flag("true") do
      events = capture_pilot_events do
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
          correlation_id: "query:scope"
        )
      end
    end

    scope = events.find { |event| event["event"] == "document_identity_scope" }
    assert_equal "no_compatible", scope["result"]
    assert_includes scope["scope_needles"], "Orona"
    assert_includes scope["scope_needles"], "PBCM-V3"
    assert_includes scope["identity_after"], "manufacturer:Orona:photo"
    assert_includes scope["identity_after"], "model:PBCM-V3:photo"
    assert_equal "ep-orona", scope["episode_id"]
    assert_equal "query:scope", scope["correlation_id"]
    assert_equal 1, scope["results_count"]
    assert_equal 0, scope["contexts_delivered"]
    assert_includes result[:generation_context], "danebo_guidance:present"
    assert_includes result[:generation_context], "photo_literal:absent"
    assert_includes result[:generation_context], "photo_interpretation:absent"
    assert result[:generation_prompt_chars].positive?
    assert_not result.key?(:evidence_applicability)
    assert_not result.key?(:meta_kind)
    assert_not_includes JSON.generate(scope), secret
    assert_not_includes JSON.generate(result[:generation_context]), secret
  end

  test "unknown identity open retrieval records identity_unknown and skips a required scope" do
    evidence = chunk("blt", "E18 fallo de nivelación.", canonical_name: "Código de Avería BLT Ascensor", page: 4)
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    retrieve_calls = []
    service.define_singleton_method(:retrieve_chunks) do |*, **kwargs|
      retrieve_calls << kwargs
      { chunks: [ evidence ], retrieval_trace: {} }
    end
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| flunk "unknown identity must not retrieve_and_generate" }
    service.define_singleton_method(:fallback_retrieve) { |*, **| flunk "direct generation must not open a fallback retrieve" }
    generator = Object.new
    generator.define_singleton_method(:query) { |_prompt, **| "Mirar la placa. [1]" }
    service.define_singleton_method(:document_identity_generator) { generator }
    events = capture_pilot_events do
      service.query(
        "no nivela",
        equipment_identity: nil,
        correlation_id: "query:open",
        output_channel: :web
      )
    end

    open = events.find { |event| event["event"] == "open_retrieval" }
    assert_equal 1, retrieve_calls.size
    assert_equal "query:open", retrieve_calls.first[:correlation_id]
    assert_equal "identity_unknown_reference", retrieve_calls.first[:route_taken]
    assert_equal "identity_unknown", open["outcome_reason"]
    assert_equal "identity_unknown_reference", open["evidence_applicability"]
    assert_not open.key?("results_count")
    assert_not open.key?("contexts_delivered")
    assert_equal "query:open", open["correlation_id"]
    assert_equal "ok", open["result"]
    assert events.none? { |event| event["event"] == "document_identity_scope" }
  end

  test "document identity scope telemetry failure stays inside the recorder" do
    identity = orona_identity
    original = Rag::DocumentIdentityScope.method(:needles)
    Rag::DocumentIdentityScope.define_singleton_method(:needles) { |*| raise "needles down" }
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    continued = false

    assert_nothing_raised do
      Rag::DocumentIdentityScopeEvent.record(
        identity: identity,
        correlation_id: "query:scope-down",
        status: :scoped
      )
      continued = true
    end

    assert continued
    assert_includes output.string, "document_identity_scope telemetry failed RuntimeError"
    assert_not_includes output.string, "needles down"
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
    Rag::DocumentIdentityScope.define_singleton_method(:needles, original) if original
  end

  test "pin denial keeps correlation and does not claim identity_unknown" do
    service = BedrockRagService.allocate
    service.instance_variable_set(:@account, accounts(:legacy))
    service.instance_variable_set(:@retrieval_denied, true)
    service.instance_variable_set(:@retrieval_denied_reason, "caller_uri_denied")
    service.instance_variable_set(:@rejected_result_count, 2)
    events = capture_pilot_events do
      result = service.deny_retrieval_result(question: "pregunta", correlation_id: "query:pin")
      assert_equal "DENY_RETRIEVAL", result[:retrieval]
    end

    open = events.find { |event| event["event"] == "open_retrieval" }
    assert_equal "query:pin", open["correlation_id"]
    assert_equal "deny", open["result"]
    assert_equal "caller_uri_denied", open["retrieval_denied_reason"]
    assert_nil open["outcome_reason"]
    assert_nil open["evidence_applicability"]
  end

  test "identity_unknown_reference does not change apply" do
    body = "Procedimiento genérico de nivelación."
    manual = chunk("manual", body, canonical_name: "Manual seleccionado")
    unknown = Rag::DocumentIdentityScope.apply([ manual ], nil)
    known_body = "En PBCM-V3 revisar el sensor de nivelación de la placa Orona."
    known_manual = chunk("orona", known_body, canonical_name: "Manual Orona PBCM-V3")
    known = Rag::DocumentIdentityScope.apply([ known_manual ], orona_identity)

    assert_nil Rag::DocumentIdentityScope.applicability_mode(:malformed)
    assert_nil Rag::DocumentIdentityScope.applicability_mode(orona_identity)
    assert_equal "identity_unknown_reference", Rag::DocumentIdentityScope.applicability_mode(nil)
    assert_nil unknown.status
    assert_equal :not_required, unknown.reason
    assert_equal body, unknown.chunks.sole[:content]
    marked = Rag::DocumentIdentityScope.mark_unconfirmed_reference([ manual ])
    assert_includes marked.sole[:content], "UNCONFIRMED REFERENCE"
    assert_includes marked.sole[:content], "Manual: Manual seleccionado"
    assert_includes marked.sole[:content], body
    assert_equal "unconfirmed_reference", marked.sole[:identity_applicability]
    assert_equal body, unknown.chunks.sole[:content]
    assert_equal :scoped, known.status
    assert_equal "compatible", known.applicability.sole
    assert_equal known_body, known.chunks.sole[:content]
    assert_equal "THIS JOB'S EQUIPMENT: Manual Orona PBCM-V3", known.labels.sole
  end

  test "managed unknown identity keeps generative mode and the sent applicability block" do
    raw = "No nivela en planta 3. Todavía no sé fabricante ni modelo."
    episode = Rag::ActiveEpisode.open(correlation_id: "query:trace", now: Time.current)
    before = episode.fork
    perception = Rag::TurnPerception.build(
      {
        "move" => "report",
        "assertions" => [],
        "observations" => [ "No nivela en planta 3" ],
        "pending_resolution" => nil,
        "clarification_target" => nil
      },
      turn: raw,
      episode: Rag::ActiveEpisode.new,
      catalog: nil,
      viewer_account: nil
    )
    decision = Rag::RoutePolicy.call(previous: episode, perception: perception, focus_count: 0, locale: :es)
    Rag::WorkContextReducer.apply!(
      episode: episode, perception: perception, decision: decision,
      turn: raw, correlation_id: "query:trace", now: Time.current
    )
    delta = Rag::ActiveEpisodeTurn.changed_fields(before, episode.fork)
    explained = Rag::QueryComposer.explain(
      state: episode, turn: raw, perception: perception, decision: decision
    )
    answer = "Referencia del manual Código de Avería BLT Ascensor, página 4. No está confirmado que aplique al equipo actual. [1]"
    blt = chunk("blt", "E18 fallo de nivelación.", canonical_name: "Código de Avería BLT Ascensor", page: 4)
    blt[:metadata]["original_source_uri"] = "s3://bucket/blt.pdf"
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    rag_calls = 0
    retrieve_calls = []
    prompts = []
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }
    service.define_singleton_method(:retrieve_chunks) do |*, **kwargs|
      retrieve_calls << kwargs
      { chunks: [ blt ], retrieval_trace: {} }
    end
    service.define_singleton_method(:fallback_retrieve) { |*, **| flunk "direct generation must not open a fallback retrieve" }
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      prompts << prompt
      answer
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    events = []
    result = nil
    events = capture_pilot_events do
      result = service.query(
        explained[:query],
        raw_question: raw,
        equipment_identity: nil,
        user_id: 9,
        conversation_session_id: 11,
        correlation_id: "query:trace",
        output_channel: :web,
        response_locale: :es
      )
    end

    prompt = prompts.sole
    open = events.find { |event| event["event"] == "open_retrieval" }

    original_sha = Digest::SHA256.hexdigest(raw)
    effective_sha = Digest::SHA256.hexdigest(explained[:query].to_s)

    assert perception.valid
    assert_equal "report", perception.move
    assert_includes delta, "observations"
    assert_includes explained[:query], "No nivela en planta 3"
    assert_includes explained[:components], "current_turn:full"
    assert_equal 64, original_sha.length
    assert_equal 64, effective_sha.length
    assert_not_equal original_sha, effective_sha
    assert_includes prompt, raw
    assert_not_includes prompt, explained[:query] unless explained[:query] == raw
    assert_equal explained[:query], Rag::QueryComposer.call(
      state: episode, turn: raw, perception: perception, decision: decision
    )
    assert_equal 0, rag_calls
    assert_equal 1, retrieve_calls.size
    assert_equal 1, prompts.size
    assert_equal 9, retrieve_calls.first[:user_id]
    assert_equal 11, retrieve_calls.first[:conversation_session_id]
    assert_equal "query:trace", retrieve_calls.first[:correlation_id]
    assert_equal "identity_unknown_reference", retrieve_calls.first[:route_taken]
    assert_includes prompt, "# FIELD COMPANION"
    assert_includes prompt, "The equipment identity is not confirmed."
    assert_includes prompt, "Código de Avería BLT Ascensor, p. 4"
    assert_not_includes prompt, "UNCONFIRMED REFERENCE"
    assert_not_includes prompt, "E18 fallo de nivelación."
    assert_not_includes prompt, "APPLICABILITY_BLOCK"
    assert_not_includes prompt, "$output_format_instructions$"
    assert_not_includes prompt, "THIS JOB'S EQUIPMENT:"
    assert_equal "identity_unknown_reference", open["evidence_applicability"]
    assert_equal "identity_unknown", open["outcome_reason"]
    assert_not open.key?("results_count")
    assert_not open.key?("contexts_delivered")
    assert events.none? { |event| event["event"] == "document_identity_scope" }
    assert_nil result[:generation_mode]
    assert_equal "generative", Rag::CausalTrace.resolved_generation_mode(nil, success: true)
    assert result[:generation_context].none? { |token| token.include?("applicability") || token.include?("identity_unknown") }
    assert_equal "Código de Avería BLT Ascensor", result[:doc_refs].sole["canonical_name"]
    assert_includes result[:answer], "No está confirmado"
    assert_not_includes result[:answer], "Ajusta"
    assert_not_includes result[:answer], "terminal"
  end

  test "unconfirmed identity assertion is read from chunk metadata" do
    orona = chunk(
      "up900",
      "Reenviar al piso extremo inferior. Terminal X9. Código E18.",
      canonical_name: "Listado de Averías Orona uP-900",
      section_identity: "MANIOBRA UNIVERSAL uP-900",
      page: 4
    )
    acme = chunk("acme", "Procedimiento secreto del terminal Z9.", canonical_name: "ACME ZX-42", page: 2)
    tijera = chunk("tijera", "Descenso de emergencia.", canonical_name: "Manual Plataforma Tijera", page: 8)

    [
      "Este equipo es ORONA uP-900.",
      "He identificado el controlador de este ascensor: MANIOBRA UNIVERSAL uP-900.",
      "Según la documentación recuperada, el equipo dispone de un controlador MANIOBRA UNIVERSAL uP-900.",
      "Este equipo es ORONA uP-900. Envíalo al piso inferior, entra en inspección y corta tensión."
    ].each do |answer|
      assert Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(answer, [ orona ]), answer
    end

    [
      "No está confirmado que este ascensor sea Orona uP-900.",
      "Confirma si este equipo es uP-900.",
      "Confirma que el ascensor es efectivamente una Maniobra Universal uP-900.",
      "En el manual Orona uP-900 se documenta el síntoma.",
      "Envíalo al piso inferior, entra en inspección y corta tensión."
    ].each do |answer|
      assert_not Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(answer, [ orona ]), answer
    end

    assert Rag::DocumentIdentityScope.unconfirmed_identity_assertion?("Este equipo es ACME ZX-42.", [ acme ])
    assert_not Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(
      "En el manual ACME ZX-42 se documenta el síntoma.",
      [ acme ]
    )
    assert_not Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(
      "La documentación recuperada corresponde a una plataforma tijera.",
      [ tijera ]
    )
    assert_not Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(
      "Este equipo no es una plataforma tijera.",
      [ tijera ]
    )
    assert Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(
      "Este equipo es una plataforma tijera.",
      [ tijera ]
    )

    aliased = chunk("fault", "Cuerpo que no debe copiarse.", canonical_name: "Fault Code List Document", page: 1)
    aliased[:metadata]["aliases"] = [ "Listado de Averías", "Norma de Montaje 0426049", "Instrucciones Generales uP-900" ]
    generic = chunk("fault", "Cuerpo que no debe copiarse.", canonical_name: "Fault Code List Document", page: 1)
    display = "Según la documentación recuperada, el equipo dispone de un controlador **MANIOBRA UNIVERSAL uP-900** [1], fabricado por ORONA."
    assert Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(display, [ aliased ])
    assert_not Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(display, [ generic ])
    assert_not Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(
      "En el manual uP-900 se documenta el síntoma.",
      [ aliased ]
    )
  end

  test "unconfirmed reference withheld names manuals and drops the foreign procedure" do
    body = "Reenviar al piso extremo inferior. Terminal X9. Código E18."
    chunks = [
      chunk("a", body, canonical_name: "Listado de Averías Orona uP-900", page: 4),
      chunk("b", "otro cuerpo", canonical_name: "Manual Plataforma Tijera", page: 8),
      chunk("c", "otro cuerpo", canonical_name: "Tercero", page: 1),
      chunk("d", "otro cuerpo", canonical_name: "Cuarto", page: 2)
    ]

    spanish = Rag::DocumentIdentityScope.unconfirmed_reference_withheld(chunks, locale: :es)
    english = Rag::DocumentIdentityScope.unconfirmed_reference_withheld([ chunks.first ], locale: :en)

    assert_includes spanish, "La identidad de este equipo no está confirmada."
    assert_includes spanish, "Listado de Averías Orona uP-900, p. 4"
    assert_includes spanish, "Manual Plataforma Tijera, p. 8"
    assert_includes spanish, "Tercero, p. 1"
    assert_not_includes spanish, "Cuarto"
    assert_includes spanish, "no se aplica como procedimiento de este trabajo"
    assert_includes spanish, "placa del cuadro o del controlador"
    [ "piso extremo", "X9", "E18", "otro cuerpo" ].each do |foreign|
      assert_not_includes spanish, foreign
    end
    assert_includes english, "This equipment identity is not confirmed."
    assert_includes english, "Listado de Averías Orona uP-900, p. 4"
    assert_includes english, "nameplate"
    assert_not_includes english, "piso extremo"
  end

  test "known identity generation does not receive the unknown applicability block" do
    body = "En PBCM-V3 revisar el sensor de nivelación de la placa Orona."
    chunks = [ chunk("orona", body, canonical_name: "Manual Orona PBCM-V3") ]
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    prompts = []
    rag_calls = 0
    retrieve_calls = 0
    service.define_singleton_method(:retrieve_chunks) do |*, **|
      retrieve_calls += 1
      { chunks: chunks, retrieval_trace: {} }
    end
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      prompts << prompt
      "Revisar el sensor de nivelación. [1]"
    end
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }

    events = []
    result = nil
    with_flag("true") do
      events = capture_pilot_events do
        result = service.query(
          "no nivela",
          equipment_identity: orona_identity,
          correlation_id: "query:known",
          output_channel: :web
        )
      end
    end

    scope = events.find { |event| event["event"] == "document_identity_scope" }
    assert_equal 1, retrieve_calls
    assert_equal 1, prompts.size
    assert_equal 0, rag_calls
    assert_equal "document_identity_scope", result[:generation_mode]
    assert_not_includes prompts.first, "identity_unknown_reference"
    assert_not_includes prompts.first, "UNKNOWN EQUIPMENT IDENTITY"
    assert_not_includes prompts.first, "UNCONFIRMED REFERENCE"
    assert_nil scope["evidence_applicability"]
    assert events.none? { |event| event["event"] == "open_retrieval" }
    assert_includes prompts.first, body
  end

  test "known identity publishes an identity sentence the unknown guard would withhold" do
    published = "Este equipo es ORONA uP-900. [1]"
    chunks = [ chunk("orona", "Este equipo es ORONA uP-900.", canonical_name: "Manual Orona PBCM-V3", section_identity: "ORONA uP-900") ]
    ran = run_identity_generation(published, chunks, equipment_identity: orona_identity)

    assert_equal 1, ran[:retrieve_calls]
    assert_equal 1, ran[:prompts].size
    assert_equal 0, ran[:rag_calls]
    assert_equal published, ran[:result][:answer]
    assert_nil ran[:result][:applicability_violation]
    assert ran[:events].none? { |event| event["event"] == "open_retrieval" }
  end

  test "known identity publishes a grounded control instruction the unknown guard withholds" do
    published = "Pulse el botón de inspección. [1]"
    body = "Pulse el botón de inspección."
    chunks = [
      chunk(
        "orona", body,
        canonical_name: "Manual Orona PBCM-V3", section_identity: "ORONA PBCM-V3"
      )
    ]
    known = run_identity_generation(published, chunks, equipment_identity: orona_identity, question: "como sigo")
    unknown = run_identity_generation(
      "Pulse el botón de inspección.", chunks, equipment_identity: nil, question: "como sigo"
    )

    assert_equal published, known[:result][:answer]
    assert_nil known[:result][:applicability_violation]
    assert_equal :procedure_application, unknown[:result][:applicability_violation]
    assert_equal :operation, unknown[:result][:applicability_violation_basis]
    assert_not_includes unknown[:result][:answer], "Pulse el botón"
  end

  test "known identity still publishes a code meaning the unknown guard would withhold" do
    published = "Q-731 = fallo de puerta. [1]"
    chunks = [
      chunk(
        "orona", "Q-731 = fallo de puerta.",
        canonical_name: "Manual Orona PBCM-V3", section_identity: "ORONA PBCM-V3"
      )
    ]
    ran = run_identity_generation(published, chunks, equipment_identity: orona_identity)

    assert_equal published, ran[:result][:answer]
    assert_nil ran[:result][:applicability_violation]
  end

  test "unknown identity withholds a new code meaning when the question only named the code" do
    promoted = "Q-731 = fallo de puerta. [1]"
    evidence = chunk(
      "zephyr", "Q-731 = fallo de puerta.",
      canonical_name: "ZEPHYR QX-77", section_identity: "ZEPHYR QX-77", page: 12
    )
    ran = run_identity_generation(
      promoted, [ evidence ], equipment_identity: nil,
      question: "El display muestra Q-731, ¿qué significa?"
    )

    assert_equal :procedure_application, ran[:result][:applicability_violation]
    assert_equal :value_code, ran[:result][:applicability_violation_basis]
    assert_includes ran[:result][:answer], "no está confirmada"
    assert_not_includes ran[:result][:answer], "fallo de puerta"
  end

  test "unknown identity withholds an asserted foreign identity and its procedure" do
    adversarial = "Este equipo es ORONA uP-900. Envíalo al piso inferior, entra en inspección y corta tensión."
    body = "Reenviar al piso extremo inferior. Terminal X9. Código E18."
    evidence = chunk(
      "up900", body,
      canonical_name: "Listado de Averías Orona uP-900",
      section_identity: "MANIOBRA UNIVERSAL uP-900",
      page: 4
    )
    evidence[:metadata]["original_source_uri"] = "s3://bucket/up900.pdf"
    ran = run_identity_generation(adversarial, [ evidence ], equipment_identity: nil)

    open = ran[:events].find { |event| event["event"] == "open_retrieval" }
    answer = ran[:result][:answer]

    assert_equal 1, ran[:retrieve_calls]
    assert_equal 1, ran[:prompts].size
    assert_equal 0, ran[:rag_calls]
    assert_includes ran[:prompts].first, "# FIELD COMPANION"
    assert_includes ran[:prompts].first, "Listado de Averías Orona uP-900, p. 4"
    assert_not_includes ran[:prompts].first, "UNCONFIRMED REFERENCE"
    assert_not_includes ran[:prompts].first, body
    assert_equal "identity_unknown", open["outcome_reason"]
    assert_equal :identity_assertion, ran[:result][:applicability_violation]
    assert_equal adversarial, ran[:result].dig(:diagnostics, :raw_answer)
    assert_equal :identity_assertion, ran[:result].dig(:diagnostics, :applicability_violation)
    assert_includes answer, "La identidad de este equipo no está confirmada."
    assert_includes answer, "Listado de Averías Orona uP-900, p. 4"
    assert_not_includes answer, "Este equipo es ORONA uP-900"
    assert_not_includes answer, "Envíalo al piso inferior"
    assert_not_includes answer, "X9"
    assert_not_includes answer, "E18"
    assert_equal [], ran[:result][:citations]
    assert ran[:result][:retrieved_citations].any?
    assert_equal "Listado de Averías Orona uP-900", ran[:result][:doc_refs].sole["canonical_name"]
  end

  test "unknown identity withholds an unqualified procedure without another call" do
    procedure = "Envíalo al piso inferior, entra en inspección y corta tensión."
    evidence = chunk(
      "up900", "Reenviar al piso extremo inferior.",
      canonical_name: "Listado de Averías Orona uP-900",
      section_identity: "MANIOBRA UNIVERSAL uP-900",
      page: 4
    )
    evidence[:metadata]["original_source_uri"] = "s3://bucket/up900.pdf"
    assert_not Rag::DocumentIdentityScope.unconfirmed_identity_assertion?(procedure, [ evidence ])

    ran = run_identity_generation(procedure, [ evidence ], equipment_identity: nil)
    answer = ran[:result][:answer]

    assert_equal 1, ran[:retrieve_calls]
    assert_equal 1, ran[:prompts].size
    assert_equal 0, ran[:rag_calls]
    assert_equal :procedure_application, ran[:result][:applicability_violation]
    assert_equal :operation, ran[:result][:applicability_violation_basis]
    assert_equal "identity_unknown", ran[:events].find { |event| event["event"] == "open_retrieval" }["outcome_reason"]
    assert_equal procedure, ran[:result].dig(:diagnostics, :raw_answer)
    assert_includes answer, "no está confirmada"
    assert_not_includes answer, "Envíalo"
    assert_equal [], ran[:result][:citations]
    assert ran[:result][:retrieved_citations].any?
  end

  test "a pin without confirmed identity does not suppress the applicability contract" do
    uri = "s3://bucket/blt-nivelacion.pdf"
    KbDocument.create!(account: accounts(:legacy), s3_key: uri, display_name: "BLT", aliases: [])
    answer = "Mirar la cabina al llegar a la planta. [1]"
    blt = chunk("blt", "Mirar el final de carrera.", canonical_name: "BLT", page: 4)
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    prompts = []
    retrieves = []
    rag_calls = 0
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }
    service.define_singleton_method(:fallback_retrieve) { |*, **| flunk "a pin does not add a second retrieve" }
    service.define_singleton_method(:retrieve_chunks) do |*, **kwargs|
      retrieves << kwargs
      { chunks: [ blt ], retrieval_trace: {} }
    end
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      prompts << prompt
      answer
    end
    service.define_singleton_method(:document_identity_generator) { generator }

    events = capture_pilot_events do
      service.query(
        "no nivela",
        equipment_identity: nil,
        entity_s3_uris: [ uri ],
        entity_sources: [ "document" ],
        force_entity_filter: true,
        correlation_id: "query:pin-unknown",
        output_channel: :web
      )
    end

    prompt = prompts.sole
    filter = retrieves.sole[:vector_search_configuration].to_h[:filter]
    open = events.find { |event| event["event"] == "open_retrieval" }

    assert_equal 0, rag_calls
    assert_equal 1, retrieves.size
    assert_includes prompt, "# FIELD COMPANION"
    assert_includes prompt, "The equipment identity is not confirmed."
    assert_includes prompt, "BLT, p. 4"
    assert_not_includes prompt, "UNCONFIRMED REFERENCE"
    assert_not_includes prompt, "Mirar el final de carrera."
    assert_not_includes prompt, "APPLICABILITY_BLOCK"
    assert_includes filter.to_json, uri
    assert_equal "identity_unknown_reference", open["evidence_applicability"]
    assert_equal "identity_unknown", open["outcome_reason"]
    assert events.none? { |event| event["event"] == "document_identity_scope" }
    assert_nil Rag::DocumentIdentityScope.applicability_mode(orona_identity)
  end

  private

  def assert_applicability_contract(prompt)
    assert_includes prompt, "identity_unknown_reference"
    assert_includes prompt, "UNKNOWN EQUIPMENT IDENTITY"
    assert_includes prompt, "prompt_version: f1cal.r2.a1"
    assert_includes prompt, "not confirmed for this equipment"
    assert_includes prompt, "A pin is retrieval focus, not identity."
    assert_includes prompt, "look, read, or listen"
    assert_includes prompt, "Do not paste another manual's steps."
    assert_not_includes prompt, "$output_format_instructions$"
    assert_includes prompt, "Cite a claim taken from a search result with [n]"
    assert prompt.index("identity_unknown_reference") < prompt.index("Cite a claim taken from a search result with [n]")
    assert_not_includes prompt, "THIS JOB'S EQUIPMENT:"
    assert_not_includes prompt, "REFERENCE ONLY — OTHER EQUIPMENT:"
  end

  def native_citation(text, canonical_name:, page:)
    OpenStruct.new(
      generated_response_part: OpenStruct.new(
        text_response_part: OpenStruct.new(span: OpenStruct.new(start: 0, end: text.length))
      ),
      retrieved_references: [
        OpenStruct.new(
          content: OpenStruct.new(text: text),
          location: OpenStruct.new(s3_location: OpenStruct.new(uri: "s3://bucket/chunks/blt.txt")),
          metadata: {
            "canonical_name" => canonical_name,
            "original_source_uri" => "s3://bucket/blt.pdf",
            "page_number" => page,
            "doc_type" => "manual",
            "account_id" => accounts(:legacy).id.to_s
          }
        )
      ]
    )
  end

  def closed_identity_service(chunks:)
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: chunks, retrieval_trace: {} } }
    service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
    service
  end

  def assert_identity_retrieval_failure(error, reason)
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { |*, **| raise error }
    service.define_singleton_method(:document_identity_generator) { flunk "generator" }
    rag_calls = 0
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }

    result = nil
    with_flag("true") do
      result = service.query("no nivela", equipment_identity: orona_identity, output_channel: :web)
    end

    assert_equal 0, rag_calls
    assert_equal "unavailable", result[:equipment_identity_status]
    assert_equal reason, result[:equipment_identity_reason]
    assert_equal false, Thread.current[:document_identity_scope]["fallback"]
    assert_equal [], result[:citations]
  end

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

  def run_identity_generation(answer, chunks, equipment_identity:, question: "el display parpadea")
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    prompts = []
    retrieve_calls = 0
    rag_calls = 0
    service.define_singleton_method(:retrieve_chunks) do |*, **|
      retrieve_calls += 1
      { chunks: chunks, retrieval_trace: {} }
    end
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      prompts << prompt
      answer
    end
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| rag_calls += 1 }

    result = nil
    events = []
    with_flag("true") do
      events = capture_pilot_events do
        result = service.query(
          question,
          equipment_identity: equipment_identity,
          correlation_id: "query:f1c",
          output_channel: :web,
          response_locale: :es,
          include_diagnostics: true
        )
      end
    end
    { result: result, events: events, prompts: prompts, retrieve_calls: retrieve_calls, rag_calls: rag_calls }
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

  def job_identity(manufacturer, model)
    turn = "pin:#{model}"
    Rag::EquipmentIdentity.new(
      manufacturer: manufacturer,
      needles: [ manufacturer, model ],
      facts: [
        { "slot" => "manufacturer", "value" => manufacturer, "source" => "user", "correlation_id" => turn },
        { "slot" => "model", "value" => model, "source" => "user", "correlation_id" => turn }
      ]
    )
  end

  def pinned_manual(name, body, uri)
    selected = chunk(name.parameterize, body, canonical_name: name, section_identity: name)
    selected[:metadata]["original_source_uri"] = uri
    selected
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

  def capture_pilot_events
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    output.string.lines.filter_map do |line|
      JSON.parse(line.split("[PILOT_USAGE] ", 2).last) if line.include?("[PILOT_USAGE]")
    end
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
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
