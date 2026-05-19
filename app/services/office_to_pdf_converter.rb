# frozen_string_literal: true

require "open3"
require "timeout"
require "tmpdir"

# Converts Office documents (doc, docx, xls, xlsx, ppt, pptx, odt, ods, odp)
# to PDF using LibreOffice in headless mode.
#
# Requires libreoffice-core (+ libreoffice-writer/calc/impress) on the system PATH.
# In Docker, install via: apt-get install --no-install-recommends libreoffice-core ...
#
# Raises OfficeToPdfConverter::Error on timeout, non-zero exit, or missing binary.
class OfficeToPdfConverter
  class Error < StandardError; end

  TIMEOUT_SECONDS = 120
  SOFFICE_BIN     = "soffice"

  # @param binary    [String] raw bytes of the Office document
  # @param extension [String] original file extension, e.g. ".docx" or "docx"
  # @return [String] raw PDF bytes
  # @raise [Error]
  def self.convert(binary, extension:)
    new(binary, extension: extension).convert
  end

  def initialize(binary, extension:)
    @binary    = binary
    @extension = extension.to_s.downcase.delete_prefix(".")
  end

  def convert
    Dir.mktmpdir("office_conv_") do |tmpdir|
      input_path  = File.join(tmpdir, "input.#{@extension}")
      output_path = File.join(tmpdir, "input.pdf")

      File.binwrite(input_path, @binary)

      stdout, stderr, status = Timeout.timeout(TIMEOUT_SECONDS) do
        Open3.capture3(
          SOFFICE_BIN,
          "--headless",
          "--convert-to", "pdf",
          "--outdir", tmpdir,
          "-env:UserInstallation=file://#{tmpdir}/profile",
          input_path,
          stdin_data: ""
        )
      end

      raise Error, "LibreOffice exited #{status.exitstatus}: #{stderr.strip.truncate(300)}" unless status.success?
      raise Error, "LibreOffice produced no output — stdout=#{stdout.strip.truncate(200)}" unless File.exist?(output_path)

      File.binread(output_path)
    end
  rescue Timeout::Error
    raise Error, "LibreOffice conversion exceeded #{TIMEOUT_SECONDS}s"
  rescue Errno::ENOENT
    raise Error, "LibreOffice (#{SOFFICE_BIN}) not found — install libreoffice-core in this environment"
  end
end
