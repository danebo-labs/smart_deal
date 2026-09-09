# frozen_string_literal: true

# Turns recorded audio into a durable dictation: bytes to S3 first, then one
# row, then one job. Same shape as the photo path — the bytes never travel
# inside job arguments.
#
# Idempotent by content, per report. A double tap on the record button, a
# retried upload from a flaky field connection, or two browser tabs submitting
# the same blob all resolve to the same dictation and therefore to a single
# billed transcription. The same audio filed against a *different* report is a
# new row on purpose: deduplicating globally by account would make it
# impossible to reuse a recording across reports (section 2.2, gap 5).
class VoiceDictationIntake
  # @param duration_seconds [Integer, nil] measured at recording time. The
  #   OpenAI-compatible providers report no audio length, so for them this is
  #   the only figure the cost estimate can use.
  # @return [VoiceDictation, nil] nil only when the upload failed or the
  #   arguments were unusable — never a row without audio behind it.
  def self.call(account_id:, user_id:, binary:, content_type:,
                certification_report_id: nil, duration_seconds: nil, filename: nil, s3: nil)
    return nil if account_id.blank? || user_id.blank? || binary.blank?

    sha256 = Digest::SHA256.hexdigest(binary)
    existing = find_existing(account_id, certification_report_id, sha256)
    return existing if existing

    key = VoiceDictationAudio.store!(
      account_id: account_id, sha256: sha256, binary: binary,
      content_type: content_type, filename: filename, s3: s3
    )
    return nil if key.blank?

    dictation = VoiceDictation.create!(
      account_id: account_id,
      user_id: user_id,
      certification_report_id: certification_report_id,
      sha256: sha256,
      s3_key_audio: key,
      content_type: content_type,
      byte_size: binary.bytesize,
      duration_seconds: duration_seconds
    )
    TranscriptionJob.perform_later(voice_dictation_id: dictation.id)
    dictation
  rescue ActiveRecord::RecordNotUnique
    # Lost the race to a concurrent upload of the same audio. The winner has
    # already enqueued the job; enqueueing again here is exactly the second
    # billed call the claim exists to prevent, so this returns the row and
    # stops.
    find_existing(account_id, certification_report_id, sha256)
  end

  # Matches the unique index, including its NULLS NOT DISTINCT behaviour: a
  # report-less dictation still finds its twin, because `nil` becomes IS NULL
  # here and the index treats NULLs as equal.
  def self.find_existing(account_id, certification_report_id, sha256)
    VoiceDictation.find_by(
      account_id: account_id,
      certification_report_id: certification_report_id,
      sha256: sha256
    )
  end
  private_class_method :find_existing
end
