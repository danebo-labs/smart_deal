# frozen_string_literal: true

# Mock Vips module for CI environments where the real vips is not installed.
# Used when require 'vips' raises LoadError (e.g. libvips not installed).
module Vips
  class Error < StandardError; end

  class Image
    def self.black(width, height)
      new
    end

    def self.new_from_buffer(data, opts = "")
      raise Error, "unable to load" if data.blank?
      # Raise for invalid/non-image data (e.g. "X" * 600_000)
      str = data.to_s
      if str.bytesize > 1000
        looks_like_image = str.start_with?("GIF8") ||
          (str.getbyte(0) == 0xFF && str.getbyte(1) == 0xD8) ||
          (str.getbyte(0) == 0x89 && str.getbyte(1) == 0x50 && str.getbyte(2) == 0x4E && str.getbyte(3) == 0x47)
        raise Error, "invalid image" unless looks_like_image
      end
      new
    end

    def self.new_from_file(path, **opts)
      new
    end

    def write_to_buffer(format)
      # Return a minimal, valid image string for the given format.
      Base64.decode64("R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=")
    end

    def close
      # no-op for mock
    end
  end
end
