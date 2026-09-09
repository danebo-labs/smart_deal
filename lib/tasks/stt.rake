# frozen_string_literal: true

# End-to-end smoke test of the transcription layer against a real provider.
# Entry point only — every line of logic lives in the services this calls, per
# script/AGENTS.md.
#
#   STT_PROVIDER=amazon_transcribe bin/rails "stt:smoke[tmp/dictado.webm]"
#
# Fase 6 extends this into the multi-provider benchmark; the shape is already
# what it needs (same audio, one adapter per run, cost printed).
namespace :stt do
  desc "Transcribe a local audio file end to end through the real provider (dev smoke test)"
  task :smoke, [ :path, :duration ] => :environment do |_task, args|
    path = args[:path].to_s
    abort "usage: bin/rails \"stt:smoke[path/to/audio.webm]\"" if path.blank?
    abort "no such file: #{path}" unless File.exist?(path)

    account = Account.first or abort "no Account in this database"
    user    = User.where(account_id: account.id).first or abort "no User for account #{account.id}"
    report  = CertificationReport.owned_by(account_id: account.id, user_id: user.id).first ||
              CertificationReport.create!(account: account, user: user,
                                          building_name: "STT smoke test")

    binary   = File.binread(path)
    provider = SpeechToText::Client.resolve_provider
    puts "provider=#{provider} bytes=#{binary.bytesize} account=#{account.id} report=#{report.id}"

    dictation = VoiceDictationIntake.call(
      account_id: account.id, user_id: user.id, certification_report_id: report.id,
      binary: binary, content_type: content_type_for(path), filename: File.basename(path),
      duration_seconds: args[:duration].presence&.to_i
    ) or abort "intake failed — check the S3 upload"

    puts "dictation=#{dictation.id} status=#{dictation.status} key=#{dictation.s3_key_audio}"

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    TranscriptionJob.perform_now(voice_dictation_id: dictation.id)
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

    dictation.reload
    puts "\n--- result (#{elapsed}s wall clock) ---"
    puts "status:   #{dictation.status}"
    puts "provider: #{dictation.provider}"
    puts "duration: #{dictation.duration_seconds}s"
    puts "cost:     $#{dictation.cost_estimate_usd} (pricing #{SpeechToText::Pricing::VERSION})"
    puts "failure:  #{dictation.failure_reason}" if dictation.failure_reason.present?
    puts "\ntranscript:\n#{dictation.transcript_raw}"
  end

  def content_type_for(path)
    case File.extname(path).downcase
    when ".webm" then "audio/webm"
    when ".m4a"  then "audio/mp4"
    when ".mp3"  then "audio/mpeg"
    when ".wav"  then "audio/wav"
    when ".ogg"  then "audio/ogg"
    when ".flac" then "audio/flac"
    else "application/octet-stream"
    end
  end
end
