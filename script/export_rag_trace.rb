#!/usr/bin/env ruby
# frozen_string_literal: true

# Exporta las últimas trazas de consultas RAG del log de desarrollo
# Uso: ruby script/export_rag_trace.rb [numero_de_trazas]
# Ejemplo: ruby script/export_rag_trace.rb 5

require "json"

num_traces = (ARGV[0] || 10).to_i
log_file = File.expand_path("../log/development.log", __dir__)

unless File.exist?(log_file)
  puts "Error: No se encontró log/development.log"
  exit 1
end

traces = []

File.readlines(log_file).each do |line|
  if line.include?("[RAG_QUALITY]")
    json_str = line.match(/\[RAG_QUALITY\]\s+(.+)/)[1]
    traces << JSON.parse(json_str)
  end
end

puts "=" * 80
puts "ÚLTIMAS #{[ num_traces, traces.size ].min} TRAZAS DE CONSULTAS RAG"
puts "=" * 80
puts

traces.last(num_traces).each_with_index do |trace, idx|
  puts "\n--- TRAZA #{idx + 1} ---"
  puts "Timestamp:       #{trace['ts']}"
  puts "Pregunta:        #{trace['question']}"
  puts "Correlation ID:  #{trace['correlation_id']}"
  puts "Latencia:        #{trace['latency_ms']} ms"
  puts "Chunks:          #{trace['chunk_count']}"
  puts "Citaciones:      #{trace['citations_count']}"
  puts "Modelo:          #{trace['model_id']}"
  puts "Filtro entity:   #{trace['entity_filter'] || 'ninguno'}"
  puts "Respuesta (extracto):"
  puts "  #{trace['answer_snippet']}"

  if trace['doc_refs']
    puts "\nDocumentos referenciados:"
    trace['doc_refs'].each do |doc|
      puts "  - #{doc['canonical_name']} (#{doc['source_uri']})"
    end
  end

  puts "\n--- JSON COMPLETO ---"
  puts JSON.pretty_generate(trace)
end

puts "\n" + "=" * 80
puts "Total de trazas en el log: #{traces.size}"
puts "=" * 80
