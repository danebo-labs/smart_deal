# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# bin/pilot_metrics itself is covered by PilotMetricsCommandTest; here it is a
# stub, so these tests stay on the wrapper's own contract: the Chile-time window,
# both accounts, and telling "nobody used it today" apart from "we could not read
# the logs".
class PilotMetricsDailyTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir("pilot-metrics-daily")
    @output_root = File.join(@tmpdir, "exports")
    @invocations = File.join(@tmpdir, "invocations.jsonl")
    @metrics_bin = File.join(@tmpdir, "pilot_metrics_stub")
    @stack_bin = File.join(@tmpdir, "stack_stub")
    @stack_calls = File.join(@tmpdir, "stack.log")
    write_metrics_stub
    write_stack_stub
    @env = {
      "PILOT_METRICS_DAILY_BIN" => @metrics_bin,
      "PILOT_METRICS_DAILY_STACK_BIN" => @stack_bin,
      "STUB_STACK_LOG" => @stack_calls,
      # Every test whose subject is not the window bypasses it: otherwise the
      # suite only passes between 09:00 and 21:59 in Santiago and fails at night
      # for reasons that have nothing to do with the code under test.
      "PILOT_METRICS_DAILY_FORCE" => "true",
      "PILOT_METRICS_DAILY_ACCOUNTS" => "acct-one acct-two",
      "PILOT_METRICS_OUTPUT_ROOT" => @output_root,
      "PILOT_METRICS_RUBY" => RbConfig.ruby,
      "STUB_INVOCATIONS" => @invocations,
      "STUB_OUTPUT_ROOT" => @output_root
    }
  end

  teardown do
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  test "exports every account with --with-questions and reports success" do
    stdout, stderr, status = run_daily

    assert status.success?, stderr + stdout
    calls = invocations
    assert_equal 2, calls.size
    assert_equal [ "acct-one", "acct-two" ], calls.map { |args| args[args.index("--account") + 1] }
    calls.each do |args|
      assert_includes args, "--with-questions"
      today = args[args.index("--from") + 1]
      assert_equal today, args[args.index("--to") + 1]
      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, today)
    end

    # A quiet pilot day must not be an error: --strict would fail here.
    assert_not_includes calls.flatten, "--strict"
    assert_match(/ok: acct-one/, stdout)
    assert_match(/ok: acct-two/, stdout)
    assert_match(/done/, stdout)
  end

  test "uses the Chile date, not the machine's local date" do
    # 23:30 in Madrid on 2026-08-21 is still 17:30 of the same day in Santiago;
    # a naive local-date cron would export the wrong range half the year.
    _stdout, stderr, status = run_daily(env: { "TZ" => "Europe/Madrid" })

    assert status.success?, stderr
    santiago_today = Time.current.in_time_zone("America/Santiago").strftime("%Y-%m-%d")
    invocations.each do |args|
      assert_equal santiago_today, args[args.index("--from") + 1]
    end
  end

  test "skips outside the export window instead of running against a stopped stack" do
    # 30 is unreachable for an hour-of-day, so the skip is asserted without
    # depending on what time the suite happens to run.
    stdout, _stderr, status = run_daily(
      env: {
        "PILOT_METRICS_DAILY_WINDOW_START" => "30",
        "PILOT_METRICS_DAILY_WINDOW_END" => "30",
        "PILOT_METRICS_DAILY_FORCE" => "false"
      }
    )

    assert status.success?
    assert_match(/skipped:.*outside the 30-30h export window/, stdout)
    assert_not File.exist?(@invocations)
  end

  test "the window can be overridden for an out-of-hours manual run" do
    _stdout, stderr, status = run_daily(
      env: {
        "PILOT_METRICS_DAILY_WINDOW_START" => "30",
        "PILOT_METRICS_DAILY_WINDOW_END" => "30",
        "PILOT_METRICS_DAILY_FORCE" => "true"
      }
    )

    assert status.success?, stderr
    assert_equal 2, invocations.size
  end

  test "fails when an export command fails" do
    stdout, stderr, status = run_daily(env: { "STUB_FAIL_ACCOUNT" => "acct-two" })

    assert_not status.success?
    assert_match(/ERROR: export failed for acct-two/, stdout)
    assert_match(/export incomplete for: acct-two/, stderr)
    assert_match(/ok: acct-one/, stdout)
  end

  test "fails when the manifest read no containers" do
    stdout, stderr, status = run_daily(env: { "STUB_NO_CONTAINERS" => "acct-one" })

    assert_not status.success?
    assert_match(/ERROR: incomplete export for acct-one: no containers read/, stdout)
    assert_match(/export incomplete for: acct-one/, stderr)
  end

  test "fails when a container's logs were unreadable" do
    stdout, _stderr, status = run_daily(env: { "STUB_UNREADABLE" => "acct-two" })

    assert_not status.success?
    assert_match(/ERROR: incomplete export for acct-two: unreadable containers: web:bbb222/, stdout)
  end

  test "fails when a role was never downloaded" do
    stdout, _stderr, status = run_daily(env: { "STUB_MISSING_ROLE" => "acct-one" })

    assert_not status.success?
    assert_match(/ERROR: incomplete export for acct-one: roles not downloaded: worker/, stdout)
  end

  test "authorizes this machine's SSH IP before exporting" do
    _stdout, stderr, status = run_daily

    assert status.success?, stderr
    assert_equal [ "ssh-ip" ], File.readlines(@stack_calls, chomp: true)
  end

  test "a failed IP authorization warns but does not abort the export" do
    stdout, stderr, status = run_daily(env: { "STUB_STACK_FAIL" => "true" })

    assert status.success?, stderr
    assert_match(/warning: could not authorize this machine's IP/, stdout)
    assert_equal 2, invocations.size
  end

  test "IP authorization can be disabled for a machine with a static address" do
    _stdout, stderr, status = run_daily(env: { "PILOT_METRICS_DAILY_AUTHORIZE_IP" => "false" })

    assert status.success?, stderr
    assert_not File.exist?(@stack_calls)
    assert_equal 2, invocations.size
  end

  test "an export with zero events is still a success" do
    stdout, stderr, status = run_daily(env: { "STUB_EMPTY_EVENTS" => "true" })

    assert status.success?, stderr
    assert_match(/ok: acct-one/, stdout)
    assert_match(/ok: acct-two/, stdout)
  end

  private

  def run_daily(env: {})
    Open3.capture3(
      @env.merge(env),
      Rails.root.join("bin/pilot_metrics_daily").to_s,
      chdir: Rails.root.to_s
    )
  end

  def invocations
    return [] unless File.exist?(@invocations)

    File.readlines(@invocations, chomp: true).map { |line| JSON.parse(line) }
  end

  def write_stack_stub
    File.write(@stack_bin, <<~SH)
      #!/usr/bin/env bash
      echo "$1" >> "$STUB_STACK_LOG"
      [[ "${STUB_STACK_FAIL:-false}" != "true" ]]
    SH
    File.chmod(0o755, @stack_bin)
  end

  def write_metrics_stub
    File.write(@metrics_bin, <<~RUBY)
      #!#{RbConfig.ruby}
      require "fileutils"
      require "json"

      File.open(ENV.fetch("STUB_INVOCATIONS"), "a") { |file| file.puts(JSON.generate(ARGV)) }

      account = ARGV.fetch(ARGV.index("--account") + 1)
      from = ARGV.fetch(ARGV.index("--from") + 1)
      to = ARGV.fetch(ARGV.index("--to") + 1)
      exit 1 if ENV["STUB_FAIL_ACCOUNT"] == account

      dir = File.join(ENV.fetch("STUB_OUTPUT_ROOT"), "\#{from}_\#{to}_\#{account}")
      FileUtils.mkdir_p(dir)
      containers = ENV["STUB_NO_CONTAINERS"] == account ? [] : [ "web:bbb222", "web:abc123", "worker:def456" ]
      roles = ENV["STUB_MISSING_ROLE"] == account ? [ "web" ] : [ "web", "worker" ]
      unreadable = ENV["STUB_UNREADABLE"] == account ? [ "web:bbb222" ] : []
      File.write(File.join(dir, "manifest.json"), JSON.generate(
        range: { from: from, to: to },
        roles_downloaded: roles,
        containers_read: containers,
        containers_unreadable: unreadable
      ))
      File.write(File.join(dir, "source_events.jsonl"), ENV["STUB_EMPTY_EVENTS"] == "true" ? "" : "{}\\n")
      puts "{}"
    RUBY
    File.chmod(0o755, @metrics_bin)
  end
end
