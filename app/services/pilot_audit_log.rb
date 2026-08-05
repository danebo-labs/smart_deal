# frozen_string_literal: true

# Shared [PILOT_AUDIT] emitter for every RAG generation path — the classic
# BedrockRagService#query flow and Rag::StructuredEvidenceRoute. One line per
# interaction with the full question/answer/citations, one line per retrieved
# chunk with its full text (bounded). Gated by PILOT_AUDIT_CAPTURE so
# production stays byte-identical to before this class existed when unset.
# Never writes to PilotUsageLog — that whitelist and its 500-char cap remain
# the privacy boundary for the rest of the pilot telemetry.
class PilotAuditLog
  CHUNK_MAX_CHARS = 4_000
  LINE_MAX_BYTES = 8.kilobytes
  TAG = "[PILOT_AUDIT] "

  def self.log(question:, answer:, citations:, retrieved_chunks:, correlation_id:, attribution:)
    return unless ENV["PILOT_AUDIT_CAPTURE"] == "true"

    new(
      question: question, answer: answer, citations: citations, retrieved_chunks: retrieved_chunks,
      correlation_id: correlation_id, attribution: attribution
    ).call
  rescue StandardError => e
    Rails.logger.warn("PilotAuditLog failed: #{e.message}")
  end

  def initialize(question:, answer:, citations:, retrieved_chunks:, correlation_id:, attribution:)
    @question = question
    @answer = answer
    @citations = citations
    @retrieved_chunks = retrieved_chunks
    @correlation_id = correlation_id
    @attribution = attribution
  end

  def call
    Rails.logger.info("#{TAG}#{JSON.generate(interaction_payload)}")
    Array(@retrieved_chunks).each do |chunk|
      Rails.logger.info("#{TAG}#{chunk_json(chunk)}")
    end
  end

  private

  def identity
    {
      ts: Time.current.iso8601,
      correlation_id: @correlation_id,
      account_id: @attribution[:account_id],
      user_id: @attribution[:user_id],
      conversation_session_id: @attribution[:conversation_session_id]
    }
  end

  def interaction_payload
    identity.merge(
      type: "interaction",
      question: @question.to_s,
      answer: @answer.to_s,
      answer_length: @answer.to_s.length,
      citations: Array(@citations).map { |citation| citation.slice(:number, :title, :filename, :page) }
    )
  end

  def chunk_json(chunk)
    metadata = (chunk[:metadata] || chunk["metadata"] || {}).to_h.stringify_keys
    content = (chunk[:content] || chunk["content"]).to_s
    payload = identity.merge(
      type: "chunk",
      document: metadata["canonical_name"],
      page: metadata["page_number"] || metadata["page"] ||
        metadata["x-amz-bedrock-kb-document-page-number"],
      section_identity: metadata["section_identity"],
      chunk_sha256: chunk[:chunk_sha256] || chunk["chunk_sha256"] ||
        metadata["chunk_sha256"] || Digest::SHA256.hexdigest(content)
    )
    bounded_chunk_json(payload, content)
  end

  # Binary search for the longest prefix of `content` whose JSON-encoded line
  # (with the log tag) still fits under LINE_MAX_BYTES — the Docker json-file
  # driver's 16KB line ceiling means an unbounded chunk plus its metadata risks
  # being split mid-JSON in transit. Never truncates silently: `truncated` is
  # explicit whenever the emitted text is shorter than the source content.
  def bounded_chunk_json(payload, content)
    maximum = [ content.length, CHUNK_MAX_CHARS ].min
    low = 0
    high = maximum
    result = nil

    while low <= high
      length = (low + high) / 2
      candidate = JSON.generate(payload.merge(text: content.first(length), truncated: length < content.length))
      if candidate.bytesize + TAG.bytesize <= LINE_MAX_BYTES
        result = candidate
        low = length + 1
      else
        high = length - 1
      end
    end

    result || JSON.generate(payload.merge(text: "", truncated: content.present?))
  end
end
