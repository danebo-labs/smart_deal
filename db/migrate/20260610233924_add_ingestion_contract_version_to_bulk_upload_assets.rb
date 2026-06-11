class AddIngestionContractVersionToBulkUploadAssets < ActiveRecord::Migration[8.1]
  def change
    add_column :bulk_upload_assets, :ingestion_contract_version, :string
  end
end
