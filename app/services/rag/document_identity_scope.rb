# frozen_string_literal: true

module Rag
  # Before generation, a general-corpus chunk that does not match the episode
  # keeps its manual, page, and section title. The body does not enter the prompt.
  class DocumentIdentityScope
    Result = Data.define(:chunks, :blocked, :undeclared_private)
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
      labels = episode_labels(episode)
      catalog = DocumentIdentityCatalog.current
      undeclared_private = 0
      scoped = []

      Array(chunks).each do |chunk|
        metadata = metadata_of(chunk)
        account_id = metadata["account_id"].to_s
        document_id = metadata["document_id"].to_s

        if account_id.blank? || document_id.blank?
          return Result.new(chunks: chunks, blocked: true, undeclared_private: undeclared_private)
        end

        unless DocumentIdentityCatalog::GENERAL_ACCOUNT_IDS.include?(account_id)
          undeclared_private += 1
          Rails.logger.info(
            "[DOCUMENT_IDENTITY] undeclared_private account_id=#{account_id} document_id=#{document_id}"
          )
          scoped << chunk
          next
        end

        entry = catalog.find(account_id, document_id)
        if entry.nil? || !entry.confirmed
          return Result.new(chunks: chunks, blocked: true, undeclared_private: undeclared_private)
        end

        if entry.generic || matches?(entry, labels)
          scoped << chunk
        else
          scoped << redact(chunk, metadata)
        end
      end

      Result.new(chunks: scoped, blocked: false, undeclared_private: undeclared_private)
    end

    def self.episode_labels(episode)
      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      values = []
      %w[manufacturer model].each do |key|
        fact = parsed.fact(key)
        values << fact["value"] if fact&.dig("status") == "known"
      end
      parsed.identifiers.each { |item| values << item["value"] }
      values.filter_map { |value| FollowupQueryRewriter.normalize_label(value).presence }.uniq
    end

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

      copied = metadata.except("section_identity")
      chunk.merge(
        content: body,
        metadata: copied,
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

    def self.metadata_of(chunk)
      chunk[:metadata].to_h.stringify_keys
    end
    private_class_method :metadata_of
  end
end
