# frozen_string_literal: true

namespace :backfill do
  desc "Backfill missing document_uid values on KB documents"
  task document_uids: :environment do
    KbDocument.where(document_uid: nil).find_each do |document|
      document.update_column(:document_uid, SecureRandom.uuid) # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
