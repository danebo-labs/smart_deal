# frozen_string_literal: true

require 'test_helper'
require 'zip'
require 'tmpdir'

class ZipExtractionServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # Minimal valid file binaries (magic bytes only — force binary encoding)
  JPEG_BINARY = ("\xFF\xD8\xFF\xE0" + ("x" * 100)).b
  PNG_BINARY  = ("\x89PNG\r\n\x1A\n" + ("x" * 100)).b
  PDF_BINARY  = ("%PDF-1.4\n" + ("x" * 100)).b
  GIF_BINARY  = ("GIF89a" + ("x" * 100)).b
  WEBP_BINARY = ("RIFF\x00\x00\x00\x00WEBP" + ("x" * 100)).b

  def build_zip(entries:)
    path = Tempfile.new([ 'test_zip', '.zip' ]).path
    Zip::OutputStream.open(path) do |zos|
      entries.each do |name, content|
        zos.put_next_entry(name)
        zos.write(content)
      end
    end
    path
  end

  # ============================================
  # Valid ZIP — happy path
  # ============================================

  test 'yields one entry per valid file with correct fields' do
    path = build_zip(entries: { 'photo.jpg' => JPEG_BINARY, 'manual.pdf' => PDF_BINARY })
    results = []

    ZipExtractionService.new(path).each_entry { |e| results << e }

    assert_equal 2, results.size
    jpg = results.find { |r| r[:filename] == 'photo.jpg' }
    assert_not_nil jpg
    assert_equal 'image/jpeg', jpg[:content_type]
    assert_equal Digest::SHA256.hexdigest(JPEG_BINARY), jpg[:sha256]
    assert_equal JPEG_BINARY, jpg[:binary]
    assert_equal false, jpg[:office_origin]
  end

  test 'skips directories and hidden files' do
    path = build_zip(entries: {
      '__MACOSX/'        => '',
      '.DS_Store'        => 'junk',
      'real/photo.png'   => PNG_BINARY
    })
    results = []
    ZipExtractionService.new(path).each_entry { |e| results << e }

    assert_equal 1, results.size
    assert_equal 'photo.png', results.first[:filename]
  end

  test 'detects PNG by magic bytes' do
    path = build_zip(entries: { 'img.png' => PNG_BINARY })
    results = []
    ZipExtractionService.new(path).each_entry { |e| results << e }

    assert_equal 'image/png', results.first[:content_type]
  end

  test 'detects PDF by magic bytes' do
    path = build_zip(entries: { 'doc.pdf' => PDF_BINARY })
    results = []
    ZipExtractionService.new(path).each_entry { |e| results << e }

    assert_equal 'application/pdf', results.first[:content_type]
  end

  # ============================================
  # Webp / GIF detection
  # ============================================

  test 'detects WEBP by magic bytes' do
    path = build_zip(entries: { 'photo.webp' => WEBP_BINARY })
    results = []
    ZipExtractionService.new(path).each_entry { |e| results << e }

    assert_equal 1, results.size
    assert_equal 'image/webp', results.first[:content_type]
    assert_equal 'photo.webp', results.first[:filename]
  end

  test 'detects GIF by magic bytes' do
    path = build_zip(entries: { 'anim.gif' => GIF_BINARY })
    results = []
    ZipExtractionService.new(path).each_entry { |e| results << e }

    assert_equal 1, results.size
    assert_equal 'image/gif', results.first[:content_type]
  end

  # ============================================
  # Office → PDF conversion
  # ============================================

  test 'converts Office entry to PDF via OfficeToPdfConverter' do
    docx_binary = ("PK\x03\x04" + ("x" * 100)).b  # fake DOCX bytes
    pdf_result  = PDF_BINARY
    orig_convert = OfficeToPdfConverter.method(:convert)

    OfficeToPdfConverter.define_singleton_method(:convert) do |_binary, extension:|
      raise OfficeToPdfConverter::Error, "unsupported" unless extension == ".docx"
      pdf_result
    end

    path = build_zip(entries: { 'manual.docx' => docx_binary })
    results = []
    svc = ZipExtractionService.new(path)
    svc.each_entry { |e| results << e }

    assert_equal 1, results.size
    assert_equal 'application/pdf', results.first[:content_type]
    assert_equal 'manual.pdf',      results.first[:filename]
    assert_equal pdf_result,        results.first[:binary]
    assert_equal true,              results.first[:office_origin]
    assert_empty svc.skipped_entries
  ensure
    OfficeToPdfConverter.define_singleton_method(:convert, orig_convert) if defined?(orig_convert)
  end

  test 'skips Office entry when OfficeToPdfConverter fails (per-file, no global raise)' do
    docx_binary  = ("PK\x03\x04" + ("x" * 100)).b
    orig_convert = OfficeToPdfConverter.method(:convert)

    OfficeToPdfConverter.define_singleton_method(:convert) do |_binary, extension:|
      raise OfficeToPdfConverter::Error, "LibreOffice not found"
    end

    path = build_zip(entries: { 'doc.docx' => docx_binary })
    results = []
    svc = ZipExtractionService.new(path)
    svc.each_entry { |e| results << e }

    assert_empty results
    assert_equal 1, svc.skipped_entries.size
    assert_equal 'doc.docx', svc.skipped_entries.first[:filename]
    assert_equal "bulk_uploads.office_conversion_failed", svc.skipped_entries.first[:reason_key]
  ensure
    OfficeToPdfConverter.define_singleton_method(:convert, orig_convert) if defined?(orig_convert)
  end

  test 'skips Office entry alongside a valid PDF' do
    docx_binary  = ("PK\x03\x04" + ("x" * 100)).b
    orig_convert = OfficeToPdfConverter.method(:convert)

    OfficeToPdfConverter.define_singleton_method(:convert) do |_binary, extension:|
      raise OfficeToPdfConverter::Error, "LibreOffice not found"
    end

    path = build_zip(entries: { 'bad.docx' => docx_binary, 'good.pdf' => PDF_BINARY })
    results = []
    svc = ZipExtractionService.new(path)
    svc.each_entry { |e| results << e }

    assert_equal 1, results.size
    assert_equal 'good.pdf', results.first[:filename]
    assert_equal 1, svc.skipped_entries.size
    assert_equal 'bad.docx', svc.skipped_entries.first[:filename]
  ensure
    OfficeToPdfConverter.define_singleton_method(:convert, orig_convert) if defined?(orig_convert)
  end

  # ============================================
  # MIME allowlist enforcement — per-file skip (no global raise)
  # ============================================

  test 'skips entry with disallowed MIME type and accumulates in skipped_entries' do
    path = build_zip(entries: { 'readme.bin' => ("UNKNOWN" + ("x" * 100)).b })

    results = []
    svc = ZipExtractionService.new(path)
    svc.each_entry { |e| results << e }

    assert_empty results
    assert_equal 1, svc.skipped_entries.size
    assert_equal "bulk_uploads.unsupported_file_type", svc.skipped_entries.first[:reason_key]
    assert_equal 'readme.bin', svc.skipped_entries.first[:filename]
  end

  test 'skips plain text file and accumulates in skipped_entries' do
    path = build_zip(entries: { 'readme.txt' => 'hello world' })

    results = []
    svc = ZipExtractionService.new(path)
    svc.each_entry { |e| results << e }

    assert_empty results
    assert_equal 1, svc.skipped_entries.size
    assert_equal 'readme.txt', svc.skipped_entries.first[:filename]
  end

  test 'yields valid entries and skips invalid in mixed ZIP' do
    avif_binary = ("AVIF" + ("x" * 100)).b
    path = build_zip(entries: {
      'photo.jpg'  => JPEG_BINARY,
      'photo.avif' => avif_binary,
      'manual.pdf' => PDF_BINARY
    })

    results = []
    svc = ZipExtractionService.new(path)
    svc.each_entry { |e| results << e }

    assert_equal 2, results.size
    filenames = results.pluck(:filename)
    assert_includes filenames, 'photo.jpg'
    assert_includes filenames, 'manual.pdf'

    assert_equal 1, svc.skipped_entries.size
    assert_equal 'photo.avif', svc.skipped_entries.first[:filename]
    assert_equal "bulk_uploads.unsupported_file_type", svc.skipped_entries.first[:reason_key]
  end

  # ============================================
  # Per-file size cap (50 MB)
  # ============================================

  test 'raises Error when a single entry exceeds 50 MB' do
    # Construct a fake entry by stubbing size on the Zip::Entry object.
    # Rather than allocating 50 MB in memory, we override the size after building.
    large_content = JPEG_BINARY  # small actual content
    path = build_zip(entries: { 'big.jpg' => large_content })

    # Stub size/compressed_size to report over the limit with ratio ≤100× so bomb check passes
    original_size       = Zip::Entry.instance_method(:size)
    original_compressed = Zip::Entry.instance_method(:compressed_size)
    Zip::Entry.define_method(:size)             { 51 * 1024 * 1024 }
    Zip::Entry.define_method(:compressed_size)  { 1 * 1024 * 1024 }  # ratio ≈ 51×

    err = assert_raises(ZipExtractionService::Error) do
      ZipExtractionService.new(path).each_entry { }
    end
    assert_match(/File too large/, err.message)
  ensure
    Zip::Entry.define_method(:size, original_size)
    Zip::Entry.define_method(:compressed_size, original_compressed)
  end

  # ============================================
  # Total size cap (500 MB)
  # ============================================

  test 'raises Error when cumulative size exceeds 500 MB' do
    # 11 entries × 49 MB = 539 MB > 500 MB; each entry stays under per-file 50 MB cap
    entries = (1..11).each_with_object({}) { |i, h| h["f#{i}.jpg"] = JPEG_BINARY }
    path = build_zip(entries: entries)

    # 49 MB per file at ratio ≈ 10× (well under bomb limit)
    original_size       = Zip::Entry.instance_method(:size)
    original_compressed = Zip::Entry.instance_method(:compressed_size)
    Zip::Entry.define_method(:size)             { 49 * 1024 * 1024 }
    Zip::Entry.define_method(:compressed_size)  { 5 * 1024 * 1024 }  # ratio ≈ 10×

    err = assert_raises(ZipExtractionService::Error) do
      ZipExtractionService.new(path).each_entry { }
    end
    assert_match(/500 MB/, err.message)
  ensure
    Zip::Entry.define_method(:size, original_size)
    Zip::Entry.define_method(:compressed_size, original_compressed)
  end

  # ============================================
  # ZIP bomb (compression ratio > 100×)
  # ============================================

  test 'raises Error when compression ratio exceeds 100x' do
    path = build_zip(entries: { 'bomb.jpg' => JPEG_BINARY })

    original_compressed = Zip::Entry.instance_method(:compressed_size)
    original_size       = Zip::Entry.instance_method(:size)

    Zip::Entry.define_method(:compressed_size) { 1024 }
    Zip::Entry.define_method(:size) { 200 * 1024 * 1024 }  # 200 MB / 1 KB = 200000×

    err = assert_raises(ZipExtractionService::Error) do
      ZipExtractionService.new(path).each_entry { }
    end
    assert_match(/ZIP bomb/, err.message)
  ensure
    Zip::Entry.define_method(:compressed_size, original_compressed)
    Zip::Entry.define_method(:size, original_size)
  end
end
