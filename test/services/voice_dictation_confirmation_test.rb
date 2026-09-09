# frozen_string_literal: true

require "test_helper"

# The gate of fixed rule 3 and the idempotency half of fixed rule 13: nothing a
# provider produced enters a report draft without an explicit yes, and repeating
# that yes — double tap, retried request, late client response — yields one
# finding and the same answer.
class VoiceDictationConfirmationTest < ActiveSupport::TestCase
  def setup
    @account = accounts(:legacy)
    @user    = users(:one)
    @report  = certification_reports(:torre_amunategui)
  end

  def dictation(status: :transcribed, **attrs)
    sha = SecureRandom.hex(32)
    VoiceDictation.create!(
      { account: @account, user: @user, certification_report: @report, sha256: sha,
        content_type: "audio/webm", status: status, provider: "amazon_transcribe",
        transcript_raw: "La puerta de cabina roza al cerrar.",
        s3_key_audio: "voice_dictations/#{@account.id}/#{sha}/audio.webm" }.merge(attrs)
    )
  end

  # --- what a confirmation commits ---

  test "confirming creates one finding carrying the confirmed text" do
    record = dictation

    finding = nil
    assert_difference -> { InspectionFinding.count }, 1 do
      finding = VoiceDictationConfirmation.call(record)
    end

    assert_equal "La puerta de cabina roza al cerrar.", finding.body
    assert_equal @report.id, finding.certification_report_id
    assert_equal record.id, finding.voice_dictation_id
    assert_equal @account.id, finding.account_id
  end

  test "the certifier's correction is what gets committed, not the raw transcript" do
    record  = dictation(transcript_edited: "La puerta de cabina roza en el marco al cerrar.")
    finding = VoiceDictationConfirmation.call(record)

    assert_equal "La puerta de cabina roza en el marco al cerrar.", finding.body
  end

  test "confirming freezes the committed text on the dictation and stamps the time" do
    record = dictation
    VoiceDictationConfirmation.call(record)

    record.reload
    assert_equal "confirmed", record.status
    assert_not_nil record.confirmed_at
    assert_equal "La puerta de cabina roza al cerrar.", record.transcript_edited
  end

  test "an optional dictated location is carried through" do
    finding = VoiceDictationConfirmation.call(dictation, location: "Embarque 3")

    assert_equal "Embarque 3", finding.location
    assert_nil VoiceDictationConfirmation.call(dictation).location
  end

  # Fase 2 leaves typed findings at position 0, so a dictated one has to land
  # after whatever the certifier already wrote.
  test "the dictated finding is appended after the findings already in the draft" do
    InspectionFinding.create!(certification_report: @report, body: "Tecleado", position: 4)

    assert_equal 5, VoiceDictationConfirmation.call(dictation).position
  end

  # --- idempotency (fixed rule 13) ---

  test "confirming twice yields one finding and the same answer" do
    record = dictation

    first = VoiceDictationConfirmation.call(record)
    second = nil
    assert_no_difference -> { InspectionFinding.count } do
      second = VoiceDictationConfirmation.call(record)
    end

    assert_equal first.id, second.id
  end

  test "a stale in-memory copy of the dictation cannot confirm a second time" do
    record = dictation
    stale  = VoiceDictation.find(record.id)

    first  = VoiceDictationConfirmation.call(record)
    second = VoiceDictationConfirmation.call(stale)

    assert_equal first.id, second.id
    assert_equal 1, InspectionFinding.where(voice_dictation_id: record.id).count
  end

  test "confirming by id behaves exactly like confirming by record" do
    record = dictation

    first  = VoiceDictationConfirmation.call(record.id)
    second = VoiceDictationConfirmation.call(record.id)

    assert_equal first.id, second.id
  end

  # The second, independent layer: the unique index. Even a caller that skipped
  # the state transition entirely cannot produce a second finding.
  test "the database refuses a second finding for the same dictation" do
    record = dictation
    VoiceDictationConfirmation.call(record)

    assert_raises ActiveRecord::RecordNotUnique do
      InspectionFinding.create!(certification_report: @report, body: "Duplicado",
                                voice_dictation: record)
    end
  end

  # --- what it refuses ---

  test "only a transcribed dictation can be confirmed" do
    %i[pending transcribing failed].each do |status|
      assert_no_difference -> { InspectionFinding.count } do
        assert_nil VoiceDictationConfirmation.call(dictation(status: status)),
                   "a dictation in #{status} has nothing confirmable yet"
      end
    end
  end

  test "a dictation with no report has nowhere to file a finding" do
    orphan = dictation(certification_report: nil)

    assert_no_difference -> { InspectionFinding.count } do
      assert_nil VoiceDictationConfirmation.call(orphan)
    end
    assert_equal "transcribed", orphan.reload.status
  end

  test "an empty transcript never becomes an empty finding" do
    [ nil, "", "   " ].each do |text|
      assert_no_difference -> { InspectionFinding.count } do
        assert_nil VoiceDictationConfirmation.call(dictation(transcript_raw: text))
      end
    end
  end

  test "a dictation that does not exist is refused without raising" do
    assert_nil VoiceDictationConfirmation.call(-1)
  end

  # --- undo (Fase 5, T7) ---

  test "undo destroys the finding and puts the dictation back in front of the certifier" do
    record  = dictation
    VoiceDictation.record_edit(id: record.id, text: "La puerta roza al cerrar.")
    finding = VoiceDictationConfirmation.call(record.reload)

    assert_difference -> { InspectionFinding.count }, -1 do
      assert VoiceDictationConfirmation.undo(record)
    end

    assert_not InspectionFinding.exists?(finding.id)
    record.reload
    assert_equal "transcribed", record.status
    assert_equal "La puerta roza al cerrar.", record.transcript_edited
  end

  test "undo is idempotent and refuses a dictation that was never confirmed" do
    record = dictation
    VoiceDictationConfirmation.call(record)

    assert VoiceDictationConfirmation.undo(record)
    assert_not VoiceDictationConfirmation.undo(record), "a second undo has nothing left to reverse"
    assert_equal "transcribed", record.reload.status

    untouched = dictation
    assert_not VoiceDictationConfirmation.undo(untouched)
    assert_not VoiceDictationConfirmation.undo(-1)
  end

  test "after an undo the certifier can correct and confirm again, still yielding one finding" do
    record = dictation
    VoiceDictationConfirmation.call(record)
    VoiceDictationConfirmation.undo(record)

    assert VoiceDictation.record_edit(id: record.id, text: "Texto corregido tras deshacer.")
    again = VoiceDictationConfirmation.call(record.reload)

    assert_equal "Texto corregido tras deshacer.", again.body
    assert_equal 1, InspectionFinding.where(voice_dictation_id: record.id).count
  end

  # Fixed rule 1: classifying a defect against the norm is the certifier's
  # judgement, and Danebo guessing it would be worse than leaving it blank.
  test "Danebo fills only body, location and position" do
    finding = VoiceDictationConfirmation.call(dictation, location: "Embarque 3")

    assert_nil finding.severity
    assert_nil finding.nch2840_box
    assert_nil finding.norm_point
    assert_nil finding.inspection_item
    assert_nil finding.field_photo_id
  end
end
