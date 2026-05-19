# frozen_string_literal: true

require "test_helper"
require "open3"

class OfficeToPdfConverterTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Helpers — stub Open3.capture3
  # ---------------------------------------------------------------------------

  def with_open3_stub(stdout: "", stderr: "", success: true, &_block)
    fake_status = OpenStruct.new(success?: success, exitstatus: success ? 0 : 1)
    original    = Open3.method(:capture3)

    Open3.define_singleton_method(:capture3) do |*_args, **_kwargs|
      # Write a fake output PDF so the converter can read it
      args = _args
      outdir = args.each_cons(2).find { |a, _| a == "--outdir" }&.last
      if outdir
        File.binwrite(File.join(outdir, "input.pdf"), "%PDF-1.4 fake")
      end
      [ stdout, stderr, fake_status ]
    end

    yield
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  test "returns PDF bytes on successful conversion" do
    with_open3_stub do
      result = OfficeToPdfConverter.convert("fake docx bytes", extension: ".docx")
      assert_kind_of String, result
      assert result.start_with?("%PDF"), "expected PDF bytes"
    end
  end

  test "accepts extension with or without leading dot" do
    with_open3_stub do
      result = OfficeToPdfConverter.convert("fake", extension: "docx")
      assert_kind_of String, result
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths
  # ---------------------------------------------------------------------------

  test "raises Error when soffice exits non-zero" do
    fake_status = OpenStruct.new(success?: false, exitstatus: 1)
    original    = Open3.method(:capture3)

    Open3.define_singleton_method(:capture3) { |*_, **__| [ "", "conversion error", fake_status ] }

    assert_raises(OfficeToPdfConverter::Error) do
      OfficeToPdfConverter.convert("bad bytes", extension: ".xlsx")
    end
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  test "raises Error when libreoffice binary not found" do
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |*_, **__| raise Errno::ENOENT, "soffice" }

    assert_raises(OfficeToPdfConverter::Error) do
      OfficeToPdfConverter.convert("bytes", extension: ".doc")
    end
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  test "raises Error on timeout — no ArgumentError from timeout: kwarg" do
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |*_, **__| raise Timeout::Error }

    err = assert_raises(OfficeToPdfConverter::Error) do
      OfficeToPdfConverter.convert("bytes", extension: ".pptx")
    end
    assert_match(/exceeded/, err.message)
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  test "UserInstallation flag is passed to soffice — concurrent jobs use isolated profiles" do
    args_captured = []
    original = Open3.method(:capture3)

    Open3.define_singleton_method(:capture3) do |*args, **kwargs|
      args_captured.concat(args)
      fake_status = OpenStruct.new(success?: true, exitstatus: 0)
      # Write fake output so converter can read it
      outdir = args.each_cons(2).find { |a, _| a == "--outdir" }&.last
      File.binwrite(File.join(outdir, "input.pdf"), "%PDF-1.4 fake") if outdir
      [ "", "", fake_status ]
    end

    OfficeToPdfConverter.convert("fake bytes", extension: ".docx")

    assert args_captured.any? { |a| a.to_s.start_with?("-env:UserInstallation=") },
           "expected -env:UserInstallation= flag in soffice args for profile isolation"
  ensure
    Open3.define_singleton_method(:capture3, original)
  end
end
