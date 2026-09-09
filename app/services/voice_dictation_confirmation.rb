# frozen_string_literal: true

# The gate of fixed rule 3: nothing a provider produced reaches a report draft
# until the certifier has read it, corrected it if needed, and said yes. This
# service is that yes, and it is the only path from a dictation to an
# InspectionFinding.
#
# Confirming twice produces one finding and the same answer. Two independent
# mechanisms guarantee it, because a double tap with gloves on a bad connection
# is the expected input, not the edge case:
#
#   1. The transition is a conditional UPDATE inside a transaction, so it takes
#      the row lock. A second concurrent confirm blocks until the first
#      commits, then finds zero rows updated and reads the finding the winner
#      created.
#   2. inspection_findings.voice_dictation_id carries a unique index, so even a
#      caller that bypassed the transition could not insert a second finding.
#
# Danebo fills body, location and position and nothing else: severity,
# nch2840_box, norm_point and inspection_item stay empty because classifying a
# defect is the certifier's judgement, never ours (fixed rule 1).
class VoiceDictationConfirmation
  # @param dictation [VoiceDictation, Integer] the dictation or its id
  # @param location [String, nil] optional free-text location, as dictated
  # @return [InspectionFinding, nil] the single finding for this dictation, or
  #   nil when it cannot be confirmed: no report to file it against, nothing
  #   transcribed yet, or an empty transcript.
  def self.call(dictation, location: nil, now: Time.current)
    record = resolve(dictation)
    return nil if record.nil?

    # Already confirmed — including by the caller that just lost the race
    # below. Returning the existing finding is what makes the second tap
    # indistinguishable from the first.
    existing = InspectionFinding.find_by(voice_dictation_id: record.id)
    return existing if existing

    return nil if record.certification_report_id.blank?

    text = record.confirmed_text
    return nil if text.blank?

    created = nil
    ActiveRecord::Base.transaction do
      claimed = VoiceDictation.claim_confirmation!(id: record.id, text: text, now: now)
      # Someone else won. Leave the transaction cleanly and read their finding
      # outside it — by now it is committed.
      next unless claimed

      created = create_finding(record, text: text, location: location)
    end

    created || InspectionFinding.find_by(voice_dictation_id: record.id)
  rescue ActiveRecord::RecordNotUnique
    # The unique index fired: a finding for this dictation already exists.
    InspectionFinding.find_by(voice_dictation_id: record&.id)
  end

  # The inline undo offered right after a confirmation (Fase 5). Reverses
  # exactly what .call committed — the finding goes, the dictation returns to
  # `transcribed` with its text intact (T7) — inside one transaction, so a
  # crash between the two halves can't leave a finding without a dictation
  # state to match. Idempotent: a second undo finds nothing to reopen and
  # returns false without touching anything.
  #
  # @return [Boolean] true when this call performed the undo.
  def self.undo(dictation, now: Time.current)
    record = resolve(dictation)
    return false if record.nil?

    ActiveRecord::Base.transaction do
      InspectionFinding.where(voice_dictation_id: record.id).find_each(&:destroy!)
      VoiceDictation.reopen_confirmed!(id: record.id, now: now) or raise ActiveRecord::Rollback
      true
    end || false
  end

  # Goes through the model rather than insert_all on purpose: account_id is
  # NOT NULL and inherited from the report in a before_validation, so a raw
  # insert would have to duplicate that rule (Fase 4 insumos).
  def self.create_finding(record, text:, location:)
    InspectionFinding.create!(
      certification_report_id: record.certification_report_id,
      voice_dictation_id: record.id,
      body: text,
      location: location.presence,
      position: next_position(record.certification_report_id)
    )
  end
  private_class_method :create_finding

  # Appends after whatever the certifier already has. Fase 2 leaves position at
  # its default of 0 for typed findings, so the first dictated finding of a
  # report full of typed ones lands last, which is where a new dictation
  # belongs.
  def self.next_position(certification_report_id)
    (InspectionFinding.where(certification_report_id: certification_report_id).maximum(:position) || -1) + 1
  end
  private_class_method :next_position

  def self.resolve(dictation)
    return dictation if dictation.is_a?(VoiceDictation)

    VoiceDictation.find_by(id: dictation)
  end
  private_class_method :resolve
end
