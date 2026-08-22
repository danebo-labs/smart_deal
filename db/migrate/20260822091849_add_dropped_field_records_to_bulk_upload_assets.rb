# frozen_string_literal: true

# A dropped field_record is content the model produced and we chose not to keep,
# on a document that still counts as ingested. Rails.logger is the wrong home for
# that: pilot logs live in a Docker json-file with max-size=10m and no max-file,
# so the record of what safety content was discarded rotates away. This column is
# the durable copy.
class AddDroppedFieldRecordsToBulkUploadAssets < ActiveRecord::Migration[8.1]
  def change
    add_column :bulk_upload_assets, :dropped_field_records, :jsonb, default: [], null: false
  end
end
