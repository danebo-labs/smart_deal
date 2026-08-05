# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class PilotMetricsCommandTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir("pilot-metrics-command")
    @fake_bin = File.join(@tmpdir, "bin")
    @output_root = File.join(@tmpdir, "exports")
    @ssh_log = File.join(@tmpdir, "ssh.jsonl")
    @source_capture = File.join(@tmpdir, "source-events.capture")
    FileUtils.mkdir_p(@fake_bin)
    write_deploy_config
    write_fake_ssh
    write_fake_rails
    @env = {
      "PATH" => "#{@fake_bin}:#{ENV.fetch('PATH')}",
      "PILOT_METRICS_DEPLOY_CONFIG" => File.join(@tmpdir, "deploy.yml"),
      "PILOT_METRICS_OUTPUT_ROOT" => @output_root,
      "PILOT_METRICS_RAILS_BIN" => File.join(@fake_bin, "rails"),
      "PILOT_METRICS_RUBY" => RbConfig.ruby,
      "FAKE_SSH_LOG" => @ssh_log,
      "FAKE_SOURCE_CAPTURE" => @source_capture
    }
  end

  teardown do
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  test "uses direct non-PTY SSH and writes the complete artifact package" do
    stdout, stderr, status = run_command("--format", "both")

    assert status.success?, stderr
    assert_match(/Cohort: account_id=7 slug=pilot-account user_ids=11,12 count=2/, stderr)
    assert_match(/Rendered pilot metrics 2026-07-22/, stdout)
    assert_match(/"date":"2026-07-22"/, stdout)

    expected_files.each { |name| assert_path_exists File.join(output_dir, name) }
    manifest = JSON.parse(File.read(File.join(output_dir, "manifest.json")))
    assert_equal({ "from" => "2026-07-22", "to" => "2026-07-22" }, manifest.fetch("range"))
    assert_equal 7, manifest.dig("cohort", "account_id")
    assert_equal [ "web", "worker" ], manifest.fetch("roles_downloaded")
    assert_equal "registry.example/smart-deal:abc123", manifest.fetch("image_version")

    source = File.read(File.join(output_dir, "source_events.jsonl"))
    assert_includes source, '"role":"web"'
    assert_includes source, '"role":"worker"'
    assert_equal source, File.read(@source_capture)

    ssh_calls = File.readlines(@ssh_log, chomp: true).map { |line| JSON.parse(line) }
    assert ssh_calls.none? { |args| args.include?("-t") || args.include?("-it") }
    assert ssh_calls.any? { |args| args.last.include?("label=service=test-service") && args.last.include?("label=role=web") }
    assert ssh_calls.any? { |args| args.last.include?("docker exec -i") && args.last.include?("pilot_metrics_export.rb") }
    verify_hashes
  end

  test "human format still preserves report JSON in the artifact package" do
    stdout, stderr, status = run_command("--format", "human")

    assert status.success?, stderr
    assert_equal "Rendered pilot metrics 2026-07-22\n", stdout
    assert_path_exists File.join(output_dir, "report.json")
    assert_equal "2026-07-22", JSON.parse(File.read(File.join(output_dir, "report.json"))).fetch("date")
  end

  test "with questions restricts artifact permissions and prints a warning" do
    _stdout, stderr, status = run_command("--with-questions", "--format", "raw")

    assert status.success?, stderr
    assert_match(/artifacts contain raw technician questions/, stderr)
    expected_files.each do |name|
      assert_equal 0o600, File.stat(File.join(output_dir, name)).mode & 0o777
    end
    assert_equal 0o700, File.stat(output_dir).mode & 0o777
  end

  test "strict fails when a declared role has no log events" do
    _stdout, stderr, status = run_command("--strict", env: { "FAKE_EMPTY_ROLE" => "worker" })

    assert_not status.success?
    assert_match(/strict: empty or unavailable logs for role\(s\): worker/, stderr)
  end

  test "strict fails when the report declares partial telemetry" do
    _stdout, stderr, status = run_command("--strict", env: { "FAKE_USAGE_STATUS" => "partial" })

    assert_not status.success?
    assert_match(/strict report validation failed/, stderr)
  end

  test "strict fails stale pending reconciliation but permits the current UTC day" do
    _stdout, stale_stderr, stale_status = run_command(
      "--strict",
      env: {
        "FAKE_COST_STATUS" => "pending_reconciliation",
        "FAKE_MISSING_DATES" => "2026-07-20",
        "PILOT_METRICS_NOW" => "2026-07-22T05:00:00Z"
      }
    )
    assert_not stale_status.success?
    assert_match(/strict report validation failed/, stale_stderr)

    _stdout, current_stderr, current_status = run_command(
      "--strict",
      env: {
        "FAKE_COST_STATUS" => "pending_reconciliation",
        "FAKE_MISSING_DATES" => "2026-07-22",
        "PILOT_METRICS_NOW" => "2026-07-22T12:00:00Z"
      }
    )
    assert current_status.success?, current_stderr
  end

  test "strict rejects an empty cohort" do
    _stdout, stderr, status = run_command("--strict", env: { "FAKE_COHORT_EMPTY" => "true" })

    assert_not status.success?
    assert_match(/strict: cohort is empty/, stderr)
  end

  test "rejects an inverted range before opening SSH" do
    _stdout, stderr, status = run_command("--from", "2026-07-23", "--to", "2026-07-22", include_defaults: false)

    assert_not status.success?
    assert_match(/--from must be on or before --to/, stderr)
    assert_not File.exist?(@ssh_log)
  end

  private

  def output_dir
    File.join(@output_root, "2026-07-22_2026-07-22_pilot-account")
  end

  def expected_files
    %w[report.json report.txt source_events.jsonl manifest.json SHA256SUMS]
  end

  def run_command(*args, env: {}, include_defaults: true)
    defaults = %w[--from 2026-07-22 --to 2026-07-22 --account pilot-account]
    command_args = include_defaults ? defaults + args : args + %w[--account pilot-account]
    Open3.capture3(
      @env.merge(env),
      Rails.root.join("bin/pilot_metrics").to_s,
      *command_args,
      chdir: Rails.root.to_s
    )
  end

  def verify_hashes
    File.readlines(File.join(output_dir, "SHA256SUMS"), chomp: true).each do |line|
      expected, filename = line.split(/\s+/, 2)
      actual = Digest::SHA256.file(File.join(output_dir, filename)).hexdigest
      assert_equal expected, actual
    end
  end

  def write_deploy_config
    File.write(File.join(@tmpdir, "deploy.yml"), <<~YAML)
      service: test-service
      servers:
        web:
          hosts:
            - 127.0.0.1
      ssh:
        user: tester
        keys:
          - /tmp/fake-key
    YAML
  end

  def write_fake_ssh
    path = File.join(@fake_bin, "ssh")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"

      File.open(ENV.fetch("FAKE_SSH_LOG"), "a") { |file| file.puts(JSON.generate(ARGV)) }
      command = ARGV.last
      case command
      when /docker ps.*label=role=web/
        puts "abc123"
      when /docker ps.*label=role=worker/
        puts "def456"
      when /Account\.find_by!/
        empty = ENV["FAKE_COHORT_EMPTY"] == "true"
        puts JSON.generate(
          account_id: 7,
          account_slug: "pilot-account",
          user_ids: empty ? [] : [ 11, 12 ],
          user_count: empty ? 0 : 2
        )
      when /docker logs.*abc123/
        unless ENV["FAKE_EMPTY_ROLE"] == "web"
          puts %(2026-07-22T00:00:00-04:00 [PILOT_USAGE] {"event":"interaction_completed","ts":"2026-07-22T00:00:00-04:00","correlation_id":"query:web"})
        end
      when /docker logs.*def456/
        unless ENV["FAKE_EMPTY_ROLE"] == "worker"
          puts %(2026-07-22T23:59:59-04:00 [RAG_QUALITY] {"ts":"2026-07-22T23:59:59-04:00","correlation_id":"query:worker","evidence_present":true})
        end
      when /docker inspect/
        puts "registry.example/smart-deal:abc123"
      when /pilot_metrics_export\.rb/
        source = $stdin.read
        File.write(ENV.fetch("FAKE_SOURCE_CAPTURE"), source)
        report = {
          date: "2026-07-22",
          timezone: "America/Santiago",
          generated_at: "2026-07-23T00:00:00-04:00",
          technical_and_cost: {
            totals: {
              rag_llm_calls: 1,
              visual_llm_calls: 0,
              photo_cache_hits: 0,
              visual_llm_calls_avoided: 0,
              photo_cache_hit_rate: 0.0,
              input_tokens: 10,
              output_tokens: 2,
              attributed_cost_usd: 0.001,
              provider_usage_usd: 0.0,
              estimated_usd: 0.001,
              estimated_cost_avoided: 0.0
            },
            cost_authority: {
              status: ENV.fetch("FAKE_COST_STATUS", "reconciled"),
              missing_utc_dates: ENV.fetch("FAKE_MISSING_DATES", "").split(",").reject(&:empty?),
              reconciled_bedrock_usd: 0.001,
              scope: "platform_wide_all_accounts",
              utc_day_overlap: "partial"
            },
            evidence_route_summary: { status: "logs_not_available" },
            per_user: [],
            per_account: []
          },
          interactions: { status: "logs_not_available" },
          adoption_signals: {
            active_users: 1,
            active_accounts: 1,
            sessions: 1,
            user_messages: 1,
            assistant_messages: 1,
            rag_llm_calls: 1,
            photo_requests: 0
          },
          repeat_usage: { status: "logs_not_available" },
          evidence_quality: { status: "logs_not_available", records: nil },
          knowledge_gap_signals: {
            data_not_available_count: 0,
            require_field_verification_count: 0,
            reformulation_count: 0
          },
          commercial_outcomes: { status: "REQUIRES_MANUAL_SURVEY" },
          data_quality: {
            usage_log: ENV.fetch("FAKE_USAGE_STATUS", "loaded"),
            messages_without_timestamp_excluded: 0,
            unattributed_messages: 0,
            limits: []
          }
        }
        puts JSON.generate(report)
      else
        warn "unexpected fake ssh command: \#{command}"
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
  end

  def write_fake_rails
    path = File.join(@fake_bin, "rails")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"

      report = JSON.parse(File.read(ARGV.fetch(-1)))
      puts "Rendered pilot metrics \#{report.fetch("date")}"
    RUBY
    File.chmod(0o755, path)
  end
end
