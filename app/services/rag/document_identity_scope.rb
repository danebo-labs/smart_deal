# frozen_string_literal: true

module Rag
  # One compatibility policy for typed turns and photo turns.
  # Callers pass a Rag::EquipmentIdentity. An episode is accepted only so
  # the text path can be derived through EquipmentIdentity.from_episode.
  #
  # Outcomes when the policy is required (identity known):
  #   :scoped         — at least one chunk body applies to this equipment
  #   :no_compatible  — the policy ran and no body applies
  #   :unavailable    — the policy could not run reliably
  #
  # N3 classifies and strips foreign procedural bodies from the generation
  # context. It does not close the caller's open retrieve_and_generate
  # fallback and it does not drop reference-only citations. That is N4.
  class DocumentIdentityScope
    Result = Data.define(
      :chunks, :labels, :blocked, :undeclared_private, :unconfirmed_general,
      :status, :reason, :applicability, :excluded_labels
    ) do
      def reference_only?
        Array(applicability).any? { |item| item == "reference_only" }
      end
    end
    PREAMBLE = "Only evidence marked THIS JOB'S EQUIPMENT can support a step, terminal, code, or value for this job. " \
               "Evidence marked REFERENCE ONLY — OTHER EQUIPMENT contains source identity only; its procedural body " \
               "was removed and cannot support an instruction for this job."
    OTHER_EQUIPMENT_PREFIX = "REFERENCE ONLY — OTHER EQUIPMENT:"
    IDENTITY_FIELDS = %w[canonical_name original_filename section_identity].freeze
    # A catalog fact is a query signal. It is not a needle. Controller is the
    # same: F8 may store it, and this list stays user and photo.
    NEEDLE_SOURCES = %w[user photo].freeze
    Resolution = Data.define(:values, :conflict, :manufacturer_labels, :excluded_labels)

    def self.applicable?(identity_or_episode)
      return false unless DocumentIdentityScopeFlag.enabled?

      identity = coerce_identity(identity_or_episode)
      identity.is_a?(EquipmentIdentity) && identity.known?
    end

    def self.needles(identity_or_episode)
      identity = coerce_identity(identity_or_episode)
      return [] unless identity.is_a?(EquipmentIdentity)

      resolve_needles(identity).values
    end

    def self.apply(chunks, identity_or_episode, focus_uris: [])
      identity = coerce_identity(identity_or_episode)
      if identity == :malformed
        return build_result(
          chunks: Array(chunks),
          labels: blank_labels(chunks),
          status: :unavailable,
          reason: :malformed_identity
        )
      end

      uris = Array(focus_uris).map { |uri| uri.to_s.strip }.compact_blank.to_set
      resolution = identity.is_a?(EquipmentIdentity) ? resolve_needles(identity) : empty_resolution
      needles = resolution.values
      return not_required(chunks) if !identity&.known? && needles.empty? && uris.empty?

      labels = []
      applicability = []
      scoped_chunks = Array(chunks).map do |chunk|
        kind = chunk_applicability(chunk, needles, focus_membership(chunk, uris), identity, resolution)
        case kind
        when :compatible, :neutral
          labels << this_job_line(document_name(chunk))
          applicability << kind.to_s
          chunk.merge(identity_applicability: kind.to_s)
        when :reference_only
          labels << other_equipment_line(document_name(chunk))
          applicability << "reference_only"
          chunk.merge(content: reference_identity(chunk), identity_applicability: "reference_only")
        else
          labels << nil
          applicability << nil
          chunk
        end
      end
      return not_required(chunks) if labels.all?(&:blank?) && !identity&.known?

      status = if applicability.any? { |item| item == "compatible" || item == "neutral" }
        :scoped
      elsif identity&.known?
        :no_compatible
      else
        :scoped
      end
      build_result(
        chunks: scoped_chunks,
        labels: labels,
        status: status,
        reason: resolution.conflict ? :conflicting_current_identity : nil,
        applicability: applicability,
        excluded_labels: resolution.excluded_labels
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

    def self.not_required(chunks)
      build_result(chunks: Array(chunks), labels: blank_labels(chunks), status: nil, reason: :not_required)
    end
    private_class_method :not_required

    def self.build_result(chunks:, labels:, status:, reason: nil, applicability: nil, excluded_labels: [])
      Result.new(
        chunks: chunks,
        labels: labels,
        blocked: false,
        undeclared_private: 0,
        unconfirmed_general: 0,
        status: status,
        reason: reason,
        applicability: applicability || Array.new(Array(chunks).size),
        excluded_labels: Array(excluded_labels)
      )
    end
    private_class_method :build_result

    def self.blank_labels(chunks)
      Array.new(Array(chunks).size)
    end
    private_class_method :blank_labels

    # :out stays reference-only so a pin is not widened.
    # A needle match is this job's equipment.
    # A selected document that names a different KbDocumentResolver brand is
    # reference-only. A selected document that does not name one stays
    # THIS JOB: the pin compensates for incomplete metadata.
    def self.chunk_applicability(chunk, needles, membership, identity, resolution)
      return :reference_only if membership == :out
      return :compatible if needles.any? && identity_matches?(chunk, needles)
      return conflicting_or_neutral(chunk, identity, resolution) if membership == :in
      return nil if needles.empty?

      :reference_only
    end
    private_class_method :chunk_applicability

    def self.conflicting_or_neutral(chunk, identity, resolution)
      return :neutral unless identity&.known?
      return :reference_only if conflicting_brand?(chunk, resolution)

      :neutral
    end
    private_class_method :conflicting_or_neutral

    def self.conflicting_brand?(chunk, resolution)
      brands = brands_in_identity(chunk)
      return false if brands.empty?

      known = resolution.manufacturer_labels
      brands.any? { |brand| known.none? { |label| label == brand || contains_word?(label, brand) } }
    end
    private_class_method :conflicting_brand?

    def self.brands_in_identity(chunk)
      metadata = metadata_of(chunk)
      text = IDENTITY_FIELDS.filter_map { |field| metadata[field].presence }.join(" ")
      normalized = FollowupQueryRewriter.normalize_label(text)
      return [] if normalized.blank?

      KbDocumentResolver::BRANDS.select { |brand| normalized.match?(/\b#{Regexp.escape(brand)}\b/) }
    end
    private_class_method :brands_in_identity

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

    # A current model is more specific than an inherited manufacturer.
    # Same-correlation facts travel together. Two current trusted
    # manufacturers are not a compatibility union: neither label makes a
    # body applicable. The current model, when there is one, stays a needle.
    def self.resolve_needles(identity)
      facts = identity.facts
      models = slot_facts(facts, "model")
      manufacturers = slot_facts(facts, "manufacturer")
      identifiers = slot_facts(facts, "identifier")
      current_model = models.last
      if current_model
        current_manufacturers = manufacturers.select { |fact| same_correlation?(fact, current_model) }
        current_identifiers = identifiers.select { |fact| same_correlation?(fact, current_model) }
        current_models = models.select { |fact| fact.equal?(current_model) || same_correlation?(fact, current_model) }
      else
        current_manufacturers = manufacturers
        current_identifiers = identifiers
        current_models = []
      end

      distinct = current_manufacturers.map { |fact| normalize_label(fact["value"]) }.uniq
      conflict = distinct.size > 1
      values = current_models.pluck("value")
      excluded = conflict ? current_manufacturers.pluck("value") : []
      current_manufacturers.each { |fact| values << fact["value"] } unless conflict
      current_identifiers.each do |fact|
        next if conflict && excluded.any? { |label| normalize_label(label) == normalize_label(fact["value"]) }

        values << fact["value"]
      end
      Resolution.new(
        values: values.map { |value| value.to_s.strip }.compact_blank.uniq,
        conflict: conflict,
        manufacturer_labels: conflict ? [] : current_manufacturers.map { |fact| normalize_label(fact["value"]) }.uniq,
        excluded_labels: excluded.map { |value| value.to_s.strip }.uniq
      )
    end
    private_class_method :resolve_needles

    def self.empty_resolution
      Resolution.new(values: [], conflict: false, manufacturer_labels: [], excluded_labels: [])
    end
    private_class_method :empty_resolution

    def self.slot_facts(facts, slot)
      Array(facts).select do |fact|
        fact["slot"] == slot && needle_source?(fact) && fact["value"].present?
      end
    end
    private_class_method :slot_facts

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

    def self.same_correlation?(earlier, current)
      turn = current["correlation_id"].to_s
      turn.present? && turn == earlier["correlation_id"].to_s
    end
    private_class_method :same_correlation?

    def self.normalize_label(value)
      FollowupQueryRewriter.normalize_label(value)
    end
    private_class_method :normalize_label

    def self.coerce_identity(input)
      return nil if input.nil?
      return input if input.is_a?(EquipmentIdentity)
      return EquipmentIdentity.from_episode(input) if input.is_a?(ActiveEpisode) || input.is_a?(Hash)

      :malformed
    end
    private_class_method :coerce_identity

    def self.metadata_of(chunk)
      chunk[:metadata].to_h.stringify_keys
    end
    private_class_method :metadata_of
  end
end
