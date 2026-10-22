# frozen_string_literal: true

require "test_helper"

class Rag::CompanionAssemblyTest < ActiveSupport::TestCase
  T1 = "query:t1"
  T2 = "query:t2"
  T3 = "query:t3"
  T1_TEXT = "Estoy con un operador de puerta Fermator VF5+. La puerta se reabre sola. El LED de fotocélula está apagado. No veo obstrucción. No he comprobado el #54. No hice mediciones."
  T2_TEXT = "Corrijo solo el estado del LED: el LED de fotocélula está encendido, no apagado."
  T3_TEXT = "Ya revisé la fotocélula y no está activada."
  CURRENT = "¿qué sigue?"
  SYSTEM_SHA = "83c457e98134bc388ba172ef70476216ab2190662079adce91088a5dfa50679e"
  URI = "s3://example/manual.pdf"

  test "the companion system file stays the reference prompt" do
    path = Rails.root.join("app/prompts/bedrock/companion_turn.txt")
    assert_equal SYSTEM_SHA, Digest::SHA256.file(path).hexdigest
  end

  test "t4 keeps the first turn, the led correction, and the literal photocell result" do
    now = Time.current
    episode = reabre_episode(now)
    before = JSON.generate(episode.to_h)
    session = session_for(episode, now)

    text = travel_to(now) { SessionContextBuilder.companion_context(session, current_message: CURRENT) }
    turns = text[/Turnos del técnico.*\z/m]
    history = travel_to(now) { session.episode_prompt_history.select { |turn| turn[:role] == "user" } }

    assert_equal before, JSON.generate(episode.to_h)
    assert_equal 3, history.size
    assert_not_includes history.pluck(:content), T1_TEXT
    assert_includes text, "Objetivo: La puerta se reabre sola"
    assert_includes text, "Fermator"
    assert_includes text, "No veo obstrucción"
    assert_includes text, "el LED de fotocélula está encendido"
    assert_includes text, "texto original del mensaje: «Ya revisé la fotocélula y no está activada.»"
    assert_includes text, "resultado: «no está activada»"
    assert_includes text, "texto original del mensaje: «No he comprobado el #54.»"
    assert_includes text, "texto original del mensaje: «No hice mediciones.»"
    assert_includes text, "no es una tarea prescrita"
    assert_not_includes text, "sin hacer"
    assert_includes turns, T1_TEXT
    assert_includes turns, T2_TEXT
    assert_includes turns, T3_TEXT
    assert_not_includes turns, CURRENT
    assert_operator turns.index(T1_TEXT), :<, turns.index(T2_TEXT)
    assert_operator turns.index(T2_TEXT), :<, turns.index(T3_TEXT)
  end

  test "a stored cut is not presented as the whole technician message" do
    now = Time.current
    episode = reabre_episode(now)
    stored = "#{"detalle " * 80}no sigue".truncate(ConversationSession::MAX_MSG_LENGTH)
    assert_equal ConversationSession::MAX_MSG_LENGTH, stored.length
    session = session_for(episode, now, extra: [
      { "role" => "user", "content" => stored, "correlation_id" => "query:cut", "ts" => (now - 30.seconds).iso8601 }
    ])

    text = travel_to(now) { SessionContextBuilder.companion_context(session, current_message: CURRENT) }

    assert_includes text, "texto almacenado truncado, no es el mensaje íntegro"
    assert_includes text, stored
    assert_not_includes text, "texto original del mensaje: «#{stored}"
  end

  test "a turn that does not fit is omitted whole and a negation is kept" do
    now = Time.current
    episode = reabre_episode(now)
    long = "detalle del tablero " * 40
    session = session_for(episode, now, extra: [
      { "role" => "user", "content" => long, "correlation_id" => "query:long", "ts" => (now - 4.minutes).iso8601 }
    ])

    text = travel_to(now) do
      with_turn_budget(900) { SessionContextBuilder.companion_context(session, current_message: CURRENT) }
    end

    assert_includes text, "No hice mediciones."
    assert_includes text, "Omitido por presupuesto, sin recortar: correlación query:long, #{long.length} caracteres."
    assert_not_includes text, "detalle del tablero detalle"
  end

  test "the default history still keeps three user messages and cuts the assistant at 200" do
    now = Time.current
    episode = reabre_episode(now)
    session = session_for(episode, now)
    session.conversation_history << {
      "role" => "assistant", "content" => "x" * 400, "ts" => (now - 20.seconds).iso8601
    }
    session.save!

    travel_to(now) do
      history = session.episode_prompt_history
      users = history.select { |turn| turn[:role] == "user" }
      assistant = history.find { |turn| turn[:role] == "assistant" }
      context = SessionContextBuilder.build(session)
      shown = context[/Assistant: .*/]

      assert_equal 3, users.size
      assert_not_includes users.pluck(:content), T1_TEXT
      assert_equal 400, assistant[:content].length
      assert_operator shown.delete_prefix("Assistant: ").length, :<=, 200
      assert_not_includes context, "x" * 201
    end
  end

  test "an unambiguous definition is added once with its page and is citable" do
    chunk = mention_chunk("Revisar la válvula de caudal (#7). El paso sigue cerrado.")
    catalog = catalog_with("4.2 Válvula (7)\nLa válvula de caudal regula el paso del fluido.\n")
    result = Rag::CompanionDefinitionExpander.expand([ chunk ], catalog: catalog)
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "kb-test")
    sources = service.send(:companion_publication_sources, result.chunks)
    block = service.send(:companion_source_block, result.chunks)

    assert_equal 2, result.chunks.size
    assert_equal [ "#7" ], result.added.pluck("definition_of")
    assert_equal "4", result.chunks.last[:metadata]["page_number"]
    assert_equal "4.2", result.chunks.last[:metadata]["section"]
    assert_includes result.chunks.last[:content], "La válvula de caudal regula el paso del fluido."
    assert_equal result.chunks.last[:content], sources.last["content"]
    assert_equal 2, sources.last["index"]
    assert_includes block, "[2] Documento: Manual de válvulas. Página: 4. Sección: 4.2."
    assert_includes block, "definición de #7"
    assert_equal "compatible", sources.last["applicability"]
  end

  test "a bracketed keyword line does not confirm a definition" do
    chunk = mention_chunk("[SEARCH_ALIASES: paso libre, entrada OPEN (#7)]\nEl paso sigue cerrado.")
    catalog = catalog_with("4.2 Válvula (7)\nLa válvula usa un contacto libre de tensión.\n")
    result = Rag::CompanionDefinitionExpander.expand([ chunk ], catalog: catalog)

    assert_empty result.added
    assert_empty result.omitted
  end

  test "a numeric heading without a shared distinctive word is not added" do
    chunk = mention_chunk("Revisar la válvula de caudal (#7).")
    catalog = catalog_with("4.2 Pieza (7)\nIndice general del documento sin ese termino.\n")
    result = Rag::CompanionDefinitionExpander.expand([ chunk ], catalog: catalog)

    assert_equal 1, result.chunks.size
    assert_equal "no_match", result.omitted.first["reason"]
  end

  test "two defining sections for one identifier are not added" do
    chunk = mention_chunk("Revisar la válvula de caudal (#7).")
    text = <<~TEXT
      4.2 Válvula (7)
      La válvula de caudal regula el paso.

      4.3 Otra válvula (7)
      La válvula de caudal también aparece aquí.
    TEXT
    result = Rag::CompanionDefinitionExpander.expand([ chunk ], catalog: catalog_with(text))

    assert_equal 1, result.chunks.size
    assert_equal "ambiguous", result.omitted.first["reason"]
    assert_not_includes result.chunks.first[:content], "también aparece"
  end

  test "a definition already present is not repeated and expansion does not recurse" do
    present = "4.2 Válvula (7)\nLa válvula de caudal regula el paso del fluido.\n"
    repeated = Rag::CompanionDefinitionExpander.expand(
      [ mention_chunk("Revisar la válvula de caudal (#7). #{present}") ],
      catalog: catalog_with(present)
    )
    nested = "4.2 Válvula (7)\nLa válvula de caudal regula el paso del fluido y usa el borne (#8).\n"
    result = Rag::CompanionDefinitionExpander.expand(
      [ mention_chunk("Revisar la válvula de caudal (#7).") ],
      catalog: Rag::CompanionDefinitionCatalog.from_pages([
        page(nested),
        page("8.1 Borne (8)\nEl borne de la válvula alimenta el circuito.\n", page: 5)
      ])
    )

    assert_empty repeated.added
    assert_equal [ "#7" ], result.added.pluck("definition_of")
    assert_equal 2, result.chunks.size
    assert_not_includes result.chunks.last[:content], "alimenta el circuito"
  end

  test "a list heading and another component name do not add a guessed section" do
    chunk = mention_chunk("La fotocélula no responde. Revisar la válvula de caudal (#7).")
    text = <<~TEXT
      4.1 Grupo (7, 8)
      El grupo reúne varias entradas.

      7.- Válvula
      La válvula de caudal regula el paso del fluido.

      8.3 Fotocélula
      Desconectar la fotocélula y repetir la prueba.
    TEXT
    result = Rag::CompanionDefinitionExpander.expand([ chunk ], catalog: catalog_with(text))

    assert_equal 2, result.chunks.size
    assert_equal "7.- Válvula", result.added.first["heading"]
    assert_includes result.chunks.last[:content], "4.1 Grupo (7, 8)"
    assert_includes result.chunks.last[:content], "La válvula de caudal regula el paso del fluido."
    assert_not_includes result.chunks.last[:content], "Desconectar la fotocélula"
    assert_not_includes result.chunks.pluck(:content).join, "8.3 Fotocélula"
  end

  test "a section that does not fit is omitted whole" do
    chunk = mention_chunk("Revisar la válvula de caudal (#7).")
    body = "La válvula de caudal regula el paso. #{"dato adicional " * 400}"
    catalog = catalog_with("4.2 Válvula (7)\n#{body}\n")
    previous = Rag::CompanionDefinitionExpander::MAX_ADDED_CHARS
    Rag::CompanionDefinitionExpander.send(:remove_const, :MAX_ADDED_CHARS)
    Rag::CompanionDefinitionExpander.const_set(:MAX_ADDED_CHARS, 80)
    result = Rag::CompanionDefinitionExpander.expand([ chunk ], catalog: catalog)

    assert_equal 1, result.chunks.size
    assert_equal "budget", result.omitted.first["reason"]
    assert_not_includes result.chunks.first[:content], "dato adicional dato"
  ensure
    Rag::CompanionDefinitionExpander.send(:remove_const, :MAX_ADDED_CHARS)
    Rag::CompanionDefinitionExpander.const_set(:MAX_ADDED_CHARS, previous)
  end

  test "a different document and a missing catalog do not expand" do
    chunk = mention_chunk("Revisar la válvula de caudal (#7).")
    foreign = Rag::CompanionDefinitionCatalog.from_pages([
      page("4.2 Válvula (7)\nLa válvula de caudal regula el paso del fluido.\n", key: "s3://other/manual.pdf")
    ])
    foreign_result = Rag::CompanionDefinitionExpander.expand([ chunk ], catalog: foreign)
    absent = Rag::CompanionDefinitionExpander.expand([ chunk ], catalog: nil)

    assert_equal 1, foreign_result.chunks.size
    assert_equal [ chunk ], absent.chunks
  end

  test "certified bodies add the two definitions and keep the original four" do
    root = Rails.root.join("tmp/field_companion/vf5_correction")
    bodies = root.join("ingest/bodies")
    chunks = root.join("f3/chunks")
    skip "cuerpos locales ausentes" unless bodies.join("p08.txt").exist? && chunks.join("p12-p13-reabre.txt").exist?

    catalog = Rag::CompanionDefinitionCatalog.from_pages(certified_pages(bodies))
    selected = certified_chunks(chunks)
    result = Rag::CompanionDefinitionExpander.expand(selected, catalog: catalog)
    headings = result.added.pluck("heading")
    joined = result.chunks.drop(4).pluck(:content).join("\n")

    assert_equal 4, selected.size
    assert_equal selected.pluck(:content), result.chunks.first(4).pluck(:content)
    assert_includes headings, "21.- Re-apertura"
    assert_includes headings, "5.11 Seguridad (54)"
    assert_equal "7", result.chunks.find { |chunk| chunk.dig(:metadata, "definition_of") == "#21" }[:metadata]["page_number"]
    assert_equal "5.5", result.chunks.find { |chunk| chunk.dig(:metadata, "definition_of") == "#21" }[:metadata]["section"]
    assert_equal "8", result.chunks.find { |chunk| chunk.dig(:metadata, "definition_of") == "#54" }[:metadata]["page_number"]
    assert_equal "5.11", result.chunks.find { |chunk| chunk.dig(:metadata, "definition_of") == "#54" }[:metadata]["section"]
    assert_includes joined, "Potenciómetro que permite ajustar la fuerza de cierre de la puerta"
    assert_includes joined, "21.- Re-apertura"
    assert_not_includes joined, "8.3 Fotocélula"
    assert_not_includes joined, "Poner potenciómetros al mínimo"
    assert_not_includes joined, "300N"
  end

  test "companion generation adds the definition and the opt-in off does not" do
    episode = known_episode
    session = session_for_generation(episode)
    catalog = catalog_with("4.2 Válvula (7)\nLa válvula de caudal regula el paso del fluido.\n")
    on_calls = []
    off_calls = []

    with_scope do
      Rag::CompanionDefinitionCatalog.with(catalog) do
        with_companion do
          ask(episode, session, calls: on_calls, content: "#{PHOTOCELL}\nRevisar la válvula de caudal (#7).")
        end
        without_companion do
          ask(episode, session, calls: off_calls, content: "#{PHOTOCELL}\nRevisar la válvula de caudal (#7).")
        end
      end
    end

    assert_includes on_calls.first[:user], "La válvula de caudal regula el paso del fluido."
    assert_includes on_calls.first[:user], "Sección: 4.2."
    assert_includes on_calls.first[:system], "una sola respuesta integrada"
    assert_not_includes off_calls.first[:user], "La válvula de caudal regula el paso del fluido."
    assert_not_includes off_calls.first[:user], "Mensaje del técnico:"
  end

  private

  PHOTOCELL = "Indicador LED y relé activado cuando la fotocélula o la entrada de re-apertura está activada."

  def reabre_episode(now)
    episode = Rag::ActiveEpisode.open(correlation_id: T1, now: now)
    episode.assign_goal!("La puerta se reabre sola", correlation_id: T1)
    episode.write_fact!(
      "manufacturer", status: "known", value: "Fermator", source: "user",
      correlation_id: T1, at: now.iso8601
    )
    episode.append_observation!("No veo obstrucción", correlation_id: T1)
    episode.append_observation!("el LED de fotocélula está encendido", correlation_id: T2)
    episode.upsert_check!({ "subject" => "#54", "status" => "not_done" }, correlation_id: T1)
    episode.upsert_check!({ "subject" => "mediciones", "status" => "not_done" }, correlation_id: T1)
    episode.upsert_check!(
      { "subject" => "fotocélula", "status" => "done", "result" => "no está activada" },
      correlation_id: T3
    )
    episode
  end

  def session_for(episode, now, extra: [])
    ConversationSession.create!(
      identifier: "web:assembly-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy),
      active_episode: episode.to_h.merge("opened_at" => (now - 10.minutes).iso8601, "updated_at" => now.iso8601),
      conversation_history: [
        user_turn(T1_TEXT, T1, now - 5.minutes),
        user_turn(T2_TEXT, T2, now - 4.minutes),
        user_turn(T3_TEXT, T3, now - 3.minutes),
        user_turn(CURRENT, "query:t4", now - 1.minute),
        *extra
      ]
    )
  end

  def user_turn(content, correlation_id, time)
    {
      "role" => "user",
      "content" => content,
      "correlation_id" => correlation_id,
      "ts" => time.iso8601,
      "text_provenance" => "captura-local #{correlation_id}"
    }
  end

  def mention_chunk(content)
    {
      content: content,
      metadata: {
        "canonical_name" => "Manual de válvulas",
        "original_filename" => "valvulas.pdf",
        "document_id" => "doc-valvula",
        "original_source_uri" => URI,
        "page_number" => "2"
      },
      identity_applicability: "compatible"
    }
  end

  def catalog_with(text)
    Rag::CompanionDefinitionCatalog.from_pages([ page(text) ])
  end

  def page(text, page: 4, key: URI)
    {
      "document_key" => key,
      "page" => page,
      "name" => "Manual de válvulas",
      "filename" => "valvulas.pdf",
      "provenance" => "fixture página #{page}",
      "text" => text
    }
  end

  def certified_pages(dir)
    Dir.children(dir).grep(/\Ap\d+\.txt\z/).sort_by { |name| name[/\d+/].to_i }.map { |name|
      {
        "document_key" => "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf",
        "page" => name[/\d+/].to_i,
        "name" => "Módulo electrónico VF5+ Fermator",
        "filename" => "VF5.pdf",
        "provenance" => "cuerpo certificado F2 ingest/bodies/#{name}",
        "text" => dir.join(name).read
      }
    }
  end

  def certified_chunks(dir)
    %w[p5-sw4 p12-abre-no-cierra p12-p13-reabre p7-5-6].map { |id|
      {
        content: dir.join("#{id}.txt").read,
        metadata: {
          "canonical_name" => "Módulo electrónico VF5+ Fermator",
          "original_filename" => "VF5.pdf",
          "original_source_uri" => "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf",
          "page_number" => id == "p7-5-6" ? "7" : (id.start_with?("p5") ? "5" : "12")
        },
        identity_applicability: "compatible"
      }
    }
  end

  def known_episode
    now = Time.current
    episode = Rag::ActiveEpisode.open(correlation_id: "case", now: now)
    episode.assign_goal!("La puerta se reabre sola", correlation_id: "case")
    episode.write_fact!(
      "manufacturer", status: "known", value: "Fermator", source: "user",
      correlation_id: "case", at: now.iso8601
    )
    episode
  end

  def session_for_generation(episode)
    ConversationSession.create!(
      identifier: "web:assembly-gen-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy),
      active_episode: episode.to_h
    )
  end

  def ask(episode, session, calls:, content:)
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "kb-test")
    retrieved = chunk_for(content)
    service.define_singleton_method(:retrieve_chunks) do |*, **|
      { chunks: [ retrieved ], retrieval_trace: {}, retrieval: "retrieve" }
    end
    generator = Object.new
    generator.define_singleton_method(:query) do |user, system: nil, max_tokens: nil, temperature: nil, **|
      calls << { user: user, system: system, max_tokens: max_tokens, temperature: temperature }
      "El cierre puede quedar pendiente [1]."
    end
    generator.define_singleton_method(:last_stop_reason) { "end_turn" }
    service.define_singleton_method(:document_identity_generator) { generator }
    service.send(
      :document_identity_scope_result,
      "COMPUESTA",
      episode: episode,
      response_locale: :es,
      entity_s3_uris: [],
      entity_sources: [],
      force_entity_filter: false,
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conversation_session_id: session.id,
      correlation_id: "query:assembly",
      raw_question: CURRENT,
      conv_session: session
    )
  end

  def chunk_for(content)
    {
      rank: 1,
      content: content,
      metadata: {
        "account_id" => accounts(:legacy).id.to_s,
        "document_id" => "vf5",
        "canonical_name" => "Manual Fermator",
        "original_source_uri" => URI,
        "page_number" => "7"
      },
      chunk_sha256: Digest::SHA256.hexdigest(content)
    }
  end

  def with_scope
    previous = {
      "DOCUMENT_IDENTITY_SCOPE_ENABLED" => ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"],
      "RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE" => ENV["RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"]
    }
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV.delete("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE")
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_companion
    previous = ENV["RAG_COMPANION_TURN"]
    ENV["RAG_COMPANION_TURN"] = "1"
    yield
  ensure
    previous.nil? ? ENV.delete("RAG_COMPANION_TURN") : ENV["RAG_COMPANION_TURN"] = previous
  end

  def with_turn_budget(amount)
    original = SessionContextBuilder.method(:companion_turn_budget)
    SessionContextBuilder.define_singleton_method(:companion_turn_budget) { amount }
    yield
  ensure
    SessionContextBuilder.define_singleton_method(:companion_turn_budget, original)
  end

  def without_companion
    previous = ENV["RAG_COMPANION_TURN"]
    ENV.delete("RAG_COMPANION_TURN")
    yield
  ensure
    previous.nil? ? ENV.delete("RAG_COMPANION_TURN") : ENV["RAG_COMPANION_TURN"] = previous
  end
end
