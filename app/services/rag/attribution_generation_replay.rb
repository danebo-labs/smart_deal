# frozen_string_literal: true

module Rag
  # Generation-only comparison for the captured phase-2 prompt.
  # It rebuilds that prompt and refuses unless the only differences are the
  # three field-guidance lines, the attribution contract, and the two
  # general-inference clauses. With RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE=1 the
  # same blocks may move into system and user. The gate compares each block's
  # exact text and order with the single prompt. It does not call the prompt
  # constructor again, and any other split is prompt_delta. A refusal would
  # show that this split was not enough for the captured case. A pass would
  # support this configuration for that capture. Neither identifies one cause
  # or general reliability. It does not call a model unless
  # PHASE2_ATTRIBUTION_GENERATION_AUTHORIZED=1.
  # Two calls repeat one prompt. They do not measure general reliability.
  # Correlations are phase2:attr:gen:<tag>:1 and :2. The tag defaults to
  # voices, or system when that split is on and no tag was set.
  # Historical phase2:attr:gen:1 and phase2:attr:gen:2 are not reused.
  class AttributionGenerationReplay
    AUTHORIZED_ENV = "PHASE2_ATTRIBUTION_GENERATION_AUTHORIZED"
    CORRELATION_TAG_ENV = "PHASE2_ATTRIBUTION_CORRELATION_TAG"
    MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    TEMPERATURE = 0.1
    MAX_TOKENS = 3000
    DEFAULT_CORRELATION_TAG = "voices"
    # Lowercase token. Colons stay the correlation separators, so a tag cannot
    # recreate phase2:attr:gen:1 or phase2:attr:gen:2.
    CORRELATION_TAG_PATTERN = /\A[a-z][a-z0-9_]{0,31}\z/
    HISTORICAL_CORRELATIONS = %w[phase2:attr:gen:1 phase2:attr:gen:2].freeze
    SESSION_HEADINGS = [
      "## Active Field Problem",
      "## Session Focus",
      "## Recent Conversation",
      "## Session Discipline",
      "## Query Resolution"
    ].freeze
    USER_HEADINGS = [ "# CONTEXT", *SESSION_HEADINGS, "# FINAL LANGUAGE REMINDER" ].freeze
    CONTEXT_HEADING = "# CONTEXT"
    LANGUAGE_HEADING = "# LANGUAGE AND TONE"
    FOOTER_HEADING = "# FINAL LANGUAGE REMINDER"
    PROMPT_HEADINGS = [
      "# RESPONSE LANGUAGE (ABSOLUTE PRIORITY)",
      "# ROLE",
      "# CONTEXT",
      "# LANGUAGE AND TONE",
      "# EVIDENCE CONTRACT",
      "# DOCUMENT IDENTITY",
      "# RESPONSE SELECTION",
      "# NO MATCH",
      "# FORMAT",
      "# DISCRIMINATING QUESTION",
      "# DELIVERY CHANNEL",
      *SESSION_HEADINGS,
      "# FINAL LANGUAGE REMINDER",
      "# DOCUMENT IDENTITY ATTRIBUTION"
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

    Result = Data.define(
      :status, :reason, :prompt, :prompt_sha256, :system_sha256, :user_sha256, :generations, :output_dir
    ) do
      def allowed?
        status == "ready"
      end

      def to_h
        {
          "status" => status,
          "reason" => reason,
          "prompt_sha256" => prompt_sha256,
          "system_sha256" => system_sha256,
          "user_sha256" => user_sha256,
          "output_dir" => output_dir&.to_s,
          "generations" => generations
        }.compact
      end
    end

    def self.preview(captured_prompt:, account:)
      new(captured_prompt: captured_prompt, account: account).preview
    end

    def self.write_preview(captured_prompt:, account:, output_dir:)
      new(captured_prompt: captured_prompt, account: account, output_dir: output_dir).write_preview
    end

    def self.run(captured_prompt:, account:, client:, output_dir:, correlation_tag: ENV[CORRELATION_TAG_ENV])
      new(
        captured_prompt: captured_prompt,
        account: account,
        client: client,
        output_dir: output_dir,
        correlation_tag: correlation_tag
      ).run
    end

    def self.correlation_tag(raw = ENV[CORRELATION_TAG_ENV])
      normalize_correlation_tag(raw)
    end

    def self.correlations_for(raw = ENV[CORRELATION_TAG_ENV])
      tag = normalize_correlation_tag(raw)
      return if tag.nil?

      ids = [ 1, 2 ].map { |index| "phase2:attr:gen:#{tag}:#{index}" }
      return if (ids & HISTORICAL_CORRELATIONS).any?

      ids
    end

    def self.normalize_correlation_tag(raw)
      text = raw.to_s.strip
      text = DEFAULT_CORRELATION_TAG if text.empty?
      text.match?(CORRELATION_TAG_PATTERN) ? text : nil
    end
    private_class_method :normalize_correlation_tag

    def self.field_guidance_lines
      Rails.root.join("app/prompts/bedrock/generation.txt").each_line.filter_map { |line|
        next unless line.start_with?("#{BedrockRagService::FIELD_GUIDANCE_PROMPT_PREFIX} ")

        "- #{line.delete_prefix("#{BedrockRagService::FIELD_GUIDANCE_PROMPT_PREFIX} ")}"
      }
    end

    def initialize(captured_prompt:, account:, client: nil, output_dir: nil, correlation_tag: nil)
      @captured_prompt = utf8_text(captured_prompt)
      @account = account
      @client = client
      @output_dir = output_dir
      @correlation_tag = correlation_tag
    end

    def preview
      return refuse("encoding") unless @captured_prompt.encoding == Encoding::UTF_8 && @captured_prompt.valid_encoding?

      pieces = extract(@captured_prompt)
      return pieces if pieces.is_a?(Result)

      current = render_prompt(pieces)
      return current if current.is_a?(Result)

      unique = if current.system.nil?
        current.to_s
      else
        reference = without_system_role { render_prompt(pieces) }
        return reference if reference.is_a?(Result)

        reference.to_s
      end
      return refuse("prompt_delta") unless allowed_delta?(@captured_prompt, unique)
      return ready(unique) if current.system.nil?
      return refuse("prompt_delta") unless partition_matches?(unique, current)

      ready(
        current,
        prompt_sha256: Digest::SHA256.hexdigest(unique),
        system_sha256: Digest::SHA256.hexdigest(current.system),
        user_sha256: Digest::SHA256.hexdigest(current.user)
      )
    end

    def write_preview
      checked = preview
      return checked unless checked.allowed?

      directory = Pathname(@output_dir)
      FileUtils.mkdir_p(directory)
      user_text, system_text = generation_parts(checked.prompt)
      user_sha = Digest::SHA256.hexdigest(user_text)
      request = {
        "model_id" => MODEL_ID,
        "temperature" => TEMPERATURE,
        "max_tokens" => MAX_TOKENS,
        "anthropic_version" => "bedrock-2023-05-31",
        "prompt_sha256" => user_sha,
        "user_sha256" => user_sha,
        "messages" => [ { "role" => "user", "content_sha256" => user_sha } ],
        "correlation_ids" => correlations_for(checked),
        "provenance" => "reconstructed",
        "sent" => false
      }
      request["system_sha256"] = Digest::SHA256.hexdigest(system_text) if system_text
      File.binwrite(directory.join("prompt.txt"), user_text)
      File.binwrite(directory.join("system.txt"), system_text) if system_text
      File.write(directory.join("request.json"), JSON.pretty_generate(request))
      File.write(directory.join("gate.json"), JSON.pretty_generate(checked.to_h.merge(
        "authorized" => false,
        "model_called" => false,
        "request_provenance" => "reconstructed"
      )))
      lines = [ "prompt #{request['prompt_sha256']}" ]
      lines << "system #{request['system_sha256']}" if request["system_sha256"]
      lines << "unique #{checked.prompt_sha256}"
      File.write(directory.join("sha256.txt"), "#{lines.join("\n")}\n")
      checked
    end

    def run
      checked = preview
      return checked unless checked.allowed?
      return refuse("authorization_absent") unless authorized?
      return refuse("budget_armed") if budget_armed?

      correlations = correlations_for(checked)
      return refuse("correlation_tag") if correlations.nil?
      return refuse("client_absent") unless @client.respond_to?(:generate_text)

      record(checked, correlations)
    end

    private

    def render_prompt(pieces)
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

    # Cuts the single prompt at the three blocks the partition moves. It does
    # not call document_identity_generation_prompt.
    def partition_matches?(unique, prompt)
      return false if prompt.system.blank? || prompt.user.blank?

      context, session, footer = moved_blocks(unique)
      return false if context.nil? || session.nil? || footer.nil?
      return false unless context_intact?(unique, prompt.user, context, session)
      return false if prompt.user.include?("# DOCUMENT IDENTITY ATTRIBUTION\n")
      return false if prompt.user.include?("# EVIDENCE CONTRACT\n")
      return false if prompt.system.include?("#{CONTEXT_HEADING}\n")
      return false if prompt.system.include?("#{SESSION_HEADINGS.first}\n")
      return false if prompt.system.include?("#{FOOTER_HEADING}\n")

      expected_user = [ context, session, footer ].join("\n\n")
      expected_system = system_after_moves(unique, context, session, footer)
      return false if expected_system.nil?

      expected_system == prompt.system && expected_user == prompt.user
    end

    def moved_blocks(unique)
      context_at = unique.index("#{CONTEXT_HEADING}\nQuery: ")
      language_at = unique.index("\n\n#{LANGUAGE_HEADING}\n", context_at || 0)
      return if context_at.nil? || language_at.nil? || language_at < context_at

      context = unique[context_at...language_at]
      session_at = unique.index("#{SESSION_HEADINGS.first}\n", language_at)
      footer_at = unique.index("\n\n#{FOOTER_HEADING}\n", session_at || 0)
      return if session_at.nil? || footer_at.nil?

      session = unique[session_at...footer_at]
      closing = unique.index("\n\n", footer_at + 2)
      return if closing.nil?

      footer = unique[(footer_at + 2)...closing]
      return unless context.present? && session.present? && footer.start_with?("#{FOOTER_HEADING}\n")

      [ context, session, footer ]
    end

    def system_after_moves(unique, context, session, footer)
      without_context = unique.sub(context, "")
      return if without_context == unique

      without_session = excise_block(without_context, session)
      return if without_session.nil?

      excise_block(without_session, footer)
    end

    def excise_block(text, block)
      needle = "\n\n#{block}"
      return unless text.include?(needle)

      text.sub(needle, "")
    end

    def context_intact?(unique, user, context, session)
      query = context[/\A# CONTEXT\nQuery: (.*)\nResults: /, 1]
      results = context.sub(/\A# CONTEXT\nQuery: .*\nResults: /, "")
      return false if query.blank? || results.blank? || session.blank?
      return false unless user.include?("#{CONTEXT_HEADING}\nQuery: #{query}\nResults: #{results}")
      return false unless user.include?(session)

      count = context.scan("<search_result>").size
      count.positive? && count == unique.scan("<search_result>").size && user.scan("<search_result>").size == count
    end

    def correlations_for(checked)
      explicit = @correlation_tag
      explicit = ENV[CORRELATION_TAG_ENV] if explicit.nil?
      explicit = "system" if explicit.to_s.strip.empty? && checked.system_sha256.present?
      self.class.correlations_for(explicit)
    end

    def without_system_role
      key = "RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"
      previous = ENV[key]
      ENV.delete(key)
      yield
    ensure
      previous.nil? ? ENV.delete(key) : ENV[key] = previous
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
      transformed = BedrockRagService.withhold_document_identity_inference(transformed)
      transformed == candidate
    end

    def record(checked, correlations)
      directory = Pathname(@output_dir)
      FileUtils.mkdir_p(directory)
      user_text, system_text = generation_parts(checked.prompt)
      generations = []
      correlations.each_with_index do |correlation, index|
        events = ValidationCapture.capture do
          @client.generate_text(
            user_text,
            system: system_text,
            model_id: MODEL_ID,
            max_tokens: MAX_TOKENS,
            temperature: TEMPERATURE,
            tracking: { correlation_id: correlation }
          )
        end
        generations << write_generation(directory, index + 1, correlation, user_text, system_text, events)
        returned = events.find { |event| event["kind"] == "generation_result" && event["result"] == "returned" }
        break if returned.nil? || returned["answer"].blank?
      end
      Result.new(
        status: "recorded",
        reason: nil,
        prompt: checked.prompt,
        prompt_sha256: checked.prompt_sha256,
        system_sha256: checked.system_sha256,
        user_sha256: checked.user_sha256,
        generations: generations,
        output_dir: directory
      )
    end

    def generation_parts(prompt)
      if prompt.respond_to?(:system) && prompt.system.present?
        [ prompt.user.to_s, prompt.system.to_s ]
      else
        [ prompt.to_s, nil ]
      end
    end

    def write_generation(directory, index, correlation, user_text, system_text, events)
      folder = directory.join(format("gen_%d", index))
      FileUtils.mkdir_p(folder)
      prepared = events.find { |event| event["kind"] == "generate_text" && event["result"] == "prepared" } || {}
      returned = events.find { |event| event["kind"] == "generation_result" } || {}
      request = {
        "model_id" => prepared.fetch("model_id", MODEL_ID),
        "temperature" => prepared.fetch("temperature", TEMPERATURE),
        "max_tokens" => prepared.fetch("max_tokens", MAX_TOKENS),
        "correlation_id" => correlation,
        "prompt_sha256" => Digest::SHA256.hexdigest(user_text),
        "user_sha256" => Digest::SHA256.hexdigest(user_text)
      }
      request["system_sha256"] = Digest::SHA256.hexdigest(system_text) if system_text.present?
      usage = {
        "input_tokens" => returned.fetch("input_tokens", "unavailable"),
        "output_tokens" => returned.fetch("output_tokens", "unavailable")
      }
      File.write(folder.join("request.json"), JSON.pretty_generate(request))
      File.binwrite(folder.join("prompt.txt"), user_text)
      File.binwrite(folder.join("system.txt"), system_text) if system_text.present?
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

    def ready(prompt, prompt_sha256: nil, system_sha256: nil, user_sha256: nil)
      Result.new(
        status: "ready",
        reason: nil,
        prompt: prompt,
        prompt_sha256: prompt_sha256 || Digest::SHA256.hexdigest(prompt.to_s),
        system_sha256: system_sha256,
        user_sha256: user_sha256,
        generations: nil,
        output_dir: nil
      )
    end

    def refuse(reason)
      Result.new(
        status: "refused",
        reason: reason,
        prompt: nil,
        prompt_sha256: nil,
        system_sha256: nil,
        user_sha256: nil,
        generations: nil,
        output_dir: nil
      )
    end
  end
end
