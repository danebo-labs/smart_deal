# frozen_string_literal: true

# Transcribes one dictation, exactly once per attempt.
#
# The whole job is built around fixed rule 13. Before anything is sent to a
# provider it claims the dictation with a compare-and-set; a second perform of
# the same dictation — a Solid Queue retry, a duplicate enqueue, two workers
# racing — fails the claim and returns without spending a cent. The result is
# written back under the same claim, so a transcript that arrives after the
# certifier already confirmed the dictation is dropped instead of overwriting
# their edit.
#
# No retry_on, and that is deliberate. A retry could not produce a second
# provider call anyway (it would fail the claim on a dictation now in
# `transcribing`), so all it would buy is a delay before the certifier learns
# the transcription failed. Instead a provider failure transitions the
# dictation to `failed` and surfaces there; retrying is then an explicit human
# decision (T5), which is the only place where paying for a second call is a
# choice someone made.
class TranscriptionJob < ApplicationJob
  # Own lane (config/queue.yml): the provider poll happens inside this job, so
  # each dictation holds a worker thread for 10–60 s. On the shared `default`
  # lane a few simultaneous dictations would delay the chat's cost footer and
  # photo analysis; two threads here also cap the provider calls in flight.
  queue_as :transcription

  def perform(voice_dictation_id:)
    dictation = VoiceDictation.find_by(id: voice_dictation_id)
    return if dictation.nil?

    unless dictation.audio_available?
      Rails.logger.warn(
        "TranscriptionJob: dictation #{dictation.id} has no audio " \
        "(purged=#{dictation.audio_purged_at.present?}) — nothing to transcribe"
      )
      return
    end

    provider = SpeechToText::Client.resolve_provider
    claim_id = VoiceDictation.claim_for_transcription!(id: dictation.id, provider: provider)
    if claim_id.nil?
      # The interesting case is not the duplicate enqueue but the concurrent
      # one: this branch is what keeps two performs from becoming two invoices.
      Rails.logger.info(
        "TranscriptionJob: dictation #{dictation.id} already claimed " \
        "(status=#{dictation.reload.status}) — no provider call made"
      )
      return
    end

    transcribe(dictation, provider: provider, claim_id: claim_id)
  end

  private

  def transcribe(dictation, provider:, claim_id:)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = SpeechToText::Client.for(provider).transcribe(
      s3_key: dictation.s3_key_audio,
      language: language,
      duration_hint_seconds: dictation.duration_seconds
    )

    duration = result.duration_seconds.presence || dictation.duration_seconds
    cost     = SpeechToText::Pricing.estimate_usd(
      provider: result.provider, duration_seconds: duration, model: result.model
    )

    written = VoiceDictation.record_transcript(
      id: dictation.id, claim_id: claim_id, text: result.text,
      provider: result.provider, duration_seconds: duration, cost_estimate_usd: cost
    )

    unless written
      # Billed but unusable: the dictation moved on while the provider worked.
      # Logged with its cost so the benchmark of Fase 6 can see money spent on
      # transcripts nobody received, and explicitly *not* written anywhere near
      # transcript_edited.
      log_usage(dictation, provider: result.provider, model: result.model, duration_seconds: duration,
                           cost: cost, latency_ms: elapsed_ms(started_at), outcome: "discarded_late_result")
      Rails.logger.warn(
        "TranscriptionJob: late result for dictation #{dictation.id} discarded — " \
        "claim #{claim_id} is no longer live"
      )
      return
    end

    log_usage(dictation, provider: result.provider, model: result.model, duration_seconds: duration,
                         cost: cost, latency_ms: elapsed_ms(started_at), outcome: "transcribed")
    VoiceDictationBroadcaster.transcribed(dictation.reload)
  rescue SpeechToText::Error => e
    handle_failure(dictation, claim_id: claim_id, error: e,
                              provider: provider, latency_ms: elapsed_ms(started_at))
  end

  def handle_failure(dictation, claim_id:, error:, provider:, latency_ms:)
    reason = "#{error.class.name.demodulize}: #{error.message}"
    recorded = VoiceDictation.record_failure(id: dictation.id, claim_id: claim_id, reason: reason)

    log_usage(dictation, provider: provider, model: nil, duration_seconds: dictation.duration_seconds,
                         cost: nil, latency_ms: latency_ms,
                         outcome: recorded ? "failed" : "discarded_late_failure",
                         error_class: error.class.name)
    Rails.logger.error("TranscriptionJob: dictation #{dictation.id} failed — #{reason}")

    VoiceDictationBroadcaster.failed(dictation.reload, reason: reason) if recorded
  end

  # This phase's own telemetry (fixed rule 7): a transcription is not a model
  # invocation and must never become a bedrock_queries row, whose `source` enum
  # is closed and whose every row assumes a positive input token count. The
  # durable record is the voice_dictations row itself; this line is what makes
  # a single transcription greppable alongside its latency and outcome.
  def log_usage(dictation, provider:, model:, duration_seconds:, cost:, latency_ms:, outcome:,
                error_class: nil)
    payload = {
      event: "stt_transcription",
      ts: Time.current.iso8601,
      voice_dictation_id: dictation.id,
      account_id: dictation.account_id,
      user_id: dictation.user_id,
      certification_report_id: dictation.certification_report_id,
      provider: provider,
      model: model,
      duration_seconds: duration_seconds,
      cost_estimate_usd: cost,
      pricing_version: SpeechToText::Pricing::VERSION,
      latency_ms: latency_ms,
      outcome: outcome,
      error_class: error_class
    }.compact
    Rails.logger.info("[STT_USAGE] #{JSON.generate(payload)}")
  rescue StandardError => e
    Rails.logger.warn("TranscriptionJob: usage log failed — #{e.class}")
  end

  def language
    ENV.fetch("STT_LANGUAGE", SpeechToText::DEFAULT_LANGUAGE)
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
