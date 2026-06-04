# frozen_string_literal: true

module BulkUploadsHelper
  def bulk_upload_asset_error_message(asset)
    BulkUploadAssetErrorMessage.display(asset.error_message)
  end
end
