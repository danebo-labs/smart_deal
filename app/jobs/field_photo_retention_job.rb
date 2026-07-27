# frozen_string_literal: true

# Purges field photos older than the retention window. This is a bounded
# override for "don't make the technician re-upload during an active
# diagnosis," not a permanent photo archive.
#
# Scheduled every day at 3am via config/recurring.yml.
class FieldPhotoRetentionJob < ApplicationJob
  queue_as :default

  def perform
    cutoff = ENV.fetch("FIELD_PHOTO_RETENTION_DAYS", "90").to_i.days.ago
    count = 0

    FieldPhoto.where(created_at: ...cutoff).in_batches do |batch|
      batch.each do |photo|
        S3DocumentsService.new.delete_prefix("field_photos/#{photo.account_id}/#{photo.sha256}/")
        photo.destroy
        count += 1
      end
    end

    Rails.logger.info("FieldPhotoRetentionJob: purged #{count} expired field photo(s)")
  end
end
