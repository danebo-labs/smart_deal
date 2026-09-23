# frozen_string_literal: true

module Rag
  # Versioned identity of the general corpus. Index account ids, not local
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
    end

    def find(account_id, document_id)
      @entries[[ account_id.to_s, document_id.to_s ]]
    end

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

    def evidence_page_of(value)
      return if value.nil? || value.to_s.strip.empty?

      Integer(value)
    end
  end
end
