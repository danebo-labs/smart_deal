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

    Resolution = Data.define(:status, :value, :type, :manufacturer, :candidates)
    # Brand plus designator of one visible entry. Exact tokens only: a shorter
    # token does not select a longer designator.
    CompoundBrand = Data.define(:brand, :designator)

    def initialize(raw, loaded: true)
      @loaded = loaded
      @entries = {}
      @designator_types = {}
      Array(raw["documents"]).each do |row|
        row = row.to_h.stringify_keys
        entry = Entry.new(
          account_id: row["account_id"].to_s,
          document_id: row["document_id"].to_s,
          s3_key: row["s3_key"].to_s,
          display_name: row["display_name"].to_s,
          brands: Array(row["brands"]).map(&:to_s),
          designators: designator_values(row),
          generic: row["generic"] == true,
          confirmed: row["confirmed"] == true,
          evidence_page: evidence_page_of(row["evidence_page"]),
          evidence_text: row["evidence_text"].to_s.presence,
          role: row["role"].to_s.presence
        )
        @entries[[ entry.account_id, entry.document_id ]] = entry
        remember_designator_types(entry, row["designators"])
      end
      index_entries!
    end

    # Exact canonical wins over a longer prefix. A prefix expands only when
    # one canonical remains. A collision asks; it does not pick.
    #
    # viewer_account nil keeps the unscoped YAML lookup used by F8.
    # A viewer only sees entries KnowledgeScopePolicy authorizes. A YAML row
    # is not authorization. Unauthorized matches contribute nothing: no
    # canonical value, manufacturer, candidates, or alias.
    def resolve_designator(token, viewer_account: nil)
      norm = designator_label(token)
      return unresolved if norm.blank?

      exact = visible_rows(designator_rows.select { |row| row[:norm] == norm }, viewer_account)
      return designator_resolution(exact, :exact) if exact.any?
      return unresolved if norm.length < 6 || !norm.match?(/\d/)

      prefixed = designator_rows.select { |row|
        row[:norm].start_with?(norm) && (row[:norm].length - norm.length) <= 4
      }
      prefixed = visible_rows(prefixed, viewer_account)
      canons = prefixed.uniq { |row| row[:norm] }
      return unresolved if canons.empty?
      return ambiguous_resolution(canons) if canons.size > 1

      designator_resolution(prefixed.select { |row| row[:norm] == canons.first[:norm] }, :prefix)
    end

    # First token is one exact brand and the remainder is one exact designator
    # of that same visible, confirmed entry. Two entries, an ambiguous brand,
    # or a designator of a different entry return nil. No prefix match.
    def resolve_compound_brand(span, viewer_account: nil)
      tokens = span.to_s.squish.split(/\s+/)
      return nil if tokens.size < 2

      brand_norm = FollowupQueryRewriter.normalize_label(tokens.first)
      rest_norm = designator_label(tokens.drop(1).join(" "))
      return nil if brand_norm.blank? || rest_norm.blank?

      brand_matches = entries.filter_map { |entry|
        brand = Array(entry.brands).find { |item| FollowupQueryRewriter.normalize_label(item) == brand_norm }
        next if brand.blank? || !entry.confirmed

        { entry: entry, brand: brand }
      }
      brand_matches = visible_entry_matches(brand_matches, viewer_account)
      return nil unless brand_matches.map { |row| row[:brand].downcase }.uniq.one?

      hits = visible_rows(
        designator_rows.select { |row| row[:norm] == rest_norm && row[:entry].confirmed },
        viewer_account
      )
      brand_keys = brand_matches.map { |row| entry_key(row[:entry]) }
      shared = hits.select { |row| brand_keys.include?(entry_key(row[:entry])) }
      return nil unless shared.uniq { |row| entry_key(row[:entry]) }.one?

      entry = shared.first[:entry]
      brand = Array(entry.brands).find { |item| FollowupQueryRewriter.normalize_label(item) == brand_norm }
      return nil if brand.blank?

      CompoundBrand.new(brand: brand, designator: shared.first[:value])
    end

    # Exact brand only. No prefix and no fuzzy match. One canonical brand
    # (downcase) is one manufacturer. Two canonical strings are ambiguous.
    def resolve_brand(token, viewer_account: nil)
      norm = FollowupQueryRewriter.normalize_label(token)
      return unresolved if norm.blank?

      matches = entries.filter_map { |entry|
        brand = Array(entry.brands).find { |item| FollowupQueryRewriter.normalize_label(item) == norm }
        next if brand.blank?

        { entry: entry, brand: brand }
      }
      matches = visible_entry_matches(matches, viewer_account)
      return unresolved if matches.empty?

      canonicals = matches.map { |row| row[:brand] }.uniq { |brand| brand.downcase }
      if canonicals.size > 1
        return Resolution.new(
          status: :ambiguous, value: nil, type: nil, manufacturer: nil, candidates: canonicals
        )
      end

      brand = canonicals.first
      Resolution.new(status: :exact, value: brand, type: "manufacturer", manufacturer: brand, candidates: [])
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
      @designator_rows = entries.flat_map { |entry|
        Array(entry.designators).filter_map { |value|
          norm = designator_label(value)
          next if norm.blank?

          {
            value: value,
            norm: norm,
            type: @designator_types[[ entry.account_id, entry.document_id, norm ]],
            entry: entry
          }
        }
      }
    end

    def designator_rows
      @designator_rows || []
    end

    def designator_values(row)
      Array(row["designators"]).filter_map { |item|
        text = item.is_a?(Hash) ? item["value"] : item
        text.to_s.strip.presence
      }
    end

    def remember_designator_types(entry, raw)
      Array(raw).each do |item|
        next unless item.is_a?(Hash)

        value = item["value"].to_s.strip
        type = item["type"].to_s
        next if value.blank? || %w[controller model family].exclude?(type)

        norm = designator_label(value)
        @designator_types[[ entry.account_id, entry.document_id, norm ]] = type
      end
    end

    # "+" stays on the designator. normalize_label drops it, so MH would
    # equal MH+ and CEA15 would equal CEA15+. Brands still use that method.
    def designator_label(value)
      value.to_s
           .unicode_normalize(:nfkd)
           .gsub(/\p{Mn}/, "")
           .downcase
           .gsub(/[^\p{L}\d+]+/, " ")
           .squish
    end

    def unresolved
      Resolution.new(status: :none, value: nil, type: nil, manufacturer: nil, candidates: [])
    end

    def visible_rows(rows, viewer_account)
      return rows if viewer_account.nil?
      return [] if rows.empty?

      allowed = authorized_entry_keys(rows.pluck(:entry), viewer_account)
      rows.select { |row| allowed.include?(entry_key(row[:entry])) }
    end

    def visible_entry_matches(matches, viewer_account)
      return matches if viewer_account.nil?
      return [] if matches.empty?

      allowed = authorized_entry_keys(matches.pluck(:entry), viewer_account)
      matches.select { |row| allowed.include?(entry_key(row[:entry])) }
    end

    def authorized_entry_keys(catalog_entries, viewer_account)
      list = Array(catalog_entries).uniq { |entry| entry_key(entry) }
      candidates = list.map { |entry|
        { document_id: entry.document_id, s3_key: entry.s3_key, catalog_account_id: entry.account_id }
      }
      db_rows = KnowledgeScopePolicy.rows_for_catalog_candidates(candidates)
      list.filter_map { |entry|
        bound = KnowledgeScopePolicy.bind_catalog_candidate(
          { document_id: entry.document_id, s3_key: entry.s3_key, catalog_account_id: entry.account_id },
          rows: db_rows,
          viewer_account: viewer_account
        )
        entry_key(entry) if bound
      }
    end

    def entry_key(entry)
      [ entry.account_id.to_s, entry.document_id.to_s, entry.s3_key.to_s ]
    end

    def ambiguous_resolution(rows)
      Resolution.new(
        status: :ambiguous,
        value: nil,
        type: nil,
        manufacturer: nil,
        candidates: rows.pluck(:value).uniq
      )
    end

    def designator_resolution(rows, status)
      values = rows.map { |row| row[:value] }.uniq { |value| designator_label(value) }
      return ambiguous_resolution(rows) if values.size > 1

      types = rows.filter_map { |row| row[:type] }.uniq
      type = types.one? ? types.first : nil
      brands = rows.flat_map { |row| Array(row[:entry].brands) }.compact_blank.uniq { |brand| brand.downcase }
      confirmed = rows.all? { |row| row[:entry].confirmed }
      manufacturer = confirmed && type && brands.one? ? brands.first : nil
      type = nil unless confirmed && manufacturer
      Resolution.new(status: status, value: values.first, type: type, manufacturer: manufacturer, candidates: [])
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
