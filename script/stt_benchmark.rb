# frozen_string_literal: true

# Entry point only — logic lives in SpeechToText::Benchmark.
#
#   DB_USERNAME=lahirisan bin/rails runner script/stt_benchmark.rb
#
report = SpeechToText::Benchmark.run!
puts File.read(report.fetch("output_md"))
puts "json=#{report['output_json']}"
