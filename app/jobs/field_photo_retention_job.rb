# frozen_string_literal: true

# Purges field photos older than the retention window. This is a bounded
# override for "don't make the technician re-upload during an active
# diagnosis," not a permanent photo archive.
#
# Evidence is exempt: a photo referenced by an InspectionFinding belongs to a
# certification report and is never purged (fixed rule 10 of
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md). Two independent layers
# enforce that — the exclusion below, and a restrictive foreign key from
# inspection_findings.field_photo_id that aborts a DELETE the query missed.
#
# Scheduled every day at 3am via config/recurring.yml.
class FieldPhotoRetentionJob < ApplicationJob
  queue_as :default

  # @return [Hash] { purged:, kept:, aborted: } — `kept` counts photos the
  #   exclusion skipped, `aborted` counts the FK backstop firing. A healthy run
  #   has aborted == 0: the query, not the constraint, protects the evidence.
  def perform
    cutoff  = ENV.fetch("FIELD_PHOTO_RETENTION_DAYS", "90").to_i.days.ago
    purged  = 0
    aborted = 0
    kept    = evidence_past(cutoff).count

    purgeable(cutoff).in_batches do |batch|
      batch.each do |photo|
        # Row before bytes: deleting from S3 is irreversible, so a finding
        # created after the batch was loaded must abort on the foreign key while
        # the original is still in the bucket.
        photo.destroy!
        prefix = s3_prefix_for(photo)
        if S3DocumentsService.new.delete_prefix(prefix).zero?
          Rails.logger.warn("FieldPhotoRetentionJob: no S3 object deleted under #{prefix}")
        end
        purged += 1
      rescue ActiveRecord::InvalidForeignKey
        # The FK backstop fired: the photo became report evidence mid-run.
        aborted += 1
      end
    end

    Rails.logger.info(
      "FieldPhotoRetentionJob: purged #{purged} expired field photo(s), " \
      "kept #{kept} referenced by a finding, #{aborted} aborted on the evidence FK"
    )

    { purged: purged, kept: kept, aborted: aborted }
  end

  private

  def purgeable(cutoff)
    expired(cutoff).where.not(id: InspectionFinding.with_photo.select(:field_photo_id))
  end

  def evidence_past(cutoff)
    expired(cutoff).where(id: InspectionFinding.with_photo.select(:field_photo_id))
  end

  def expired(cutoff)
    FieldPhoto.where(created_at: ...cutoff)
  end

  def s3_prefix_for(photo)
    "field_photos/#{photo.account_id}/#{photo.sha256}/"
  end
end
