# frozen_string_literal: true

# The one place that knows where a dictation's audio lives in S3.
#
# Four callers need that layout — intake writes it, the adapters read it, the
# retention job deletes it, and destroying a draft report deletes it — so the
# prefix is defined once here rather than rebuilt in each. Same role
# FieldPhotoStore plays for photos.
#
# Never under bulk_chunks/: that prefix is what the Bedrock data source
# ingests, and a certifier's dictation must never become Knowledge Base
# content.
class VoiceDictationAudio
  PREFIX = "voice_dictations"

  class << self
    # @return [String, nil] the S3 key on success, nil when the upload failed —
    #   intake treats nil as "do not create a row", so a dictation never exists
    #   pointing at bytes that are not there.
    def store!(account_id:, sha256:, binary:, content_type:, filename: nil, s3: nil)
      return nil if account_id.blank? || sha256.blank? || binary.blank?

      key = object_key(account_id: account_id, sha256: sha256,
                       filename: filename, content_type: content_type)
      (s3 || S3DocumentsService.new).upload_binary(key, binary, content_type)
    end

    def object_key(account_id:, sha256:, content_type:, filename: nil)
      "#{prefix_for(account_id: account_id, sha256: sha256)}audio.#{extension_for(filename, content_type)}"
    end

    def prefix_for(account_id:, sha256:)
      "#{PREFIX}/#{account_id}/#{sha256}/"
    end

    # @return [Integer] objects deleted. S3DocumentsService#delete_prefix
    #   rescues everything and returns 0 rather than raising, so zero is the
    #   only signal that the bytes may still be there — logged loudly because
    #   by this point the row no longer points at them and only a human can
    #   reconcile it. Deliberately not re-raised: the row is already gone, and
    #   raising would only abort the rest of the batch.
    def delete!(account_id:, sha256:, s3: nil)
      prefix  = prefix_for(account_id: account_id, sha256: sha256)
      deleted = (s3 || S3DocumentsService.new).delete_prefix(prefix)
      if deleted.zero?
        Rails.logger.warn("VoiceDictationAudio: no S3 object deleted under #{prefix}")
      end
      deleted
    end

    private

    def extension_for(filename, content_type)
      File.extname(filename.to_s).delete_prefix(".").presence ||
        content_type.to_s.split("/").last.to_s.split(";").first.presence ||
        "bin"
    end
  end
end
