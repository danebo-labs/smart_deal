# frozen_string_literal: true

require "test_helper"

class BulkUploadAssetErrorMessageTest < ActiveSupport::TestCase
  test "display translates JSON key with current locale" do
    stored = described_class.encode(
      "bulk_uploads.unsupported_file_type",
      mime: "application/octet-stream", filename: "x.avif", allowed: "image/jpeg"
    )

    I18n.with_locale(:es) do
      msg = described_class.display(stored)
      assert_match(/Tipo de archivo no compatible/, msg)
      assert_match(/x\.avif/, msg)
    end
  end

  test "display re-translates legacy English unsupported message in Spanish UI" do
    legacy = "Unsupported file type 'application/octet-stream' for folder/x.avif. Allowed: image/jpeg, image/png"

    I18n.with_locale(:es) do
      msg = described_class.display(legacy)
      assert_match(/Tipo de archivo no compatible/, msg)
      assert_no_match(/Unsupported file type/, msg)
    end
  end

  private

  def described_class
    BulkUploadAssetErrorMessage
  end
end
