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
    # A catalog fact is a query signal. It is not a needle. Controller is the
    # same: F8 may store it, and this list stays user and photo.
    NEEDLE_SOURCES = %w[user photo].freeze

    def self.applicable?(episode)
      return false unless DocumentIdentityScopeFlag.enabled?

      parsed = parsed_episode(episode)
      known_value(parsed, "manufacturer").present? || known_value(parsed, "model").present?
    end

    def self.needles(episode)
      match_needles(episode)
    end

    def self.apply(chunks, episode, focus_uris: [])
      uris = Array(focus_uris).map { |uri| uri.to_s.strip }.compact_blank.to_set
      needles = match_needles(episode)
      return unchanged(chunks) if needles.empty? && uris.empty?

      labels = []
      scoped_chunks = Array(chunks).map do |chunk|
        membership = focus_membership(chunk, uris)
        if membership == :in || (membership.nil? && (needles.empty? || identity_matches?(chunk, needles)))
          labels << (membership == :in || needles.any? ? this_job_line(document_name(chunk)) : nil)
          chunk
        else
          labels << other_equipment_line(document_name(chunk))
          chunk.merge(content: reference_identity(chunk))
        end
      end
      return unchanged(chunks) if labels.all?(&:blank?)

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
      manufacturer = needle_fact(parsed, "manufacturer")
      model = needle_fact(parsed, "model")
      if model
        values << model["value"]
        # A model declared on a later turn supersedes an inherited
        # manufacturer. Same-turn facts share correlation_id and both match.
        values << manufacturer["value"] if manufacturer && same_correlation?(manufacturer, model)
      elsif manufacturer
        values << manufacturer["value"]
      end
      parsed.identifiers.each do |item|
        next unless needle_source?(item)
        # Same rule as an inherited manufacturer: once this turn has a model,
        # an identifier from an earlier turn is not current equipment unless
        # that turn restated it and stamped the same correlation_id.
        next if model && !same_correlation?(item, model)

        values << item["value"]
      end
      values.map { |value| value.to_s.strip }.compact_blank.uniq
    end
    private_class_method :match_needles

    def self.needle_fact(parsed, key)
      fact = known_fact(parsed, key)
      return nil unless needle_source?(fact)

      fact
    end
    private_class_method :needle_fact

    def self.needle_source?(fact)
      NEEDLE_SOURCES.include?(fact.to_h["source"].to_s)
    end
    private_class_method :needle_source?

    def self.focus_membership(chunk, uris)
      return nil if uris.empty?

      found = chunk_uris(chunk)
      return nil if found.empty?

      found.any? { |uri| uris.include?(uri) } ? :in : :out
    end
    private_class_method :focus_membership

    def self.chunk_uris(chunk)
      metadata = metadata_of(chunk)
      location = (chunk[:location] || chunk["location"] || {}).to_h
      [
        chunk[:location_uri], chunk["location_uri"],
        chunk[:original_source_uri], chunk["original_source_uri"],
        chunk[:bedrock_source_uri], chunk["bedrock_source_uri"],
        metadata["original_source_uri"],
        metadata["x-amz-bedrock-kb-source-uri"],
        location[:uri] || location["uri"]
      ].map { |value| value.to_s.strip }.compact_blank.uniq
    end
    private_class_method :chunk_uris

    def self.known_fact(parsed, key)
      fact = parsed.fact(key)
      return nil unless fact&.dig("status") == "known" && fact["value"].present?

      fact
    end
    private_class_method :known_fact

    def self.known_value(parsed, key)
      known_fact(parsed, key)&.dig("value")
    end
    private_class_method :known_value

    def self.same_correlation?(earlier, current)
      turn = current["correlation_id"].to_s
      turn.present? && turn == earlier["correlation_id"].to_s
    end
    private_class_method :same_correlation?

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
