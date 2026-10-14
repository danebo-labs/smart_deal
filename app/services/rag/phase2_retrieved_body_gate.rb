# frozen_string_literal: true

module Rag
  # Compares one chunk already returned by this turn's Retrieve.
  # Inactive until the phase 2 harness calls arm!. A disarmed check
  # does nothing and does not read the chunks. This class does not
  # retrieve, generate, or load a fixture into a missing body.
  class Phase2RetrievedBodyGate
    CHUNK_KEY = "bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p5_1.txt"
    CANDIDATE_SHA256 = %w[
      a13141fe7586c9013d698aa29f2b6809f112702e98f4da99d9a47c3ba01d7779
      bc6d057d6ed34adae196692c7a48e1291ac020b08150027c51e13a398b77441e
    ].freeze
    PREVIOUS_SHA256 = %w[
      067ff45ffa86a6d055cedbec8f38ce63ae36c5ba15266d32a48da5ccea9c6831
      b466665b37f76cf2e35441787bbd30b3fe2dd42d623b4de359e05814e2c8a85a
    ].freeze

    # Not a StandardError. The query rescue would otherwise continue
    # into another retrieval or into generation.
    class Stop < Exception; end

    class << self
      def armed?
        Thread.current[:phase2_retrieved_body_gate] == true
      end

      def arm!
        Thread.current[:phase2_retrieved_body_gate] = true
        nil
      end

      def disarm!
        Thread.current[:phase2_retrieved_body_gate] = nil
        nil
      end

      def check!(chunks, correlation_id: nil)
        return unless armed?

        linkage = {}
        linkage["correlation_id"] = correlation_id.to_s if correlation_id.present?
        rows = inspection_rows(chunks)
        write("prepared", linkage, prepared_payload(rows))
        write("attempt_started", linkage, "remote" => false)
        decision = decision_for(rows)
        write(decision.fetch(:result), linkage, decision.fetch(:payload))
        return if decision[:result] == "returned"

        block_generation(linkage)
        raise Stop, "retrieved body blocked: #{decision.dig(:payload, "reason")}"
      rescue Stop
        raise
      rescue StandardError => error
        write("error", linkage, "error_class" => error.class.name, "remote" => false)
        block_generation(linkage)
        raise Stop, "retrieved body error: #{error.class}"
      end

      private

      def prepared_payload(rows)
        {
          "expected_key" => CHUNK_KEY,
          "accepted_sha256" => CANDIDATE_SHA256,
          "previous_sha256" => PREVIOUS_SHA256,
          "rows" => rows
        }
      end

      def inspection_rows(chunks)
        Array(chunks).each_with_index.map { |chunk, index| inspection_row(chunk, index) }
      end

      def inspection_row(chunk, index)
        uris = chunk_uris(chunk)
        key = uris.map { |uri| object_key(uri) }.find { |item| item == CHUNK_KEY }
        chosen = uris.find { |uri| object_key(uri) == CHUNK_KEY } || uris.first
        row = {
          "index" => index,
          "target" => !key.nil?,
          "uri" => chosen.nil? ? "unavailable" : chosen
        }
        row["key"] = key if key
        text = effective_body(chunk)
        if text.nil?
          row["absent"] = true
          row["match"] = "altered" if row["target"]
          return row
        end

        sha = Digest::SHA256.hexdigest(text.b)
        row["text"] = text
        row["sha256"] = sha
        row["bytes"] = text.b.bytesize
        row["match"] = body_match(sha) if row["target"]
        row
      end

      def decision_for(rows)
        targets = rows.select { |row| row["target"] == true }
        if targets.empty?
          return {
            result: "blocked",
            payload: { "reason" => "absent", "absent" => true, "expected_key" => CHUNK_KEY }
          }
        end

        matches = targets.pluck("match")
        observed = {
          "sha256" => targets.pluck("sha256"),
          "bytes" => targets.pluck("bytes")
        }
        if matches.all? { |match| match == "candidate" }
          return { result: "returned", payload: observed.merge("reason" => "candidate") }
        end

        reason = matches.all? { |match| match == "previous" } ? "previous" : "altered"
        { result: "blocked", payload: observed.merge("reason" => reason) }
      end

      def body_match(sha)
        return "candidate" if CANDIDATE_SHA256.include?(sha)
        return "previous" if PREVIOUS_SHA256.include?(sha)

        "altered"
      end

      def effective_body(chunk)
        return nil unless chunk.is_a?(Hash)

        text = if chunk.key?(:content)
          chunk[:content]
        else
          chunk["content"]
        end
        text = text.text if text.respond_to?(:text)
        text.is_a?(String) ? text : nil
      end

      def chunk_uris(chunk)
        return [] unless chunk.is_a?(Hash)

        metadata = chunk[:metadata] || chunk["metadata"]
        metadata = {} unless metadata.is_a?(Hash)
        [
          chunk[:location_uri], chunk["location_uri"],
          chunk[:bedrock_source_uri], chunk["bedrock_source_uri"],
          chunk[:original_source_uri], chunk["original_source_uri"],
          metadata["x-amz-bedrock-kb-source-uri"],
          metadata["original_source_uri"],
          metadata["s3_key"]
        ].select { |value| value.is_a?(String) && !value.empty? }
      end

      def object_key(uri)
        path = uri.split("?", 2).first
        path = path.sub(%r{\A[a-z][a-z0-9+.-]*://[^/]+/}i, "")
        path.delete_prefix("/")
      end

      def write(result, linkage, payload)
        body = {
          "stage" => "retrieved_body",
          "result" => result,
          "operation" => "phase2_retrieved_body"
        }
        correlation_id = linkage["correlation_id"] if linkage.is_a?(Hash)
        body["correlation_id"] = correlation_id if correlation_id.present?
        body.merge!(payload) if payload.is_a?(Hash)
        ValidationCapture.record("retrieved_body", body)
      end

      def block_generation(linkage)
        fields = nil
        correlation_id = linkage["correlation_id"] if linkage.is_a?(Hash)
        fields = { "correlation_id" => correlation_id } if correlation_id.present?
        ValidationCapture.record_model_boundary("generate_text", "blocked", fields)
      end
    end
  end
end
