# frozen_string_literal: true

module Rag
  # FC-D12. The label is computed from the retrieved chunk. The catalog is not
  # consulted. A matching chunk keeps its body and gains one line. Every other
  # chunk stays unlabeled. The fixed rule is one line at the start of the
  # context, and only when at least one chunk matches.
  class DocumentIdentityScope
    Result = Data.define(:chunks, :labels, :blocked, :undeclared_private, :unconfirmed_general)
    PREAMBLE = "Only evidence marked THIS JOB'S EQUIPMENT can support a step, terminal, code, or value for this job. " \
               "Any other evidence is a reference: quote what that manual documents for its own equipment, " \
               "with manual and page, and say it must be confirmed in the field. " \
               "Do not reproduce a short-circuit, bridge, or disconnection of another equipment's terminals: " \
               "say what that test checks. Compatibility with this job is not established unless a document states it."
    IDENTITY_FIELDS = %w[canonical_name original_filename section_identity].freeze

    def self.applicable?(episode)
      return false unless DocumentIdentityScopeFlag.enabled?

      fact = parsed_episode(episode).fact("manufacturer")
      fact&.dig("status") == "known" && fact["value"].present?
    end

    def self.apply(chunks, episode)
      needles = match_needles(episode)
      labels = Array(chunks).map { |chunk| label_for(chunk, needles) }
      Result.new(
        chunks: Array(chunks),
        labels: labels,
        blocked: false,
        undeclared_private: 0,
        unconfirmed_general: 0
      )
    end

    # Same chunks, same order. The preamble is one line before the results.
    # A label is one line before that chunk's body.
    def self.generation_context(chunks, labels = [])
      body = Array(chunks).each_with_index.map { |chunk, index|
        content = chunk[:content].to_s
        label = labels[index]
        content = "#{label}\n#{content}" if label.present?
        [
          "<search_result>",
          "<content>",
          content,
          "</content>",
          "<source>",
          (index + 1).to_s,
          "</source>",
          "</search_result>"
        ].join("\n")
      }.join("\n")
      return body unless Array(labels).any?(&:present?)

      "#{PREAMBLE}\n#{body}"
    end

    def self.this_job_line(canonical_name)
      "THIS JOB'S EQUIPMENT: #{canonical_name}"
    end

    def self.label_for(chunk, needles)
      return if needles.empty?
      return unless identity_matches?(chunk, needles)

      this_job_line(metadata_of(chunk)["canonical_name"].to_s.strip)
    end
    private_class_method :label_for

    def self.identity_matches?(chunk, needles)
      metadata = metadata_of(chunk)
      IDENTITY_FIELDS.any? do |field|
        needles.any? { |needle| contains_word?(metadata[field], needle) }
      end
    end
    private_class_method :identity_matches?

    def self.contains_word?(haystack, needle)
      normalized = FollowupQueryRewriter.normalize_label(haystack)
      label = FollowupQueryRewriter.normalize_label(needle)
      return false if normalized.blank? || label.blank?

      normalized.match?(/\b#{Regexp.escape(label)}\b/)
    end
    private_class_method :contains_word?

    def self.match_needles(episode)
      parsed = parsed_episode(episode)
      values = []
      fact = parsed.fact("manufacturer")
      values << fact["value"] if fact&.dig("status") == "known"
      parsed.identifiers.each { |item| values << item["value"] }
      values.map { |value| value.to_s.strip }.compact_blank.uniq
    end
    private_class_method :match_needles

    def self.parsed_episode(episode)
      episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
    end
    private_class_method :parsed_episode

    def self.metadata_of(chunk)
      chunk[:metadata].to_h.stringify_keys
    end
    private_class_method :metadata_of
  end
end
