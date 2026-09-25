# frozen_string_literal: true

module Rag
  # Versioned identity of the general corpus. Not consulted on the query
  # path: FC-D12 labels from the retrieved chunk. Index account ids, not local
  # accounts.id: "1" is danebo-legacy and "3" is danebo-pilot-elevator.
  class DocumentIdentityCatalog
    PATH = Rails.root.join("config/document_identities.yml")
    GENERAL_ACCOUNT_IDS = %w[1 3].freeze

    Entry = Data.define(
      :account_id, :document_id, :s3_key, :display_name,
      :brands, :designators, :generic, :confirmed,
      :evidence_page, :evidence_text, :role
    )

    def self.load(path = PATH)
      raw = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      new(raw)
    end

    def self.current
      @current ||= load
    rescue StandardError => e
      Rails.logger.error("[DOCUMENT_IDENTITY] catalog_unreadable #{e.class}")
      @current = new({ "documents" => [] }, loaded: false)
    end

    def self.with_catalog(catalog)
      previous = @current
      @current = catalog
      yield
    ensure
      @current = previous
    end

    def initialize(raw, loaded: true)
      @loaded = loaded
      @entries = {}
      Array(raw["documents"]).each do |row|
        row = row.to_h.stringify_keys
        entry = Entry.new(
          account_id: row["account_id"].to_s,
          document_id: row["document_id"].to_s,
          s3_key: row["s3_key"].to_s,
          display_name: row["display_name"].to_s,
          brands: Array(row["brands"]).map(&:to_s),
          designators: Array(row["designators"]).map(&:to_s),
          generic: row["generic"] == true,
          confirmed: row["confirmed"] == true,
          evidence_page: evidence_page_of(row["evidence_page"]),
          evidence_text: row["evidence_text"].to_s.presence,
          role: row["role"].to_s.presence
        )
        @entries[[ entry.account_id, entry.document_id ]] = entry
      end
      index_entries!
    end

    def find(account_id, document_id)
      @entries[[ account_id.to_s, document_id.to_s ]]
    end

    def for_document(document)
      key = document.respond_to?(:s3_key) ? document.s3_key : nil
      found = for_s3_key(key)
      return found if found

      uid = document.respond_to?(:document_uid) ? document.document_uid.to_s : ""
      found = @by_document_id[uid] if uid.present?
      return found if found

      name = document.respond_to?(:display_name) ? document.display_name.to_s : ""
      @unique_display_names[name]
    end

    # One designator that equals the span is one model identity. Extra
    # designators on that same entry are variant tokens, not a second model.
    # A different designator and no match for the span is a different model.
    # An alias-only hit whose display name does not name the span is not
    # evidence for that identity.
    def self.consensus(entries, span)
      needle = span.to_s
      return nil if needle.blank?

      confirmed = []
      brands = []
      foreign = false
      Array(entries).select { |entry| identifies_span?(entry, needle) }.each do |entry|
        designators = Array(entry.designators)
        matched = designators.select { |item| item.casecmp?(needle) }
        if matched.any?
          confirmed << matched.first
          brands.concat(Array(entry.brands))
        elsif designators.any?
          foreign = true
        end
      end

      identities = confirmed.uniq { |item| item.downcase }
      return { "ambiguous" => true } if foreign || identities.size > 1
      return nil unless identities.one?

      brand_names = brands.map(&:to_s).compact_blank.uniq { |item| item.downcase }
      { "model" => identities.first, "manufacturer" => (brand_names.one? ? brand_names.first : nil) }
    end

    def self.identifies_span?(entry, needle)
      Array(entry.designators).any? { |item| item.casecmp?(needle) } ||
        entry.display_name.to_s.match?(/\b#{Regexp.escape(needle)}\b/i)
    end
    private_class_method :identifies_span?

    def entries
      @entries.values
    end

    def loaded?
      @loaded
    end

    def self.effectively_confirmed?(entry)
      return false unless entry&.confirmed
      return false unless entry.evidence_page.is_a?(Integer) && entry.evidence_page.positive?

      entry.evidence_text.present?
    end

    def activatable?
      loaded? && entries.any? { |entry| self.class.effectively_confirmed?(entry) }
    end

    def unconfirmed_count
      entries.count { |entry| !entry.confirmed }
    end

    private

    def index_entries!
      @by_document_id = {}
      @by_s3_key = {}
      @unique_display_names = {}
      seen_names = Hash.new(0)
      entries.each do |entry|
        @by_document_id[entry.document_id] = entry if entry.document_id.present?
        [ entry.s3_key, KbDocument.object_key_for_match(entry.s3_key) ].compact.uniq.each do |key|
          @by_s3_key[key] = entry if key.present?
        end
        seen_names[entry.display_name] += 1 if entry.display_name.present?
      end
      entries.each do |entry|
        @unique_display_names[entry.display_name] = entry if seen_names[entry.display_name] == 1
      end
    end

    def for_s3_key(s3_key)
      key = s3_key.to_s
      @by_s3_key[key] || @by_s3_key[KbDocument.object_key_for_match(key).to_s]
    end

    def evidence_page_of(value)
      return if value.nil? || value.to_s.strip.empty?

      Integer(value)
    end
  end
end
