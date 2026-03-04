'''# frozen_string_literal: true

# Mock Vips module for CI environments where the real vips is not installed.
module Vips
  class Error < StandardError; end

  class Image
    def self.black(width, height)
      new
    end

    def write_to_buffer(format)
      # Return a minimal, valid image string for the given format.
      # This is a 1x1 pixel black GIF.
      Base64.decode64("R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=")
    end
  end
end
'''
