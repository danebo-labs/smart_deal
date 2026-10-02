# frozen_string_literal: true

require "test_helper"

class Rag::TurnPerceptionTest < ActiveSupport::TestCase
  setup do
    @owner = accounts(:legacy)
    @other = accounts(:climb)
    @uid = SecureRandom.uuid
    @key = "manuals/#{@uid}.pdf"
    KbDocument.create!(
      account: @owner, s3_key: @key, display_name: "Monarch book", document_uid: @uid, aliases: []
    )
    @catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        {
          "account_id" => @owner.id.to_s,
          "document_id" => @uid,
          "s3_key" => @key,
          "display_name" => "Monarch",
          "brands" => [ "MONARCH" ],
          "designators" => [
            { "value" => "NICE3000", "type" => "controller" },
            { "value" => "NICE1000", "type" => "controller" }
          ],
          "generic" => false,
          "confirmed" => true
        }
      ]
    })
  end

  test "an extra tool key invalidates the perception" do
    result = perceive({ "move" => "report", "assertions" => [], "observations" => [], "pending_resolution" => nil, "route" => "ready" }, "hola")

    assert_not result.valid
    assert_equal "invalid_schema", result.invalid_reason
    assert_empty result.identities
  end

  test "a span that is not in the turn is rejected and is not a fact" do
    result = perceive(report([ assert_span("NICE3000") ]), "hola")

    assert result.valid
    assert_empty result.identities
    assert_equal "not_literal", result.field_rejections.first["reason"]
  end

  test "Q2 stays a mention and does not become a fault code" do
    raw = report([ { "span" => "Q2", "act" => "assert", "slot_hint" => "fault_code" } ])

    unfocused = perceive(raw, "¿Que es Q2?")
    assert_equal [ "mention" ], unfocused.identities.map(&:kind)
    assert_equal "Q2", unfocused.mentions.first.value
    assert_empty unfocused.facts

    focused = perceive(raw, "¿Que es Q2?")
    assert_empty focused.facts
    assert_equal "mention", focused.identities.first.act
  end

  test "a generic literal stays an untyped identifier" do
    result = perceive(report([ assert_span("ABC900", "controller") ]), "El controlador es ABC900")

    assert_equal [ "identifier" ], result.identities.map(&:kind)
    assert_nil result.identities.first.slot
    assert_nil result.identities.first.source
    assert_empty result.facts
  end

  test "a pending controller answer types an uncatalogued value as user" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:1", now: Time.current)
    episode.pending_question = { "type" => "controller" }
    episode.pending_fact = { "subject" => "controller", "correlation_id" => "query:1" }

    result = perceive(
      answer("value", [ assert_span("ABC900", "model") ]),
      "ABC900",
      episode: episode
    )

    fact = result.facts.first
    assert_equal "answer_pending", result.move
    assert_equal "controller", fact.slot
    assert_equal "ABC900", fact.value
    assert_equal "user", fact.source
    assert_equal "model", result.catalog_disagreements.first["hint"]
  end

  test "a controller correction types the uncatalogued replacement from the negated slot" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:1", now: Time.current)
    episode.write_fact!("controller", status: "known", value: "NICE3000", source: "catalog", correlation_id: "query:1", at: Time.current.iso8601)

    result = perceive(
      {
        "move" => "correct",
        "assertions" => [ negate_span("NICE3000"), assert_span("ABC900", "model") ],
        "observations" => [],
        "pending_resolution" => nil,
        "clarification_target" => nil
      },
      "No, no es NICE3000. Es ABC900.",
      episode: episode
    )

    fact = result.facts.first
    assert_equal "correct", result.move
    assert_equal "controller", fact.slot
    assert_equal "ABC900", fact.value
    assert_equal "user", fact.source
    assert result.identities.any? { |item| item.kind == "negate" && item.slot == "controller" }
  end

  test "an exact authorized designator overrides the hint and carries the manufacturer" do
    result = perceive(report([ assert_span("NICE3000", "model") ]), "Es NICE3000")

    fact = result.facts.first
    assert_equal "controller", fact.slot
    assert_equal "NICE3000", fact.value
    assert_equal "catalog", fact.source
    assert_equal "MONARCH", fact.manufacturer
    assert_equal "model", result.catalog_disagreements.first["hint"]
    assert_equal "controller", result.catalog_disagreements.first["catalog"]
  end

  test "an exact authorized brand writes manufacturer" do
    result = perceive(report([ assert_span("Monarch", "controller") ]), "Es Monarch")

    fact = result.facts.first
    assert_equal "manufacturer", fact.slot
    assert_equal "MONARCH", fact.value
    assert_equal "catalog", fact.source
  end

  test "a private catalog identity does not type another tenant" do
    result = perceive(report([ assert_span("NICE3000", "controller") ]), "NICE3000", viewer: @other)

    assert_equal [ "identifier" ], result.identities.map(&:kind)
    assert_nil result.identities.first.manufacturer
    assert_empty result.facts
  end

  test "a missing viewer does not read the catalog" do
    result = perceive(report([ assert_span("NICE3000", "controller") ]), "NICE3000", viewer: nil)

    assert_empty result.facts
    assert_equal "identifier", result.identities.first.kind
  end

  test "correct without an active negate becomes unclear and mutates nothing" do
    result = perceive(
      {
        "move" => "correct",
        "assertions" => [ negate_span("NICE3000"), assert_span("ABC900") ],
        "observations" => [ "intenta cerrar de nuevo" ],
        "pending_resolution" => nil,
        "clarification_target" => nil
      },
      "No, no es NICE3000. Es ABC900. intenta cerrar de nuevo"
    )

    assert_equal "unclear", result.move
    assert_equal "correction_target", result.clarification_target
    assert_empty result.identities
    assert_empty result.observations
  end

  test "a correct assert recovers the one stored value that is literal in the turn" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: Time.current)
    episode.write_fact!(
      "model", status: "known", value: "KONE", source: "user",
      correlation_id: "seed", at: Time.current.iso8601
    )
    result = perceive(
      {
        "move" => "correct",
        "assertions" => [ assert_span("OTIS") ],
        "observations" => [],
        "pending_resolution" => nil,
        "clarification_target" => nil
      },
      "No es KONE, es OTIS",
      episode: episode
    )

    assert_equal "correct", result.move
    assert_nil result.clarification_target
    negate = result.identities.find { |item| item.kind == "negate" }
    assert_equal "model", negate.slot
    assert_equal "KONE", negate.span
  end

  test "a correct assert does not choose between two stored values in the turn" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: Time.current)
    episode.write_fact!(
      "manufacturer", status: "known", value: "KONE", source: "user",
      correlation_id: "seed", at: Time.current.iso8601
    )
    episode.write_fact!(
      "controller", status: "known", value: "NICE3000", source: "user",
      correlation_id: "seed", at: Time.current.iso8601
    )
    result = perceive(
      {
        "move" => "correct",
        "assertions" => [ assert_span("OTIS") ],
        "observations" => [],
        "pending_resolution" => nil,
        "clarification_target" => nil
      },
      "No es KONE ni NICE3000, es OTIS",
      episode: episode
    )

    assert_equal "unclear", result.move
    assert_equal "correction_target", result.clarification_target
    assert_empty result.identities
  end

  test "a short multi-word symptom is kept and a lone technical token is not" do
    symptoms = perceive(
      observation_report([ "no abre", "no frena", "se traba" ]),
      "el freno no abre, no frena y se traba"
    )
    more = perceive(
      observation_report([ "no parte", "no nivela", "no arranca" ]),
      "el equipo no parte, no nivela y no arranca"
    )
    tokens = perceive(
      observation_report([ "E51", "NICE3000", "Elemont" ]),
      "veo E51 NICE3000 y Elemont"
    )
    code = perceive(observation_report([ "Q2" ]), "¿Qué es Q2?")
    missing = perceive(observation_report([ "no cierra" ]), "el freno falla")

    assert_equal [ "no abre", "no frena", "se traba" ], symptoms.observations
    assert_empty symptoms.field_rejections
    assert_equal [ "no parte", "no nivela", "no arranca" ], more.observations
    assert_empty tokens.observations
    assert_equal %w[not_symptom not_symptom not_symptom], tokens.field_rejections.pluck("reason")
    assert_empty code.observations
    assert_equal [ "not_symptom" ], code.field_rejections.pluck("reason")
    assert_empty missing.observations
    assert_equal [ "not_literal" ], missing.field_rejections.pluck("reason")
  end

  test "span validation uses the same truncated turn history persists" do
    body = "#{'A' * 280} KEEP #{'B' * 40} ABC900"
    truncated = Rag::TurnText.truncate(body)

    assert_equal body.truncate(ConversationSession::MAX_MSG_LENGTH), truncated
    assert_equal 300, truncated.length
    assert truncated.end_with?("...")
    assert_not_includes truncated, "ABC900"
    assert_includes truncated, "KEEP"

    kept = perceive(report([ assert_span("KEEP") ]), body)
    dropped = perceive(report([ assert_span("ABC900") ]), body)

    assert_equal "identifier", kept.identities.first.kind
    assert_empty dropped.identities
    assert_equal "not_literal", dropped.field_rejections.first["reason"]
  end

  test "the eval fixture names the critical journeys" do
    cases = YAML.safe_load_file(Rails.root.join("test/fixtures/files/field_companion/turn_interpreter_eval.yml"))
    ids = cases.pluck("id")

    assert_includes ids, "q2_carry_identity"
    assert_includes ids, "pending_custom_identity"
    assert_includes ids, "tenant_private_designator"
    %w[vis_1 vis_2 vis_3 vis_4 amb_1 amb_2 amb_2b amb_3].each do |id|
      assert_includes ids, id
    end
    assert_equal 21, cases.size
    assert cases.all? { |row| row["origin"].present? && row["expected"].is_a?(Hash) }
    assert cases.all? { |row| row["turn"].present? || row["turns"].present? }
  end

  test "ask does not call TurnPerception yet" do
    source = Rails.root.join("app/controllers/rag_controller.rb").read
    concern = Rails.root.join("app/controllers/concerns/rag_query_concern.rb").read

    assert_not_includes source, "TurnPerception"
    assert_not_includes concern, "TurnPerception"
    assert_not_includes Rails.root.join("config/deploy.yml").read, "HAIKU_QUERY_ANALYSIS_MODE: owner"
  end

  test "a missing clarification target invalidates the perception" do
    result = perceive(
      { "move" => "report", "assertions" => [], "observations" => [], "pending_resolution" => nil },
      "hola"
    )

    assert_not result.valid
    assert_equal "invalid_schema", result.invalid_reason
  end

  test "unclear without a target is invalid and a target on another move is invalid" do
    missing = perceive(
      { "move" => "unclear", "assertions" => [], "observations" => [], "pending_resolution" => nil, "clarification_target" => nil },
      "No, ese era el otro"
    )
    extra = perceive(
      { "move" => "report", "assertions" => [], "observations" => [], "pending_resolution" => nil, "clarification_target" => "work_relation" },
      "No, ese era el otro"
    )

    assert_not missing.valid
    assert_not extra.valid
  end

  test "a thin new work stays new work only while a work relation question is open" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:1", now: Time.current)
    episode.assign_goal!("la puerta no cierra", correlation_id: "query:1")
    raw = {
      "move" => "new_work",
      "assertions" => [],
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }

    downgraded = perceive(raw, "Es otro ascensor", episode: episode)
    assert_equal "follow_up", downgraded.move

    episode.pending_question = { "type" => "work_relation" }
    kept = perceive(raw, "Es otro ascensor", episode: episode)
    assert_equal "new_work", kept.move
    assert_not kept.technical_payload?
  end

  private

  def perceive(raw, turn, episode: Rag::ActiveEpisode.new, viewer: @owner)
    Rag::TurnPerception.build(
      raw, turn: turn, episode: episode, catalog: @catalog, viewer_account: viewer
    )
  end

  def observation_report(observations)
    { "move" => "report", "assertions" => [], "observations" => observations, "pending_resolution" => nil, "clarification_target" => nil }
  end

  def report(assertions)
    { "move" => "report", "assertions" => assertions, "observations" => [], "pending_resolution" => nil, "clarification_target" => nil }
  end

  def answer(resolution, assertions)
    { "move" => "answer_pending", "assertions" => assertions, "observations" => [], "pending_resolution" => resolution, "clarification_target" => nil }
  end

  def assert_span(span, hint = nil)
    { "span" => span, "act" => "assert", "slot_hint" => hint }
  end

  def negate_span(span)
    { "span" => span, "act" => "negate", "slot_hint" => nil }
  end
end
