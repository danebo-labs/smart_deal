# frozen_string_literal: true

module Rag
  # A confirmed document of another team loses only its body, in the same
  # place. Unconfirmed chunks, missing entries, and private manuals keep the
  # body retrieve_and_generate would send.
  class DocumentIdentityScope
    Result = Data.define(:chunks, :blocked, :undeclared_private, :unconfirmed_general, :redacted)
    REFERENCE = "Reference only, other equipment."
    HEADING_LINE = Rag::EvidenceCandidateSelector::HEADING_LINE

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
      redacted = 0
      scoped = []

      Array(chunks).each do |chunk|
        metadata = metadata_of(chunk)
        account_id = metadata["account_id"].to_s
        document_id = metadata["document_id"].to_s

        if account_id.blank? || document_id.blank?
          unconfirmed_general += 1
          log_unconfirmed(account_id, document_id)
          scoped << chunk
        elsif DocumentIdentityCatalog::GENERAL_ACCOUNT_IDS.exclude?(account_id)
          undeclared_private += 1
          Rails.logger.info(
            "[DOCUMENT_IDENTITY] undeclared_private account_id=#{account_id} document_id=#{document_id}"
          )
          scoped << chunk
        else
          entry = catalog.find(account_id, document_id)
          if DocumentIdentityCatalog.effectively_confirmed?(entry) &&
             !keep_body?(entry, episode_labels, identifiers)
            scoped << redact(chunk, metadata)
            redacted += 1
          else
            unless DocumentIdentityCatalog.effectively_confirmed?(entry)
              unconfirmed_general += 1
              log_unconfirmed(account_id, document_id)
            end
            scoped << chunk
          end
        end
      end

      Result.new(
        chunks: scoped, blocked: false,
        undeclared_private: undeclared_private,
        unconfirmed_general: unconfirmed_general,
        redacted: redacted
      )
    end

    # Same chunks, same order, as the search results of this turn.
    def self.generation_context(chunks)
      Array(chunks).each_with_index.map do |chunk, index|
        [
          "<search_result>",
          "<content>",
          chunk[:content].to_s,
          "</content>",
          "<source>",
          (index + 1).to_s,
          "</source>",
          "</search_result>"
        ].join("\n")
      end.join("\n")
    end

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

    def self.identifier_labels(episode)
      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      normalize_labels(parsed.identifiers.pluck("value"))
    end

    def self.normalize_labels(values)
      values.filter_map { |value| FollowupQueryRewriter.normalize_label(value).presence }.uniq
    end
    private_class_method :normalize_labels

    def self.keep_body?(entry, episode_labels, identifiers)
      return true if entry.generic || entry.role.blank?

      case entry.role
      when "equipment"
        matches?(entry, episode_labels)
      when "component"
        identifiers.empty? || matches?(entry, identifiers)
      else
        true
      end
    end
    private_class_method :keep_body?

    def self.matches?(entry, labels)
      document_labels = (entry.brands + entry.designators).filter_map do |value|
        FollowupQueryRewriter.normalize_label(value).presence
      end
      document_labels.intersect?(labels)
    end
    private_class_method :matches?

    def self.redact(chunk, metadata)
      title = section_title(chunk, metadata)
      page = metadata["page_number"].presence || "unknown"
      name = metadata["canonical_name"].to_s.presence || "unknown"
      body = "#{REFERENCE} Document: #{name}. Page: #{page}."
      body = "#{body} Section: #{title}." if title

      chunk.merge(
        content: body,
        metadata: metadata.except("section_identity"),
        chunk_sha256: Digest::SHA256.hexdigest(body)
      )
    end
    private_class_method :redact

    def self.section_title(chunk, metadata)
      title = metadata["section_identity"].to_s.strip
      title = heading_title(chunk[:content]) if title.blank?
      return if title.blank? || title.match?(/\d|\//)

      title
    end
    private_class_method :section_title

    def self.heading_title(content)
      line = content.to_s.lines.map(&:strip).find { |candidate| candidate.match?(HEADING_LINE) }
      line&.sub(HEADING_LINE, '\1')&.strip
    end
    private_class_method :heading_title

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
