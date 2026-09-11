# frozen_string_literal: true

require "test_helper"

# Guards the client-side image size check order in rag_chat_controller.js.
# A 4–8 MB phone JPEG must be compressed (Canvas → 1024 px JPEG) BEFORE the
# 3.75 MB Bedrock ingest ceiling is applied. Checking the raw file first is
# what blocked camera photos on 11-sep-2026.
class ImageUploadGuardOrderTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/controllers/rag_chat_controller.js").read.freeze

  test "MAX_IMAGE_SIZE is compared after compressImageOnClient and MAX_IMAGE_INPUT_SIZE is larger" do
    call_at = SOURCE.index("this.compressImageOnClient(")
    bytes_check_at = SOURCE.index("bytes > this.constructor.MAX_IMAGE_SIZE")

    assert call_at, "selectFile must call this.compressImageOnClient"
    assert bytes_check_at, "compressed output must be checked against MAX_IMAGE_SIZE"
    assert_operator bytes_check_at, :>, call_at,
                    "MAX_IMAGE_SIZE must be compared after compressImageOnClient, not against the raw camera file"

    input_mb = SOURCE[/\bMAX_IMAGE_INPUT_SIZE\s*=\s*([0-9.]+)\s*\*\s*1024\s*\*\s*1024/, 1]
    ingest_mb = SOURCE[/\bMAX_IMAGE_SIZE\s*=\s*([0-9.]+)\s*\*\s*1024\s*\*\s*1024/, 1]
    assert input_mb, "MAX_IMAGE_INPUT_SIZE must be declared"
    assert ingest_mb, "MAX_IMAGE_SIZE must be declared"
    assert_operator input_mb.to_f, :>, ingest_mb.to_f,
                    "raw camera ceiling must exceed the post-compression ingest ceiling"
  end
end
