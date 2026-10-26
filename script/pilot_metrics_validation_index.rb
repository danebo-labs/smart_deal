#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../app/services/rag/validation_capture_index"

source = ARGV.fetch(0)
destination = ARGV.fetch(1)
document = Rag::ValidationCaptureIndex.build(source)
File.write(destination, JSON.pretty_generate(document))
warn "pilot_metrics: validation captures #{document['status']} files=#{document['capture_files']} turns=#{Array(document['turns']).size}"
