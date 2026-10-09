# frozen_string_literal: true

module Rag
  # Isolated interpreter comparison. It builds TurnInterpreter's request,
  # translates it, and stops before any provider call. It does not write an
  # episode, does not call TurnPerception, and does not replace BedrockClient.
  class InterpreterAnthropicExperiment
    LIVE_CALLS_ENABLED = false
    LANES = %w[prepared stubs].freeze
    PHASE1_TEXT = "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. " \
                  "Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta " \
                  "y cómo se relaciona con las demás seguridades?"
    ACTIVE_GOAL = "problema de puerta en el nivel 2"
    ACTIVE_CONTEXT_ID = "ep_experiment_active"
    MODELS = InterpreterAnthropicAdapter::ACCEPTED_MODELS

    class Error < StandardError
      attr_reader :code

      def initialize(code, message = nil)
        @code = code
        super(message || code)
      end
    end

    class Budget
      # One observed Bedrock interpreter call on the phase 1 text used 2174
      # input tokens. 2500 reserves that call plus the active-context JSON.
      # 3500 is 2500 x 1.4, above the documented ~30% Haiku 5.5 tokenizer
      # increase. These are reservations, not counts from the token API.
      INPUT_RESERVATION = {
        InterpreterAnthropicAdapter::HAIKU_45 => 2500,
        InterpreterAnthropicAdapter::HAIKU_55 => 3500
      }.freeze
      OUTPUT_RESERVATION = TurnInterpreter::MAX_TOKENS

      def self.attempt_cap
        InterpreterAnthropicExperiment.matrix.size * MODELS.size
      end

      def self.reservation_usd(model_id)
        rates = InterpreterAnthropicAdapter::RATES.fetch(model_id)
        input = INPUT_RESERVATION.fetch(model_id)
        (BigDecimal(input) * rates[:input]) + (BigDecimal(OUTPUT_RESERVATION) * rates[:output])
      end

      def self.money_cap
        MODELS.sum { |model_id| reservation_usd(model_id) * InterpreterAnthropicExperiment.matrix.size }
      end

      # live and credential_present are explicit arguments. Nothing here reads
      # the process environment or a credential store.
      def self.gate(model_id, attempts:, spent_usd:, live:, credential_present:)
        return "live_calls_closed" unless live
        return "attempt_cap" if attempts >= attempt_cap
        return "money_cap" if spent_usd + reservation_usd(model_id) > money_cap
        return "credential_absent" unless credential_present

        nil
      end

      def self.continue_after?(provider_result, cost_status: "priced")
        provider_result == "returned" && cost_status == "priced"
      end
    end

    def self.matrix
      @matrix ||= build_matrix.freeze
    end

    def self.credential_status(explicit_key)
      explicit_key.to_s.empty? ? "absent" : "present"
    end

    def self.prepare(evidence_root:, run_id:)
      new(evidence_root: evidence_root, run_id: run_id, lane: "prepared").prepare
    end

    def self.rehearse(evidence_root:, run_id:, scenario_id:, model_id:, native:, latency_ms: nil)
      new(evidence_root: evidence_root, run_id: run_id, lane: "stubs").rehearse(
        scenario_id: scenario_id, model_id: model_id, native: native, latency_ms: latency_ms
      )
    end

    def self.execute(*)
      raise Error, "live_calls_closed"
    end

    def self.judge(row, tool_input)
      new(evidence_root: ".", run_id: "judge", lane: "prepared").send(:judge, row, tool_input)
    end

    def initialize(evidence_root:, run_id:, lane:)
      raise Error, "runs_closed" if lane.to_s == "runs"
      raise Error, "lane" unless LANES.include?(lane.to_s)

      @evidence_root = Pathname(evidence_root)
      @run_id = run_id.to_s
      @lane = lane.to_s
    end

    def prepare
      raise Error, "lane" unless @lane == "prepared"

      root = run_dir
      FileUtils.mkdir_p(root)
      events = ValidationCapture.capture do
        ValidationCapture.bind(run_id: @run_id)
        record_configuration
        self.class.matrix.each do |row|
          MODELS.each { |model_id| write_blocked(row, model_id) }
        end
      end
      write_capture(root, events)
      { "lane" => @lane, "run_id" => @run_id, "cases" => self.class.matrix.size * MODELS.size, "calls" => 0 }
    end

    def rehearse(scenario_id:, model_id:, native:, latency_ms: nil)
      raise Error, "runs_closed" unless @lane == "stubs"

      row = self.class.matrix.find { |item| item["id"] == scenario_id }
      raise Error, "scenario" unless row

      root = run_dir
      FileUtils.mkdir_p(root)
      events = ValidationCapture.capture do
        ValidationCapture.bind(run_id: @run_id)
        write_stub(row, model_id, native, latency_ms)
      end
      write_capture(root, events)
      { "lane" => @lane, "provider_call" => false }
    end

    private

    def run_dir
      @evidence_root.join(@lane, @run_id)
    end

    def write_blocked(row, model_id)
      built = build(row, model_id)
      dir = case_dir(row, model_id)
      ValidationCapture.with_turn(correlation(row, model_id)) do
        ValidationCapture.record(
          "interpreter_request",
          "stage" => "converse",
          "result" => "prepared",
          "operation" => "interpreter_experiment",
          "provider" => "anthropic",
          "model_id" => model_id,
          "lane" => @lane,
          "provider_call" => false,
          "request" => built[:params],
          "client_input" => built[:translated]
        )
        ValidationCapture.record(
          "model_call",
          "operation" => "interpreter_experiment",
          "result" => "blocked",
          "reason" => "live_calls_closed",
          "provider_call" => false,
          "lane" => @lane
        )
      end
      write_files(dir, blocked_files(row, model_id, built))
    end

    def write_stub(row, model_id, native, latency_ms)
      built = build(row, model_id)
      outcome = interpret_native(native)
      judgment = outcome[:error] ? not_judged("provider_error") : judge(row, outcome[:tool_input])
      dir = case_dir(row, model_id)
      ValidationCapture.with_turn(correlation(row, model_id)) do
        ValidationCapture.record(
          "interpreter_request",
          "stage" => "converse",
          "result" => "prepared",
          "operation" => "interpreter_experiment",
          "provider" => "anthropic",
          "model_id" => model_id,
          "lane" => "stubs",
          "provider_call" => false,
          "transport" => "injected_native"
        )
        record_stub_outcome(outcome)
        ValidationCapture.record(
          "experiment_judgment",
          "result" => judgment["judgment"],
          "reason" => judgment["reason"],
          "provider_call" => false,
          "lane" => "stubs"
        )
      end
      write_files(dir, stub_files(row, model_id, built, outcome, judgment, latency_ms))
    end

    def record_stub_outcome(outcome)
      if outcome[:error]
        ValidationCapture.record(
          "interpreter_failure",
          "stage" => "converse",
          "result" => "error",
          "operation" => "interpreter_experiment",
          "error_class" => outcome[:error].class.name,
          "reason" => outcome[:error].message,
          "provider_call" => false,
          "lane" => "stubs"
        )
        return
      end

      ValidationCapture.record(
        "interpreter_response",
        "stage" => "extract",
        "result" => "returned",
        "operation" => "interpreter_experiment",
        "provider_call" => false,
        "transport" => "injected_native",
        "lane" => "stubs",
        "response" => outcome[:observed].native
      )
      ValidationCapture.record(
        "interpreter_raw",
        "stage" => "extract",
        "result" => outcome[:tool_input].nil? ? "empty" : "tool_input",
        "tool_input" => outcome[:tool_input],
        "provider_call" => false,
        "lane" => "stubs"
      )
    end

    def interpret_native(native)
      observed = InterpreterAnthropicAdapter.normalize(native)
      {
        observed: observed,
        tool_input: InterpreterAnthropicAdapter.tool_input(observed.output.message.content),
        error: nil
      }
    rescue InterpreterAnthropicAdapter::ProviderError => error
      { observed: nil, tool_input: nil, error: error }
    end

    def build(row, model_id)
      params = converse_params(row)
      translated = InterpreterAnthropicAdapter.translate(params, model_id: model_id)
      prompt = translated.dig("body", "system", 0, "text")
      raise Error, "prompt_drift" unless prompt == TurnInterpreter::PROMPT
      raise Error, "max_tokens" unless translated.dig("body", "max_tokens") == TurnInterpreter::MAX_TOKENS

      { params: params, translated: translated, message: message_payload(translated) }
    end

    def converse_params(row)
      TurnInterpreter.new(
        turn: row["text"],
        episode: episode_for(row["context"]),
        viewer_account: nil,
        correlation_id: "interpreter-experiment:#{row["id"]}",
        attribution: nil,
        client: :closed,
        catalog: :closed
      ).send(:converse_params)
    end

    def episode_for(context)
      episode = ActiveEpisode.new
      return episode if context == "empty"

      episode.episode_id = ACTIVE_CONTEXT_ID
      episode.assign_goal!(ACTIVE_GOAL, correlation_id: "interpreter-experiment")
      episode.append_observation!(ACTIVE_GOAL, correlation_id: "interpreter-experiment")
      episode
    end

    def message_payload(translated)
      text = translated.dig("body", "messages", 0, "content", 0, "text").to_s
      parsed = JSON.parse(text)
      parsed.is_a?(Hash) ? parsed : { "provenance" => "uncaptured" }
    rescue JSON::ParserError
      { "provenance" => "uncaptured" }
    end

    def blocked_files(row, model_id, built)
      {
        "case.json" => case_payload(row, model_id, built),
        "prepared_request.json" => built[:params],
        "client_input.json" => built[:translated],
        "native_response.json" => { "provenance" => "not_executed", "reason" => "live_calls_closed" },
        "normalized.json" => { "provenance" => "not_executed" },
        "tool_input.json" => { "tool_input" => nil, "provenance" => "not_executed" },
        "judgment.json" => expected_and_observed(row, nil, not_judged("not_called")),
        "usage.json" => usage_payload(model_id, nil, nil, "not_called", [])
      }
    end

    def stub_files(row, model_id, built, outcome, judgment, latency_ms)
      if outcome[:error]
        native = outcome[:error].native
        normalized = { "provenance" => "not_executed", "reason" => "provider_error" }
        usage = nil
        errors = [ { "code" => outcome[:error].code, "error_type" => outcome[:error].error_type } ]
        status = "error"
      else
        native = outcome[:observed].native
        normalized = outcome[:observed].normalized
        usage = outcome[:observed].normalized["usage"]
        errors = []
        status = "returned"
      end
      {
        "case.json" => case_payload(row, model_id, built).merge(
          "transport" => "injected_native", "provider_result" => status
        ),
        "prepared_request.json" => built[:params],
        "client_input.json" => built[:translated],
        "native_response.json" => native,
        "normalized.json" => normalized,
        "tool_input.json" => { "tool_input" => outcome[:tool_input], "provider_call" => false },
        "judgment.json" => expected_and_observed(row, outcome[:tool_input], judgment).merge(
          "provider_result" => status, "provider_call" => false
        ),
        "usage.json" => usage_payload(model_id, usage, latency_ms, status, errors)
      }
    end

    def case_payload(row, model_id, built)
      {
        "id" => row["id"],
        "context" => {
          "id" => row["context"],
          "persisted" => false,
          "episode_id" => row["context"] == "active" ? ACTIVE_CONTEXT_ID : nil,
          "work_context" => built[:message]["work_context"]
        },
        "pair_of" => row["pair_of"],
        "text" => row["text"],
        "provider" => "anthropic",
        "model_id" => model_id,
        "lane" => @lane,
        "provider_call" => false,
        "live_calls_enabled" => LIVE_CALLS_ENABLED
      }
    end

    def expected_and_observed(row, tool_input, judgment)
      {
        "expected" => {
          "disposition" => row["disposition"],
          "allowed_moves" => row["allowed_moves"],
          "forbidden_moves" => row["forbidden_moves"],
          "justification" => row["justification"]
        },
        "observed" => tool_input,
        "judgment" => judgment["judgment"],
        "reason" => judgment["reason"]
      }
    end

    def usage_payload(model_id, usage, latency_ms, status, errors)
      priced = InterpreterAnthropicAdapter.price(model_id, usage)
      if %w[not_called error].include?(status)
        priced["cost_status"] = status
        priced["cost_usd"] = nil
      end
      priced["latency_ms"] = latency_ms
      priced["errors"] = errors
      priced["provider_result"] = status
      priced
    end

    def judge(row, tool_input)
      return not_judged("tool_input_absent") unless tool_input.is_a?(Hash)
      return fail_judgment("incomplete_tool_input") unless contract_shape?(tool_input)
      return fail_judgment("forbidden_move") if row["forbidden_moves"].include?(tool_input["move"])
      return fail_judgment("observation_on_non_symptom") if contaminated_observations?(row, tool_input)
      return fail_judgment("assertion_on_non_symptom") if contaminated_assertions?(row, tool_input)
      if !tool_input["clarification_target"].nil? && tool_input["move"] != "unclear"
        return fail_judgment("clarification_target")
      end
      return fail_judgment("move_outside_contract") unless row["allowed_moves"].include?(tool_input["move"])
      return { "judgment" => "review", "reason" => "ambiguous_case" } if row["disposition"] == "review"

      { "judgment" => "pass", "reason" => "allowed_move" }
    end

    def contract_shape?(tool_input)
      return false unless (tool_input.keys - TurnPerception::ROOT_KEYS).empty?
      return false unless (TurnPerception::ROOT_KEYS - tool_input.keys).empty?
      return false unless tool_input["move"].is_a?(String)
      return false unless tool_input["assertions"].is_a?(Array)
      return false unless tool_input["observations"].is_a?(Array)

      true
    end

    def contaminated_observations?(row, tool_input)
      row["empty_observations"] && tool_input["observations"].any? { |item| item.to_s.strip != "" }
    end

    def contaminated_assertions?(row, tool_input)
      row["empty_assertions"] && tool_input["assertions"].any?
    end

    def not_judged(reason)
      { "judgment" => "not_judged", "reason" => reason }
    end

    def fail_judgment(reason)
      { "judgment" => "fail", "reason" => reason }
    end

    def record_configuration
      ValidationCapture.record(
        "experiment_configuration",
        "result" => "prepared",
        "operation" => "interpreter_experiment",
        "provider" => "anthropic",
        "models" => MODELS,
        "live_calls_enabled" => LIVE_CALLS_ENABLED,
        "attempt_cap" => Budget.attempt_cap,
        "money_cap_usd" => format("%.6f", Budget.money_cap),
        "sources" => InterpreterAnthropicAdapter::SOURCES,
        "consulted_on" => InterpreterAnthropicAdapter::CONSULTED_ON,
        "provider_call" => false
      )
    end

    def write_capture(root, events)
      document = ValidationCapture.export_capture(events, root, run_id: @run_id)
      File.write(root.join("capture.json"), JSON.pretty_generate(document))
    end

    def write_files(dir, files)
      FileUtils.mkdir_p(dir)
      files.each do |name, value|
        File.write(dir.join(name), JSON.pretty_generate(InterpreterAnthropicAdapter.scrub(json_ready(value))))
      end
    end

    def json_ready(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key.to_s] = json_ready(item) }
      when Array
        value.map { |item| json_ready(item) }
      when BigDecimal
        format("%.6f", value)
      when Symbol
        value.to_s
      else
        value
      end
    end

    def case_dir(row, model_id)
      run_dir.join(row["id"], model_id)
    end

    def correlation(row, model_id)
      "interpreter-experiment:#{row["id"]}:#{model_id}"
    end

    def self.build_matrix
      technical = { "disposition" => "score", "allowed_moves" => %w[report],
                    "forbidden_moves" => %w[meta follow_up answer_pending correct new_work unclear],
                    "empty_observations" => false, "empty_assertions" => false }
      meta = { "disposition" => "score", "allowed_moves" => %w[meta],
               "forbidden_moves" => %w[report follow_up answer_pending correct new_work unclear],
               "empty_observations" => true, "empty_assertions" => true }
      [
        row("phase1", PHASE1_TEXT, "empty", technical,
            "Declara un trabajo y pregunta por el equipo. Sin trabajo abierto, el contrato usa report. meta queda prohibido."),
        row("variador", "El variador no arranca", "empty", technical,
            "Declara una falla. El contrato usa report. meta queda prohibido."),
        row("saludo_variador", "Buenas tardes. El variador no arranca", "empty", technical,
            "El saludo no borra la falla. report. meta queda prohibido. Par de variador con saludo.",
            pair_of: "variador"),
        row("oferta_variador", "Puedo enviarte una foto. El variador no arranca", "empty", technical,
            "La oferta no borra la falla. report. meta queda prohibido. Par de variador con oferta.",
            pair_of: "variador"),
        row("circuito", "Según el manual, ¿cómo funciona el circuito de seguridad?", "empty", technical,
            "Pregunta por el equipo. No pregunta qué necesita Danebo. report. meta queda prohibido."),
        row("kse", "¿Para qué sirve el contacto KSE según el plano?", "empty", technical,
            "Una pregunta por un designador es report, como «¿Qué es Q2?». meta queda prohibido."),
        row("foto_variador", "Te envío una foto: el variador no arranca", "empty", technical,
            "La misma frase trae una falla. La oferta no la borra. report. meta queda prohibido."),
        row("necesitas_motor", "¿Qué necesitas para investigar por qué el motor se detiene?", "empty", technical,
            "Pregunta qué hace falta y declara que el motor se detiene. El contrato no deja esa falla en meta."),
        row("foto_fallas", "Puedo enviarte una foto de las fallas que muestra el display", "empty", technical,
            "La oferta nombra las fallas del display. report. meta queda prohibido."),
        row("perfecto", "Perfecto, entendido", "empty", review_admin(%w[meta unclear]),
            "No declara trabajo ni falla. El prompt no la nombra. Revisión. " \
            "Falla si escribe trabajo, observación o aserción."),
        row("buenas_tardes", "Buenas tardes", "empty", meta,
            "Saludo sin contenido técnico. meta, sin observación ni aserción."),
        row("necesitas_mande", "¿Qué necesitas que te mande?", "empty", meta,
            "Pregunta qué debe enviar, sin falla. meta, sin observación ni aserción."),
        row("puedo_foto", "Puedo enviarte una foto", "empty", meta,
            "Oferta sola de una foto, sin falla. meta, sin observación ni aserción."),
        row("puedo_fotos", "Puedo enviarte unas fotos", "empty", meta,
            "Oferta sola, en plural, sin falla. meta. Par de puedo_foto.", pair_of: "puedo_foto"),
        row("como_uso", "¿Cómo uso Danebo?", "empty", review_admin(%w[meta unclear]),
            "No es una pregunta de equipo ni declara una falla. El prompt no la nombra. Revisión."),
        row("como_selecciono", "¿Cómo selecciono un manual?", "empty", review_admin(%w[meta unclear]),
            "Operación del producto, no del equipo. El prompt no la nombra. Revisión."),
        row("donde_veo_plano", "¿Dónde veo el plano seleccionado?", "empty",
            review_case(%w[meta report unclear], %w[follow_up answer_pending correct new_work],
                        observations: true, assertions: false),
            "Puede ser la pantalla de Danebo o el plano. Revisión. Una observación inventada falla."),
        row("foto_resumen", "Te mando una foto y el resumen de lo que vi", "empty", meta,
            "Ofrece foto y resumen, sin falla ni valor. meta. El resumen no es una observación."),
        row("puerta_singular", "La puerta no cierra", "empty", technical,
            "Declara una falla, en singular. report. meta queda prohibido."),
        row("puertas_plural", "Las puertas no cierran", "empty", technical,
            "La misma falla, en plural. report. meta queda prohibido. Par de puerta_singular.",
            pair_of: "puerta_singular"),
        row("phase1_active", PHASE1_TEXT, "active",
            { "disposition" => "score", "allowed_moves" => %w[follow_up report],
              "forbidden_moves" => %w[meta new_work answer_pending correct unclear],
              "empty_observations" => false, "empty_assertions" => false },
            "El trabajo abierto es esa puerta. follow_up o report respetan el contrato. meta y new_work no."),
        row("variador_active", "El variador no arranca", "active",
            review_case(%w[report follow_up new_work unclear], %w[meta answer_pending correct],
                        observations: false, assertions: false),
            "El variador puede ser otro trabajo o parte del de la puerta. Revisión. meta falla."),
        row("perfecto_active", "Perfecto, entendido", "active",
            review_case(%w[meta unclear follow_up], %w[report new_work answer_pending correct],
                        observations: true, assertions: true),
            "No sustituye el objetivo. Revisión. report, new_work o una observación fallan."),
        row("necesitas_active", "¿Qué necesitas que te mande?", "active", meta,
            "Pregunta qué enviar, sin falla. meta, sin observación. No abre otro trabajo.")
      ]
    end

    def self.row(id, text, context, rules, justification, pair_of: nil)
      copied = rules.merge(
        "id" => id,
        "text" => text,
        "context" => context,
        "pair_of" => pair_of,
        "justification" => justification
      )
      copied["allowed_moves"] = copied["allowed_moves"].dup
      copied["forbidden_moves"] = copied["forbidden_moves"].dup
      copied.freeze
    end

    def self.review_admin(allowed)
      review_case(allowed, TurnPerception::MOVES - allowed, observations: true, assertions: true)
    end

    def self.review_case(allowed, forbidden, observations:, assertions:)
      {
        "disposition" => "review",
        "allowed_moves" => allowed,
        "forbidden_moves" => forbidden,
        "empty_observations" => observations,
        "empty_assertions" => assertions
      }
    end
    private_class_method :build_matrix, :row, :review_admin, :review_case
  end
end
