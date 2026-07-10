#!/usr/bin/env ruby
# frozen_string_literal: true

#
# One-shot generator for per-account brand assets (logo / favicon / apple
# touch icon) from a single wordmark source image. Not run at request time —
# outputs are committed to the repo and served as static assets by
# AccountBranding (see app/services/account_branding.rb).
#
# Usage:
#   bundle exec ruby script/generate_account_brand_assets.rb SOURCE_IMAGE SLUG
#
# Example:
#   bundle exec ruby script/generate_account_brand_assets.rb \
#     ~/Downloads/climb-190x64-org.avif elevadores-climb
#
# Outputs:
#   app/assets/images/accounts/<slug>/logo.png     (2x wordmark, transparent)
#   app/assets/images/accounts/<slug>/favicon.png  (32x32, wordmark padded)
#   public/brands/<slug>/icon-180.png              (180x180, same padding)
#
require "vips"
require "fileutils"

source_path = ARGV[0] or abort("Usage: #{$PROGRAM_NAME} SOURCE_IMAGE SLUG")
slug        = ARGV[1] or abort("Usage: #{$PROGRAM_NAME} SOURCE_IMAGE SLUG")

ROOT          = File.expand_path("..", __dir__)
LOGO_SCALE    = 2   # wordmark → 2x for crisp header/sidebar/auth rendering
FAVICON_SIZE  = 32
ICON_SIZE     = 180
SQUARE_MARGIN = 0.16 # fraction of the square canvas left empty around the wordmark

# Centers +image+ (any aspect ratio) inside a transparent +size+x+size+ canvas,
# scaling it down to fit within the margin. Used for favicon/apple-touch icon
# since the source is a horizontal wordmark, not a square mark.
def pad_to_square(image, size, margin:)
  usable = size * (1 - (margin * 2))
  scale  = [ usable / image.width, usable / image.height ].min
  scaled = image.resize(scale)
  left = ((size - scaled.width) / 2.0).round
  top  = ((size - scaled.height) / 2.0).round
  scaled.embed(left, top, size, size, extend: :background, background: [ 0, 0, 0, 0 ])
end

source = Vips::Image.new_from_file(source_path, access: :sequential)
source = source.colourspace("srgb") unless source.interpretation == :srgb
source = source.bandjoin(255) if source.bands < 4 # ensure alpha channel for transparent padding

logo_dir  = File.join(ROOT, "app/assets/images/accounts", slug)
brand_dir = File.join(ROOT, "public/brands", slug)
FileUtils.mkdir_p(logo_dir)
FileUtils.mkdir_p(brand_dir)

logo_path    = File.join(logo_dir, "logo.png")
favicon_path = File.join(logo_dir, "favicon.png")
icon180_path = File.join(brand_dir, "icon-180.png")

source.resize(LOGO_SCALE).write_to_file(logo_path)
pad_to_square(source, FAVICON_SIZE, margin: SQUARE_MARGIN).write_to_file(favicon_path)
pad_to_square(source, ICON_SIZE, margin: SQUARE_MARGIN).write_to_file(icon180_path)

puts "Wrote:"
puts "  #{logo_path}"
puts "  #{favicon_path}"
puts "  #{icon180_path}"
