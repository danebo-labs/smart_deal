# frozen_string_literal: true

module Rag
  # The label is computed from the retrieved chunk; the catalog is not
  # consulted. Matching chunks keep their body. Other-equipment chunks keep
  # only their source identity so their procedures cannot be transplanted.
  class DocumentIdentityScope
    Result = Data.define(:chunks, :labels, :blocked, :undeclared_private, :unconfirmed_general)
    PREAMBLE = "Only evidence marked THIS JOB'S EQUIPMENT can support a step, terminal, code, or value for this job. " \
               "Evidence marked REFERENCE ONLY — OTHER EQUIPMENT contains source identity only; its procedural body " \
               "was removed and cannot support an instruction for this job."
    OTHER_EQUIPMENT_PREFIX = "REFERENCE ONLY — OTHER EQUIPMENT:"
    IDENTITY_FIELDS = %w[canonical_name original_filename section_identity].freeze

    def self.applicable?(episode)
      return false unless DocumentIdentityScopeFlag.enabled?

      fact = parsed_episode(episode).fact("manufacturer")
      fact&.dig("status") == "known" && fact["value"].present?
    end

    def self.apply(chunks, episode)
      needles = match_needles(episode)
      return unchanged(chunks) if needles.empty?

      labels = []
      scoped_chunks = Array(chunks).map do |chunk|
        if identity_matches?(chunk, needles)
          labels << this_job_line(document_name(chunk))
          chunk
        else
          labels << other_equipment_line(document_name(chunk))
          chunk.merge(content: reference_identity(chunk))
        end
      end
      Result.new(
        chunks: scoped_chunks,
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

    def self.other_equipment_line(name)
      "#{OTHER_EQUIPMENT_PREFIX} #{name}"
    end

    def self.reference_identity(chunk)
      metadata = metadata_of(chunk)
      [
        "Manual: #{document_name(chunk)}",
        "Page: #{metadata["page_number"].presence || "DATA_NOT_AVAILABLE"}",
        "Section: #{metadata["section_identity"].presence || "DATA_NOT_AVAILABLE"}"
      ].join("\n")
    end
    private_class_method :reference_identity

    def self.document_name(chunk)
      metadata = metadata_of(chunk)
      metadata["canonical_name"].presence ||
        metadata["original_filename"].presence ||
        "DATA_NOT_AVAILABLE"
    end
    private_class_method :document_name

    def self.unchanged(chunks)
      Result.new(
        chunks: Array(chunks), labels: Array.new(Array(chunks).size),
        blocked: false, undeclared_private: 0, unconfirmed_general: 0
      )
    end
    private_class_method :unchanged

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
