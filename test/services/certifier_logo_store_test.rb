# frozen_string_literal: true

require "test_helper"

# The logo is the one file a certifier uploads that is not evidence, so it gets
# its own prefix and its own validation. The point of these tests is that the
# format is decided by the real bytes: a declared content type and a filename
# are attacker-controlled and prove nothing.
class CertifierLogoStoreTest < ActiveSupport::TestCase
  class FakeS3
    attr_reader :uploads

    def initialize(succeed: true)
      @uploads = []
      @succeed = succeed
    end

    def upload_binary(key, data, content_type)
      @uploads << { key: key, data: data, content_type: content_type }
      @succeed && key
    end
  end

  def with_fake_s3(fake)
    orig = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { fake }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  def upload(binary, filename: "logo.png", type: "image/png")
    file = Tempfile.new([ "logo", File.extname(filename) ])
    file.binmode
    file.write(binary)
    file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: type)
  end

  def png_bytes
    @png_bytes ||= Rails.root.join("test/fixtures/files/tiny.png").binread
  end

  setup do
    @account_id = accounts(:legacy).id
  end

  test "stores a PNG under the certifier prefix, keyed by its digest" do
    fake = FakeS3.new
    result = with_fake_s3(fake) { CertifierLogoStore.call(upload(png_bytes), account_id: @account_id) }

    assert result.ok?
    assert_equal "image/png", result.content_type
    assert_equal Digest::SHA256.hexdigest(fake.uploads.first[:data]), result.sha256
    assert_match %r{\Acertifier_assets/#{@account_id}/#{result.sha256}/logo\.png\z}, result.s3_key
    assert_equal 1, fake.uploads.size
  end

  # Never under field_photos/: a brand mark must not be swept by the evidence
  # retention job, and it is not analyzed by any diagnosis pipeline.
  test "never writes under the field photo prefix" do
    fake = FakeS3.new
    with_fake_s3(fake) { CertifierLogoStore.call(upload(png_bytes), account_id: @account_id) }

    assert_no_match(/field_photos/, fake.uploads.first[:key])
  end

  test "keeps a PNG as a PNG so transparency survives" do
    fake = FakeS3.new
    result = with_fake_s3(fake) { CertifierLogoStore.call(upload(png_bytes), account_id: @account_id) }

    assert_equal "image/png", result.content_type
    assert_equal png_bytes.b, fake.uploads.first[:data].b, "a small logo must not be re-encoded"
  end

  test "isolates the object key per account" do
    fake = FakeS3.new
    with_fake_s3(fake) do
      CertifierLogoStore.call(upload(png_bytes), account_id: accounts(:legacy).id)
      CertifierLogoStore.call(upload(png_bytes), account_id: accounts(:climb).id)
    end

    assert_includes fake.uploads[0][:key], "/#{accounts(:legacy).id}/"
    assert_includes fake.uploads[1][:key], "/#{accounts(:climb).id}/"
    assert_not_equal fake.uploads[0][:key], fake.uploads[1][:key]
  end

  # ── The bytes decide, not the declared type or the extension ───────────────

  test "rejects an SVG renamed and declared as a PNG" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>)
    fake = FakeS3.new

    result = with_fake_s3(fake) { CertifierLogoStore.call(upload(svg, filename: "logo.png", type: "image/png"), account_id: @account_id) }

    assert_not result.ok?
    assert_equal :unsupported_format, result.error
    assert_empty fake.uploads, "nothing may reach S3 once the format is rejected"
  end

  test "rejects a PDF declared as a JPEG" do
    result = with_fake_s3(FakeS3.new) do
      CertifierLogoStore.call(upload("%PDF-1.7\n%\xC7\xEC".b, filename: "logo.jpg", type: "image/jpeg"), account_id: @account_id)
    end

    assert_not result.ok?
    assert_equal :unsupported_format, result.error
  end

  test "rejects plain text with an image content type" do
    result = with_fake_s3(FakeS3.new) do
      CertifierLogoStore.call(upload("no soy una imagen", type: "image/png"), account_id: @account_id)
    end

    assert_not result.ok?
    assert_equal :unsupported_format, result.error
  end

  test "rejects bytes that pass the magic number but are not a readable image" do
    truncated = "\x89PNG\r\n\x1A\n".b + ("\x00" * 32).b

    result = with_fake_s3(FakeS3.new) { CertifierLogoStore.call(upload(truncated), account_id: @account_id) }

    assert_not result.ok?
    assert_equal :unreadable, result.error
  end

  # ── Size limits ────────────────────────────────────────────────────────────

  test "rejects a file over the byte limit before decoding it" do
    oversized = "\x89PNG\r\n\x1A\n".b + SecureRandom.bytes(CertifierLogoStore::MAX_BYTES)

    result = with_fake_s3(FakeS3.new) { CertifierLogoStore.call(upload(oversized), account_id: @account_id) }

    assert_not result.ok?
    assert_equal :too_large, result.error
  end

  # A decompression bomb is small on disk and enormous in memory, so the pixel
  # count is checked separately from the byte size.
  test "rejects an image over the pixel limit" do
    bomb = Vips::Image.black(2100, 2100).write_to_buffer(".png")

    result = with_fake_s3(FakeS3.new) { CertifierLogoStore.call(upload(bomb), account_id: @account_id) }

    assert_not result.ok?
    assert_equal :too_many_pixels, result.error
    assert_operator bomb.bytesize, :<, CertifierLogoStore::MAX_BYTES, "the point is that a small file can still be a huge image"
  end

  test "accepts an image just under the pixel limit" do
    fake = FakeS3.new
    ok = Vips::Image.black(1000, 1000).write_to_buffer(".png")

    result = with_fake_s3(fake) { CertifierLogoStore.call(upload(ok), account_id: @account_id) }

    assert result.ok?, result.error.inspect
  end

  # ── Empty and failing inputs ───────────────────────────────────────────────

  test "reports a missing file instead of raising" do
    assert_equal :missing, CertifierLogoStore.call(nil, account_id: @account_id).error
    assert_equal :missing, CertifierLogoStore.call(upload(""), account_id: @account_id).error
  end

  test "reports the failure when S3 does not confirm the upload" do
    result = with_fake_s3(FakeS3.new(succeed: false)) { CertifierLogoStore.call(upload(png_bytes), account_id: @account_id) }

    assert_not result.ok?
    assert_equal :upload_failed, result.error
  end

  test "the same bytes produce the same key so a re-upload does not duplicate the object" do
    fake = FakeS3.new
    first  = with_fake_s3(fake) { CertifierLogoStore.call(upload(png_bytes), account_id: @account_id) }
    second = with_fake_s3(fake) { CertifierLogoStore.call(upload(png_bytes), account_id: @account_id) }

    assert_equal first.s3_key, second.s3_key
  end
end
