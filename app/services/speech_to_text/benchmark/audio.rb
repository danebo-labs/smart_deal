# frozen_string_literal: true

require "open3"

module SpeechToText
  class Benchmark
    # Builds the local WAV/M4A set the runner uploads. Speech uses macOS
    # `say` + `afconvert` (Fase 4 finding 5). Silence and noise are written
    # as PCM in Ruby so tests do not need those binaries.
    class Audio
      SAMPLE_RATE = 16_000
      CHANNELS    = 1
      BITS        = 16
      SAY         = "/usr/bin/say"
      AFCONVERT   = "/usr/bin/afconvert"

      class Error < SpeechToText::Benchmark::Error; end

      def initialize(dir:, voice: "Paulina")
        @dir   = Pathname(dir)
        @voice = voice
        FileUtils.mkdir_p(@dir)
      end

      def path_for(clip)
        ext = clip["format"].presence || "wav"
        @dir.join("#{clip.fetch('id')}.#{ext}")
      end

      def duration_seconds(path)
        samples, rate = pcm16_from_wav(path)
        (samples.length / rate.to_f).round
      rescue Error
        nil
      end

      def write_clip!(clip, clips_by_id)
        path = path_for(clip)
        return path if path.exist? && path.size.positive?

        case clip.fetch("kind")
        when "silence"
          write_silence(path, clip.fetch("duration_seconds").to_f)
        when "noise"
          write_noise(path, clip.fetch("duration_seconds").to_f)
        when "speech"
          write_speech(path, clip, clips_by_id)
        when "transcode"
          transcode(path, clip, clips_by_id)
        else
          raise Error, "unknown clip kind #{clip['kind'].inspect}"
        end

        path
      end

      private

      def write_speech(path, clip, clips_by_id)
        source_id = clip["source"]
        if source_id.present?
          source = clips_by_id.fetch(source_id)
          src    = write_clip!(source, clips_by_id)
          FileUtils.cp(src, path)
        else
          synthesize_speech(path, clip.fetch("text").to_s.squish)
        end

        scale!(path, clip["amplitude"].to_f) if clip["amplitude"].present?
        mix_noise!(path) if clip["noise"]
      end

      def transcode(path, clip, clips_by_id)
        source = clips_by_id.fetch(clip.fetch("source"))
        src    = write_clip!(source, clips_by_id)
        format = clip.fetch("format")
        raise Error, "only m4a transcode is supported (no ffmpeg for webm)" unless format == "m4a"

        run!(AFCONVERT, "-f", "m4af", "-d", "aac", src.to_s, path.to_s)
      end

      def synthesize_speech(path, text)
        raise Error, "empty speech text for #{path.basename}" if text.blank?
        raise Error, "#{SAY} is not available" unless File.executable?(SAY)
        raise Error, "#{AFCONVERT} is not available" unless File.executable?(AFCONVERT)

        aiff = path.sub_ext(".aiff")
        run!(SAY, "-v", @voice, "-o", aiff.to_s, text)
        run!(AFCONVERT, "-f", "WAVE", "-d", "LEI16@#{SAMPLE_RATE}", "-c", "1",
             aiff.to_s, path.to_s)
      ensure
        FileUtils.rm_f(aiff) if aiff
      end

      def write_silence(path, seconds)
        write_wav(path, Array.new(sample_count(seconds), 0))
      end

      def write_noise(path, seconds, amplitude: 2_400)
        write_wav(path, Array.new(sample_count(seconds)) { rand(-amplitude..amplitude) })
      end

      def mix_noise!(path, amplitude: 1_800)
        samples, rate = pcm16_from_wav(path)
        mixed = samples.map { |sample| clamp(sample + rand(-amplitude..amplitude)) }
        write_wav(path, mixed, sample_rate: rate)
      end

      def scale!(path, factor)
        samples, rate = pcm16_from_wav(path)
        write_wav(path, samples.map { |sample| clamp((sample * factor).round) }, sample_rate: rate)
      end

      def sample_count(seconds)
        (SAMPLE_RATE * seconds.to_f).round
      end

      def clamp(value)
        value.clamp(-32_768, 32_767)
      end

      def write_wav(path, samples, sample_rate: SAMPLE_RATE)
        data       = samples.pack("s<*")
        byte_rate  = sample_rate * CHANNELS * (BITS / 8)
        block      = CHANNELS * (BITS / 8)
        header     = [
          "RIFF", 36 + data.bytesize, "WAVE",
          "fmt ", 16, 1, CHANNELS, sample_rate, byte_rate, block, BITS,
          "data", data.bytesize
        ].pack("a4Va4a4VvvVVvv a4V")
        File.binwrite(path, header + data)
      end

      def pcm16_from_wav(path)
        bin = File.binread(path)
        raise Error, "#{path} is not a RIFF WAV" unless bin.start_with?("RIFF")

        offset = 12
        data = nil
        rate = SAMPLE_RATE
        while offset + 8 <= bin.bytesize
          chunk = bin[offset, 4]
          size  = bin[offset + 4, 4].unpack1("V")
          body  = offset + 8
          case chunk
          when "fmt "
            rate = bin[body + 4, 4].unpack1("V")
          when "data"
            data = bin[body, size]
          end
          offset = body + size
          offset += 1 if size.odd?
        end
        raise Error, "#{path} has no data chunk" if data.nil?

        [ data.unpack("s<*"), rate ]
      end

      def run!(*args)
        _out, err, status = Open3.capture3(*args)
        return if status.success?

        raise Error, "#{args.first} failed: #{err.presence || status.exitstatus}"
      end
    end
  end
end
