# frozen_string_literal: true

require "fileutils"
require "pathname"

# A directory that answers the S3DocumentsService calls the parser and the
# chunk store make. Keys map to files under the root. It never reaches AWS.
class LocalChunkDirectory
  attr_reader :root

  def initialize(root)
    @root = Pathname(root)
  end

  def bucket_name
    "local"
  end

  def upload_text(key, content)
    path = path_for(key)
    FileUtils.mkdir_p(path.dirname)
    path.write(content.to_s)
    key
  end

  def delete_prefix(prefix)
    keys = list_keys(prefix: prefix)
    keys.each { |key| path_for(key).delete }
    keys.size
  end

  def list_keys(prefix:)
    base = root.join(prefix.to_s)
    directory = base.directory? ? base : base.dirname
    return [] unless directory.directory?

    Dir.glob(directory.join("**/*").to_s).select { |file| File.file?(file) }.filter_map { |file|
      key = Pathname(file).relative_path_from(root).to_s
      key if key.start_with?(prefix.to_s)
    }.sort
  end

  def download(key)
    path = path_for(key)
    path.file? ? path.binread : nil
  end

  private

  def path_for(key)
    path = root.join(key.to_s).cleanpath
    raise ArgumentError, "key escapes the root: #{key}" unless path.to_s.start_with?(root.cleanpath.to_s)

    path
  end
end
