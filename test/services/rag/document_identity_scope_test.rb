# frozen_string_literal: true

require "test_helper"

class Rag::DocumentIdentityScopeTest < ActiveSupport::TestCase
  POISON = [ "BM/B1", "61:U/N", "XB21", "00 71", "6 ± 1 mm" ].freeze
  CEA15_BODY = "En la placa CEA15 el código 8 es alta temperatura en el motor.".freeze

  test "MH matches MH and does not match MHX" do
    catalog = catalog_for(entry("mh-doc", designators: [ "MH" ]))

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      kept = Rag::DocumentIdentityScope.apply(
        [ chunk("mh-doc", "cuerpo del plano MH") ],
        episode(identifiers: %w[MH])
      )
      source = chunk("mh-doc", "cuerpo del plano MH")
      rejected = Rag::DocumentIdentityScope.apply(
        [ source ],
        episode(identifiers: %w[MHX])
      )

      assert_equal "cuerpo del plano MH", kept.chunks.first[:content]
      assert_equal "THIS JOB'S EQUIPMENT: MH.", kept.labels.first
      assert_nil rejected.labels.first
      assert_equal "cuerpo del plano MH", rejected.chunks.first[:content]
      assert_equal "cuerpo del plano MH", source[:content]
    end
  end

  test "match, generic, other equipment, and a private manual" do
    catalog = catalog_for(
      entry("cea", brands: [ "Controles S.A." ], designators: [ "CEA15", "CEA15+", "CEA15P" ]),
      entry("mono", brands: [ "Monarch" ], designators: [ "NICE3000" ]),
      entry("note", generic: true),
      entry("cea51", brands: [ "Controles S.A." ], designators: [ "CEA51FB" ])
    )
    monarch = chunk("mono", "Cortocircuitar BM/B1 y BM/B2.", canonical_name: "Monarch", page: 84,
                    heading: "## Door machine", section_identity: "Door machine")
    chunks = [
      chunk("cea", CEA15_BODY, canonical_name: "Manual CEA15"),
      monarch,
      chunk("note", "Nota interna de citofono.", canonical_name: "Citofono"),
      chunk("own", "Procedimiento del manual de la cuenta.", account_id: "9", canonical_name: "Cliente")
    ]

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      result = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[MH CEA15]))

      assert_not result.blocked
      assert_equal 1, result.undeclared_private
      assert_equal CEA15_BODY, result.chunks[0][:content]
      assert_equal "THIS JOB'S EQUIPMENT: Controles S.A. CEA15 CEA15+ CEA15P.", result.labels[0]
      assert_equal other_line("Monarch NICE3000"), result.labels[1]
      assert_equal "## Door machine\nCortocircuitar BM/B1 y BM/B2.", result.chunks[1][:content]
      assert_nil result.labels[2]
      assert_equal "Nota interna de citofono.", result.chunks[2][:content]
      assert_nil result.labels[3]
      assert_equal "Procedimiento del manual de la cuenta.", result.chunks[3][:content]
      assert_equal "## Door machine\nCortocircuitar BM/B1 y BM/B2.", monarch[:content]
      assert_equal "Door machine", result.chunks[1][:metadata]["section_identity"]
    end
  end

  test "an unconfirmed entry keeps its body and does not block the turn" do
    catalog = catalog_for(
      entry("cea", designators: [ "CEA15" ]),
      entry("mono", brands: [ "Monarch" ]),
      entry("draft", brands: [ "Otis" ], confirmed: false)
    )
    chunks = [
      chunk("cea", CEA15_BODY),
      chunk("mono", "Cortocircuitar BM/B1."),
      chunk("draft", "Procedimiento Otis sin confirmar.")
    ]
    io = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      result = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[CEA15]))

      assert_not result.blocked
      assert_equal 0, result.undeclared_private
      assert_equal 1, result.unconfirmed_general
      assert_equal CEA15_BODY, result.chunks[0][:content]
      assert_equal other_line("Monarch", job: "Elemont CEA15"), result.labels[1]
      assert_equal "Cortocircuitar BM/B1.", result.chunks[1][:content]
      assert_nil result.labels[2]
      assert_equal "Procedimiento Otis sin confirmar.", result.chunks[2][:content]
    end

    assert_includes io.string, "[DOCUMENT_IDENTITY] unconfirmed_general account_id=1 document_id=draft"
  ensure
    Rails.logger = previous_logger if previous_logger
  end

  test "a loaded catalog with one confirmed entry is activatable" do
    mixed = catalog_for(
      entry("cea", designators: [ "CEA15" ], confirmed: true),
      entry("draft", confirmed: false)
    )
    failed = Rag::DocumentIdentityCatalog.new(
      { "documents" => [ entry("cea", confirmed: true) ] },
      loaded: false
    )

    assert mixed.activatable?
    assert_not failed.activatable?
    assert_not catalog_for(entry("draft", confirmed: false)).activatable?
  end

  test "flag off does not retrieve and the unconfirmed catalog cannot activate" do
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

    catalog = Rag::DocumentIdentityCatalog.load
    assert_equal 204, catalog.entries.size
    assert_equal 204, catalog.unconfirmed_count
    assert_not catalog.activatable?

    with_flag("true") do
      assert_not Rag::DocumentIdentityScope.applicable?(episode)
      Rag::DocumentIdentityCatalog.with_catalog(catalog_for(entry("cea", designators: [ "CEA15" ], confirmed: true))) do
        assert Rag::DocumentIdentityScope.applicable?(episode)
        assert_not Rag::DocumentIdentityScope.applicable?(episode(manufacturer_status: "unknown_confirmed"))
      end
    end
  end

  test "lookup key is document_id because the sidecar uri is not the s3 key" do
    entry = Rag::DocumentIdentityCatalog.load.find(
      "1",
      "9a4fa817-b9e8-4a9e-ae83-526c0731e603"
    )
    uri = "s3://multimodal-source-destination/#{entry.s3_key}"

    assert entry.s3_key.end_with?("manual-cea15p.pdf")
    assert_not_equal entry.s3_key, uri
    assert_includes entry.brands, "Controles S.A."
    assert_includes entry.designators, "CEA15"
    assert_not entry.confirmed
  end

  test "equipment of another brand is trimmed and the same brand is kept" do
    catalog = catalog_for(
      entry("elemont", brands: [ "Elemont" ], designators: [ "MH" ], role: "equipment"),
      entry("kone", brands: [ "KONE" ], designators: [ "MX05" ], role: "equipment")
    )
    chunks = [
      chunk("elemont", "Procedimiento Elemont MH."),
      chunk("kone", "Desconecte XB21.")
    ]

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      result = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[MH CEA15]))

      assert_equal "Procedimiento Elemont MH.", result.chunks[0][:content]
      assert_equal "THIS JOB'S EQUIPMENT: Elemont MH.", result.labels[0]
      assert_equal "Desconecte XB21.", result.chunks[1][:content]
      assert_equal other_line("KONE MX05"), result.labels[1]
    end
  end

  test "a component is trimmed only when an identifier is present and none match" do
    catalog = catalog_for(
      entry("vf5", brands: [ "Fermator" ], designators: [ "VF5" ], role: "component"),
      entry("cea", brands: [ "Controles S.A." ], designators: [ "CEA15" ], role: "component")
    )
    foreign = chunk("vf5", "Ajuste VF5 270 mm.")
    own = chunk("cea", CEA15_BODY)

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      named = Rag::DocumentIdentityScope.apply([ foreign, own ], episode(identifiers: %w[CEA15]))
      unnamed = Rag::DocumentIdentityScope.apply([ foreign ], episode(identifiers: []))

      assert_equal "Ajuste VF5 270 mm.", named.chunks[0][:content]
      assert_equal other_line("Fermator VF5", job: "Elemont CEA15"), named.labels[0]
      assert_equal CEA15_BODY, named.chunks[1][:content]
      assert_equal "THIS JOB'S EQUIPMENT: Controles S.A. CEA15.", named.labels[1]
      assert_equal "Ajuste VF5 270 mm.", unnamed.chunks[0][:content]
      assert_nil unnamed.labels[0]
    end
  end

  test "a confirmed entry without a role keeps its body" do
    catalog = catalog_for(entry("mono", brands: [ "Monarch" ], role: nil))

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      result = Rag::DocumentIdentityScope.apply(
        [ chunk("mono", "Cortocircuitar BM/B1.") ],
        episode(identifiers: %w[CEA15])
      )

      assert_equal "Cortocircuitar BM/B1.", result.chunks[0][:content]
      assert_nil result.labels[0]
    end
  end

  test "CEA15 does not match CEA15P" do
    catalog = catalog_for(
      entry("plus", brands: [ "KONE" ], designators: [ "CEA15P" ], role: "equipment"),
      entry("plain", brands: [ "KONE" ], designators: [ "CEA15" ], role: "equipment")
    )

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      plus = Rag::DocumentIdentityScope.apply(
        [ chunk("plus", "texto CEA15P") ],
        episode(identifiers: %w[CEA15])
      )
      plain = Rag::DocumentIdentityScope.apply(
        [ chunk("plain", "texto CEA15") ],
        episode(identifiers: %w[CEA15P])
      )

      assert_equal "texto CEA15P", plus.chunks[0][:content]
      assert_equal other_line("KONE CEA15P", job: "Elemont CEA15"), plus.labels[0]
      assert_equal "texto CEA15", plain.chunks[0][:content]
      assert_equal other_line("KONE CEA15", job: "Elemont CEA15P"), plain.labels[0]
    end
  end

  test "confirmed without a printed mark keeps its body" do
    raw = entry("mono", brands: [ "Monarch" ], role: "equipment")
    raw["evidence_page"] = nil
    raw["evidence_text"] = nil
    catalog = catalog_for(raw)

    assert_not catalog.activatable?
    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      result = Rag::DocumentIdentityScope.apply(
        [ chunk("mono", "Cortocircuitar BM/B1.") ],
        episode(identifiers: %w[CEA15])
      )

      assert_equal "Cortocircuitar BM/B1.", result.chunks[0][:content]
      assert_nil result.labels[0]
      assert_equal 1, result.unconfirmed_general
    end
  end

  test "a chunk without an identity does not block the turn" do
    catalog = catalog_for(entry("kone", brands: [ "KONE" ], role: "equipment"))
    blank = chunk("kone", "Cuerpo sin identidad.")
    blank[:metadata] = { "canonical_name" => "sin id" }
    chunks = [
      blank,
      chunk("kone", "Desconecte XB24.")
    ]

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      result = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[CEA15]))

      assert_not result.blocked
      assert_equal "Cuerpo sin identidad.", result.chunks[0][:content]
      assert_nil result.labels[0]
      assert_equal "Desconecte XB24.", result.chunks[1][:content]
      assert_equal other_line("KONE", job: "Elemont CEA15"), result.labels[1]
      assert_equal 1, result.unconfirmed_general
    end
  end

  test "generation context matches byte for byte except label lines" do
    catalog = catalog_for(
      entry("cea", designators: [ "CEA15" ], role: "equipment"),
      entry("mono", brands: [ "Monarch" ], role: "equipment")
    )
    chunks = [
      chunk("mono", "Cortocircuitar BM/B1.", canonical_name: "Monarch"),
      chunk("cea", CEA15_BODY, canonical_name: "Manual CEA15")
    ]
    question = "¿Qué reviso?"
    service = BedrockRagService.new(account: accounts(:legacy))

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      applied = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[CEA15]))
      off = service.send(
        :document_identity_generation_prompt, question, chunks,
        response_locale: :es, session_context: nil, output_channel: :web
      )
      on = service.send(
        :document_identity_generation_prompt, question, applied.chunks, labels: applied.labels,
        response_locale: :es, session_context: nil, output_channel: :web
      )

      assert_equal off, strip_labels(on, applied.labels)
      assert_not_equal off, on
      assert_includes on, "Cortocircuitar BM/B1."
      assert_includes on, CEA15_BODY
      assert_includes on, other_line("Monarch", job: "Elemont CEA15")
      assert_includes on, "THIS JOB'S EQUIPMENT: CEA15."
    end
  end

  test "eight retrieved chunks stay eight, bodies and order unchanged" do
    catalog = catalog_for(
      entry("mono", brands: [ "Monarch" ], role: "equipment"),
      entry("kone", brands: [ "KONE" ], role: "equipment"),
      entry("blt", brands: [ "BLT" ], role: "equipment"),
      entry("cea", designators: [ "CEA15" ], role: "component"),
      entry("mh", brands: [ "Elemont" ], designators: [ "MH" ], role: "equipment"),
      entry("door", brands: [ "Elemont" ], role: "equipment"),
      entry("board", brands: [ "Elemont" ], role: "component"),
      entry("panel", brands: [ "Elemont" ], role: "equipment")
    )
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
    ids = %w[mono kone blt cea mh door board panel]
    chunks = ids.zip(bodies).map { |id, body| chunk(id, body) }
    question = "Elemont MH con placa CEA15, falla en puerta 1."
    service = BedrockRagService.new(account: accounts(:legacy))

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      applied = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[MH CEA15]))
      off = service.send(
        :document_identity_generation_prompt, question, chunks,
        response_locale: :es, session_context: nil, output_channel: :web
      )
      prompt = service.send(
        :document_identity_generation_prompt, question, applied.chunks, labels: applied.labels,
        response_locale: :es, session_context: nil, output_channel: :web
      )

      assert_equal 8, applied.chunks.size
      assert_equal bodies, applied.chunks.map { |item| item[:content] }
      assert_equal 3, applied.labels.count { |line| line.to_s.start_with?("OTHER EQUIPMENT:") }
      assert_equal 5, applied.labels.count { |line| line.to_s.start_with?("THIS JOB'S EQUIPMENT:") }
      assert_equal 8, prompt.scan("<source>").size
      assert_equal off, strip_labels(prompt, applied.labels)
      bodies.each { |body| assert_includes prompt, body }
      POISON.each { |token| assert_includes prompt, token }
      positions = bodies.map { |body| prompt.index(body) }
      assert_equal positions, positions.compact.sort
    end
  end

  test "scope on retrieves the same result count and a technical failure uses retrieve_and_generate" do
    catalog = catalog_for(entry("mono", brands: [ "Monarch" ], role: "equipment"))
    question = "pregunta"
    retrieved = { chunks: [ chunk("mono", "Cortocircuitar BM/B1.") ], retrieval_trace: { "ok" => true } }
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
      Rag::DocumentIdentityCatalog.with_catalog(catalog) do
        result = service.query(question, episode: episode(identifiers: %w[CEA15]), output_channel: :web)
        assert_includes result[:answer], "Respuesta del camino de hoy."
      end
    end

    assert_equal 1, rag_calls
    assert_equal RagRetrievalProfile.new(entity_sources: [], question: question).number_of_results, seen[:number_of_results]
    assert_equal 8, seen[:number_of_results]
    assert_equal true, Thread.current[:document_identity_scope]["fallback"]
    assert_equal "retrieve_and_generate", Thread.current[:document_identity_scope]["path"]
  end

  test "a blank generation falls back to retrieve_and_generate" do
    catalog = catalog_for(entry("mono", brands: [ "Monarch" ], role: "equipment"))
    question = "pregunta"
    retrieved = { chunks: [ chunk("mono", "Cortocircuitar BM/B1.") ], retrieval_trace: { "ok" => true } }
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
      Rag::DocumentIdentityCatalog.with_catalog(catalog) do
        result = service.query(question, episode: episode(identifiers: %w[CEA15]), output_channel: :web)
        assert_includes result[:answer], "Respuesta del camino de hoy."
      end
    end

    assert_equal 1, rag_calls
    assert_equal true, Thread.current[:document_identity_scope]["fallback"]
  end

  test "scope off leaves the retrieve_and_generate prompt and an unchanged catalog does not generate" do
    question = "pregunta"
    chunks = [ chunk("cea", CEA15_BODY) ]
    service = BedrockRagService.new(account: accounts(:legacy))
    service.define_singleton_method(:retrieve_chunks) { flunk "retrieve_chunks" }
    profile = RagRetrievalProfile.new(entity_sources: [], question: question)
    from_query = service.send(
      :enforce_query_contractual_limits,
      service.build_complete_optimized_config(question: question, entity_s3_uris: [], entity_sources: [])
    )
    from_retrieve = service.build_vector_search_configuration(
      question: question,
      entity_s3_uris: [],
      entity_sources: [],
      number_of_results: profile.number_of_results.clamp(1, ContractualLimits::QUERY[:max_top_k])
    )

    assert_equal from_query.dig(:retrieval_configuration, :vector_search_configuration), from_retrieve

    with_flag(nil) do
      assert_nil service.send(
        :document_identity_scope_result,
        question,
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

    with_flag("true") do
      Rag::DocumentIdentityCatalog.with_catalog(catalog_for(entry("cea", brands: [ "Monarch" ], role: nil))) do
        service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: chunks, retrieval_trace: {} } }
        service.define_singleton_method(:document_identity_generator) { flunk "generator" }
        assert_nil service.send(
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
    end

    assert_equal 0, Thread.current[:document_identity_scope]["labels"]
    assert_equal "retrieve_and_generate", Thread.current[:document_identity_scope]["path"]
  end

  private

  def other_line(name, job: "Elemont MH CEA15")
    "OTHER EQUIPMENT: #{name}. This job: #{job}. #{Rag::DocumentIdentityScope::OTHER_EQUIPMENT_RULE}"
  end

  def strip_labels(prompt, labels)
    labels.reduce(prompt) { |text, label| label.present? ? text.sub("#{label}\n", "") : text }
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

  def catalog_for(*entries)
    Rag::DocumentIdentityCatalog.new({ "documents" => entries })
  end

  def entry(document_id, brands: [], designators: [], generic: false, confirmed: true, role: "equipment",
            evidence_page: 1, evidence_text: "marca impresa")
    {
      "account_id" => "1",
      "document_id" => document_id,
      "s3_key" => "bulk_uploads/1/#{document_id}.pdf",
      "display_name" => document_id,
      "brands" => brands,
      "designators" => designators,
      "generic" => generic,
      "confirmed" => confirmed,
      "role" => role,
      "evidence_page" => confirmed ? evidence_page : nil,
      "evidence_text" => confirmed ? evidence_text : nil
    }
  end

  def chunk(document_id, content, account_id: "1", canonical_name: document_id, page: 1,
            section_identity: nil, heading: nil)
    body = heading.present? ? "#{heading}\n#{content}" : content
    metadata = {
      "account_id" => account_id,
      "document_id" => document_id,
      "canonical_name" => canonical_name,
      "page_number" => page
    }
    metadata["section_identity"] = section_identity if section_identity
    {
      rank: 1,
      content: body,
      metadata: metadata,
      chunk_sha256: Digest::SHA256.hexdigest(body)
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
