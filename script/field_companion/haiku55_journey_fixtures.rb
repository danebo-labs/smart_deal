# frozen_string_literal: true

# Turns one captured script into the offline journey fixture.
#
#   ruby script/field_companion/haiku55_journey_fixtures.rb SOURCE_SCRIPT_DIR NAME
#
# SOURCE_SCRIPT_DIR holds turn-N/ directories with capture.json, bodies/ and
# question.txt, as written by run_haiku55_companion.rb or run_haiku55_http.rb.
# The fixture keeps what the providers returned (interpreter tool input,
# Retrieve rows in their order, rerank order, generator text) and what the
# product sent (Retrieve query, generator messages digest). Nothing else.

require "json"
require "digest"
require "fileutils"

module Haiku55JourneyFixtures
  ROOT = File.expand_path("../../test/fixtures/files/field_companion/haiku55_journeys", __dir__)

  module_function

  def extract(source, name)
    turns = Dir[File.join(source, "turn-*")].select { |path| File.directory?(path) }
      .sort_by { |path| path[/(\d+)\z/, 1].to_i }
    raise "no turns under #{source}" if turns.empty?

    out = File.join(ROOT, name)
    FileUtils.rm_rf(out)
    FileUtils.mkdir_p(out)
    turns.each do |dir|
      number = dir[/(\d+)\z/, 1].to_i
      File.write(File.join(out, format("turn-%d.json", number)), JSON.pretty_generate(turn(dir)) + "\n")
    end
    out
  end

  def turn(dir)
    events = JSON.parse(File.read(File.join(dir, "capture.json")))["events"]
    raw = events.reverse.find { |event| event["kind"] == "interpreter_raw" && event["tool_input"].is_a?(Hash) }
    retrieve = events.reverse.find { |event| event["kind"] == "retrieve" }
    retrieved = events.find { |event| event["kind"] == "retrieval_results" && event["role"] == "retrieved" }
    rerank = events.find { |event| event["kind"] == "companion_rerank" }
    request = events.reverse.find { |event| event["kind"] == "converse" && event["provider"] == "anthropic" }
    direct = events.reverse.find { |event| event["kind"] == "companion_direct" }
    {
      "source" => dir.sub(%r{\A.*?/tmp/}, "tmp/"),
      "question" => File.read(File.join(dir, "question.txt")).strip,
      "tool_input" => raw.fetch("tool_input"),
      "retrieve_query" => text(dir, retrieve.dig("retrieval_query", "text")),
      "rows" => Array(retrieved["rows"]).map { |row|
        {
          "uri" => row["uri"], "page" => row["page"], "score" => row["score"],
          "document" => row["document"], "content" => text(dir, row["text"])
        }
      },
      "rerank_sha256" => rerank && Array(rerank["order"]).sort_by { |item| item["rank"].to_i }.map { |item| item.fetch("sha256") },
      "generator_messages_sha256" => request && Digest::SHA256.hexdigest(messages_text(dir, request["messages"])),
      "generator_text" => text(dir, direct&.fetch("text", nil)),
      "stop_reason" => direct && direct["stop_reason"]
    }
  end

  # role:text per message, joined. The test digests the sent payload the same way.
  def messages_text(dir, messages)
    Array(messages).map { |message|
      "#{message['role']}:" + Array(message["content"]).map { |block| text(dir, block["text"]) }.join
    }.join("\n---\n")
  end

  def text(dir, value)
    return File.read(File.join(dir, value["path"])) if value.is_a?(Hash) && value["path"]

    value.to_s
  end
end

if $PROGRAM_NAME == __FILE__
  source, name = ARGV
  abort "usage: #{$PROGRAM_NAME} SOURCE_SCRIPT_DIR NAME" unless source && name
  puts Haiku55JourneyFixtures.extract(source, name)
end
