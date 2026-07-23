# frozen_string_literal: true

# Disk-backed representation of one split PDF page.
#
# The path is intentionally stored without retaining a Tempfile object so Ruby's
# finalizer cannot unlink the page while it is still queued for batch submission.
class SplitPage
  attr_reader :number, :path, :byte_size, :text
  attr_accessor :model, :force_opus

  def initialize(number:, path:, byte_size:, text:)
    @number     = number
    @path       = path
    @byte_size  = byte_size
    @text       = text.to_s
    @model      = BatchChunkingPrompt::MODEL_TEXT
    @force_opus = false
  end

  def binary
    File.binread(path)
  end

  def cleanup
    File.unlink(path) if path.present? && File.exist?(path)
  rescue Errno::ENOENT
    nil
  end

  def cleaned?
    path.blank? || !File.exist?(path)
  end
end
