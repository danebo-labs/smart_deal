# frozen_string_literal: true

require "digest"
require "fileutils"
require "vips"

# How the two photos of case 29 (T1 console, T3 guide) become the 576x448 JPEG
# that Rag::GuardedPhotoVision accepts. The guard is unchanged: the photo is
# fitted into the frame keeping its proportion, with neutral grey borders. The
# result is not the original bytes. Every run records the source SHA-256, the
# parameters and the prepared SHA-256 in photos.json, so the next run can be
# compared byte for byte with this one.
#
# Pure: reads a file, writes a file. No database, no network.
module Stage1Live
  module PhotoPrep
    module_function

    WIDTH = 576
    HEIGHT = 448
    BACKGROUND = [ 128, 128, 128 ].freeze
    QUALITY = 90
    FIXTURES = File.expand_path("../../test/fixtures/files/field_companion/otis_case29", __dir__)

    # The supplied images, kept in the repository with the hash that the live
    # run 20261120T012019Z recorded for them.
    SOURCES = {
      1 => { "file" => File.join(FIXTURES, "otis-t1-console.jpg"),
             "sha256" => "731004c7b081cec5cf26efc1b87774739dfdf5b5334047cbd1c0de091dc98690" },
      3 => { "file" => File.join(FIXTURES, "otis-t3-guide.jpg"),
             "sha256" => "35fc2281cb38dc4dc9cf4b849b8d33b3a2ea3e5df66a8f964d827617c4a7e2e1" }
    }.freeze

    # What the live run produced from those sources.
    PREPARED_SHA256 = {
      1 => "2277e269768391bd7e76036a78bb333f5cd5c488caa56fe1c7546459f2d43d8f",
      3 => "fb8d4b0fcc53f934f79559e5d6cbbbaf1921ae656b2c3056ebfee5672cda34ad"
    }.freeze

    def parameters
      {
        "canvas" => [ WIDTH, HEIGHT ], "fit" => "proportional, centered, no crop", "background" => BACKGROUND,
        "format" => "jpeg", "quality" => QUALITY, "strip_metadata" => true, "libvips" => Vips.version_string
      }
    end

    # Writes the prepared JPEG and returns what was done. A source whose
    # SHA-256 is not the recorded one is refused unless the caller passes the
    # expected hash of its own file.
    def prepare(source, destination, expected_sha256: nil)
      sha = Digest::SHA256.file(source).hexdigest
      raise ArgumentError, "source #{source} has SHA-256 #{sha}, expected #{expected_sha256}" if expected_sha256 && sha != expected_sha256

      image = Vips::Image.new_from_file(source)
      scaled = image.resize([ WIDTH.fdiv(image.width), HEIGHT.fdiv(image.height) ].min)
      framed = scaled.embed((WIDTH - scaled.width) / 2, (HEIGHT - scaled.height) / 2, WIDTH, HEIGHT,
        extend: :background, background: BACKGROUND)
      FileUtils.mkdir_p(File.dirname(destination))
      framed.write_to_file(destination.to_s, Q: QUALITY, strip: true)
      raise ArgumentError, "prepared photo is not #{WIDTH}x#{HEIGHT}" unless Vips::Image.new_from_file(destination.to_s).size == [ WIDTH, HEIGHT ]

      {
        "source" => source.to_s, "source_bytes" => File.size(source), "source_sha256" => sha,
        "source_size" => [ image.width, image.height ], "prepared" => destination.to_s,
        "prepared_bytes" => File.size(destination), "prepared_sha256" => Digest::SHA256.file(destination).hexdigest,
        "prepared_size" => [ WIDTH, HEIGHT ], "parameters" => parameters,
        "note" => "Not the original bytes: re-encoded into the frame the vision guard accepts."
      }
    end
  end
end
