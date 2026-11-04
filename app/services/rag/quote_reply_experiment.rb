# frozen_string_literal: true

module Rag
  # Harness for the quote contract that now lives on the product prompt.
  # prepare_params, fingerprint, and case_reading stay here. Location and
  # observation copy are TurnPerception.
  class QuoteReplyExperiment
    PRODUCT_PROMPT_SHA256 = "669df150364315bc9a3ef272d4bad8e8703b3a5ad91bb13b8ce2e56a00949905"
    OFFSET_INSTRUCTION = "start is the first character and end is the index after the last character of that slice of the turn you were given; omit both to cite that whole turn for that one part. Do not send a paraphrase."
    DECLARED_OFFSET = "both start and end on that exact slice"
    DECLARED_QUOTE = "that same literal quote"
    QUOTE_RULE = "quote is the shortest literal substring of turn that carries that answer. Copy it exactly. Every item needs quote. When that text appears more than once in turn, extend quote until it appears once. Do not send a paraphrase. A quote that states a fact of the case is also listed in observations."
    CASE_IDS = %w[t2 led mixed ac code].freeze
    LED_WORDING = "El LED STATUS está apagado"
    CODE_WORDING = "Muestra E4"
    TEMPORAL_WORDING = "Solo aparece después de las dos de la tarde"
    FACTS = {
      "t2" => [ "Fue solo la primera apertura", "Después volvió a abrir y cerrar como antes" ],
      "led" => [ LED_WORDING ],
      "mixed" => [ LED_WORDING, "Fue solo la primera apertura" ],
      "ac" => [ "Esto pasa solo cuando hace mucho calor afuera", "De noche enfría bien" ],
      "code" => [ CODE_WORDING, TEMPORAL_WORDING ]
    }.freeze

    class << self
      def prompt_copy(source = TurnInterpreter::PROMPT)
        prompt = source.to_s.dup
        raise ArgumentError, "quote rule missing" unless prompt.scan(QUOTE_RULE).size == 1
        raise ArgumentError, "declared quote missing" unless prompt.scan(DECLARED_QUOTE).size == 1
        raise ArgumentError, "offset instruction remains" if prompt.include?(OFFSET_INSTRUCTION)
        raise ArgumentError, "declared offsets remain" if prompt.include?(DECLARED_OFFSET)

        prompt
      end

      def schema_copy(schema = TurnPerception.tool_schema)
        copy = schema.deep_dup
        item = copy.dig(:properties, :part_replies, :items)
        raise ArgumentError, "part_replies missing" unless item.is_a?(Hash)

        props = item[:properties]
        raise ArgumentError, "part_replies properties missing" unless props.is_a?(Hash)
        raise ArgumentError, "start remains" if props.key?(:start) || props.key?(:end)
        raise ArgumentError, "quote missing" unless props[:quote].is_a?(Hash)
        raise ArgumentError, "quote length" unless props.dig(:quote, :maxLength) == ActiveEpisode::MAX_OBSERVATION_CHARS
        raise ArgumentError, "quote required" unless item[:required] == %w[question_id part_id state quote]

        copy
      end

      def prepare_params(message, prompt: nil, schema: nil)
        {
          model_id: TurnInterpreter::MODEL_ID,
          system: [ { text: prompt || prompt_copy } ],
          messages: [ { role: "user", content: [ { text: message.to_s } ] } ],
          inference_config: { temperature: 0, max_tokens: TurnInterpreter::MAX_TOKENS },
          tool_config: {
            tools: [
              {
                tool_spec: {
                  name: TurnInterpreter::TOOL_NAME,
                  description: "Classify one technician turn.",
                  input_schema: { json: schema || schema_copy }
                }
              }
            ],
            tool_choice: { tool: { name: TurnInterpreter::TOOL_NAME } }
          }
        }
      end

      def fingerprint(text)
        Digest::SHA256.hexdigest(text.to_s)
      end

      def schema_fingerprint(schema)
        Digest::SHA256.hexdigest(JSON.generate(schema))
      end

      delegate :locate, :adapt, to: TurnPerception

      # Coverage of each sentence by a conserved phrase. A shorter fragment,
      # or the sentence sitting inside a longer stored string, is not the
      # sentence.
      def phrase_coverage(turn, conserved_texts)
        texts = Array(conserved_texts).map { |text| text.to_s }
        sentences(turn).map { |sentence| sentence_coverage(sentence, texts) }
      end

      def reading(rows)
        indexed = Array(rows).index_by { |row| row["id"].to_s }
        cases = {}
        CASE_IDS.each do |id|
          row = indexed[id]
          cases[id] = row.is_a?(Hash) ? case_reading(id, row) : { "conservation" => false, "association" => false, "missing" => true }
        end
        if indexed["led"].is_a?(Hash) && indexed["mixed"].is_a?(Hash)
          same = led_answer?(indexed["led"]) && led_answer?(indexed["mixed"])
          cases["led"]["association"] = same
          cases["mixed"]["association"] = same
          cases["led"]["same_answer"] = same
          cases["mixed"]["same_answer"] = same
        end
        conservation = cases.values.all? { |item| item["conservation"] }
        association = cases.values.all? { |item| item["association"] }
        {
          "cases" => cases,
          "conservation" => conservation,
          "association" => association,
          "partial" => conservation && !association,
          "quote_supported" => conservation && association,
          "approves_interpreter" => false,
          "approves_script_2" => false
        }
      end

      private

      def sentences(turn)
        turn.to_s.split(/(?<=[.!?])[[:space:]]+/).map(&:strip).reject(&:empty?)
      end

      def sentence_coverage(sentence, texts)
        body = sentence.sub(/[.!?]+\z/, "")
        pieces = texts.map { |text| text.sub(/[.!?]+\z/, "") }.select { |piece| piece.present? && body.include?(piece) }
        longest = pieces.max_by(&:length)
        conserved = pieces.any? { |piece| piece == body }
        {
          "sentence" => sentence,
          "conserved" => conserved,
          "fragment_only" => !conserved && pieces.any?,
          "only_inside_larger" => !conserved && texts.any? { |text| larger_holder?(text, sentence, body) },
          "covered_chars" => longest ? longest.length : 0,
          "sentence_chars" => body.length
        }
      end

      def larger_holder?(text, sentence, body)
        holder = text.sub(/[.!?]+\z/, "")
        holder.length > body.length && (text.include?(sentence) || holder.include?(body))
      end

      def case_reading(id, row)
        facts = FACTS.fetch(id).map { |wording| { "wording" => wording, "conserved" => fact_conserved?(id, wording, row) } }
        {
          "conservation" => facts.all? { |fact| fact["conserved"] },
          "association" => associated?(id, row),
          "facts" => facts,
          "state" => reply_state(row, "p1"),
          "text" => reply_body(row, "p1"),
          "stored_replies" => Array(row["replies"]).size
        }
      end

      def fact_conserved?(id, wording, row)
        texts = observation_texts(row)
        return code_e4?(row) if id == "code" && wording == CODE_WORDING

        wording_kept?(texts, wording)
      end

      def code_e4?(row)
        texts = observation_texts(row)
        wording_kept?(texts, CODE_WORDING) || wording_kept?(texts, "E4") ||
          reply_body(row, "p1") == CODE_WORDING || fault_value(row) == "E4"
      end

      def associated?(id, row)
        case id
        when "t2", "ac"
          Array(row["replies"]).empty?
        when "led", "mixed"
          led_answer?(row)
        when "code"
          code_answer?(row)
        else
          false
        end
      end

      def led_answer?(row)
        return false unless Array(row["replies"]).one?

        reply_state(row, "p1") == "complete" && reply_body(row, "p1") == LED_WORDING
      end

      def code_answer?(row)
        return false unless Array(row["replies"]).one?

        reply_body(row, "p1") == CODE_WORDING && reply_state(row, "p1") == "partial"
      end

      def wording_kept?(texts, wording)
        Array(texts).any? { |text| text.to_s.sub(/[.!?]+\z/, "") == wording }
      end

      def observation_texts(row)
        Array(row["observations"]).map { |item| item.is_a?(Hash) ? item["text"].to_s : item.to_s }
      end

      def p1_replies(row)
        Array(row["replies"]).select { |reply|
          reply.is_a?(Hash) && (reply["p"].to_s == "p1" || reply["part_id"].to_s == "p1")
        }
      end

      def reply_body(row, part_id)
        return nil unless part_id == "p1"

        replies = p1_replies(row)
        return nil unless replies.one?

        replies.first["text"].to_s.sub(/[.!?]+\z/, "")
      end

      def reply_state(row, part_id)
        return nil unless part_id == "p1"

        replies = p1_replies(row)
        return nil unless replies.one?

        replies.first["state"].to_s
      end

      def fault_value(row)
        facts = row["facts"]
        return nil unless facts.is_a?(Hash)

        code = facts["fault_code"]
        code.is_a?(Hash) ? code["value"].to_s : nil
      end
    end
  end
end
