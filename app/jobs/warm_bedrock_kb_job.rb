# frozen_string_literal: true

# Fire-and-forget warmup for the Aurora Serverless vector store backing the
# Bedrock Knowledge Base. Aurora goes to standby after ~5 min idle to save
# cost in MVO; the first query after standby pays a 30–60s cold-start.
#
# Enqueued from web entry points (login, home reload) so Aurora is warm by
# the time the technician asks a real question. Throttled via Rails.cache
# to one ping per 4 minutes per KB.
class WarmBedrockKbJob < ApplicationJob
  queue_as :default

  THROTTLE_TTL = 4.minutes
  # AuroraColdStartRetry duerme 15+30+45s más la duración de las cuatro
  # llamadas. El marcador de "en vuelo" tiene que sobrevivir esa cascada
  # completa, o un segundo login encolaría otro wakeup compitiendo por el mismo
  # cluster pausado — que es lo que los logs del 2026-08-03 registraron.
  IN_FLIGHT_TTL = 2.minutes
  THROTTLE_KEY = "bedrock_kb_warm:last_ping"

  # Última red, no la primera. #warm_with_retry ya absorbe el cold-start que la
  # KB reporta; un error que sobrevive los tres reintentos no lo arregla un
  # re-encolado, y re-encolar añadiría otro competidor por el mismo cluster.
  discard_on StandardError do |_job, error|
    Rails.logger.warn("[KB_WARM] discarded: #{error.class}: #{error.message}")
  end

  def perform
    return if throttled?

    knowledge_base_id = ENV["BEDROCK_KNOWLEDGE_BASE_ID"].presence ||
                        Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
    return unless knowledge_base_id

    # Reclamar el turno ANTES de la llamada, no después. El throttle se escribía
    # sólo en el camino de éxito, así que un ping fallido dejaba la clave sin
    # poner y cada login siguiente encolaba otro wakeup contra la misma base
    # pausada. TTL corto: un ping que falla debe poder reintentarse antes que uno
    # que funcionó.
    Rails.cache.write(THROTTLE_KEY, Time.current.to_i, expires_in: IN_FLIGHT_TTL)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client  = Aws::BedrockAgentRuntime::Client.new(aws_options)

    warm_with_retry(client, knowledge_base_id)

    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.cache.write(THROTTLE_KEY, Time.current.to_i, expires_in: THROTTLE_TTL)
    Rails.logger.info("[KB_WARM] ok ms=#{elapsed_ms} kb=#{knowledge_base_id}")
    PilotUsageLog.log("kb_warm_ping", route: "kb_warm_ping", latency_ms: elapsed_ms, result: "ok")
  end

  private

  def throttled?
    Rails.cache.exist?(THROTTLE_KEY)
  end

  # El mismo wrapper que usa la ruta de consulta viva
  # (bedrock_rag_service.rb:828-834). Un precalentador que se rinde ante el único
  # error que existe para absorber deja la factura del cold-start a la primera
  # pregunta real del técnico.
  def warm_with_retry(client, knowledge_base_id)
    Bedrock::AuroraColdStartRetry.with_retry(
      error_classes: [ Aws::BedrockAgentRuntime::Errors::ServiceError ]
    ) do
      client.retrieve(
        knowledge_base_id: knowledge_base_id,
        retrieval_query:   { text: "warm" },
        retrieval_configuration: {
          vector_search_configuration: { number_of_results: 1 }
        }
      )
    end
  end

  # Inline copy of the AWS client option resolution. Kept tiny on purpose:
  # a warmup job must not depend on the full BedrockRagService boot path.
  def aws_options
    region = ENV.fetch("AWS_REGION", nil).presence ||
             Rails.application.credentials.dig(:aws, :region) ||
             "us-east-1"

    opts = { region: region }

    bearer = ENV["AWS_BEARER_TOKEN_BEDROCK"].presence ||
             ENV["AWS_BEDROCK_BEARER_TOKEN"].presence ||
             Rails.application.credentials.dig(:aws, :bedrock_bearer_token)
    if bearer
      opts[:token_provider] = Aws::StaticTokenProvider.new(bearer)
    elsif (k = ENV["AWS_ACCESS_KEY_ID"].presence) && (s = ENV["AWS_SECRET_ACCESS_KEY"].presence)
      opts[:access_key_id]     = k
      opts[:secret_access_key] = s
    end

    opts[:http_open_timeout] = ENV.fetch("AWS_HTTP_OPEN_TIMEOUT", 5).to_i
    opts[:http_read_timeout] = ENV.fetch("AWS_HTTP_READ_TIMEOUT", 90).to_i
    opts[:http_idle_timeout] = ENV.fetch("AWS_HTTP_IDLE_TIMEOUT", 5).to_i
    opts
  end
end
