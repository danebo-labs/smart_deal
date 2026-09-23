# frozen_string_literal: true

module Rag
  # FC-D12. A confirmed chunk of another team, or of this job, keeps its body.
  # The only addition is one label line in the generation context. An
  # unconfirmed chunk, a missing entry, and a private manual get no label.
  class DocumentIdentityScope
    Result = Data.define(:chunks, :labels, :blocked, :undeclared_private, :unconfirmed_general)
    OTHER_EQUIPMENT_RULE = "Reference only: quote what this manual documents for its own equipment, " \
                           "with manual and page, and say it must be confirmed in the field. " \
                           "Never turn it into a step for this job. " \
                           "Do not reproduce a short-circuit, bridge, or disconnection of this equipment's terminals: " \
                           "say what that test checks, not which terminals. " \
                           "Compatibility with this job is not established unless a document states it."

    def self.applicable?(episode)
      return false unless DocumentIdentityScopeFlag.enabled?
      return false unless DocumentIdentityCatalog.current.activatable?

      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      fact = parsed.fact("manufacturer")
      fact&.dig("status") == "known" && fact["value"].present?
    end

    def self.apply(chunks, episode)
      episode_labels = episode_labels(episode)
      identifiers = identifier_labels(episode)
      catalog = DocumentIdentityCatalog.current
      undeclared_private = 0
      unconfirmed_general = 0
      labels = []

      Array(chunks).each do |chunk|
        metadata = metadata_of(chunk)
        account_id = metadata["account_id"].to_s
        document_id = metadata["document_id"].to_s

        if account_id.blank? || document_id.blank?
          unconfirmed_general += 1
          log_unconfirmed(account_id, document_id)
          labels << nil
        elsif DocumentIdentityCatalog::GENERAL_ACCOUNT_IDS.exclude?(account_id)
          undeclared_private += 1
          Rails.logger.info(
            "[DOCUMENT_IDENTITY] undeclared_private account_id=#{account_id} document_id=#{document_id}"
          )
          labels << nil
        else
          entry = catalog.find(account_id, document_id)
          unless DocumentIdentityCatalog.effectively_confirmed?(entry)
            unconfirmed_general += 1
            log_unconfirmed(account_id, document_id)
            labels << nil
            next
          end

          labels << label_for(entry, episode, episode_labels, identifiers)
        end
      end

      Result.new(
        chunks: Array(chunks),
        labels: labels,
        blocked: false,
        undeclared_private: undeclared_private,
        unconfirmed_general: unconfirmed_general
      )
    end

    # Same chunks, same order. A label is one line before that chunk's body.
    def self.generation_context(chunks, labels = [])
      Array(chunks).each_with_index.map do |chunk, index|
        body = chunk[:content].to_s
        label = labels[index]
        content = label.present? ? "#{label}\n#{body}" : body
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
      end.join("\n")
    end

    def self.this_job_line(entry)
      "THIS JOB'S EQUIPMENT: #{equipment_name(entry)}."
    end

    def self.other_equipment_line(entry, episode)
      "OTHER EQUIPMENT: #{equipment_name(entry)}. This job: #{job_name(episode)}. #{OTHER_EQUIPMENT_RULE}"
    end

    def self.label_for(entry, episode, episode_labels, identifiers)
      if matches?(entry, episode_labels)
        this_job_line(entry)
      elsif other_equipment?(entry, episode_labels, identifiers)
        other_equipment_line(entry, episode)
      end
    end
    private_class_method :label_for

    def self.other_equipment?(entry, episode_labels, identifiers)
      return false if entry.role.blank?
      return false if matches?(entry, episode_labels)
      return true if entry.role == "equipment" && branded?(entry)
      return true if entry.role == "component" && identifiers.any?

      false
    end
    private_class_method :other_equipment?

    def self.matches?(entry, labels)
      document_labels = (entry.brands + entry.designators).filter_map do |value|
        FollowupQueryRewriter.normalize_label(value).presence
      end
      document_labels.intersect?(labels)
    end
    private_class_method :matches?

    def self.branded?(entry)
      entry.brands.any? { |value| FollowupQueryRewriter.normalize_label(value).present? }
    end
    private_class_method :branded?

    def self.equipment_name(entry)
      parts = (entry.brands + entry.designators).map { |value| value.to_s.strip }.compact_blank
      parts.join(" ").presence || entry.display_name.presence || "unknown"
    end
    private_class_method :equipment_name

    def self.job_name(episode)
      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      values = []
      fact = parsed.fact("manufacturer")
      values << fact["value"] if fact&.dig("status") == "known"
      parsed.identifiers.each { |item| values << item["value"] }
      values.map { |value| value.to_s.strip }.compact_blank.join(" ").presence || "unknown"
    end
    private_class_method :job_name

    def self.episode_labels(episode)
      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      values = []
      %w[manufacturer model].each do |key|
        fact = parsed.fact(key)
        values << fact["value"] if fact&.dig("status") == "known"
      end
      parsed.identifiers.each { |item| values << item["value"] }
      normalize_labels(values)
    end
    private_class_method :episode_labels

    def self.identifier_labels(episode)
      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      normalize_labels(parsed.identifiers.pluck("value"))
    end
    private_class_method :identifier_labels

    def self.normalize_labels(values)
      values.filter_map { |value| FollowupQueryRewriter.normalize_label(value).presence }.uniq
    end
    private_class_method :normalize_labels

    def self.log_unconfirmed(account_id, document_id)
      Rails.logger.info(
        "[DOCUMENT_IDENTITY] unconfirmed_general account_id=#{account_id} document_id=#{document_id}"
      )
    end
    private_class_method :log_unconfirmed

    def self.metadata_of(chunk)
      chunk[:metadata].to_h.stringify_keys
    end
    private_class_method :metadata_of
  end
end
