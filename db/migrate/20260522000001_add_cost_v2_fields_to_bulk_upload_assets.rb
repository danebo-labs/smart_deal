# frozen_string_literal: true

class AddCostV2FieldsToBulkUploadAssets < ActiveRecord::Migration[8.1]
  def change
    add_column :bulk_upload_assets, :batch_custom_ids, :jsonb, null: false, default: []
    add_column :bulk_upload_assets, :ingestion_path, :string
  end
end
