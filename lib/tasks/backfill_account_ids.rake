# frozen_string_literal: true

namespace :backfill do
  desc "Backfill nullable account_id columns to the legacy account"
  task account_ids: :environment do
    legacy = Account.find_by!(slug: "danebo-legacy")

    [ User, KbDocument, ConversationSession, WebManualBatch, TechnicianDocument ].each do |model|
      model.where(account_id: nil).in_batches(of: 500) do |batch|
        batch.update_all(account_id: legacy.id) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end
end
