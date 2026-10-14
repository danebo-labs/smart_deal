# frozen_string_literal: true

module Rag
  # Generation-only comparison for the captured phase-2 prompt.
  # It rebuilds that prompt, refuses unless the only differences are the three
  # field-guidance lines and the attribution contract, and does not call a
  # model unless PHASE2_ATTRIBUTION_GENERATION_AUTHORIZED=1.
  # Two calls repeat one prompt. They do not measure general reliability.
  class AttributionGenerationReplay
    AUTHORIZED_ENV = "PHASE2_ATTRIBUTION_GENERATION_AUTHORIZED"
    MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    TEMPERATURE = 0.1
    MAX_TOKENS = 3000
    CORRELATIONS = %w[phase2:attr:gen:1 phase2:attr:gen:2].freeze
    SESSION_HEADINGS = [
      "## Active Field Problem",
      "## Session Focus",
      "## Recent Conversation",
      "## Session Discipline",
      "## Query Resolution"
    ].freeze
    # The contract text present in turn_2/bodies/b0005.txt of 20261013T233715Z.
    CAPTURED_CONTRACT = <<~TEXT.strip.freeze
      # DOCUMENT IDENTITY ATTRIBUTION
      When a function or a specification is attributed to the drawing, this contract takes precedence over the general instruction to state what is obvious for that kind of component. What is obvious is not a statement of the drawing.

      - A printed label, a column heading, or a bus name does not by itself prove that component's function, supply, or connection.
      - A claim presented as what the drawing states must be supported by the retrieved text and explicitly linked to the component asked about. Compatible fragments that document that same link may be combined. Do not transfer a fact from another component.
      - The physical-connection rule and TOPOLOGY_EDGE records above remain in force.
      - An allowed interpretation is identified as inference and cites only the documented premises it uses. That citation does not make the conclusion text of the drawing. Do not infer an electrical specification from a bus name.
      - When support is missing, limit the absence to the passages in this prompt. Do not say the whole document lacks the datum.
      - Do not state a function as documented and then deny it.
      - Name another sheet as the documentary location of this component only when the evidence links that component to that sheet.
      - A supported location or label may still be answered when the function is missing.
    TEXT

    Result = Data.define(:status, :reason, :prompt, :prompt_sha256, :generations, :output_dir) do
      def allowed?
        status == "ready"
      end

      def to_h
        {
          "status" => status,
          "reason" => reason,
          "prompt_sha256" => prompt_sha256,
          "output_dir" => output_dir&.to_s,
          "generations" => generations
        }.compact
      end
    end

    def self.preview(captured_prompt:, account:)
      new(captured_prompt: captured_prompt, account: account).preview
    end

    def self.run(captured_prompt:, account:, client:, output_dir:)
      new(captured_prompt: captured_prompt, account: account, client: client, output_dir: output_dir).run
    end

    def self.field_guidance_lines
      Rails.root.join("app/prompts/bedrock/generation.txt").each_line.filter_map { |line|
        next unless line.start_with?("#{BedrockRagService::FIELD_GUIDANCE_PROMPT_PREFIX} ")

        "- #{line.delete_prefix("#{BedrockRagService::FIELD_GUIDANCE_PROMPT_PREFIX} ")}"
      }
    end

    def initialize(captured_prompt:, account:, client: nil, output_dir: nil)
      @captured_prompt = utf8_text(captured_prompt)
      @account = account
      @client = client
      @output_dir = output_dir
    end

    def preview
      return refuse("encoding") unless @captured_prompt.encoding == Encoding::UTF_8 && @captured_prompt.valid_encoding?

      prompt = candidate_prompt
      return prompt if prompt.is_a?(Result)

      return refuse("prompt_delta") unless allowed_delta?(@captured_prompt, prompt)

      ready(prompt)
    end

    def run
      checked = preview
      return checked unless checked.allowed?
      return refuse("authorization_absent") unless authorized?
      return refuse("budget_armed") if budget_armed?
      return refuse("client_absent") unless @client.respond_to?(:generate_text)

      record(checked.prompt)
    end

    private

    def candidate_prompt
      pieces = extract(@captured_prompt)
      return pieces if pieces.is_a?(Result)

      prompt = with_captured_flags do
        service = BedrockRagService.new(account: @account, knowledge_base_id: "attribution-replay")
        service.send(
          :document_identity_generation_prompt,
          pieces.fetch(:question),
          pieces.fetch(:chunks),
          labels: pieces.fetch(:labels),
          response_locale: :es,
          session_context: pieces.fetch(:session_context),
          output_channel: :web
        )
      end
      rebuilt = DocumentIdentityScope.generation_context(pieces.fetch(:chunks), pieces.fetch(:labels))
      return refuse("search_results_changed") unless rebuilt == pieces.fetch(:search_results)

      prompt
    end

    def extract(captured)
      question = captured[/(?:\A|\n)# CONTEXT\nQuery: (.*)\nResults: /, 1]
      return refuse("query_absent") if question.blank?

      results_start = captured.index("Results: ")
      language_at = captured.index("\n\n# LANGUAGE AND TONE\n", results_start || 0)
      return refuse("search_results_absent") if results_start.nil? || language_at.nil?

      search_results = captured[(results_start + "Results: ".length)...language_at]
      parsed = parse_search_results(search_results)
      return parsed if parsed.is_a?(Result)

      session_start = captured.index("#{SESSION_HEADINGS.first}\n")
      footer_at = captured.index("\n\n# FINAL LANGUAGE REMINDER\n", session_start || 0)
      return refuse("session_absent") if session_start.nil? || footer_at.nil?

      session_context = captured[session_start...footer_at]
      return refuse("session_absent") unless SESSION_HEADINGS.all? { |heading| session_context.include?(heading) }

      parsed.merge(question: question, session_context: session_context, search_results: search_results)
    end

    def parse_search_results(search_results)
      preamble = "#{DocumentIdentityScope::PREAMBLE}\n"
      return refuse("search_results_absent") unless search_results.start_with?(preamble)

      body = search_results.delete_prefix(preamble)
      matches = body.scan(%r{<search_result>\n<content>\n(.*?)\n</content>\n<source>\n(\d+)\n</source>\n</search_result>}m)
      return refuse("search_results_absent") if matches.empty?
      return refuse("search_results_changed") unless matches.map { |_content, source| source.to_i } == (1..matches.size).to_a

      labels = []
      chunks = matches.map do |content, _source|
        label, rest = split_label(content)
        labels << label
        { content: rest }
      end
      { chunks: chunks, labels: labels }
    end

    def split_label(content)
      first, rest = content.split("\n", 2)
      return [ nil, content ] if first.blank?
      return [ first, rest.to_s ] if first.start_with?("THIS JOB'S EQUIPMENT:") || first.start_with?(DocumentIdentityScope::OTHER_EQUIPMENT_PREFIX)

      [ nil, content ]
    end

    def allowed_delta?(captured, candidate)
      return false unless captured.include?(CAPTURED_CONTRACT)

      omitted = self.class.field_guidance_lines.map(&:chomp)
      return false unless omitted.size == 3

      transformed = captured.lines.reject { |line| omitted.include?(line.chomp) }.join
      transformed = transformed.sub(CAPTURED_CONTRACT, BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT)
      transformed == candidate
    end

    def record(prompt)
      directory = Pathname(@output_dir)
      FileUtils.mkdir_p(directory)
      generations = []
      CORRELATIONS.each_with_index do |correlation, index|
        events = ValidationCapture.capture do
          @client.generate_text(
            prompt,
            model_id: MODEL_ID,
            max_tokens: MAX_TOKENS,
            temperature: TEMPERATURE,
            tracking: { correlation_id: correlation }
          )
        end
        generations << write_generation(directory, index + 1, correlation, prompt, events)
        returned = events.find { |event| event["kind"] == "generation_result" && event["result"] == "returned" }
        break if returned.nil? || returned["answer"].blank?
      end
      Result.new(
        status: "recorded",
        reason: nil,
        prompt: prompt,
        prompt_sha256: Digest::SHA256.hexdigest(prompt),
        generations: generations,
        output_dir: directory
      )
    end

    def write_generation(directory, index, correlation, prompt, events)
      folder = directory.join(format("gen_%d", index))
      FileUtils.mkdir_p(folder)
      prepared = events.find { |event| event["kind"] == "generate_text" && event["result"] == "prepared" } || {}
      returned = events.find { |event| event["kind"] == "generation_result" } || {}
      request = {
        "model_id" => prepared.fetch("model_id", MODEL_ID),
        "temperature" => prepared.fetch("temperature", TEMPERATURE),
        "max_tokens" => prepared.fetch("max_tokens", MAX_TOKENS),
        "correlation_id" => correlation,
        "prompt_sha256" => Digest::SHA256.hexdigest(prompt)
      }
      usage = {
        "input_tokens" => returned.fetch("input_tokens", "unavailable"),
        "output_tokens" => returned.fetch("output_tokens", "unavailable")
      }
      File.write(folder.join("request.json"), JSON.pretty_generate(request))
      File.binwrite(folder.join("prompt.txt"), prompt)
      File.binwrite(folder.join("response.txt"), returned["answer"].to_s)
      File.write(folder.join("usage.json"), JSON.pretty_generate(usage))
      { "correlation_id" => correlation, "request" => request, "response" => { "text" => returned["answer"] }, "usage" => usage }
    end

    def with_captured_flags
      previous = {
        "RAG_GROUNDED_SYNTHESIS_ENABLED" => ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"],
        "RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS" => ENV["RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS"],
        "RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED" => ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"]
      }
      ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "true"
      ENV.delete("RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS")
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
      yield
    ensure
      previous.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    def utf8_text(value)
      text = value.to_s.dup
      return text unless text.encoding == Encoding::ASCII_8BIT

      utf8 = text.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : text.force_encoding(Encoding::ASCII_8BIT)
    end

    def authorized?
      ENV[AUTHORIZED_ENV] == "1"
    end

    def budget_armed?
      (defined?(Phase2ModelBudget) && Phase2ModelBudget.armed?) ||
        (defined?(Phase1ModelBudget) && Phase1ModelBudget.armed?)
    end

    def ready(prompt)
      Result.new(
        status: "ready",
        reason: nil,
        prompt: prompt,
        prompt_sha256: Digest::SHA256.hexdigest(prompt),
        generations: nil,
        output_dir: nil
      )
    end

    def refuse(reason)
      Result.new(status: "refused", reason: reason, prompt: nil, prompt_sha256: nil, generations: nil, output_dir: nil)
    end
  end
end
