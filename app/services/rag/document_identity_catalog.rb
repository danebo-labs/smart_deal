# frozen_string_literal: true

module Rag
  # Versioned identity of the general corpus. Index account ids, not local
  # accounts.id: "1" is danebo-legacy and "3" is danebo-pilot-elevator.
  class DocumentIdentityCatalog
    PATH = Rails.root.join("config/document_identities.yml")
    GENERAL_ACCOUNT_IDS = %w[1 3].freeze

    Entry = Data.define(
      :account_id, :document_id, :s3_key, :display_name,
      :brands, :designators, :generic, :confirmed
    )

    def self.load(path = PATH)
      raw = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      new(raw)
    end

    def self.current
      @current ||= load
    rescue StandardError => e
      Rails.logger.error("[DOCUMENT_IDENTITY] catalog_unreadable #{e.class}")
      @current = new("documents" => [])
    end

    def self.with_catalog(catalog)
      previous = @current
      @current = catalog
      yield
    ensure
      @current = previous
    end

    def initialize(raw)
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
          confirmed: row["confirmed"] == true
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

    def activatable?
      entries.any? && entries.all?(&:confirmed)
    end

    def unconfirmed_count
      entries.count { |entry| !entry.confirmed }
    end
  end
end
