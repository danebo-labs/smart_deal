# frozen_string_literal: true

require "yaml"

module SpeechToText
  # Fase 6 runner: one local audio set through every configured adapter.
  # Calls adapters directly (Fase 5: do not go through TranscriptionJob).
  # Uploads each clip once; does not create VoiceDictation rows (sha256
  # dedup would block the same bytes on a second provider).
  class Benchmark
    class Error < SpeechToText::Error; end

    FIXTURE_PATH = Rails.root.join("script/fixtures/stt_benchmark.yml")
    OUTPUT_PREFIX = "voice_dictations/benchmark"
    TRANSCRIBE_LANGUAGES = AmazonTranscribeAdapter::SUPPORTED_SPANISH
    DEFAULT_LANGUAGE = SpeechToText::DEFAULT_LANGUAGE

    Lane = Data.define(:id, :provider, :language)
    ClipResult = Data.define(
      :clip_id, :clip_label, :lane_id, :provider, :language, :model,
      :duration_seconds, :billed_seconds, :cost_usd, :latency_seconds,
      :text, :error
    )

    def self.run!(**kwargs)
      new(**kwargs).run!
    end

    def initialize(dir: nil, fixture_path: FIXTURE_PATH, s3: nil, adapters: nil,
                   providers: nil, env: ENV, clock: nil)
      @env           = env
      @dir           = Pathname(dir.presence || env["STT_BENCHMARK_DIR"].presence ||
                                Rails.root.join("tmp/stt_benchmark"))
      @fixture_path  = Pathname(fixture_path)
      @s3            = s3
      @injected      = adapters
      @provider_list = Array(providers).presence || requested_providers
      @clock         = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @run_id        = env["STT_BENCHMARK_RUN_ID"].presence || Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def run!
      corpus = load_corpus
      audio  = Audio.new(dir: audio_dir, voice: corpus.fetch("voice", "Paulina"))
      clips  = selected_clips(corpus)
      clips_by_id = corpus.fetch("clips").index_by { |clip| clip.fetch("id") }
      prepared = clips.map { |clip| prepare_clip(clip, clips_by_id, audio) }
      lanes = resolve_lanes
      raise Error, "no configured STT providers to benchmark" if lanes.empty?

      results = []
      prepared.each do |clip|
        key = upload_clip!(clip)
        lanes.each do |lane|
          results << transcribe_clip(clip, key, lane)
        end
      end

      report = write_outputs(build_report(corpus, prepared, lanes, results))
      cleanup_s3! if @env["STT_BENCHMARK_CLEANUP_S3"].present?
      report
    end

    def prepare_audio!
      corpus = load_corpus
      audio  = Audio.new(dir: audio_dir, voice: corpus.fetch("voice", "Paulina"))
      clips_by_id = corpus.fetch("clips").index_by { |clip| clip.fetch("id") }
      selected_clips(corpus).map { |clip| prepare_clip(clip, clips_by_id, audio) }
    end

    def lanes
      resolve_lanes
    end

    private

    def load_corpus
      YAML.safe_load_file(@fixture_path, aliases: true)
    end

    def selected_clips(corpus)
      wanted = @env["STT_BENCHMARK_CLIPS"].to_s.split(",").map(&:strip).compact_blank
      clips  = corpus.fetch("clips")
      return clips if wanted.empty?

      clips.select { |clip| wanted.include?(clip.fetch("id")) }.tap do |chosen|
        raise Error, "no clips match STT_BENCHMARK_CLIPS=#{wanted.inspect}" if chosen.empty?
      end
    end

    def prepare_clip(clip, clips_by_id, audio)
      path = audio.write_clip!(clip, clips_by_id)
      duration = if path.extname.downcase == ".wav"
        audio.duration_seconds(path)
      else
        source = clips_by_id[clip["source"]]
        source && audio.duration_seconds(audio.path_for(source))
      end
      duration ||= clip["duration_seconds"].to_i

      {
        "id" => clip.fetch("id"),
        "label" => clip["label"] || clip.fetch("id"),
        "kind" => clip.fetch("kind"),
        "path" => path,
        "content_type" => content_type_for(path),
        "duration_seconds" => duration.to_i,
        "expected_text" => clip["text"].to_s.squish.presence
      }
    end

    def requested_providers
      raw = @env["STT_BENCHMARK_PROVIDERS"].to_s.split(",").map(&:strip).compact_blank
      raw.presence || Client.providers
    end

    def resolve_lanes
      providers = @provider_list.select do |name|
        Client.providers.include?(name) && (@injected&.key?(name) || Client.configured?(name))
      end

      providers.flat_map do |name|
        if name == "amazon_transcribe" && @env["STT_BENCHMARK_SKIP_TRANSCRIBE_VARIANTS"].blank?
          TRANSCRIBE_LANGUAGES.map { |code| Lane.new("amazon_#{code}", name, code) }
        else
          language = name == "amazon_transcribe" ? AmazonTranscribeAdapter::DEFAULT_PROVIDER_LANGUAGE : DEFAULT_LANGUAGE
          [ Lane.new(name, name, language) ]
        end
      end
    end

    def adapter_for(provider)
      return @injected[provider] if @injected&.key?(provider)

      Client.for(provider)
    end

    def upload_clip!(clip)
      key = "#{OUTPUT_PREFIX}/#{@run_id}/#{clip.fetch('path').basename}"
      uploaded = s3.upload_binary(key, File.binread(clip.fetch("path")), clip.fetch("content_type"))
      raise Error, "S3 upload failed for #{clip['id']}" if uploaded.blank?

      key
    end

    def transcribe_clip(clip, s3_key, lane)
      started = @clock.call
      result  = adapter_for(lane.provider).transcribe(
        s3_key: s3_key,
        language: lane.language,
        duration_hint_seconds: clip.fetch("duration_seconds")
      )
      elapsed = (@clock.call - started).round(2)
      duration = (result.duration_seconds.presence || clip.fetch("duration_seconds")).to_i
      billed   = Pricing.billed_seconds(provider: lane.provider, duration_seconds: duration)
      cost     = Pricing.estimate_usd(provider: lane.provider, duration_seconds: duration,
                                      model: result.model)

      ClipResult.new(
        clip_id: clip.fetch("id"), clip_label: clip.fetch("label"),
        lane_id: lane.id, provider: lane.provider, language: lane.language,
        model: result.model, duration_seconds: duration, billed_seconds: billed,
        cost_usd: cost, latency_seconds: elapsed, text: result.text.to_s, error: nil
      )
    rescue SpeechToText::Error => e
      elapsed = (@clock.call - started).round(2)
      ClipResult.new(
        clip_id: clip.fetch("id"), clip_label: clip.fetch("label"),
        lane_id: lane.id, provider: lane.provider, language: lane.language,
        model: nil, duration_seconds: clip.fetch("duration_seconds"),
        billed_seconds: Pricing.billed_seconds(provider: lane.provider,
                                               duration_seconds: clip.fetch("duration_seconds")),
        cost_usd: nil, latency_seconds: elapsed, text: nil, error: e.message
      )
    end

    def build_report(corpus, clips, lanes, results)
      by_lane = results.group_by(&:lane_id)
      lanes_table = lanes.map do |lane|
        rows = by_lane[lane.id] || []
        ok   = rows.select { |row| row.error.blank? }
        cost = ok.sum { |row| row.cost_usd.to_f }
        billed = ok.sum { |row| row.billed_seconds.to_i }
        {
          "lane_id" => lane.id,
          "provider" => lane.provider,
          "language" => lane.language,
          "clips_ok" => ok.size,
          "clips_error" => rows.size - ok.size,
          "billed_seconds" => billed,
          "cost_usd" => cost.round(6),
          "cost_per_billed_minute_usd" => billed.positive? ? (cost / (billed / 60.0)).round(6) : nil,
          "latency_p50_seconds" => percentile(ok.map(&:latency_seconds), 0.50),
          "latency_p95_seconds" => percentile(ok.map(&:latency_seconds), 0.95)
        }
      end

      total_cost = lanes_table.sum { |row| row["cost_usd"].to_f }.round(6)
      {
        "version" => corpus["version"],
        "run_id" => @run_id,
        "pricing_version" => Pricing::VERSION,
        "default_provider_unchanged" => Client::DEFAULT_PROVIDER,
        "error_count_deferred_to_founder" => true,
        "phrases" => corpus.fetch("phrases"),
        "lanes" => lanes_table,
        "clips" => clips.map { |clip| clip.except("path").merge("path" => clip["path"].to_s) },
        "results" => results.map { |row| row.to_h.stringify_keys },
        "cogs" => cogs_projection(lanes_table),
        "total_cost_usd" => total_cost,
        "total_cost_under_2_usd" => total_cost < 2.0
      }
    end

    def cogs_projection(lanes_table)
      lanes_table.to_h do |row|
        provider = row["provider"]
        [
          row["lane_id"],
          {
            "short_finding_13s_usd" => Pricing.estimate_usd(provider: provider, duration_seconds: 13),
            "report_8_short_findings_usd" => (
              8 * Pricing.estimate_usd(provider: provider, duration_seconds: 13).to_f
            ).round(6),
            "dictation_15min_usd" => Pricing.estimate_usd(provider: provider, duration_seconds: 15 * 60),
            "dictation_20min_usd" => Pricing.estimate_usd(provider: provider, duration_seconds: 20 * 60)
          }
        ]
      end
    end

    def write_outputs(report)
      FileUtils.mkdir_p(output_dir)
      json_path = output_dir.join("results.json")
      md_path   = output_dir.join("table.md")
      File.write(json_path, JSON.pretty_generate(report))
      File.write(md_path, render_markdown(report))
      report.merge("output_json" => json_path.to_s, "output_md" => md_path.to_s)
    end

    def render_markdown(report)
      lines = []
      lines << "# STT benchmark #{report['run_id']}"
      lines << ""
      lines << "Pricing table #{report['pricing_version']}. " \
               "List-price × billed seconds (Amazon 15 s minimum). " \
               "No provider returned an invoice line on the transcription response."
      lines << ""
      lines << "Default `STT_PROVIDER` was **not** changed " \
               "(still `#{report['default_provider_unchanged']}`). " \
               "Error counts on the 20 technical phrases are for the founder."
      lines << ""
      lines << "## Lanes"
      lines << ""
      lines << "| Lane | Provider | Language | OK | Errors | Billed s | Cost USD | USD / billed min | p50 latency s | p95 latency s |"
      lines << "|---|---|---|---:|---:|---:|---:|---:|---:|---:|"
      report.fetch("lanes").each do |row|
        lines << "| #{row['lane_id']} | #{row['provider']} | #{row['language']} | " \
                 "#{row['clips_ok']} | #{row['clips_error']} | #{row['billed_seconds']} | " \
                 "#{fmt_money(row['cost_usd'])} | #{fmt_money(row['cost_per_billed_minute_usd'])} | " \
                 "#{row['latency_p50_seconds']} | #{row['latency_p95_seconds']} |"
      end
      lines << ""
      lines << "**Total billed this run: USD #{fmt_money(report['total_cost_usd'])}** " \
               "(under USD 2: #{report['total_cost_under_2_usd']})."
      lines << ""
      lines << "## COGS projection (list price, not this run's audio)"
      lines << ""
      lines << "| Lane | 13 s finding | 8 short findings | 15 min | 20 min |"
      lines << "|---|---:|---:|---:|---:|"
      report.fetch("cogs").each do |lane_id, row|
        lines << "| #{lane_id} | #{fmt_money(row['short_finding_13s_usd'])} | " \
                 "#{fmt_money(row['report_8_short_findings_usd'])} | " \
                 "#{fmt_money(row['dictation_15min_usd'])} | #{fmt_money(row['dictation_20min_usd'])} |"
      end
      lines << ""
      lines << "## Side-by-side transcripts"
      lines << ""
      lanes = report.fetch("lanes").pluck("lane_id")
      report.fetch("clips").each do |clip|
        lines << "### #{clip['id']} — #{clip['label']}"
        lines << ""
        if clip["expected_text"].present?
          lines << "Spoken / expected:"
          lines << ""
          lines << "> #{clip['expected_text']}"
          lines << ""
        end
        lanes.each do |lane_id|
          row = report.fetch("results").find { |item| item["clip_id"] == clip["id"] && item["lane_id"] == lane_id }
          next unless row

          lines << "**#{lane_id}** (#{row['latency_seconds']}s, USD #{fmt_money(row['cost_usd'])})"
          lines << ""
          if row["error"].present?
            lines << "_error:_ #{row['error']}"
          else
            lines << (row["text"].presence || "_empty_")
          end
          lines << ""
        end
      end
      lines << "## Founder scorecard — 20 technical phrases"
      lines << ""
      lines << "Mark ✓ / ✗ per lane. The runner does not score these."
      lines << ""
      header = [ "Phrase", *lanes ]
      lines << "| #{header.join(' | ')} |"
      lines << "|#{Array.new(header.size, '---').join('|')}|"
      report.fetch("phrases").each do |phrase|
        blanks = Array.new(lanes.size, "")
        lines << "| #{phrase['id']}: #{phrase['text']} | #{blanks.join(' | ')} |"
      end
      lines << ""
      lines.join("\n")
    end

    def cleanup_s3!
      s3.delete_prefix("#{OUTPUT_PREFIX}/#{@run_id}/")
    end

    def percentile(values, fraction)
      return nil if values.blank?

      sorted = values.compact.sort
      return sorted.first if sorted.size == 1

      index = ((sorted.size - 1) * fraction).round
      sorted[index]
    end

    def fmt_money(value)
      return "—" if value.nil?

      format("%.6f", value.to_f)
    end

    def content_type_for(path)
      case File.extname(path.to_s).downcase
      when ".webm" then "audio/webm"
      when ".m4a"  then "audio/mp4"
      when ".mp3"  then "audio/mpeg"
      when ".wav"  then "audio/wav"
      when ".ogg"  then "audio/ogg"
      when ".flac" then "audio/flac"
      else "application/octet-stream"
      end
    end

    def audio_dir
      @dir.join("audio")
    end

    def output_dir
      @dir.join(@run_id)
    end

    def s3
      @s3 ||= S3DocumentsService.new
    end
  end
end
