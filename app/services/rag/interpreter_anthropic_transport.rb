# frozen_string_literal: true

module Rag
  # One POST to https://api.anthropic.com/v1/messages.
  # claude-haiku-5-5 and claude-haiku-4-5-20251001 both use this client.
  # It does not call Bedrock, does not read a credential, and does not retry.
  class InterpreterAnthropicTransport
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 30
    RETRIES = 0
    Result = Struct.new(:http_status, :payload, :error_code, :error_message, keyword_init: true)

    def self.live
      new(live: true)
    end

    def initialize(live: false, http: Net::HTTP)
      @live = live
      @http = http
    end

    def live?
      @live
    end

    def post(endpoint:, headers:, body:, open_timeout:, read_timeout:, authorization: nil)
      if @live && !granted?(authorization)
        return Result.new(
          http_status: nil, payload: nil, error_code: "execution_not_approved",
          error_message: "execution_not_approved"
        )
      end

      uri = URI(endpoint.to_s)
      http = @http.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.max_retries = RETRIES
      request = Net::HTTP::Post.new(uri.request_uri)
      headers.each { |key, value| request[key.to_s] = value }
      request.body = JSON.generate(body)
      parse_response(http.request(request))
    rescue Net::OpenTimeout, Net::ReadTimeout
      Result.new(http_status: nil, payload: nil, error_code: "timeout", error_message: "timeout")
    rescue StandardError => error
      Result.new(
        http_status: nil,
        payload: nil,
        error_code: "transport_error",
        error_message: InterpreterAnthropicAdapter.scrub_text(error.message.to_s).truncate(180)
      )
    end

    private

    def granted?(authorization)
      authorization.is_a?(Hash) && authorization["granted"] == true && authorization["run_id"].present?
    end

    def parse_response(response)
      status = response.code.to_i
      raw = response.body.to_s
      payload = parse_json(raw)
      return invalid_body(status) if payload == :invalid
      return Result.new(http_status: status, payload: payload, error_code: nil, error_message: nil) if status == 200 && !error_payload?(payload)

      Result.new(
        http_status: status,
        payload: payload,
        error_code: "http_#{status}",
        error_message: InterpreterAnthropicAdapter.scrub_text(error_message(payload)).truncate(180)
      )
    end

    def parse_json(raw)
      return {} if raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      :invalid
    end

    def invalid_body(status)
      Result.new(http_status: status, payload: nil, error_code: "invalid_body", error_message: "invalid_body")
    end

    def error_payload?(payload)
      return false unless payload.is_a?(Hash)
      return true if payload["type"] == "error"

      payload.key?("error") && !payload.key?("content") && !payload.key?("stop_reason")
    end

    def error_message(payload)
      return "http_error" unless payload.is_a?(Hash)

      err = payload["error"]
      return err["message"].to_s if err.is_a?(Hash) && err["message"].present?

      "http_error"
    end
  end
end
