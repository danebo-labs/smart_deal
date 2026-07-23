# frozen_string_literal: true

# Lightweight request descriptor. It retains only request metadata and a lazy
# builder, allowing batch groups to read/base64 one bounded set of tempfiles.
class ClaudeBatchRequestItem
  attr_reader :custom_id, :byte_size

  def initialize(custom_id:, byte_size:, build:, cleanup:)
    @custom_id = custom_id
    @byte_size = byte_size.to_i
    @build     = build
    @cleanup   = cleanup
  end

  def build
    @build.call
  ensure
    cleanup
  end

  def cleanup
    return if @cleaned

    @cleaned = true
    @cleanup.call
  end
end
