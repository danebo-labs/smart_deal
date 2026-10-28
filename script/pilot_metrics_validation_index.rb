#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../app/services/rag/validation_capture_index"

source = ARGV.fetch(0)
destination = ARGV.fetch(1)
archive = ARGV.fetch(2, "")
archive = nil if archive == ""
begin
  document = Rag::ValidationCaptureIndex.build(source, archive: archive)
rescue ArgumentError => error
  warn "pilot_metrics: #{error.message}"
  exit 1
end
File.write(destination, JSON.pretty_generate(document))
warn "pilot_metrics: validation captures #{document['status']} files=#{document['capture_files']} turns=#{Array(document['turns']).size}"
