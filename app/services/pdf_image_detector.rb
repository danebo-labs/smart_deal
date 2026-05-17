# frozen_string_literal: true

# Detects whether a PDF contains embedded image XObjects using HexaPDF.
# Walks the page tree looking for /XObject resources with /Subtype /Image.
# No image decoding — pure structural inspection.
class PdfImageDetector
  # @param binary [String] raw PDF bytes
  # @return [Boolean]
  def self.has_images?(binary)
    new(binary).image_pages.any?
  end

  # @param binary [String] raw PDF bytes
  # @return [Set<Integer>] 1-indexed page numbers that contain at least one Image XObject
  def self.image_pages(binary)
    new(binary).image_pages
  end

  def initialize(binary)
    @binary = binary
  end

  def image_pages
    @image_pages ||= begin
      result = Set.new
      doc    = HexaPDF::Document.new(io: StringIO.new(@binary))

      doc.pages.each_with_index do |page, idx|
        xobjects = page[:Resources]&.[](:XObject)
        next unless xobjects.is_a?(HexaPDF::Dictionary)

        xobjects.each do |_name, xobj|
          next unless xobj.is_a?(HexaPDF::Dictionary)

          if xobj[:Subtype].to_s == "Image"
            result.add(idx + 1)
            break
          end
        end
      end

      result
    rescue StandardError => e
      Rails.logger.warn("PdfImageDetector: #{e.class} — #{e.message}")
      Set.new
    end
  end
end
