# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Functional composition of the field-companion path. Providers are fakes.
# No browser, no AWS, no Vision, no Bedrock.
class Rag::FieldCompanionPilotReadinessTest < ActiveJob::TestCase
  include ActionCable::TestHelper
  parallelize(workers: 1)

  T1 = "Ahora estoy revisando otro ascensor. No nivela en planta 3. Todavía no sé fabricante ni modelo."
  T2 = "tengo una foto, te sirve?"
  T4 = "la consulta anterior, de eso estoy hablando y por eso te compartí la foto"
  SAME_TURN = "Esta placa es la del ascensor que no nivela en planta 3, ¿qué revisarías primero?"
  PHOTO_OFFER = "¿te sirve si te mando otra foto?"
  LEVELING = "no nivela en planta 3"
  YIDA_PROCEDURE = "Paso 11. Ajusta el interruptor de zona de nivelación Yida a 2,5 mm."
  BLT_PROCEDURE = "E18 fallo de nivelación. Compruebe el encoder BLT."
  KONE_PROCEDURE = "Procedimiento KONE de nivelación. Ajusta el encoder KONE."
  ORONA_PROCEDURE = "En PBCM-V3 revisar el sensor de nivelación de la placa Orona"
  REUSE_TURN = "la consulta anterior, de eso estoy hablando y por eso te compartí la foto"
  PASSED_LEVEL = "queda un poco pasada de nivel"
  FLOOR_ONLY = "pasa solo en planta 3"
  NEW_EQUIPMENT = "Ahora estoy en otro equipo. El variador no arranca."
  MONARCH_PROCEDURE = "Monarch: ajuste de nivelación del variador en el parámetro F07."
  SAFE_GUIDANCE = <<~ANSWER.strip
    En la foto se identifica Orona PBCM-V3.
    No tengo un manual compatible para darte un procedimiento del fabricante.
    Para acotar la nivelación quiero separar si la cabina queda pasada o corta de nivel, o si no llega a hacer la parada.
    ¿Qué hace la cabina al llegar a planta 3?
  ANSWER
  GUIDANCE_ANSWER = <<~ANSWER.strip
    En la foto se identifica Orona PBCM-V3.
    No tengo un manual compatible para darte un procedimiento del fabricante.
    Para acotar la nivelación quiero separar si la cabina queda pasada o corta de nivel, o si no llega a hacer la parada.
    ¿Qué hace la cabina al llegar a planta 3?
    Ajusta el terminal BM/B1 a 2,5 mm.
    X17 es la entrada de nivelación.
  ANSWER

  class FakeS3
    def upload_binary(_key, _data, _content_type)
      "uploaded"
    end

    def download(_key)
      "jpeg"
    end
  end

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @orig_s3 = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { FakeS3.new }
    @user = users(:one)
    @account = accounts(:legacy)
  end

  teardown do
    Rails.cache = @previous_cache
    orig = @orig_s3
    S3DocumentsService.define_singleton_method(:new) { |*args, **kwargs| orig.call(*args, **kwargs) }
  end

  test "F1 orona replay keeps the leveling problem and does not teach a foreign procedure" do
    session = web_session
    vision = { n: 0 }
    probe = empty_probe
    answer = nil

    with_pilot_flags do
      with_vision(orona_reading, vision) do
        with_retrieval_probe(probe, chunks: [ yida_chunk, blt_chunk ], answer: GUIDANCE_ANSWER) do
          ask(session, T1, client(report_observation("No nivela en planta 3")))
          episode_id = session.reload.live_episode_id
          assert_match(/no nivela en planta 3/i, goal_text(session))

          ask(session, T2, client(meta_turn))
          session.reload
          assert_equal episode_id, session.live_episode_id
          assert_match(/no nivela en planta 3/i, goal_text(session))
          assert_no_match(/tengo una foto/i, goal_text(session))

          run_photo(session, question: "", image: jpeg_image("plate-1"))
          assert_equal 1, vision[:n]
          episode = session.reload.active_episode
          assert_equal "Orona", episode.dig("facts", "manufacturer", "value")
          assert_equal "photo", episode.dig("facts", "manufacturer", "source")
          assert_equal "PBCM-V3", episode.dig("facts", "model", "value")

          interpreter = { n: 0 }
          ask(session, T4, client(follow_up))
          session.reload
          assert_equal episode_id, session.live_episode_id
          assert_match(/no nivela en planta 3/i, goal_text(session))
          counting_interpreter(interpreter) do
            answer = run_photo(session, question: T4, image: nil)
          end

          assert_equal 1, vision[:n]
          assert_equal 0, interpreter[:n]
        end
      end
    end

    assert_orona_guidance(answer, probe)
    assert_equal 0, probe[:open_calls]
    assert_equal "Orona", session.reload.active_episode.dig("facts", "manufacturer", "value")
    assert_equal "PBCM-V3", session.active_episode.dig("facts", "model", "value")
  end

  test "reused photo identity is durable before the next text turns and a new job starts clean" do
    session = web_session
    vision = { n: 0 }
    probe = empty_probe
    episode_id = nil
    passed = nil
    floor = nil

    with_pilot_flags do
      with_vision(orona_reading_unconfirmed, vision) do
        with_retrieval_probe(probe, chunks: [ yida_chunk, blt_chunk, monarch_chunk ], answer: SAFE_GUIDANCE) do
          ask(session, "No nivela en planta 3. Todavía no sé fabricante ni modelo.", client(report_observation(LEVELING)))
          episode_id = session.reload.live_episode_id
          assert_match(/no nivela en planta 3/i, goal_text(session))
          assert_nil session.active_episode.dig("facts", "manufacturer")

          run_photo(session, question: "", image: jpeg_image("plate-unconfirmed"))
          session.reload
          assert_equal episode_id, session.live_episode_id
          assert_equal 1, vision[:n]
          assert_nil session.active_episode.dig("facts", "manufacturer")
          assert_nil session.active_episode.dig("facts", "model")
          assert session.active_episode.dig("active_photo", "field_photo_id")

          run_photo(session, question: REUSE_TURN, image: nil)
          session.reload
          assert_equal episode_id, session.live_episode_id
          assert_equal 1, vision[:n]
          assert_equal "Orona", session.active_episode.dig("facts", "manufacturer", "value")
          assert_equal "photo", session.active_episode.dig("facts", "manufacturer", "source")
          assert_equal "PBCM-V3", session.active_episode.dig("facts", "model", "value")
          assert_equal "photo", session.active_episode.dig("facts", "model", "source")
          assert_match(/no nivela en planta 3/i, goal_text(session))
          assert Rag::EquipmentIdentity.from_episode(session.active_episode).known?
          assert_equal 0, probe[:open_calls]

          passed = retrieve_text(session, PASSED_LEVEL, client(follow_up_observation(PASSED_LEVEL)))
          session.reload
          assert_equal episode_id, session.live_episode_id
          assert_equal "Orona", session.active_episode.dig("facts", "manufacturer", "value")
          assert Rag::EquipmentIdentity.from_episode(session.active_episode).known?
          assert_scoped_guidance(session, probe[:scopes].last, passed, probe[:prompts].last)

          floor = retrieve_text(session, FLOOR_ONLY, client(follow_up_observation(FLOOR_ONLY)))
          session.reload
          assert_equal episode_id, session.live_episode_id
          assert_match(/no nivela en planta 3/i, goal_text(session))
          assert Rag::EquipmentIdentity.from_episode(session.active_episode).known?
          assert_scoped_guidance(session, probe[:scopes].last, floor, probe[:prompts].last)
          assert_equal 0, probe[:open_calls]
          assert_equal 1, vision[:n]

          opened = ask(session, NEW_EQUIPMENT, client(new_work_observation("el variador no arranca")))
          session.reload
          assert_equal :new_episode, opened.decision
          assert_not_equal episode_id, session.live_episode_id
        end
      end
    end

    fresh = session.reload.active_episode
    blob = fresh.to_json
    assert_no_match(/orona/i, blob)
    assert_no_match(/pbcm/i, blob)
    assert_no_match(/planta 3/i, blob)
    assert_no_match(/nivel/i, blob)
    assert_nil fresh["active_photo"]
    assert_nil fresh.dig("facts", "manufacturer")
    assert_nil fresh.dig("facts", "model")
    assert_nil Rag::EquipmentIdentity.from_episode(fresh)
    assert_match(/variador no arranca/i, goal_text(session))
  end

  test "a later text turn does not promote an unconfirmed photo" do
    session = web_session
    vision = { n: 0 }

    with_pilot_flags do
      with_vision(orona_reading_unconfirmed, vision) do
        ask(session, "No nivela en planta 3. Todavía no sé fabricante ni modelo.", client(report_observation(LEVELING)))
        run_photo(session, question: "", image: jpeg_image("unconfirmed"))
        ask(session, "el desnivel es de unos centimetros", client(follow_up_observation("el desnivel es de unos centimetros")))
        episode = session.reload.active_episode
        assert_equal 1, vision[:n]
        assert_nil episode.dig("facts", "manufacturer")
        assert_nil episode.dig("facts", "model")
        assert_nil Rag::EquipmentIdentity.from_episode(episode)
        assert_not Rag::DocumentIdentityScope.applicable?(episode)
      end
    end
  end

  test "F2 same-turn photo keeps the problem and guides when no manual is compatible" do
    session = web_session
    vision = { n: 0 }
    probe = empty_probe
    interpreter = { n: 0 }
    answer = nil

    with_pilot_flags do
      ask(session, SAME_TURN, client(report_observation(LEVELING)))
      with_vision(orona_reading, vision) do
        with_retrieval_probe(probe, chunks: [ yida_chunk, blt_chunk ], answer: GUIDANCE_ANSWER) do
          counting_interpreter(interpreter) do
            answer = run_photo(session, question: SAME_TURN, image: jpeg_image("same-turn"))
          end
        end
      end
    end

    assert_equal 1, vision[:n]
    assert_equal 0, interpreter[:n]
    assert_match(/no nivela en planta 3/i, goal_text(session))
    scope = probe[:scopes].last
    assert scope
    assert_includes scope_values(scope[:identity]), "Orona"
    assert_includes scope_values(scope[:identity]), "PBCM-V3"
    assert_equal :no_compatible, scope_status(scope)
    assert_orona_guidance(answer, probe)
    assert_equal 0, probe[:open_calls]
  end

  test "F2 and F4 a same-turn compatible manual stays scoped and citable" do
    session = web_session
    vision = { n: 0 }
    probe = empty_probe
    answer = nil
    body = "#{ORONA_PROCEDURE} [1]."

    with_pilot_flags do
      ask(session, SAME_TURN, client(report_observation(LEVELING)))
      with_vision(orona_reading, vision) do
        with_retrieval_probe(probe, chunks: [ orona_chunk, yida_chunk ], answer: body) do
          answer = run_photo(session, question: SAME_TURN, image: jpeg_image("compatible"))
        end
      end
    end

    assert_equal 1, vision[:n]
    scope = probe[:scopes].last
    assert_equal :scoped, scope_status(scope)
    assert_equal "compatible", scope[:result].applicability[0]
    assert_includes scope[:result].chunks[0][:content], ORONA_PROCEDURE
    assert_not_includes scope[:result].chunks[1][:content], YIDA_PROCEDURE
    assert probe[:prompts].none? { |text| text.include?("# FIELD COMPANION") }
    assert_includes answer[:answer], ORONA_PROCEDURE
    assert_not_includes answer[:answer], YIDA_PROCEDURE
    assert_not_includes answer[:answer], BLT_PROCEDURE
    bands = answer[:segments].pluck("band")
    assert_includes bands, "MANUAL_FACT"
    cited = answer[:citations].map { |item| JSON.generate(item.as_json) }.join
    assert_includes cited, "Orona"
    assert_not_includes cited, "Yida"
    assert_equal 0, probe[:open_calls]
  end

  test "F3 an offer of another photo does not replace the active problem" do
    session = web_session
    with_pilot_flags do
      ask(session, T1, client(report_observation("No nivela en planta 3")))
      before = goal_text(session)
      episode_id = session.reload.live_episode_id
      result = ask(session, PHOTO_OFFER, client(meta_turn))
      session.reload

      assert_equal before, goal_text(session)
      assert_match(/no nivela en planta 3/i, goal_text(session))
      assert_equal episode_id, session.live_episode_id
      assert_equal "meta", result.understanding.decision
      assert_not_equal :new_episode, result.decision
      assert_no_match(/foto/i, goal_text(session))
    end
  end

  test "a technical report stays technical and real new work still opens a case" do
    session = web_session
    with_pilot_flags do
      report = ask(session, "la puerta no cierra", client(report_observation("la puerta no cierra")))
      assert_equal "ready", report.understanding.decision
      assert_match(/la puerta no cierra/i, goal_text(session))
      episode_id = session.reload.live_episode_id

      opened = ask(
        session,
        "Ahora el variador no arranca en otro equipo",
        client(new_work_observation("el variador no arranca"))
      )
      session.reload
      assert_equal :new_episode, opened.decision
      assert_not_equal episode_id, session.live_episode_id
      assert_match(/variador no arranca/i, goal_text(session))
      assert_no_match(/puerta no cierra/i, goal_text(session))
    end
  end

  test "F5 unknown identity stays on the open retrieval path" do
    session = web_session
    with_pilot_flags do
      ask(session, T1, client(report_observation("No nivela en planta 3")))
    end
    episode = session.reload.active_episode
    identity = Rag::EquipmentIdentity.from_episode(episode)
    assert_nil identity
    assert_not Rag::DocumentIdentityScope.applicable?(episode)

    calls = 0
    result = nil
    with_pilot_flags do
      service = BedrockRagService.new(account: @account, knowledge_base_id: "test-kb")
      service.define_singleton_method(:retrieve_with_retry) do |_params|
        calls += 1
        Struct.new(:retrieval_results).new([])
      end
      service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
      result = service.query(LEVELING, episode: episode, output_channel: :web, correlation_id: "pilot:open")
    end

    assert_operator calls, :>=, 1
    assert_not_equal "unavailable", result[:equipment_identity_status].to_s
    assert_not_equal "no_compatible", result[:equipment_identity_status].to_s
    assert_not_equal :unavailable, result[:equipment_identity_status]
    assert_not_equal :no_compatible, result[:equipment_identity_status]
  end

  test "F6 a manufacturer conflict teaches neither procedure" do
    session = web_session
    probe = empty_probe
    answer = nil

    with_episode_flags do
      isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") do
        session.record_user_turn!(
          "Cómo se ajustan los resortes de la fijación de cables ?",
          user_id: @user.id, correlation_id: "query:open"
        )
        owner = session.live_episode_id
        session.record_assistant_turn!(
          "¿Qué marca es el equipo?", user_id: @user.id, correlation_id: "query:ask", expected_episode_id: owner
        )
        session.record_user_turn!("KONE", user_id: @user.id, correlation_id: "query:kone")
      end
      episode = Rag::ActiveEpisode.parse(session.reload.active_episode)
      episode.assign_goal!(LEVELING, correlation_id: "query:goal")
      session.update!(active_episode: episode.to_h)
      assert_equal "KONE", session.reload.active_episode.dig("facts", "manufacturer", "value")
      assert_equal "user", session.active_episode.dig("facts", "manufacturer", "source")

      with_pilot_flags do
        with_vision(orona_reading, { n: 0 }) do
          with_retrieval_probe(probe, chunks: [ kone_chunk, orona_chunk ], answer: conflict_answer) do
            answer = run_photo(session, question: "qué reviso primero", image: jpeg_image("conflict"))
          end
        end
      end
    end

    episode = session.reload.active_episode
    conflict = episode["conflicts"].first
    assert_equal "KONE", conflict["user"]
    assert_equal "Orona", conflict["photo"]
    scope = probe[:scopes].last
    labels = Array(scope[:labels]).map(&:to_s)
    assert labels.all? { |label| label.start_with?("REFERENCE ONLY") }
    assert labels.none? { |label| label.include?("THIS JOB") }
    assert_equal 0, probe[:open_calls]
    assert_not_includes answer[:answer], KONE_PROCEDURE
    assert_not_includes answer[:answer], ORONA_PROCEDURE
    assert_empty answer[:citations]
    prompt = probe[:prompts].find { |text| text.include?("Identity conflict") }
    assert prompt
    assert_includes prompt, "technician said KONE"
    assert_includes prompt, "the photo shows Orona"
    assert_includes prompt, "do not choose a manufacturer"
    assert_equal 1, answer[:answer].scan("?").size
  end

  test "F7 document focus scopes retrieval and discovery does not change it" do
    orona_uri = "s3://bucket/orona.pdf"
    fuji_uri = "s3://bucket/fuji.pdf"
    outside_uri = "s3://bucket/outside-orona.pdf"
    selected_orona = orona_chunk
    selected_orona[:metadata]["original_source_uri"] = orona_uri
    selected_fuji = yida_chunk
    selected_fuji[:metadata]["original_source_uri"] = fuji_uri
    outside = orona_chunk
    outside[:metadata] = outside[:metadata].merge("original_source_uri" => outside_uri, "canonical_name" => "Manual Orona fuera de foco")
    identity = orona_identity

    open_scope = Rag::DocumentIdentityScope.apply([ selected_orona, selected_fuji ], identity, focus_uris: [])
    assert_equal "compatible", open_scope.applicability[0]
    assert_equal "reference_only", open_scope.applicability[1]
    assert_includes open_scope.chunks[0][:content], ORONA_PROCEDURE

    focused = Rag::DocumentIdentityScope.apply(
      [ selected_orona, selected_fuji, outside ],
      identity,
      focus_uris: [ orona_uri, fuji_uri ]
    )
    assert_equal "compatible", focused.applicability[0]
    assert_equal "reference_only", focused.applicability[1]
    assert_equal "reference_only", focused.applicability[2]
    assert_includes focused.chunks[0][:content], ORONA_PROCEDURE
    assert_not_includes focused.chunks[1][:content], YIDA_PROCEDURE
    assert_not_includes focused.chunks[2][:content], ORONA_PROCEDURE
    citable = Rag::DocumentIdentityScope.citable_evidence(focused.chunks)
    assert_equal ORONA_PROCEDURE, citable[0][:content]
    assert_nil citable[1]
    assert_nil citable[2]
    segments = Rag::ProvenanceSegmenter.call(
      answer: "#{YIDA_PROCEDURE} [2]",
      citations: citable.compact
    )
    assert segments.none? { |segment| segment["band"] == "MANUAL_FACT" }

    session = web_session
    document = KbDocument.create!(
      account: @account, s3_key: "manuals/pilot-focus.pdf", display_name: "Pilot focus",
      document_uid: SecureRandom.uuid, aliases: []
    )
    with_episode_flags { session.pin_kb_document!(document) }
    before = session.reload.document_focus
    Rag::DocumentDiscovery.call(
      question: LEVELING, viewer_account: @account, session: session, retriever: ->(*) { raise "discovery retrieved" }
    )
    assert_equal before, session.reload.document_focus
  end

  test "F8 a new case does not inherit the previous one and a stale writer cannot change it" do
    session = web_session
    photo = nil
    document = nil
    previous_id = nil

    with_pilot_flags do
      photo, document = seed_case(session)
      previous_id = session.reload.live_episode_id
      result = ask(
        session,
        "Ahora el variador no arranca en otro equipo",
        client(new_work_observation("el variador no arranca"))
      )
      session.reload

      assert_equal :new_episode, result.decision
      assert_not_equal previous_id, session.live_episode_id
      assert_nil session.active_episode.dig("facts", "manufacturer")
      assert_nil session.active_episode.dig("facts", "model")
      assert_nil session.active_episode["active_photo"]
      assert_no_match(/no nivela/i, goal_text(session))
      assert_equal({}, session.current_procedure)
      assert_equal 1, session.document_focus_entries.size
      assert_equal document.id, session.document_focus_entries.first["kb_document_id"]

      stale_photo = session.record_photo_observation!(
        photo_value: { manufacturer: "KONE", model_visible: "M1", relevance_to_goal: "relevant", target_visible: true },
        field_photo_id: photo.id, sha256: photo.sha256, correlation_id: "photo:stale",
        expected_episode_id: previous_id
      )
      stale_answer = session.record_assistant_turn!(
        "Procedimiento del caso anterior", user_id: @user.id, correlation_id: "query:stale",
        expected_episode_id: previous_id, writer: "photo_assistant"
      )
      session.reload
      assert_equal :stale, stale_photo
      assert_equal :stale, stale_answer
      assert_nil session.active_episode.dig("facts", "manufacturer")
      assert session.conversation_history.none? { |message| message["content"].to_s.include?("Procedimiento del caso anterior") }
    end
  end

  test "F8 a greeting is not technical work and focus stays with the technician" do
    assert_nil Rag::TechnicalUnderstanding.call(text: "hola", episode: Rag::ActiveEpisode.new).bare_identifier

    session = web_session
    document = KbDocument.create!(
      account: @account, s3_key: "manuals/greeting-focus.pdf", display_name: "Greeting focus",
      document_uid: SecureRandom.uuid, aliases: []
    )
    at = Time.zone.parse("2026-09-30 10:00:00")
    with_episode_flags do
      isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") do
        travel_to(at) do
          session.update!(expires_at: 30.days.from_now, current_procedure: { "step" => 4 })
          episode = Rag::ActiveEpisode.open(correlation_id: "query:old", now: at)
          episode.write_fact!("manufacturer", status: "known", value: "Elemont", source: "user", correlation_id: "old", at: at.iso8601)
          episode.assign_goal!("la puerta no cierra", correlation_id: "old")
          session.update!(active_episode: episode.to_h)
          session.pin_kb_document!(document)
        end
        travel_to(at + ConversationSession::EPISODE_WINDOW + 1.second) do
          result = session.record_user_turn!("hola", user_id: @user.id, correlation_id: "query:hola", now: Time.current)
          session.reload
          assert_equal :no_episode, result.decision
          assert_equal({}, session.active_episode)
          assert_equal({}, session.current_procedure)
          assert_equal document.id, session.document_focus_entries.sole["kb_document_id"]
        end
      end
    end

    owned = web_session
    with_pilot_flags do
      ask(owned, T1, client(report_observation("No nivela en planta 3")))
      owned.pin_kb_document!(document)
      result = ask(owned, "hola", client(meta_turn))
      owned.reload
      assert_equal "meta", result.understanding.decision
      assert_match(/no nivela en planta 3/i, goal_text(owned))
      assert_equal document.id, owned.document_focus_entries.sole["kb_document_id"]
    end
  end

  test "F9 a tenant cannot retrieve cite or focus another tenant private manual" do
    viewer = accounts(:climb)
    foreign = Account.create!(slug: "pilot-foreign", display_name: "Pilot Foreign", danebo_controlled: true)
    private_manual = KbDocument.create!(
      account: foreign, s3_key: "manuals/foreign-private.pdf", display_name: "Foreign private",
      document_uid: SecureRandom.uuid, aliases: []
    )
    shared = KbDocument.create!(
      account: foreign, s3_key: "manuals/foreign-shared.pdf", display_name: "Foreign shared",
      document_uid: SecureRandom.uuid, aliases: []
    )
    index_manual_for_retrieval!(shared)
    KnowledgeScopeChange.apply!(kb_document: shared, to_scope: "danebo_general", actor: "ops", reason: "pilot shared")

    decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set([ private_manual.canonical_uri ], viewer_account: viewer)
    assert decision.denied?
    shared_decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set([ shared.canonical_uri ], viewer_account: viewer)
    assert shared_decision.allowed?
    assert_not Rag::KnowledgeScopePolicy.authorized?(private_manual, viewer_account: viewer)
    assert Rag::KnowledgeScopePolicy.authorized?(shared, viewer_account: viewer)

    candidates = KbDocument.where(account_id: viewer.id).or(KbDocument.danebo_general)
    assert_nil candidates.find_by(id: private_manual.id)
    assert candidates.find_by(id: shared.id)

    client = FakeBedrock.new
    client.retrieve_results = [ retrieve_hit(private_manual, "FOREIGN_PRIVATE_BODY") ]
    client.generate_response = cited_response("FOREIGN_PRIVATE_BODY should not ship", private_manual, "FOREIGN_PRIVATE_BODY")
    retrieved = nil
    generated = nil
    with_bedrock_client(client) do
      service = BedrockRagService.new(account: viewer, knowledge_base_id: "test-kb")
      retrieved = service.retrieve_chunks("nivelacion", correlation_id: "pilot:tenant")
      generated = service.query("nivelacion", output_channel: :web, correlation_id: "pilot:tenant-cite")
    end

    assert retrieved[:chunks].none? { |chunk| chunk[:content].to_s.include?("FOREIGN_PRIVATE_BODY") }
    assert_not_includes generated[:answer].to_s, "FOREIGN_PRIVATE_BODY"
    assert_empty generated[:citations]
  end

  private

  def assert_orona_guidance(answer, probe)
    text = answer[:answer].to_s
    assert_match(/orona/i, text)
    assert_match(/pbcm-v3/i, text)
    assert_match(/planta 3/i, text)
    assert_match(/qu[eé] hace la cabina al llegar a planta 3/i, text)
    assert_operator text.scan("?").size, :<=, 1
    assert_not_includes text, YIDA_PROCEDURE
    assert_not_includes text, BLT_PROCEDURE
    assert_not_includes text, "2,5"
    assert_not_includes text, "X17"
    assert_not_includes text, "BM/B1"
    bands = answer[:segments].pluck("band")
    assert_includes bands, "VISUAL_OBSERVATION"
    assert_includes bands, "DANEBO_GUIDANCE"
    assert_not_includes bands, "MANUAL_FACT"
    assert_empty answer[:citations]
    prompt = probe[:prompts].find { |item| item.include?("# FIELD COMPANION") }
    assert prompt
    assert_match(/no nivela en planta 3/i, prompt)
    assert_includes prompt, "Orona"
    assert_not_includes prompt, YIDA_PROCEDURE
    assert_not_includes prompt, BLT_PROCEDURE
    labels = Array(probe[:scopes].last[:labels]).map(&:to_s)
    assert labels.all? { |label| label.start_with?("REFERENCE ONLY") }
  end

  def run_photo(session, question:, image:)
    images = image ? [ image ] : []
    QueryOrchestratorService.new(
      question,
      images: images,
      account: @account,
      user_id: @user.id,
      conv_session: session,
      conversation_session_id: session.id,
      response_locale: :es,
      correlation_id: "photo:#{SecureRandom.hex(4)}"
    ).execute
    message = nil
    capture_broadcasts(KbSyncBroadcaster.channel_for(@account.id)) do
      perform_enqueued_jobs(only: FieldPhotoAnalysisJob)
    end.tap { |messages| message = messages.last.to_h }
    {
      answer: message["answer"].presence || message["summary"].to_s,
      citations: Array(message["citations"]),
      segments: Array(message["provenance_segments"])
    }
  end

  def retrieve_text(session, text, interpreter)
    turn = ask(session, text, interpreter)
    session.reload
    query = turn.composed.presence || text
    QueryOrchestratorService.new(
      query,
      raw_question: text,
      account: @account,
      user_id: @user.id,
      conv_session: session,
      conversation_session_id: session.id,
      response_locale: :es,
      correlation_id: "query:#{SecureRandom.hex(4)}",
      output_channel: :web,
      session_context: SessionContextBuilder.build(session)
    ).execute
  end

  def assert_scoped_guidance(session, scope, result, prompt)
    assert scope
    assert_equal :no_compatible, scope_status(scope)
    assert_includes scope_values(scope[:identity]), "Orona"
    assert_includes scope_values(scope[:identity]), "PBCM-V3"
    assert_equal "no_compatible", result[:equipment_identity_status]
    assert_equal "document_identity_scope", result[:generation_mode]
    assert_empty Array(result[:citations])
    [ result[:answer], prompt ].each do |text|
      assert_not_includes text.to_s, YIDA_PROCEDURE
      assert_not_includes text.to_s, BLT_PROCEDURE
      assert_not_includes text.to_s, MONARCH_PROCEDURE
    end
    photo = FieldPhoto.find_by(id: session.active_episode.dig("active_photo", "field_photo_id"))
    segments = Rag::ProvenanceSegmenter.call(
      answer: result[:answer],
      citations: result[:citations],
      visual_observation: photo&.visual_observation
    )
    bands = segments.pluck("band")
    assert_includes bands, "DANEBO_GUIDANCE"
    assert_not_includes bands, "MANUAL_FACT"
    assert_includes result[:answer], "pasada o corta"
  end

  def ask(session, text, interpreter)
    session.record_user_turn!(
      text,
      user_id: @user.id,
      correlation_id: "query:#{SecureRandom.hex(4)}",
      interpreter_client: interpreter
    )
  end

  def with_pilot_flags(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
          isolate_env("PHOTO_QUESTION_RAG_ENABLED", "true") do
            isolate_env("DOCUMENT_IDENTITY_SCOPE_ENABLED", "true") do
              isolate_env("SHOW_RAG_SOURCES", "true", &block)
            end
          end
        end
      end
    end
  end

  def with_episode_flags(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true", &block)
    end
  end

  def with_vision(result, calls)
    original = FieldPhotoAnalysisService.method(:new)
    FieldPhotoAnalysisService.define_singleton_method(:new) do |**_kwargs|
      calls[:n] += 1
      fake = Object.new
      fake.define_singleton_method(:call) { result }
      fake
    end
    yield
  ensure
    FieldPhotoAnalysisService.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) }
  end

  def with_retrieval_probe(probe, chunks:, answer:)
    original_apply = Rag::DocumentIdentityScope.method(:apply)
    original_new = BedrockRagService.method(:new)
    Rag::DocumentIdentityScope.define_singleton_method(:apply) do |rows, identity, focus_uris: []|
      result = original_apply.call(rows, identity, focus_uris: focus_uris)
      probe[:scopes] << { identity: identity, labels: result.labels, result: result }
      result
    end
    BedrockRagService.define_singleton_method(:new) do |**kwargs|
      kwargs[:knowledge_base_id] = "test-kb"
      service = original_new.call(**kwargs)
      service.define_singleton_method(:retrieve_chunks) { |*_args, **_kwargs| { chunks: chunks, retrieval_trace: {} } }
      service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
      service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
        probe[:open_calls] += 1
        output = Struct.new(:text).new("#{YIDA_PROCEDURE} [1]")
        Struct.new(:output, :citations, :session_id).new(output, [], nil)
      end
      generator = Object.new
      generator.define_singleton_method(:query) do |prompt, **|
        probe[:prompts] << prompt
        answer
      end
      service.instance_variable_set(:@document_identity_generator, generator)
      service
    end
    yield
  ensure
    Rag::DocumentIdentityScope.define_singleton_method(:apply) { |*args, **kwargs| original_apply.call(*args, **kwargs) }
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) }
  end

  def counting_interpreter(calls)
    original = Rag::TurnInterpreter.method(:call)
    Rag::TurnInterpreter.define_singleton_method(:call) do |**kwargs|
      calls[:n] += 1
      original.call(**kwargs)
    end
    yield
  ensure
    Rag::TurnInterpreter.define_singleton_method(:call) { |**kwargs| original.call(**kwargs) }
  end

  def with_bedrock_client(client)
    original = Aws::BedrockAgentRuntime::Client.method(:new)
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*| client }
    yield
  ensure
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def web_session
    ConversationSession.create!(
      identifier: "web:pilot:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: @user,
      account: @account
    )
  end

  def seed_case(session)
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: @account, sha256: sha, s3_key_original: "field_photos/#{@account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 8
    )
    document = KbDocument.create!(
      account: @account, s3_key: "manuals/case-a-#{SecureRandom.hex(3)}.pdf", display_name: "Case A",
      document_uid: SecureRandom.uuid, aliases: []
    )
    now = Time.current
    episode = Rag::ActiveEpisode.open(correlation_id: "query:case-a", now: now)
    episode.assign_goal!(LEVELING, correlation_id: "query:case-a")
    episode.write_fact!("manufacturer", status: "known", value: "Orona", source: "photo", correlation_id: "photo:a", at: now.iso8601)
    episode.write_fact!("model", status: "known", value: "PBCM-V3", source: "photo", correlation_id: "photo:a", at: now.iso8601)
    episode.active_photo = { "field_photo_id" => photo.id, "sha256" => sha, "correlation_id" => "photo:a" }
    session.update!(active_episode: episode.to_h, current_procedure: { "step" => 3, "text" => "procedimiento del caso A" })
    session.pin_kb_document!(document)
    [ photo, document ]
  end

  def goal_text(session)
    session.reload.active_episode.dig("goal", "text").to_s
  end

  def jpeg_image(label)
    { binary: "jpeg-#{label}-#{SecureRandom.hex(4)}", media_type: "image/jpeg", filename: "#{label}.jpg" }
  end

  def orona_reading_unconfirmed
    orona_reading.merge(relevance_to_goal: nil)
  end

  def orona_reading
    {
      analysis: "Placa controladora Orona PBCM-V3",
      compact_context: "[FOTO] RAW Componente: Placa controladora | Fabricante: Orona",
      canonical_name: "Placa controladora",
      aliases: [],
      model: "claude-sonnet-5-5",
      usage: { input_tokens: 120, output_tokens: 80 },
      latency_ms: 10,
      relevance_to_goal: "relevant",
      target_visible: true,
      parsed: {
        "canonical_component" => "Placa controladora",
        "manufacturer" => "Orona",
        "model" => "PBCM-V3",
        "subsystem" => "CONTROLLER_LOGIC",
        "condition" => "GOOD",
        "visible_text" => [ "PBCM-V3" ]
      }
    }
  end

  def empty_probe
    { open_calls: 0, prompts: [], scopes: [] }
  end

  def scope_status(scope)
    scope[:result].status
  end

  def scope_values(identity)
    Array(identity.respond_to?(:facts) ? identity.facts : nil).filter_map { |fact| fact.is_a?(Hash) ? fact["value"] : nil }
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

  def procedure_chunk(name, body, document_id)
    {
      rank: 1,
      content: body,
      metadata: {
        "account_id" => @account.id.to_s,
        "document_id" => document_id,
        "canonical_name" => name,
        "page_number" => 4
      },
      chunk_sha256: Digest::SHA256.hexdigest(body)
    }
  end

  def yida_chunk
    procedure_chunk("Fuji Yida Guía del Usuario Ascensor", YIDA_PROCEDURE, "yida")
  end

  def blt_chunk
    procedure_chunk("Código de Avería BLT Ascensor", BLT_PROCEDURE, "blt")
  end

  def orona_chunk
    procedure_chunk("Manual Orona PBCM-V3", ORONA_PROCEDURE, "orona")
  end

  def kone_chunk
    procedure_chunk("Manual KONE", KONE_PROCEDURE, "kone")
  end

  def monarch_chunk
    procedure_chunk("Manual Monarch", MONARCH_PROCEDURE, "monarch")
  end

  def conflict_answer
    "Hay una inconsistencia entre el fabricante indicado y el leído en la foto. ¿Puedes mostrarme la placa del controlador?"
  end

  def meta_turn
    { "move" => "meta", "assertions" => [], "observations" => [], "pending_resolution" => nil, "clarification_target" => nil }
  end

  def report_observation(text)
    { "move" => "report", "assertions" => [], "observations" => [ text ], "pending_resolution" => nil, "clarification_target" => nil }
  end

  def new_work_observation(text)
    { "move" => "new_work", "assertions" => [], "observations" => [ text ], "pending_resolution" => nil, "clarification_target" => nil }
  end

  def follow_up
    { "move" => "follow_up", "assertions" => [], "observations" => [], "pending_resolution" => nil, "clarification_target" => nil }
  end

  def follow_up_observation(text)
    { "move" => "follow_up", "assertions" => [], "observations" => [ text ], "pending_resolution" => nil, "clarification_target" => nil }
  end

  def client(response)
    ScriptedClient.new([ response ])
  end

  def retrieve_hit(document, body)
    OpenStruct.new(
      content: OpenStruct.new(text: body),
      score: 0.9,
      metadata: {
        "original_source_uri" => document.canonical_uri,
        "account_id" => document.account_id.to_s,
        "document_id" => document.document_uid
      },
      location: OpenStruct.new(s3_location: OpenStruct.new(uri: "s3://bucket/chunks/#{document.id}.txt"))
    )
  end

  def cited_response(answer, document, body)
    OpenStruct.new(
      output: OpenStruct.new(text: answer),
      session_id: "sid",
      citations: [
        OpenStruct.new(
          retrieved_references: [
            OpenStruct.new(
              content: OpenStruct.new(text: body),
              location: OpenStruct.new(s3_location: OpenStruct.new(uri: "s3://bucket/chunks/#{document.id}.txt")),
              metadata: {
                "original_source_uri" => document.canonical_uri,
                "account_id" => document.account_id.to_s,
                "document_id" => document.document_uid
              }
            )
          ]
        )
      ]
    )
  end

  class ScriptedClient
    def initialize(responses)
      @responses = responses.dup
    end

    def converse(_params)
      tool = Struct.new(:name, :input).new("turn_perception", @responses.shift)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(4, 2)
      Struct.new(:output, :usage).new(output, usage)
    end
  end

  class FakeBedrock
    attr_accessor :generate_response, :retrieve_results

    def retrieve(_params)
      OpenStruct.new(retrieval_results: Array(retrieve_results))
    end

    def retrieve_and_generate(_params)
      generate_response
    end
  end
end
