# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"

# Raw collection is private scratch. Copy only attributable events and the
# verified bodies they reference into the shareable account package.
class PilotMetricsScope
  MARKER = /\[(?:PILOT_USAGE|RAG_QUALITY|PILOT_AUDIT|TURN_EVIDENCE|DOCUMENT_IDENTITY|RAG_REGRESSION)\]|\bR1A_PROBE\b/
  BODY = %r{\Abodies/[A-Za-z0-9_.-]+\.txt\z}

  def initialize(report, account_id, from, to)
    @account_id = account_id.to_s
    @from = from
    @to = to
    @window = report["export_window"]
    @turns = {}
    @by_turn_id = {}
    @cases = {}
    Array(report["durable_traces"]).each { |turn| index(turn, turn) }
    Array(report.dig("interactions", "by_correlation")).each { |turn| index(turn, turn) }
    Array(report["field_case_threads"]).each do |kase|
      Array(kase["turns"]).each { |turn| index(turn, kase) }
    end
  end

  def copy_events(source, target)
    File.open(target, "w", 0o600) do |output|
      File.foreach(source) do |line|
        marker = MARKER.match(line)
        next unless marker

        event = parse(line[marker.end(0)..])
        stamp = line[/\d{4}-\d{2}-\d{2}T[^\s]+/]
        output.write(line) if event && visible?(event, stamp)
      end
    end
  end

  def copy_captures(source, target)
    root = Pathname(source)
    Dir.glob(root.join("**", "capture.json")).sort.each do |name|
      path = Pathname(name)
      next unless regular_file?(path, root)

      capture = parse(path.read)
      next unless capture

      candidates = Array(capture["events"]).select { |event| event.is_a?(Hash) }
      events = candidates.select { |event| visible?(event) }
      next if events.empty?

      scope_accounts = candidates.filter_map { |event| event["account_id"]&.to_s }.uniq
      correlated = candidates.select { |event| event["correlation_root"] || event["correlation_id"] }
      roots = correlated.map { |event| (event["correlation_root"] || event["correlation_id"]).to_s.delete_suffix(":query") }.uniq
      if scope_accounts == [ @account_id ] && roots.one? && (correlated - events).empty?
        metadata = candidates.select do |event|
          %w[web_request process_contract].include?(event["kind"]) && event["account_id"].to_s == @account_id
        end
        events = candidates & (metadata + events)
      end

      output = Pathname(target).join(path.relative_path_from(root))
      FileUtils.mkdir_p(output.dirname)
      # Metadata generated for the original bucket may summarize other turns.
      header = capture.slice("schema_version", "linkage")
      output.write(JSON.pretty_generate(header.merge("events" => events)))
      body_references(events).each do |reference|
        name = reference["path"].to_s
        next unless BODY.match?(name)

        file = path.dirname.join(name)
        next unless regular_file?(file, root)
        next unless Digest::SHA256.file(file).hexdigest == reference["sha256"]

        destination = output.dirname.join(name)
        FileUtils.mkdir_p(destination.dirname)
        FileUtils.cp(file, destination)
      end
    end
  end

  private

  def index(turn, owner)
    return unless owner["account_id"].to_s == @account_id && turn["correlation_id"].to_s != ""

    id = turn["correlation_id"]
    @turns[id] = (@turns[id] || {}).merge(turn.slice("field_case_id", "field_turn_id", "user_id").compact)
      .merge(owner.slice("field_case_id", "user_id").compact)
    @by_turn_id[@turns[id]["field_turn_id"].to_s] = @turns[id] if @turns[id]["field_turn_id"]
    @cases[@turns[id]["field_case_id"].to_s] = @turns[id].slice("field_case_id", "user_id") if @turns[id]["field_case_id"]
  end

  def visible?(event, fallback_stamp = nil)
    explicit = event["account_id"]
    return false if explicit && explicit.to_s != @account_id

    links = event.values_at("correlation_root", "correlation_id").compact.reject(&:empty?)
    matched = links.filter_map { |id| @turns[id] || @turns[id.delete_suffix(":query")] }
    turn_id = event["field_turn_id"]
    case_id = event["field_case_id"]
    return false if turn_id && !@by_turn_id.key?(turn_id.to_s)
    return false if case_id && !@cases.key?(case_id.to_s)

    matched << @by_turn_id.fetch(turn_id.to_s) if turn_id
    return false if matched.any? { |turn| contradictory?(event, turn) }
    return false if case_id && contradictory?(event, @cases.fetch(case_id.to_s))

    stamp = event["ts"] || event["occurred_at"] || fallback_stamp
    return false if stamp && !in_window?(stamp)

    matched.any? || ((explicit.to_s == @account_id || case_id) && !stamp.nil?)
  end

  def contradictory?(event, turn)
    %w[field_case_id field_turn_id user_id].any? do |key|
      event[key] && turn[key] && event[key].to_s != turn[key].to_s
    end
  end

  def in_window?(stamp)
    time = Time.iso8601(stamp)
    if @window
      time >= Time.iso8601(@window.fetch("from")) && time < Time.iso8601(@window.fetch("until"))
    else
      date = stamp[0, 10]
      date >= @from && date <= @to
    end
  rescue ArgumentError
    false
  end

  def parse(text)
    value = JSON.parse(text)
    value if value.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end

  def regular_file?(path, root)
    path.file? && !path.symlink? && path.realpath == root.realpath.join(path.relative_path_from(root))
  end

  def body_references(value)
    case value
    when Hash
      return [ value ] if value["evidence"] == "external" && value["absent"] != true

      value.values.flat_map { |nested| body_references(nested) }
    when Array
      value.flat_map { |nested| body_references(nested) }
    else
      []
    end
  end
end

if $PROGRAM_NAME == __FILE__
  report, account_id, from, to, logs, captures, target = ARGV
  filter = PilotMetricsScope.new(JSON.parse(File.read(report)), account_id, from, to)
  filter.copy_events(logs, File.join(target, "source_events.jsonl"))
  filter.copy_captures(captures, File.join(target, "validation_captures"))
end
