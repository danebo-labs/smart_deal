# frozen_string_literal: true

require "test_helper"

class Rag::DocumentIdentityScopeTest < ActiveSupport::TestCase
  POISON = [ "BM/B1", "61:U/N", "XB21", "00 71", "6 ± 1 mm" ].freeze
  CEA15_BODY = "En la placa CEA15 el código 8 es alta temperatura en el motor.".freeze
  PREAMBLE = Rag::DocumentIdentityScope::PREAMBLE

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
