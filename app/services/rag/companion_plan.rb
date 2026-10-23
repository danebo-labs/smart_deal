# frozen_string_literal: true

module Rag
  # One companion turn as a forced tool call. The model chooses links between
  # case facts and numbered source statements, the step ids, and at most one
  # question. Rag::CompanionPlanCheck drops what the sources and the case do
  # not support, and Rag::CompanionPlanRender writes the answer, so the
  # documentary words of the answer are copied from the sources and not
  # generated.
  class CompanionPlan
    TOOL_NAME = "companion_plan"
    MAX_TOKENS = 1200
    SYSTEM_PROMPT_PATH = Rails.root.join("app/prompts/bedrock/companion_plan.txt")
    STATEMENT_KINDS = %w[heading item step text warning conflict].freeze

    TOOL_SCHEMA = {
      "type" => "object",
      "properties" => {
        "links" => {
          "type" => "array",
          "maxItems" => CompanionPlanCheck::MAX_LINKS,
          "items" => {
            "type" => "object",
            "properties" => {
              "fact" => { "type" => "string", "description" => "Id del hecho del caso, p. ej. O1 o C1." },
              "statement" => { "type" => "string", "description" => "Id de la afirmación, p. ej. S2.4." },
              "reading" => { "type" => "string", "description" => "Lectura breve de Danebo." }
            },
            "required" => %w[fact statement reading]
          }
        },
        "steps" => {
          "type" => "array",
          "maxItems" => CompanionPlanCheck::MAX_STEPS,
          "items" => { "type" => "string", "description" => "Id de un paso, p. ej. S1.3." }
        },
        "question" => { "type" => "string", "description" => "Una pregunta o vacío." }
      },
      "required" => %w[links steps question]
    }.freeze

    Prepared = Data.define(:params, :system, :user, :facts, :statements, :turns)
    Composed = Data.define(:text, :check, :input, :stop_reason)

    class << self
      def prepare(raw_question:, chunks:, episode:, session:, correlation_id: nil)
        facts = CompanionCaseFacts.build(episode, session: session)
        statements = CompanionStatements.parse(chunks)
        turns_block = SessionContextBuilder.companion_technician_turns(
          session, current_message: raw_question, current_correlation_id: correlation_id
        )
        user = [
          "Mensaje de este turno:\n#{raw_question.to_s.strip}",
          facts.prompt_block,
          turns_block,
          SessionContextBuilder.companion_prior_answer(session),
          statements_block(statements, chunks)
        ].compact_blank.join("\n\n")
        system = SYSTEM_PROMPT_PATH.read
        Prepared.new(
          params: params(system, user),
          system: system,
          user: user,
          facts: facts,
          statements: statements,
          turns: technician_turns(session, raw_question)
        )
      end

      def compose(response, prepared)
        input = tool_input(response)
        stop_reason = response.respond_to?(:stop_reason) ? response.stop_reason.to_s.presence : nil
        check = CompanionPlanCheck.call(
          input, facts: prepared.facts, statements: prepared.statements, turns: prepared.turns
        )
        text = check.usable? ? CompanionPlanRender.call(check, facts: prepared.facts, statements: prepared.statements) : ""
        Composed.new(text: text, check: check, input: input, stop_reason: stop_reason)
      end

      def tool_input(response)
        content = response&.output&.message&.content
        Array(content).each do |block|
          tool_use = block.respond_to?(:tool_use) ? block.tool_use : nil
          next unless tool_use && tool_use.name == TOOL_NAME

          input = tool_use.input
          return input.is_a?(Hash) ? input.deep_stringify_keys : {}
        end
        nil
      end

      def statements_block(statements, chunks)
        lines = [ "Documentación (afirmaciones numeradas; usa sus ids):" ]
        Array(chunks).each_with_index do |chunk, index|
          source = index + 1
          listed = statements.by_source(source).select { |item| STATEMENT_KINDS.include?(item.kind) }
          next if listed.empty?

          lines << source_heading(chunk, source)
          listed.each { |item| lines << statement_line(item) }
        end
        lines.size > 1 ? lines.join("\n") : ""
      end

      private

      def params(system, user)
        {
          model_id: BedrockClient::QUERY_MODEL_ID,
          system: [ { text: system } ],
          messages: [ { role: "user", content: [ { text: user } ] } ],
          inference_config: { temperature: 0, max_tokens: MAX_TOKENS },
          tool_config: {
            tools: [ {
              tool_spec: {
                name: TOOL_NAME,
                description: "Plan de orientación de este turno, con ids del caso y de la documentación.",
                input_schema: { json: TOOL_SCHEMA }
              }
            } ],
            tool_choice: { tool: { name: TOOL_NAME } }
          }
        }
      end

      def source_heading(chunk, source)
        metadata = (chunk[:metadata] || chunk["metadata"]).to_h.stringify_keys
        name = metadata["canonical_name"].presence || metadata["original_filename"].presence || "documento sin nombre"
        page = metadata["page_number"].presence
        definition = metadata["definition_of"].presence
        heading = "[#{source}] #{name}"
        heading += ", página #{page}" if page
        heading += ", definición añadida de #{definition}" if definition
        heading
      end

      def statement_line(item)
        label = case item.kind
        when "heading" then "título"
        when "item" then "síntoma o apartado"
        when "step" then "paso de «#{item.item}»"
        when "warning" then "advertencia"
        when "conflict" then "nota de conflicto"
        else "texto"
        end
        "#{item.id} (#{label}): #{item.text}"
      end

      def technician_turns(session, raw_question)
        texts = [ raw_question.to_s ]
        if session.respond_to?(:conversation_history)
          SessionContextBuilder.companion_episode_user_messages(session).each do |message|
            texts << SessionContextBuilder.companion_message_text(message)
          end
        end
        texts.compact_blank
      end
    end
  end
end
