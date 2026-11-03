# frozen_string_literal: true

require "test_helper"

class Rag::QuoteReplyExperimentTest < ActiveSupport::TestCase
  T2 = "Fue solo la primera apertura. Después volvió a abrir y cerrar como antes."
  FIRST = "Fue solo la primera apertura"
  SECOND = "Después volvió a abrir y cerrar como antes."
  LED = "El LED STATUS está apagado."
  CODE = "Muestra E4. Solo aparece después de las dos de la tarde."

  test "the experimental prompt replaces only the offset instruction" do
    product = Rag::TurnInterpreter::PROMPT
    copy = Rag::QuoteReplyExperiment.prompt_copy(product)
    left = product.split(/\n\n/)
    right = copy.split(/\n\n/)

    assert_equal Rag::QuoteReplyExperiment::PRODUCT_PROMPT_SHA256, Digest::SHA256.hexdigest(product)
    assert_equal left.size, right.size
    changed = left.zip(right).select { |before, after| before != after }
    assert_equal 1, changed.size
    assert_includes changed.first.first, Rag::QuoteReplyExperiment::OFFSET_INSTRUCTION
    assert_includes copy, Rag::QuoteReplyExperiment::QUOTE_RULE
    assert_includes copy, "and that same literal quote"
    assert_not_includes copy, Rag::QuoteReplyExperiment::OFFSET_INSTRUCTION
    assert_not_includes copy, Rag::QuoteReplyExperiment::DECLARED_OFFSET
    assert_includes product, Rag::QuoteReplyExperiment::OFFSET_INSTRUCTION
  end

  test "the experimental schema requires quote and keeps the other contract" do
    product = Rag::TurnPerception.tool_schema
    copy = Rag::QuoteReplyExperiment.schema_copy(product)
    item = copy.dig(:properties, :part_replies, :items)
    product_item = product.dig(:properties, :part_replies, :items)

    assert_equal %w[question_id part_id state quote], item[:required]
    assert_not item[:properties].key?(:start)
    assert_not item[:properties].key?(:end)
    assert_equal({ type: "string" }, item[:properties][:quote])
    assert_equal Rag::AnswerContract::STATES, item.dig(:properties, :state, :enum)
    assert_equal 4, copy.dig(:properties, :part_replies, :maxItems)
    assert_equal product.dig(:properties, :observations, :maxItems), copy.dig(:properties, :observations, :maxItems)
    assert product_item[:properties].key?(:start)
    assert product_item[:properties].key?(:end)

    stripped_product = product.deep_dup
    stripped_copy = copy.deep_dup
    stripped_product.dig(:properties, :part_replies, :items).delete(:required)
    stripped_copy.dig(:properties, :part_replies, :items).delete(:required)
    stripped_product.dig(:properties, :part_replies, :items, :properties).delete(:start)
    stripped_product.dig(:properties, :part_replies, :items, :properties).delete(:end)
    stripped_copy.dig(:properties, :part_replies, :items, :properties).delete(:quote)
    assert_equal stripped_product, stripped_copy
  end

  test "prepare params sends the quote schema and leaves the product schema" do
    message = JSON.generate("turn" => LED)
    params = Rag::QuoteReplyExperiment.prepare_params(message)
    schema = params.dig(:tool_config, :tools, 0, :tool_spec, :input_schema, :json)

    assert_equal message, params.dig(:messages, 0, :content, 0, :text)
    assert_equal 0, params.dig(:inference_config, :temperature)
    assert_equal 512, params.dig(:inference_config, :max_tokens)
    assert_equal Rag::TurnInterpreter::MODEL_ID, params[:model_id]
    assert_not schema.dig(:properties, :part_replies, :items, :properties).key?(:start)
    assert schema.dig(:properties, :part_replies, :items, :properties).key?(:quote)
    assert_includes params.dig(:system, 0, :text), Rag::QuoteReplyExperiment::QUOTE_RULE
    assert Rag::TurnPerception.tool_schema.dig(:properties, :part_replies, :items, :properties).key?(:start)
    assert_not_includes Rag::TurnInterpreter::PROMPT, Rag::QuoteReplyExperiment::QUOTE_RULE
  end

  test "one exact quote becomes ruby offsets and keeps the original fragment" do
    found = Rag::QuoteReplyExperiment.locate(FIRST, T2)

    assert_equal "located", found["status"]
    assert_equal T2.index(FIRST), found["start"]
    assert_equal found["start"] + FIRST.length, found["end"]
    assert_equal FIRST, found["fragment"]
    assert_equal FIRST, T2[found["start"]...found["end"]]
  end

  test "a repeated quote is ambiguous and does not use the first index" do
    turn = "abre despacio y abre despacio"
    quote = "abre despacio"
    found = Rag::QuoteReplyExperiment.locate(quote, turn)
    raw = reply_payload(turn, quote, "complete")
    adapted = Rag::QuoteReplyExperiment.adapt(raw, turn)

    overlap = Rag::QuoteReplyExperiment.locate("aaa", "aaaaa")

    assert_equal "quote_ambiguous", found["status"]
    assert_equal 2, found["count"]
    assert_nil found["start"]
    assert_equal "quote_ambiguous", overlap["status"]
    assert_equal 3, overlap["count"]
    assert_nil overlap["start"]
    assert_equal quote, found["quote"]
    assert_equal [], adapted["adapted"]["part_replies"]
    assert_equal [], adapted["adapted"]["observations"]
    assert_nil adapted["resolutions"].first["start"]
  end

  test "a missing quote stays quote_not_literal and records the difference" do
    turn = LED.dup
    missing = Rag::QuoteReplyExperiment.locate("El LED STATUS está encendido.", turn)
    cased = Rag::QuoteReplyExperiment.locate("el led status está apagado.", turn)
    spaced = Rag::QuoteReplyExperiment.locate("El LED  STATUS está apagado.", turn)
    decomposed = "está".unicode_normalize(:nfd)
    composed = "está".unicode_normalize(:nfc)
    unicode = Rag::QuoteReplyExperiment.locate(decomposed, composed)
    blank = Rag::QuoteReplyExperiment.locate("", turn)
    other = Rag::QuoteReplyExperiment.locate(nil, turn)

    assert_equal "quote_not_literal", missing["status"]
    assert_equal "absent", missing["difference"]
    assert_equal "El LED STATUS está encendido.", missing["quote"]
    assert_nil missing["start"]
    assert_equal "case", cased["difference"]
    assert_equal "whitespace", spaced["difference"]
    assert_equal "unicode_normalization", unicode["difference"]
    assert_equal decomposed, unicode["quote"]
    assert_equal composed, turn_unchanged(composed, decomposed)
    assert_equal "blank", blank["difference"]
    assert_equal "not_a_string", other["difference"]
    assert_equal LED, turn
  end

  test "a valid quote is conserved before its association and the state stays" do
    raw = reply_payload(T2, FIRST, "partial", observations: [ SECOND.sub(/[.!?]+\z/, "") ])
    result = Rag::QuoteReplyExperiment.adapt(raw, T2)
    reply = result["adapted"]["part_replies"].first

    assert_equal "partial", reply["state"]
    assert_equal "q1", reply["question_id"]
    assert_equal "p1", reply["part_id"]
    assert_nil reply["supersedes"]
    assert_not reply.key?("quote")
    assert_equal T2.index(FIRST), reply["start"]
    assert_equal FIRST, result["adapted"]["observations"].last
    assert_equal "added", result["observation_notes"].last["result"]
    assert_equal "follow_up", result["adapted"]["move"]
    assert_equal FIRST, raw["part_replies"].first["quote"]
    assert_equal "partial", raw["part_replies"].first["state"]
  end

  test "unknown stays unknown and a lone code is not forced into observations" do
    raw = reply_payload(CODE, "E4", "unknown")
    result = Rag::QuoteReplyExperiment.adapt(raw, CODE)
    reply = result["adapted"]["part_replies"].first

    assert_equal "unknown", reply["state"]
    assert_equal CODE.index("E4"), reply["start"]
    assert_equal [], result["adapted"]["observations"]
    assert_equal "not_symptom", result["observation_notes"].first["result"]
    assert_equal 1, result["adapted"]["part_replies"].size
  end

  test "a symptom quote is added and a duplicate does not consume the cap" do
    raw = reply_payload(CODE, "Muestra E4", "partial")
    added = Rag::QuoteReplyExperiment.adapt(raw, CODE)
    duplicate = Rag::QuoteReplyExperiment.adapt(
      reply_payload(T2, FIRST, "partial", observations: [ FIRST ]),
      T2
    )

    assert_equal [ "Muestra E4" ], added["adapted"]["observations"]
    assert_equal "added", added["observation_notes"].first["result"]
    assert_equal "partial", added["adapted"]["part_replies"].first["state"]
    assert_equal [ FIRST ], duplicate["adapted"]["observations"]
    assert_equal "duplicate", duplicate["observation_notes"].first["result"]
  end

  test "the third observation blocks another quote with cap_reached" do
    raw = reply_payload(T2, FIRST, "partial", observations: [
      "Esto pasa solo cuando hace mucho calor afuera",
      "De noche enfría bien",
      SECOND.sub(/[.!?]+\z/, "")
    ])
    result = Rag::QuoteReplyExperiment.adapt(raw, T2)

    assert_equal 3, result["adapted"]["observations"].size
    assert_not_includes result["adapted"]["observations"], FIRST
    assert_equal "cap_reached", result["observation_notes"].first["result"]
    assert_equal "partial", result["adapted"]["part_replies"].first["state"]
  end

  test "a fragment inside a sentence does not conserve the sentence" do
    coverage = Rag::QuoteReplyExperiment.phrase_coverage(T2, [ "la primera apertura", SECOND.sub(/[.!?]+\z/, "") ])
    first = coverage.first
    second = coverage.last
    whole = Rag::QuoteReplyExperiment.phrase_coverage(T2, [ T2 ])

    assert_not first["conserved"]
    assert first["fragment_only"]
    assert_operator first["covered_chars"], :<, first["sentence_chars"]
    assert second["conserved"]
    assert_not second["fragment_only"]
    assert whole.none? { |item| item["conserved"] }
    assert whole.all? { |item| item["only_inside_larger"] }
  end

  test "conservation can succeed while the false association remains" do
    rows = [
      {
        "id" => "t2",
        "observations" => [ FIRST, SECOND.sub(/[.!?]+\z/, "") ],
        "replies" => [ { "p" => "p1", "state" => "partial", "text" => FIRST } ]
      },
      row("led", [ "El LED STATUS está apagado" ], reply: led_reply),
      row("mixed", [ "El LED STATUS está apagado", FIRST ], reply: led_reply),
      row("ac", [ "Esto pasa solo cuando hace mucho calor afuera", "De noche enfría bien" ]),
      row("code", [ "Solo aparece después de las dos de la tarde" ], reply: code_reply, facts: { "fault_code" => { "value" => "E4" } })
    ]
    reading = Rag::QuoteReplyExperiment.reading(rows)

    assert reading.dig("cases", "t2", "conservation")
    assert_not reading.dig("cases", "t2", "association")
    assert reading["conservation"]
    assert_not reading["association"]
    assert reading["partial"]
    assert_not reading["quote_supported"]
    assert_not reading["approves_interpreter"]
    assert_not reading["approves_script_2"]
  end

  test "both dimensions passing still does not approve the interpreter" do
    rows = [
      row("t2", [ FIRST, SECOND.sub(/[.!?]+\z/, "") ]),
      row("led", [ "El LED STATUS está apagado" ], reply: led_reply),
      row("mixed", [ "El LED STATUS está apagado", FIRST ], reply: led_reply),
      row("ac", [ "Esto pasa solo cuando hace mucho calor afuera", "De noche enfría bien" ]),
      row("code", [ "Solo aparece después de las dos de la tarde" ], reply: code_reply, facts: { "fault_code" => { "value" => "E4" } })
    ]
    reading = Rag::QuoteReplyExperiment.reading(rows)

    assert reading["conservation"]
    assert reading["association"]
    assert reading["quote_supported"]
    assert_not reading["partial"]
    assert_not reading["approves_interpreter"]
    assert_not reading["approves_script_2"]
  end

  test "a whole-turn observation does not count as each fact" do
    reading = Rag::QuoteReplyExperiment.reading([
      { "id" => "t2", "observations" => [ T2 ], "replies" => [] }
    ])

    assert_not reading.dig("cases", "t2", "conservation")
    assert reading.dig("cases", "t2", "association")
  end

  private

  def reply_payload(_turn, quote, state, observations: [])
    {
      "move" => "follow_up",
      "observations" => observations,
      "part_replies" => [ {
        "question_id" => "q1",
        "part_id" => "p1",
        "state" => state,
        "quote" => quote,
        "supersedes" => nil
      } ]
    }
  end

  def row(id, observations, reply: nil, facts: nil)
    payload = { "id" => id, "observations" => observations, "replies" => reply.nil? ? [] : [ reply ] }
    payload["facts"] = facts if facts
    payload
  end

  def led_reply
    { "p" => "p1", "state" => "complete", "text" => "El LED STATUS está apagado." }
  end

  def code_reply
    { "p" => "p1", "state" => "partial", "text" => "Muestra E4" }
  end

  def turn_unchanged(composed, decomposed)
    copy = composed.dup
    Rag::QuoteReplyExperiment.locate(decomposed, copy)
    copy
  end
end
