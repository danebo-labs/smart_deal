# frozen_string_literal: true

class AddOfficeOriginToBulkUploadAssets < ActiveRecord::Migration[8.0]
  def change
    add_column :bulk_upload_assets, :office_origin, :boolean, default: false, null: false
  end
end
