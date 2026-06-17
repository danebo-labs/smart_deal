# frozen_string_literal: true

require "test_helper"

# Gate 9R final manual harness — $0 tests with fakes.
# ALL tests run without Anthropic/AWS calls (FakeBatchClient + FakeS3Client).
class Gate9FinalManualTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ─── Fakes ────────────────────────────────────────────────────────────

  class FakeBatchClient
    attr_reader :submit_calls

    def initialize(results: [], batch_id: "msgbatch_gate9_001", poll_status: "ended")
      @results      = results
      @batch_id     = batch_id
      @poll_status  = poll_status
      @submit_calls = []
    end

    def submit_batch(requests:)
      @submit_calls << requests
      OpenStruct.new(id: @batch_id)
    end

    def retrieve(batch_id:)
      OpenStruct.new(processing_status: @poll_status)
    end

    def results_each(batch_id:, &block)
      @results.each(&block)
    end
  end

  class FakeS3Client
    def put_object(**);    nil; end
    def delete_object(**); nil; end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────

  # Creates a minimal valid multi-page PDF using the same HexaPDF that
  # PdfPageSplitterService uses so fakes work end-to-end.
  def build_fake_pdf_binary(page_count = 3)
    doc = HexaPDF::Document.new
    page_count.times { doc.pages.add }
    io = StringIO.new("".b)
    doc.write(io, validate: false)
    io.string
  end

  # Minimal valid manual_batch_v1 JSON for a single page.
  def valid_chunk_json(page: 1)
    JSON.generate({
      document_name: "Test Manual",
      aliases: %w[test manual],
      summary: "Test summary.",
      companion_offer: "Ask me anything.",
      chunks: [ {
        text: "Content for page #{page}.",
        page: page,
        aliases: [ "test" ],
        field_records: [ {
          k: "MAINTENANCE_TASK",
          h: "Section 1",
          a: "Perform inspection",
          r: "System operating normally",
          ev: "Per procedure step 3"
        } ]
      } ]
    })
  end

  def fake_batch_result(custom_id, json_text, model: "claude-sonnet-4-6",
                        stop_reason: "end_turn", input_tokens: 500, output_tokens: 200)
    usage  = OpenStruct.new(input_tokens: input_tokens, output_tokens: output_tokens,
                            cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
    msg    = OpenStruct.new(model: model, stop_reason: stop_reason, usage: usage,
                            content: [ OpenStruct.new(type: "text", text: json_text) ])
    result = OpenStruct.new(type: "succeeded", message: msg)
    OpenStruct.new(custom_id: custom_id, result: result)
  end

  def fake_failed_batch_result(custom_id, type: "errored")
    OpenStruct.new(custom_id: custom_id, result: OpenStruct.new(type: type))
  end

  # Builds a harness inside a temp dir, runs the block, then cleans state.
  # Default env: all flags off, poll_seconds=0, KNOWLEDGE_BASE_S3_BUCKET set.
  def with_harness(page_count: 3, env_extra: {}, batch_client: nil, pdf_binary: nil)
    Dir.mktmpdir("gate9_test") do |tmpdir|
      binary = pdf_binary || build_fake_pdf_binary(page_count)
      pdf    = File.join(tmpdir, "manual_#{page_count}pp.pdf")
      File.binwrite(pdf, binary)
      sha256 = Digest::SHA256.hexdigest(binary)
      base   = File.join("tmp", "gate9_final", sha256)

      env = {
        "GATE9_FINAL_MANUAL"             => pdf,
        "BEDROCK_RERANKER_ENABLED"       => "false",
        "QUERY_ROUTING_ENABLED"          => "false",
        "GATE9_FINAL_BATCH_POLL_SECONDS" => "0",
        "GATE9_FINAL_MAX_RETRY_PAGES"    => "1",
        "KNOWLEDGE_BASE_S3_BUCKET"       => "test-bucket"
      }.merge(env_extra)

      bc      = batch_client || FakeBatchClient.new
      harness = Gate9FinalManual.new(env: env, batch_client: bc, s3_client: FakeS3Client.new)

      yield harness, pdf, sha256, env, bc
    ensure
      FileUtils.rm_rf(base)
    end
  end

  # ─── Stub helpers (save + restore via define_method) ──────────────────

  def stub_git_clean
    orig = Gate9FinalManual.instance_method(:git_status)
    Gate9FinalManual.define_method(:git_status) { "" }
    yield
  ensure
    Gate9FinalManual.define_method(:git_status, orig)
  end

  def stub_dedup_miss
    orig = ContentDedupService.method(:find_completed)
    ContentDedupService.define_singleton_method(:find_completed) do |**|
      ContentDedupService::Result.new(hit: false, asset: nil, canonical_name: nil, aliases: [])
    end
    yield
  ensure
    ContentDedupService.define_singleton_method(:find_completed, orig)
  end

  def stub_scanned_zero
    orig = Gate9FinalManual.instance_method(:count_scanned_dense_local)
    Gate9FinalManual.define_method(:count_scanned_dense_local) { |_binary| 0 }
    yield
  ensure
    Gate9FinalManual.define_method(:count_scanned_dense_local, orig)
  end

  def stub_filter_keep_all
    orig = PageRelevanceFilter.method(:filter_pages)
    PageRelevanceFilter.define_singleton_method(:filter_pages) do |pages:, **|
      pages.each_with_object({}) do |p, h|
        h[p.number] = { keep: true, reason: :heuristic, source: :heuristic, force_opus: false }
      end
    end
    yield
  ensure
    PageRelevanceFilter.define_singleton_method(:filter_pages, orig)
  end

  def stub_track_job
    orig = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }
    yield
  ensure
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig)
  end

  def with_clean_run_stubs(&block)
    stub_git_clean do
      stub_dedup_miss do
        stub_scanned_zero do
          stub_filter_keep_all do
            stub_track_job(&block)
          end
        end
      end
    end
  end

  # ─── Test 1: Preflight fails for each cause ───────────────────────────

  test "preflight fails on dirty git tree" do
    orig = Gate9FinalManual.instance_method(:git_status)
    Gate9FinalManual.define_method(:git_status) { "M dirty.rb" }
    with_harness do |h|
      err = assert_raises(Gate9FinalManual::PreflightError) { h.run! }
      assert_includes err.message, "git working tree"
    end
  ensure
    Gate9FinalManual.define_method(:git_status, orig)
  end

  test "preflight fails when BEDROCK_RERANKER_ENABLED=true" do
    stub_git_clean do
      with_harness(env_extra: { "BEDROCK_RERANKER_ENABLED" => "true" }) do |h|
        err = assert_raises(Gate9FinalManual::PreflightError) { h.run! }
        assert_includes err.message, "BEDROCK_RERANKER_ENABLED"
      end
    end
  end

  test "preflight fails when QUERY_ROUTING_ENABLED=true" do
    stub_git_clean do
      with_harness(env_extra: { "QUERY_ROUTING_ENABLED" => "true" }) do |h|
        err = assert_raises(Gate9FinalManual::PreflightError) { h.run! }
        assert_includes err.message, "QUERY_ROUTING_ENABLED"
      end
    end
  end

  test "preflight fails when WEB_PAGE_MAX_TOKENS != 8000" do
    stub_git_clean do
      saved = BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS
      BatchChunkingPrompt.send(:remove_const, :WEB_PAGE_MAX_TOKENS)
      BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS = 4000
      with_harness do |h|
        err = assert_raises(Gate9FinalManual::PreflightError) { h.run! }
        assert_includes err.message, "WEB_PAGE_MAX_TOKENS"
      end
    ensure
      BatchChunkingPrompt.send(:remove_const, :WEB_PAGE_MAX_TOKENS)
      BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS = saved
    end
  end

  test "preflight fails when manual file does not exist" do
    stub_git_clean do
      with_harness(env_extra: { "GATE9_FINAL_MANUAL" => "/tmp/nonexistent_xyz_gate9.pdf" }) do |h|
        err = assert_raises(Gate9FinalManual::PreflightError) { h.run! }
        assert_includes err.message, "GATE9_FINAL_MANUAL"
      end
    end
  end

  test "preflight fails on dedup hit" do
    stub_git_clean do
      stub_scanned_zero do
        orig = ContentDedupService.method(:find_completed)
        ContentDedupService.define_singleton_method(:find_completed) do |**|
          ContentDedupService::Result.new(hit: true, asset: nil, canonical_name: "dup", aliases: [])
        end
        with_harness do |h|
          err = assert_raises(Gate9FinalManual::PreflightError) { h.run! }
          assert_includes err.message, "dedup hit"
        end
      ensure
        ContentDedupService.define_singleton_method(:find_completed, orig)
      end
    end
  end

  test "preflight fails when scanned_fraction_local >= threshold" do
    stub_git_clean do
      stub_dedup_miss do
        orig = Gate9FinalManual.instance_method(:count_scanned_dense_local)
        Gate9FinalManual.define_method(:count_scanned_dense_local) { |_binary| 9_999 }
        with_harness do |h|
          err = assert_raises(Gate9FinalManual::PreflightError) { h.run! }
          assert_includes err.message, "predominantemente escaneado"
        end
      ensure
        Gate9FinalManual.define_method(:count_scanned_dense_local, orig)
      end
    end
  end

  test "preflight fails when modeled estimate exceeds GATE9_FINAL_BUDGET_USD" do
    stub_git_clean do
      stub_dedup_miss do
        stub_scanned_zero do
          orig = Gate9FinalManual.instance_method(:compute_estimate)
          Gate9FinalManual.define_method(:compute_estimate) do |*|
            { modeled_estimate_usd: 999.0,
              breakdown: { page_filter: 0, sonnet_parse: 999, opus_parse: 0, embeddings_estimated: 0 } }
          end
          with_harness(env_extra: {
            "GATE9_FINAL_EXECUTE"    => "true",
            "GATE9_FINAL_BUDGET_USD" => "0.01",
            "ANTHROPIC_API_KEY"      => "fake"
          }) do |h|
            err = assert_raises(Gate9FinalManual::PreflightError) { h.run! }
            assert_includes err.message, "budget"
          end
        ensure
          Gate9FinalManual.define_method(:compute_estimate, orig)
        end
      end
    end
  end

  # ─── Test 2: Dedup calls find_completed with correct contract version ──

  test "dedup calls find_completed with sha256 and INGESTION_CONTRACT_VERSION" do
    stub_git_clean do
      stub_scanned_zero do
        calls = []
        orig  = ContentDedupService.method(:find_completed)
        ContentDedupService.define_singleton_method(:find_completed) do |sha256:, contract_version:|
          calls << { sha256: sha256, contract_version: contract_version }
          ContentDedupService::Result.new(hit: false, asset: nil, canonical_name: nil, aliases: [])
        end
        with_harness do |h|
          h.run! rescue Gate9FinalManual::PreflightError
        end
        assert calls.any?, "find_completed must be called during preflight"
        assert_equal BatchChunkingPrompt::INGESTION_CONTRACT_VERSION, calls.first[:contract_version]
        assert calls.first[:sha256].present?, "sha256 must be passed to find_completed"
      ensure
        ContentDedupService.define_singleton_method(:find_completed, orig)
      end
    end
  end

  # ─── Test 3: Submit writes "submitting" BEFORE calling submit_batch ───

  test "submit writes 'submitting' with sha/commit/contract/fingerprint before calling submit_batch" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(2)
      sha256 = Digest::SHA256.hexdigest(binary)
      state_path_for_test = File.join("tmp", "gate9_final", sha256, "state.json")

      cids     = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }
      inner_bc = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1)),
        fake_batch_result(cids[2], valid_chunk_json(page: 2))
      ])
      state_at_submit = nil

      # Decorator: capture state.json at the moment submit_batch is called, then delegate.
      bc = Object.new
      bc.define_singleton_method(:submit_batch) do |requests:|
        state_at_submit = File.exist?(state_path_for_test) ? JSON.parse(File.read(state_path_for_test)) : nil
        inner_bc.submit_batch(requests: requests)
      end
      bc.define_singleton_method(:retrieve)     { |batch_id:| inner_bc.retrieve(batch_id: batch_id) }
      bc.define_singleton_method(:results_each) { |batch_id:, &blk| inner_bc.results_each(batch_id: batch_id, &blk) }

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness|
        harness.run!

        assert state_at_submit,                                "state.json must exist when submit_batch is called"
        assert_equal "submitting",                             state_at_submit["status"]
        assert_equal sha256,                                   state_at_submit["sha256"]
        assert state_at_submit["commit"].present?,             "commit must be present in submitting state"
        assert state_at_submit["contract_version"].present?,   "contract_version must be in submitting state"
        assert state_at_submit["prompt_fingerprint"].present?, "prompt_fingerprint must be in submitting state"
        assert_nil state_at_submit["batch_id"],                "batch_id must NOT be set in submitting state"
      end
    end
  end

  # ─── Test 4: "submitting" without batch_id → AbortError, no submit_batch

  test "state 'submitting' without batch_id aborts without calling submit_batch" do
    stub_git_clean do
      stub_dedup_miss do
        stub_scanned_zero do
          bc = FakeBatchClient.new

          with_harness(
            env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                         "ANTHROPIC_API_KEY" => "fake" },
            batch_client: bc
          ) do |harness, _pdf, sha|
            state_dir = File.join("tmp", "gate9_final", sha)
            FileUtils.mkdir_p(state_dir)
            File.write(File.join(state_dir, "state.json"), JSON.generate({
              status:             "submitting",
              sha256:             sha,
              commit:             `git rev-parse HEAD`.strip,
              contract_version:   BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
              prompt_fingerprint: BatchChunkingPrompt.prompt_fingerprint_sha256
            }))

            assert_raises(Gate9FinalManual::AbortError) { harness.run! }
            assert_empty bc.submit_calls, "submit_batch must NOT be called on 'submitting' + no batch_id"
          end
        end
      end
    end
  end

  # ─── Test 5: Resume does NOT call submit_batch ────────────────────────

  test "resume from 'submitted' state never calls submit_batch" do
    stub_git_clean do
      stub_dedup_miss do
        stub_scanned_zero do
          # poll_status=in_progress + timeout=0 → goes to "waiting" without
          # needing stream/retry/merge, so we don't need ChunkMergerService stubs.
          bc = FakeBatchClient.new(poll_status: "in_progress")

          with_harness(
            env_extra: {
              "GATE9_FINAL_EXECUTE"               => "true",
              "GATE9_FINAL_BUDGET_USD"            => "100",
              "ANTHROPIC_API_KEY"                 => "fake",
              "GATE9_FINAL_BATCH_TIMEOUT_SECONDS" => "0"
            },
            batch_client: bc
          ) do |harness, _pdf, sha|
            commit    = `git rev-parse HEAD`.strip
            state_dir = File.join("tmp", "gate9_final", sha)
            FileUtils.mkdir_p(state_dir)
            File.write(File.join(state_dir, "state.json"), JSON.generate({
              status:             "submitted",
              batch_id:           "msgbatch_existing_001",
              sha256:             sha,
              commit:             commit,
              contract_version:   BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
              prompt_fingerprint: BatchChunkingPrompt.prompt_fingerprint_sha256,
              page_customs:       {},
              kept_pages:         [],
              total_pages:        3,
              filter_results:     {},
              filter_bq_window:   { start: 0, end: 0 },
              retried_pages:      {}
            }))

            harness.run!  # → polls once → waiting (timeout=0), clean exit

            assert_empty bc.submit_calls, "submit_batch must NEVER be called on resume"
          end
        end
      end
    end
  end

  # ─── Test 6: sha / commit / contract / fingerprint mismatch → AbortError

  test "abort when state sha256 does not match current PDF sha256" do
    stub_git_clean do
      stub_dedup_miss do
        stub_scanned_zero do
          bc = FakeBatchClient.new
          with_harness(
            env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                         "ANTHROPIC_API_KEY" => "fake" },
            batch_client: bc
          ) do |harness, _pdf, sha|
            state_dir = File.join("tmp", "gate9_final", sha)
            FileUtils.mkdir_p(state_dir)
            File.write(File.join(state_dir, "state.json"), JSON.generate({
              status:             "submitted",
              batch_id:           "msgbatch_001",
              sha256:             "a" * 64,  # DIFFERENT sha
              commit:             `git rev-parse HEAD`.strip,
              contract_version:   BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
              prompt_fingerprint: BatchChunkingPrompt.prompt_fingerprint_sha256
            }))
            err = assert_raises(Gate9FinalManual::AbortError) { harness.run! }
            assert_match(/sha/i, err.message)
          end
        end
      end
    end
  end

  test "abort when state contract_version does not match current" do
    stub_git_clean do
      stub_dedup_miss do
        stub_scanned_zero do
          bc = FakeBatchClient.new
          with_harness(
            env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                         "ANTHROPIC_API_KEY" => "fake" },
            batch_client: bc
          ) do |harness, _pdf, sha|
            state_dir = File.join("tmp", "gate9_final", sha)
            FileUtils.mkdir_p(state_dir)
            File.write(File.join(state_dir, "state.json"), JSON.generate({
              status:             "submitted",
              batch_id:           "msgbatch_001",
              sha256:             sha,
              commit:             `git rev-parse HEAD`.strip,
              contract_version:   "field_records_v1",  # STALE
              prompt_fingerprint: BatchChunkingPrompt.prompt_fingerprint_sha256
            }))
            err = assert_raises(Gate9FinalManual::AbortError) { harness.run! }
            assert_includes err.message, "contract_version"
          end
        end
      end
    end
  end

  # ─── Test 7: filter_results fully persisted; requests_manifest has fingerprints

  test "filter_results persisted with keep/reason/source/force_opus and requests_manifest has fingerprints" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(2)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }
      bc     = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1)),
        fake_batch_result(cids[2], valid_chunk_json(page: 2))
      ])

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!

        state = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "state.json")))
        fr    = state["filter_results"]
        assert fr.key?("1"), "filter_results must have page 1"
        assert fr.key?("2"), "filter_results must have page 2"
        %w[keep reason source force_opus].each do |k|
          assert fr["1"].key?(k), "filter_results[1] must have key #{k}"
        end

        req_path = File.join("tmp", "gate9_final", sha, "requests_manifest.json")
        assert File.exist?(req_path), "requests_manifest.json must be written"
        reqs = JSON.parse(File.read(req_path))
        assert reqs.any?, "requests_manifest must be non-empty"
        reqs.each do |r|
          assert r["system_fingerprint"].present?, "system_fingerprint must be in each request entry"
          assert r["content_digest"].present?,     "content_digest must be in each request entry"
        end
      end
    end
  end

  # ─── Test 8: retry anchor=min(kept_pages), total_kept from full set ───

  test "retry passes anchor=min(kept_pages) and total_kept from the complete kept set" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(4)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = (1..4).index_with { |n| "#{sha256[0..15]}_p#{n}" }

      # Page 3 has invalid JSON → needs retry; pages 1, 2, 4 are good.
      bc = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1)),
        fake_batch_result(cids[2], valid_chunk_json(page: 2)),
        fake_batch_result(cids[3], "{broken json}"),
        fake_batch_result(cids[4], valid_chunk_json(page: 4))
      ])

      observed_page_num = nil
      observed_total    = nil
      chunk_builder     = method(:valid_chunk_json)

      orig_new = ClaudeChunkingClient.method(:new)
      ClaudeChunkingClient.define_singleton_method(:new) do |model:|
        client = Object.new
        client.define_singleton_method(:call) do |**kwargs|
          observed_page_num = kwargs[:page_number]
          observed_total    = kwargs[:total_pages]
          { text: chunk_builder.call(page: kwargs[:page_number] || 1),
            stop_reason: nil,
            usage: { "input_tokens" => 100, "output_tokens" => 50,
                     "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 } }
        end
        client
      end

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness|
        harness.run!

        assert_equal 3, observed_page_num, "retry must target page 3 (the invalid-JSON page)"
        assert_equal 4, observed_total,    "total_kept must be 4 — full kept set, not just retry subset"
      end
    ensure
      ClaudeChunkingClient.define_singleton_method(:new, orig_new)
    end
  end

  # ─── Test 9: retry idempotent — retried_pages substituted, not re-called

  test "page already in retried_pages is substituted but ClaudeChunkingClient is NOT called" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(2)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }

      bc = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1)),
        fake_batch_result(cids[2], "{bad json}")
      ])

      client_calls  = []
      chunk_builder = method(:valid_chunk_json)
      orig_new      = ClaudeChunkingClient.method(:new)
      ClaudeChunkingClient.define_singleton_method(:new) do |model:|
        client = Object.new
        client.define_singleton_method(:call) do |**kwargs|
          client_calls << kwargs[:page_number]
          { text: chunk_builder.call(page: kwargs[:page_number] || 1), stop_reason: nil,
            usage: { "input_tokens" => 100, "output_tokens" => 50,
                     "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 } }
        end
        client
      end

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        commit    = `git rev-parse HEAD`.strip
        state_dir = File.join("tmp", "gate9_final", sha)
        FileUtils.mkdir_p(state_dir)

        # Resume from "retried" — page 2 already has healthy text in retried_pages.
        File.write(File.join(state_dir, "state.json"), JSON.generate({
          status:             "retried",
          batch_id:           "msgbatch_001",
          sha256:             sha,
          commit:             commit,
          contract_version:   BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
          prompt_fingerprint: BatchChunkingPrompt.prompt_fingerprint_sha256,
          page_customs:       cids.transform_keys(&:to_s),
          kept_pages:         [ 1, 2 ],
          total_pages:        2,
          filter_results: {
            "1" => { keep: true, reason: "heuristic", source: "heuristic", force_opus: false },
            "2" => { keep: true, reason: "heuristic", source: "heuristic", force_opus: false }
          },
          filter_bq_window: { start: 0, end: 0 },
          retried_pages:    { "2" => valid_chunk_json(page: 2) }
        }))
        FileUtils.touch(File.join(state_dir, "retries.jsonl"))
        File.open(File.join(state_dir, "results.jsonl"), "w") do |f|
          f.puts JSON.generate({ custom_id: cids[1], result_type: "succeeded",
            model: "claude-sonnet-4-6", stop_reason: nil,
            usage: { "input_tokens" => 100, "output_tokens" => 50,
                     "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 },
            text: valid_chunk_json(page: 1) })
          f.puts JSON.generate({ custom_id: cids[2], result_type: "succeeded",
            model: "claude-sonnet-4-6", stop_reason: nil,
            usage: { "input_tokens" => 100, "output_tokens" => 50,
                     "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 },
            text: "{bad json}" })
        end

        harness.run!

        assert_empty client_calls,
                     "ClaudeChunkingClient must NOT be called for a page already in retried_pages"
      end
    ensure
      ClaudeChunkingClient.define_singleton_method(:new, orig_new)
    end
  end

  # ─── Test 10: GateFailure BEFORE retries when candidates > max_retry_pages

  test "raises GateFailure before any retry call when candidates > MAX_RETRY_PAGES" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(3)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = (1..3).index_with { |n| "#{sha256[0..15]}_p#{n}" }

      # All 3 pages have invalid JSON → 3 candidates but MAX_RETRY_PAGES=1.
      bc = FakeBatchClient.new(results: (1..3).map { |n| fake_batch_result(cids[n], "{bad}") })

      client_calls = []
      orig_new     = ClaudeChunkingClient.method(:new)
      ClaudeChunkingClient.define_singleton_method(:new) do |model:|
        client = Object.new
        client.define_singleton_method(:call) do |**kwargs|
          client_calls << kwargs[:page_number]
          { text: "{}", stop_reason: nil, usage: { "input_tokens" => 10, "output_tokens" => 10,
                                                    "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 } }
        end
        client
      end

      with_harness(
        env_extra: {
          "GATE9_FINAL_EXECUTE"         => "true",
          "GATE9_FINAL_BUDGET_USD"      => "100",
          "ANTHROPIC_API_KEY"           => "fake",
          "GATE9_FINAL_MAX_RETRY_PAGES" => "1"
        },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness|
        assert_raises(Gate9FinalManual::GateFailure) { harness.run! }
        assert_empty client_calls, "ClaudeChunkingClient must NOT be called before GateFailure check"
      end
    ensure
      ClaudeChunkingClient.define_singleton_method(:new, orig_new)
    end
  end

  # ─── Test 11: Cero KB sync — prohibited classes never instantiated ────

  test "BulkKbSyncService BedrockIngestionJob S3DocumentsService are never instantiated" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(2)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }
      bc     = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1)),
        fake_batch_result(cids[2], valid_chunk_json(page: 2))
      ])

      [ BulkKbSyncService, BedrockIngestionJob, S3DocumentsService ].each do |klass|
        klass.define_singleton_method(:new) do |*|
          raise "#{klass.name} must not be instantiated inside the Gate 9R harness"
        end
      end

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!  # must not raise the sentinel
        state = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "state.json")))
        assert_equal "awaiting_human_review", state["status"],
                     "run must complete to awaiting_human_review without touching KB sync services"
      end
    ensure
      # remove_method (not undef_method) so Class#new remains accessible via inheritance
      [ BulkKbSyncService, BedrockIngestionJob, S3DocumentsService ].each do |klass|
        klass.singleton_class.remove_method(:new) rescue nil
      end
    end
  end

  # ─── Test 12: results.jsonl + retries.jsonl store FULL text + usage ───

  test "results.jsonl stores full text and full usage per page" do
    with_clean_run_stubs do
      binary    = build_fake_pdf_binary(2)
      sha256    = Digest::SHA256.hexdigest(binary)
      cids      = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }
      full_text = valid_chunk_json(page: 1)
      bc = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], full_text, input_tokens: 1234, output_tokens: 567),
        fake_batch_result(cids[2], valid_chunk_json(page: 2))
      ])

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!

        rows = File.readlines(File.join("tmp", "gate9_final", sha, "results.jsonl"))
                   .map { |l| JSON.parse(l) }
        row1 = rows.find { |r| r["custom_id"] == cids[1] }
        assert row1,                                                    "page 1 row must be in results.jsonl"
        assert_equal full_text, row1["text"],                           "full text must be stored"
        assert_equal 1234,      row1.dig("usage", "input_tokens"),      "input_tokens must be stored"
        assert_equal 567,       row1.dig("usage", "output_tokens"),     "output_tokens must be stored"
      end
    end
  end

  test "retries.jsonl stores full text and full usage when a retry occurs" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(2)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }
      bc     = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1)),
        fake_batch_result(cids[2], "{bad}")
      ])

      retry_text = valid_chunk_json(page: 2)
      orig_new   = ClaudeChunkingClient.method(:new)
      ClaudeChunkingClient.define_singleton_method(:new) do |model:|
        client = Object.new
        client.define_singleton_method(:call) do |**kwargs|
          { text: retry_text, stop_reason: nil,
            usage: { "input_tokens" => 800, "output_tokens" => 300,
                     "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 } }
        end
        client
      end

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!

        retries_path = File.join("tmp", "gate9_final", sha, "retries.jsonl")
        assert File.exist?(retries_path), "retries.jsonl must exist"
        rows = File.readlines(retries_path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
        assert rows.any?, "retries.jsonl must have at least one entry"
        r = rows.first
        assert_equal retry_text, r["text"],                       "full retry text must be stored"
        assert_equal 800,        r.dig("usage", "input_tokens"),  "retry input_tokens must be stored"
        assert_equal 300,        r.dig("usage", "output_tokens"), "retry output_tokens must be stored"
      end
    ensure
      ClaudeChunkingClient.define_singleton_method(:new, orig_new)
    end
  end

  # ─── Test 13: PRICING == BedrockQuery::BEDROCK_PRICING for all routes ─

  test "PRICING table matches BedrockQuery::BEDROCK_PRICING for all ingestion model routes" do
    p  = Gate9FinalManual::PRICING
    bp = BedrockQuery::BEDROCK_PRICING

    assert_equal bp["claude-sonnet-4-6-batch"][:input],           p["sonnet_batch"][:input],      "sonnet_batch input"
    assert_equal bp["claude-sonnet-4-6-batch"][:output],          p["sonnet_batch"][:output],     "sonnet_batch output"
    assert_equal bp["claude-sonnet-4-6-batch"][:cache_read],      p["sonnet_batch"][:cache_read], "sonnet_batch cache_read"
    assert_equal bp["claude-opus-4-8-batch"][:input],             p["opus_batch"][:input],        "opus_batch input"
    assert_equal bp["claude-opus-4-8-batch"][:output],            p["opus_batch"][:output],       "opus_batch output"
    assert_equal bp["claude-sonnet-4-6-direct"][:input],          p["sonnet_direct"][:input],     "sonnet_direct input"
    assert_equal bp["claude-sonnet-4-6-direct"][:output],         p["sonnet_direct"][:output],    "sonnet_direct output"
    assert_equal bp["claude-opus-4-8-direct"][:input],            p["opus_direct"][:input],       "opus_direct input"
    assert_equal bp["claude-opus-4-8-direct"][:output],           p["opus_direct"][:output],      "opus_direct output"
    assert_equal bp["claude-haiku-4-5-20251001-direct"][:input],  p["haiku_direct"][:input],      "haiku_direct input"
    assert_equal bp["claude-haiku-4-5-20251001-direct"][:output], p["haiku_direct"][:output],     "haiku_direct output"
  end

  test "parse cost uses sonnet_batch vs opus_batch determined by message.model" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(2)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }

      orig_filter = PageRelevanceFilter.method(:filter_pages)
      PageRelevanceFilter.define_singleton_method(:filter_pages) do |pages:, **|
        pages.each_with_object({}) do |p, h|
          h[p.number] = { keep: true, reason: :heuristic, source: :heuristic, force_opus: p.number == 2 }
        end
      end

      bc = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1), model: "claude-sonnet-4-6"),
        fake_batch_result(cids[2], valid_chunk_json(page: 2), model: "claude-opus-4-8")
      ])

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!
        output = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "output.json")))

        assert_equal 1, output.dig("metrics", "model_split", "sonnet"), "page 1 must be counted as sonnet"
        assert_equal 1, output.dig("metrics", "model_split", "opus"),   "page 2 must be counted as opus"
        assert_operator output.dig("cost", "harness_computed_usd", "parse").to_f, :>, 0
      end
    ensure
      PageRelevanceFilter.define_singleton_method(:filter_pages, orig_filter)
    end
  end

  # ─── Test 14: unit_cost and opus slope = null when n=0 ───────────────

  test "sonnet_per_page is null when all pages use opus (n_sonnet=0)" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(1)
      sha256 = Digest::SHA256.hexdigest(binary)

      orig_filter = PageRelevanceFilter.method(:filter_pages)
      PageRelevanceFilter.define_singleton_method(:filter_pages) do |pages:, **|
        pages.each_with_object({}) { |p, h| h[p.number] = { keep: true, reason: :heuristic, source: :heuristic, force_opus: true } }
      end

      bc = FakeBatchClient.new(results: [
        fake_batch_result("#{sha256[0..15]}_p1", valid_chunk_json(page: 1), model: "claude-opus-4-8")
      ])

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!
        output = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "output.json")))

        assert_nil output.dig("metrics", "unit_cost_usd", "sonnet_per_page"),
                   "sonnet_per_page must be null when n_sonnet=0"
        assert_equal 0, output.dig("metrics", "unit_cost_usd", "n_sonnet")
      end
    ensure
      PageRelevanceFilter.define_singleton_method(:filter_pages, orig_filter)
    end
  end

  test "opus slope_usd_per_opus_point is null when all pages use sonnet (n_opus=0)" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(1)
      sha256 = Digest::SHA256.hexdigest(binary)
      bc = FakeBatchClient.new(results: [
        fake_batch_result("#{sha256[0..15]}_p1", valid_chunk_json(page: 1), model: "claude-sonnet-4-6")
      ])

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!
        output = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "output.json")))

        assert_nil output.dig("commercial", "opus_sensitivity", "slope_usd_per_opus_point"),
                   "opus slope must be null when n_opus=0"
        assert_nil output.dig("metrics", "unit_cost_usd", "opus_per_page"),
                   "opus_per_page must be null when n_opus=0"
      end
    end
  end

  # ─── Test 15: counterfactual 4k separates truncation vs invalid_json ──

  test "counterfactual 4k separates truncation bucket (output>4000) from invalid_json bucket" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(3)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = (1..3).index_with { |n| "#{sha256[0..15]}_p#{n}" }

      # Page 1: normal (output ≤ 4000, no retry)
      # Page 2: valid JSON but output > 4000 → truncation bucket (would-be-truncated at 4k)
      # Page 3: invalid JSON, output ≤ 4000 → invalid_json bucket (retried)
      bc = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1), output_tokens: 3000),
        fake_batch_result(cids[2], valid_chunk_json(page: 2), output_tokens: 5000),
        fake_batch_result(cids[3], "{bad json}",              output_tokens: 200)
      ])

      chunk_builder = method(:valid_chunk_json)
      orig_new      = ClaudeChunkingClient.method(:new)
      ClaudeChunkingClient.define_singleton_method(:new) do |model:|
        client = Object.new
        client.define_singleton_method(:call) do |**kwargs|
          { text: chunk_builder.call(page: kwargs[:page_number] || 1),
            stop_reason: nil,
            usage: { "input_tokens" => 100, "output_tokens" => 50,
                     "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 } }
        end
        client
      end

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!
        output = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "output.json")))
        ba     = output.dig("commercial", "before_after")

        # Page 2 output > 4000 and was NOT retried → truncation bucket
        assert_operator ba["retries_4k_truncation_usd"].to_f, :>, 0,
                        "truncation_usd must be > 0 for pages with output > 4000 not retried"
        # Page 3 retried for invalid_json → invalid_json bucket
        assert_operator ba["retries_4k_invalid_json_usd"].to_f, :>, 0,
                        "invalid_json_usd must be > 0 for pages whose retry reason is invalid_json"
        assert_operator ba["counterfactual_4k_modeled_usd"].to_f, :>,
                        ba["retries_4k_truncation_usd"].to_f,
                        "counterfactual total must exceed individual truncation bucket"
      end
    ensure
      ClaudeChunkingClient.define_singleton_method(:new, orig_new)
    end
  end

  # ─── Test 16: batch timeout → status "waiting", not "failed" ──────────

  test "batch timeout sets status 'waiting' not 'failed' and exits cleanly" do
    with_clean_run_stubs do
      bc = FakeBatchClient.new(poll_status: "in_progress")

      with_harness(
        env_extra: {
          "GATE9_FINAL_EXECUTE"               => "true",
          "GATE9_FINAL_BUDGET_USD"            => "100",
          "ANTHROPIC_API_KEY"                 => "fake",
          "GATE9_FINAL_BATCH_TIMEOUT_SECONDS" => "0"
        },
        batch_client: bc
      ) do |harness, _pdf, sha|
        harness.run!  # must not raise

        state = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "state.json")))
        assert_equal "waiting", state["status"],
                     "status must be 'waiting' on timeout, not 'failed'"
      end
    end
  end

  # ─── Test 17: Phase IV stamps verdict, recalculates l2_publishable ────

  test "GATE9_FINAL_VERDICT=pass stamps human_review_verdict and sets l2_publishable" do
    with_clean_run_stubs do
      binary    = build_fake_pdf_binary(2)
      sha256    = Digest::SHA256.hexdigest(binary)
      state_dir = File.join("tmp", "gate9_final", sha256)

      begin
        Dir.mktmpdir("gate9_phase34") do |tmpdir|
          pdf  = File.join(tmpdir, "manual_2pp.pdf")
          File.binwrite(pdf, binary)
          cids = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }

          base_env = {
            "GATE9_FINAL_MANUAL"             => pdf,
            "BEDROCK_RERANKER_ENABLED"       => "false",
            "QUERY_ROUTING_ENABLED"          => "false",
            "GATE9_FINAL_BATCH_POLL_SECONDS" => "0",
            "GATE9_FINAL_MAX_RETRY_PAGES"    => "1",
            "KNOWLEDGE_BASE_S3_BUCKET"       => "test-bucket",
            "GATE9_FINAL_EXECUTE"            => "true",
            "GATE9_FINAL_BUDGET_USD"         => "100",
            "ANTHROPIC_API_KEY"              => "fake"
          }

          # Phase III
          bc3 = FakeBatchClient.new(results: [
            fake_batch_result(cids[1], valid_chunk_json(page: 1)),
            fake_batch_result(cids[2], valid_chunk_json(page: 2))
          ])
          Gate9FinalManual.new(env: base_env, batch_client: bc3, s3_client: FakeS3Client.new).run!

          p3 = JSON.parse(File.read(File.join(state_dir, "output.json")))
          assert_nil p3.dig("quality", "human_review_verdict"),
                     "human_review_verdict must be null after Phase III"
          assert_nil p3.dig("commercial", "verdict", "gate9R_l2_publishable"),
                     "gate9R_l2_publishable must be null before Phase IV"

          # Phase IV — PDF still exists in tmpdir so current_sha256 resolves correctly.
          phase4_env = base_env.merge("GATE9_FINAL_VERDICT" => "pass", "GATE9_FINAL_EXECUTE" => nil)
          Gate9FinalManual.new(env: phase4_env, batch_client: FakeBatchClient.new,
                               s3_client: FakeS3Client.new).run!

          p4 = JSON.parse(File.read(File.join(state_dir, "output.json")))
          assert_equal "pass",   p4.dig("quality", "human_review_verdict")
          assert_equal "passed", p4["status"]
          assert_not_nil p4.dig("commercial", "verdict", "quality_gate_pass")
          assert_not_nil p4.dig("commercial", "verdict", "gate9R_l2_publishable")
        end
      ensure
        FileUtils.rm_rf(state_dir)
      end
    end
  end

  test "gate9R_l2_publishable is null while human_review_verdict has not been stamped" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(1)
      sha256 = Digest::SHA256.hexdigest(binary)
      bc     = FakeBatchClient.new(results: [
        fake_batch_result("#{sha256[0..15]}_p1", valid_chunk_json(page: 1))
      ])

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!  # Phase III only — no verdict

        output = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "output.json")))
        assert_nil output.dig("quality", "human_review_verdict"),
                   "human_review_verdict must be null after Phase III"
        assert_nil output.dig("commercial", "verdict", "gate9R_l2_publishable"),
                   "gate9R_l2_publishable must be null while human_review_verdict is null"
      end
    end
  end

  # ─── Test 18: QC lists — dropped = complement of kept; sonnet_sample stride

  test "dropped_pages is the complement of kept_pages" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(4)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = (1..4).index_with { |n| "#{sha256[0..15]}_p#{n}" }

      # Filter keeps 1, 2, 4 — drops page 3.
      orig_filter = PageRelevanceFilter.method(:filter_pages)
      PageRelevanceFilter.define_singleton_method(:filter_pages) do |pages:, **|
        pages.each_with_object({}) do |p, h|
          h[p.number] = { keep: p.number != 3, reason: (p.number == 3 ? :toc : :heuristic),
                          source: :heuristic, force_opus: false }
        end
      end

      bc = FakeBatchClient.new(results: [ 1, 2, 4 ].map { |n|
        fake_batch_result(cids[n], valid_chunk_json(page: n))
      })

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!
        output = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "output.json")))

        dropped_pages = output.dig("quality", "qc_review_lists", "dropped_pages").pluck("page")
        assert_equal [ 3 ], dropped_pages, "dropped_pages must be complement of kept_pages"
        assert_includes output.dig("batch", "dropped_pages"), 3
      end
    ensure
      PageRelevanceFilter.define_singleton_method(:filter_pages, orig_filter)
    end
  end

  test "sonnet_sample is deterministic by stride — every Nth sonnet page sorted by page_number" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(10)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = (1..10).index_with { |n| "#{sha256[0..15]}_p#{n}" }
      bc     = FakeBatchClient.new(results: (1..10).map { |n|
        fake_batch_result(cids[n], valid_chunk_json(page: n), model: "claude-sonnet-4-6")
      })

      with_harness(
        env_extra: {
          "GATE9_FINAL_EXECUTE"              => "true",
          "GATE9_FINAL_BUDGET_USD"           => "100",
          "ANTHROPIC_API_KEY"                => "fake",
          "GATE9_FINAL_SONNET_SAMPLE_STRIDE" => "3"
        },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!
        output = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "output.json")))
        sample = output.dig("quality", "qc_review_lists", "sonnet_sample").pluck("page")

        # Sorted sonnet pages 1..10, stride=3: select where (idx+1) % 3 == 0
        # → idx 2, 5, 8 (0-based) → pages 3, 6, 9
        assert_equal [ 3, 6, 9 ], sample,
                     "sonnet_sample must be deterministic: every 3rd sonnet page by sorted order"
      end
    end
  end

  test "paid execution requires positive budget dedicated API key and explicit S3 bucket" do
    with_clean_run_stubs do
      with_harness(env_extra: { "GATE9_FINAL_EXECUTE" => "true" }) do |harness|
        error = assert_raises(Gate9FinalManual::PreflightError) { harness.run! }
        assert_includes error.message, "GATE9_FINAL_BUDGET_USD"
        assert_includes error.message, "ANTHROPIC_API_KEY"
      end

      with_harness(env_extra: {
        "GATE9_FINAL_EXECUTE"       => "true",
        "GATE9_FINAL_BUDGET_USD"    => "100",
        "ANTHROPIC_API_KEY"         => "fake",
        "KNOWLEDGE_BASE_S3_BUCKET" => nil
      }) do |harness|
        error = assert_raises(Gate9FinalManual::PreflightError) { harness.run! }
        assert_includes error.message, "KNOWLEDGE_BASE_S3_BUCKET"
      end
    end
  end

  test "preflight rejects empty PDFs and manuals over the 200 page L2 limit" do
    stub_git_clean do
      stub_dedup_miss do
        stub_scanned_zero do
          with_harness(page_count: 0) do |harness|
            error = assert_raises(Gate9FinalManual::PreflightError) { harness.run! }
            assert_includes error.message, "no readable pages"
          end

          with_harness(page_count: 201) do |harness|
            error = assert_raises(Gate9FinalManual::PreflightError) { harness.run! }
            assert_includes error.message, "included L2 maximum is 200"
          end

          with_harness(page_count: 200) do |harness|
            output = harness.run!
            assert_equal 200, output.dig("manifest", "page_count")
          end
        end
      end
    end
  end

  test "corrupt state aborts without treating the run as a fresh submit" do
    with_clean_run_stubs do
      bc = FakeBatchClient.new
      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc
      ) do |harness, _pdf, sha|
        state_dir = File.join("tmp", "gate9_final", sha)
        FileUtils.mkdir_p(state_dir)
        File.write(File.join(state_dir, "state.json"), "{corrupt")

        error = assert_raises(Gate9FinalManual::AbortError) { harness.run! }
        assert_includes error.message, "DO NOT resubmit"
        assert_empty bc.submit_calls
      end
    end
  end

  test "retry preserves the original max_tokens cause after a healthy retry" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(1)
      sha256 = Digest::SHA256.hexdigest(binary)
      cid    = "#{sha256[0..15]}_p1"
      bc     = FakeBatchClient.new(results: [
        fake_batch_result(cid, "{truncated", stop_reason: "max_tokens")
      ])

      chunk_builder = method(:valid_chunk_json)
      original_new  = ClaudeChunkingClient.method(:new)
      ClaudeChunkingClient.define_singleton_method(:new) do |model:|
        client = Object.new
        client.define_singleton_method(:call) do |**kwargs|
          { text: chunk_builder.call(page: kwargs[:page_number]), stop_reason: nil,
            usage: { "input_tokens" => 100, "output_tokens" => 50,
                     "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 } }
        end
        client
      end

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!
        retry_row = JSON.parse(File.readlines(File.join("tmp", "gate9_final", sha, "retries.jsonl")).first)
        assert_equal "max_tokens", retry_row["reason"]
      end
    ensure
      ClaudeChunkingClient.define_singleton_method(:new, original_new)
    end
  end

  test "failed batch results survive Phase IV and prevent publication without the PDF env" do
    with_clean_run_stubs do
      binary = build_fake_pdf_binary(2)
      sha256 = Digest::SHA256.hexdigest(binary)
      cids   = { 1 => "#{sha256[0..15]}_p1", 2 => "#{sha256[0..15]}_p2" }
      bc     = FakeBatchClient.new(results: [
        fake_batch_result(cids[1], valid_chunk_json(page: 1)),
        fake_failed_batch_result(cids[2])
      ])

      with_harness(
        env_extra: { "GATE9_FINAL_EXECUTE" => "true", "GATE9_FINAL_BUDGET_USD" => "100",
                     "ANTHROPIC_API_KEY" => "fake" },
        batch_client: bc,
        pdf_binary: binary
      ) do |harness, _pdf, sha|
        harness.run!

        phase4 = Gate9FinalManual.new(env: { "GATE9_FINAL_VERDICT" => "pass" })
        phase4.run!

        output = JSON.parse(File.read(File.join("tmp", "gate9_final", sha, "output.json")))
        assert_equal "failed", output["status"]
        assert_equal [ { "page" => 2, "type" => "errored" } ], output.dig("batch", "failed_results")
        assert_equal false, output.dig("quality", "structural_gates", "manual_complete")
        assert_equal false, output.dig("commercial", "verdict", "gate9R_l2_publishable")
      end
    end
  end

  test "Phase IV refuses a batch that is not awaiting human review" do
    with_clean_run_stubs do
      bc = FakeBatchClient.new(poll_status: "in_progress")
      with_harness(
        env_extra: {
          "GATE9_FINAL_EXECUTE"               => "true",
          "GATE9_FINAL_BUDGET_USD"            => "100",
          "ANTHROPIC_API_KEY"                 => "fake",
          "GATE9_FINAL_BATCH_TIMEOUT_SECONDS" => "0"
        },
        batch_client: bc
      ) do |harness, pdf|
        harness.run!
        verdict_harness = Gate9FinalManual.new(env: {
          "GATE9_FINAL_MANUAL" => pdf,
          "GATE9_FINAL_VERDICT" => "pass"
        })
        error = assert_raises(Gate9FinalManual::AbortError) { verdict_harness.run! }
        assert_includes error.message, "awaiting_human_review"
      end
    end
  end

  test "evidence contract is validated instead of hardcoded" do
    with_harness do |harness|
      invalid = JSON.generate({
        document_name: "Test",
        aliases: [],
        chunks: [ { text: "Unsafe", field_records: [ { k: "INVENTED", h: "H", a: "A", r: "R", ev: "E" } ] } ]
      })
      harness.instance_variable_set(:@page_results, [ { page_number: 1, text: invalid } ])
      assert_equal false, harness.send(:evidence_contract_ok?)
    end
  end

  test "contractual maximum is sourced from Gate9CostMatrix" do
    assert_equal Gate9CostMatrix.new.report.dig(:contractual_max, :manual_200pp),
                 Gate9FinalManual.contractual_max
  end
end
