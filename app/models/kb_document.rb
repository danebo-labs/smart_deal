# frozen_string_literal: true

# Global catalog row per S3 object key in the KB bucket. Created once on first upload;
# aliases can be enriched later (e.g. from entity extraction).
class KbDocument < ApplicationRecord
  has_one :thumbnail, class_name: "KbDocumentThumbnail", dependent: :destroy

  # DB: jsonb, default []. Stored as JSON array of strings; exposed as Array in Ruby.
  validates :s3_key, presence: true, uniqueness: true

  # Normalizes stored s3_key (plain object key or s3://bucket/key) for matching S3 list :full_path.
  def self.object_key_for_match(s3_ref)
    return nil if s3_ref.blank?

    s = s3_ref.to_s.strip
    s.sub(%r{\As3://[^/]+/}, "")
  end

  def display_s3_uri(bucket_name)
    return s3_key if s3_key.to_s.start_with?("s3://")
    return if bucket_name.blank?

    key = self.class.object_key_for_match(s3_key)
    "s3://#{bucket_name}/#{key}"
  end

  # Machine-generated upload names (WhatsApp/web chat). These filenames carry
  # no human value ("wa_20260410_174231_0.jpeg") and are never useful as
  # search aliases. Presence of this pattern is the ONLY signal that allows
  # overwriting a stored display_name with a richer canonical.
  MACHINE_FILENAME_PATTERN = /\A(?:wa|chat)_\d{8}_\d{6}_\d+\./.freeze

  def self.machine_generated_filename?(s3_key_or_filename)
    File.basename(s3_key_or_filename.to_s).match?(MACHINE_FILENAME_PATTERN)
  end

  def machine_generated_filename?
    self.class.machine_generated_filename?(s3_key)
  end

  # Plain-text derivation of the display name from s3_key. Used as the
  # fallback display_name when no canonical is available, and as the marker
  # for "auto-assigned placeholder" when deciding whether a display_name
  # is safe to overwrite with a richer canonical (display_name_promotable?).
  def stem_from_s3_key
    base = File.basename(s3_key.to_s)
    File.basename(base, ".*").tr("_-", " ").strip
  end

  # Always true: the Opus canonical discovered at ingestion wins over whatever
  # stem was stored at upload time. The original filename stem is kept in aliases.
  def display_name_promotable?
    true
  end

  # docs: hashes from S3DocumentsService#list_documents (:full_path). kb_by_object_key: index by object_key_for_match.
  # Newest KbDocument#created_at first; S3 objects without a KB row last (tamaño sigue alineado por fila).
  def self.sort_s3_documents_by_kb_created_at(docs, kb_by_object_key)
    docs.sort_by do |doc|
      kb = kb_by_object_key[doc[:full_path]]
      kb ? -kb.created_at.to_f : Float::INFINITY
    end
  end

  # First successful upload wins: creates row with optional human display_name from filename stem.
  # Does not overwrite an existing row.
  def self.ensure_for_s3_key!(key, size_bytes: nil)
    return if key.blank?

    record = find_or_initialize_by(s3_key: key)
    return record if record.persisted?

    stem = File.basename(key)
    record.display_name = File.basename(stem, ".*").tr("_-", " ").strip.presence
    record.aliases = [] if record.aliases.nil?
    record.size_bytes = size_bytes if size_bytes.present?
    record.save!
    record
  end

  # Easiest-to-read aliases for compact UI: fewest words, then shortest string.
  def simplest_display_aliases(limit = 2)
    Array(aliases).map(&:to_s).map(&:strip).compact_blank
      .uniq
      .sort_by { |a| [ a.split(/\s+/).size, a.length ] }
      .first(limit)
  end
end
