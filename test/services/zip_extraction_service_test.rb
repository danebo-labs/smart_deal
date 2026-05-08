# frozen_string_literal: true

require 'test_helper'
require 'zip'
require 'tmpdir'

class ZipExtractionServiceTest < ActiveSupport::TestCase
  # Minimal valid file binaries (magic bytes only — force binary encoding)
  JPEG_BINARY = ("\xFF\xD8\xFF\xE0" + ("x" * 100)).b
  PNG_BINARY  = ("\x89PNG\r\n\x1A\n" + ("x" * 100)).b
  PDF_BINARY  = ("%PDF-1.4\n" + ("x" * 100)).b

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
  # MIME allowlist enforcement
  # ============================================

  test 'raises Error for disallowed MIME type' do
    gif_binary = "GIF89a" + ("x" * 100)
    path = build_zip(entries: { 'anim.gif' => gif_binary })

    err = assert_raises(ZipExtractionService::Error) do
      ZipExtractionService.new(path).each_entry { }
    end
    assert_match(/Unsupported file type/, err.message)
  end

  test 'raises Error for plain text files' do
    path = build_zip(entries: { 'readme.txt' => 'hello world' })

    assert_raises(ZipExtractionService::Error) do
      ZipExtractionService.new(path).each_entry { }
    end
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
