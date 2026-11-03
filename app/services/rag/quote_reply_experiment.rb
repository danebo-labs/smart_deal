# frozen_string_literal: true

module Rag
  # One-off quote experiment. It copies the current interpreter prompt and
  # schema, resolves a literal quote against the admitted turn, and prepares
  # offsets the current flow can store. It does not change that flow.
  class QuoteReplyExperiment
    PRODUCT_PROMPT_SHA256 = "a5de394a7d87687763b0cd4bd03313ed687a29637698e45e34e05b3aed015b3e"
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
        raise ArgumentError, "offset instruction missing" unless prompt.scan(OFFSET_INSTRUCTION).size == 1
        raise ArgumentError, "declared offsets missing" unless prompt.scan(DECLARED_OFFSET).size == 1

        prompt.sub!(OFFSET_INSTRUCTION, QUOTE_RULE)
        prompt.sub!(DECLARED_OFFSET, DECLARED_QUOTE)
        prompt
      end

      def schema_copy(schema = TurnPerception.tool_schema)
        copy = schema.deep_dup
        item = copy.dig(:properties, :part_replies, :items)
        raise ArgumentError, "part_replies missing" unless item.is_a?(Hash)

        props = item[:properties]
        raise ArgumentError, "part_replies properties missing" unless props.is_a?(Hash)

        props.delete(:start)
        props.delete(:end)
        props[:quote] = { type: "string" }
        item[:required] = %w[question_id part_id state quote]
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

      # Exact substring search on the admitted turn. A normalized match is
      # recorded as a difference and is not an offset.
      def locate(quote, admitted)
        text = admitted.to_s
        unless quote.is_a?(String)
          return { "status" => "quote_not_literal", "difference" => "not_a_string", "quote" => nil }
        end
        if quote.empty?
          return { "status" => "quote_not_literal", "difference" => "blank", "quote" => quote }
        end

        starts = occurrence_indexes(text, quote)
        if starts.one?
          start = starts.first
          finish = start + quote.length
          {
            "status" => "located",
            "start" => start,
            "end" => finish,
            "fragment" => text[start...finish],
            "quote" => quote
          }
        elsif starts.many?
          { "status" => "quote_ambiguous", "count" => starts.size, "quote" => quote }
        else
          {
            "status" => "quote_not_literal",
            "difference" => literal_difference(quote, text),
            "quote" => quote
          }
        end
      end

      def adapt(raw, turn, stored_observations: [])
        data = stringify(raw)
        admitted = AnswerContract.admitted_text(turn)
        resolutions = []
        fragments = []
        if data.key?("part_replies")
          kept = []
          Array(data["part_replies"]).each_with_index do |reply, index|
            reply = stringify(reply)
            reply = {} unless reply.is_a?(Hash)
            found = locate(reply["quote"], admitted)
            resolutions << found.merge(
              "index" => index,
              "state" => reply["state"],
              "question_id" => reply["question_id"],
              "part_id" => reply["part_id"]
            )
            next unless found["status"] == "located"

            fragments << found["fragment"]
            kept << offset_reply(reply, found)
          end
          data["part_replies"] = kept
        end
        observations, notes = incorporate(data["observations"], fragments, admitted, stored_observations)
        if data.key?("observations") || notes.any? { |note| note["result"] == "added" }
          data["observations"] = observations
        end
        {
          "adapted" => data,
          "resolutions" => resolutions,
          "observation_notes" => notes,
          "admitted" => admitted
        }
      end

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

      def occurrence_indexes(text, quote)
        found = []
        from = 0
        while (index = text.index(quote, from))
          found << index
          from = index + 1
        end
        found
      end

      def literal_difference(quote, text)
        return "unicode_normalization" if text.unicode_normalize(:nfc).include?(quote.unicode_normalize(:nfc))
        return "case" if text.downcase.include?(quote.downcase)
        return "whitespace" if collapsed(text).include?(collapsed(quote))

        "absent"
      end

      def collapsed(text)
        text.to_s.gsub(/[[:space:]]+/, " ")
      end

      def offset_reply(reply, found)
        adapted = {
          "question_id" => reply["question_id"],
          "part_id" => reply["part_id"],
          "state" => reply["state"],
          "start" => found["start"],
          "end" => found["end"]
        }
        adapted["supersedes"] = reply["supersedes"] if reply.key?("supersedes")
        adapted
      end

      def incorporate(observations, fragments, turn, stored)
        current = Array(observations).map { |item| item.to_s }
        notes = []
        Array(fragments).each do |fragment|
          reason = observation_block(fragment, turn, current, stored)
          if reason
            notes << { "quote" => fragment, "result" => reason }
          else
            current << fragment
            notes << { "quote" => fragment, "result" => "added" }
          end
        end
        [ current, notes ]
      end

      def observation_block(quote, turn, current, stored)
        return "over_length" if quote.length > ActiveEpisode::MAX_OBSERVATION_CHARS
        return "not_symptom" unless symptom?(quote)
        return "not_literal" unless existing_literal?(quote, turn)

        labels = (current + Array(stored)).map { |text| ObservationText.normalize(text) }
        return "duplicate" if ObservationText.redundant?(quote, labels)
        return "cap_reached" if current.size >= ActiveEpisode::MAX_OBSERVATIONS

        nil
      end

      def symptom?(quote)
        gate.send(:symptom_observation?, quote)
      end

      def existing_literal?(quote, turn)
        perception = TurnPerception.allocate
        perception.instance_variable_set(:@turn, turn)
        perception.send(:literal_span?, quote)
      end

      def gate
        TurnPerception.allocate
      end

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

      def stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), out| out[key.to_s] = stringify(item) }
        when Array
          value.map { |item| stringify(item) }
        else
          value
        end
      end
    end
  end
end
