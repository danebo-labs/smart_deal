# frozen_string_literal: true

# The issuer identity of a certification company: one header per account,
# configured once (fixed rule 14 / shared contract point 6). A company is an
# account, so these are columns on `accounts` — not a per-report choice, not a
# template engine, and not a variant selector.
#
# Every column is nullable: capturing a draft and dictating must work before
# anyone fills this in (shared contract point 1). Completeness is a product rule
# enforced when a PDF is requested, not a database constraint.
#
# certifier_settings_user_id is the explicit owner of this shared configuration.
# Nullable on purpose: an account with nobody assigned shows the data read-only
# instead of letting the first visitor claim it. ON DELETE SET NULL because
# removing that user must degrade the account to read-only, never block the
# delete or leave a dangling pointer.
class AddCertifierProfileToAccounts < ActiveRecord::Migration[8.1]
  def change
    change_table :accounts, bulk: true do |t|
      t.string :certifier_name
      t.string :certifier_minvu_role
      t.string :certifier_logo_s3_key
      t.string :certifier_logo_content_type
      t.integer :certifier_logo_byte_size
      t.string :certifier_logo_sha256
    end

    add_reference :accounts, :certifier_settings_user,
                  foreign_key: { to_table: :users, on_delete: :nullify },
                  index: { name: "idx_accounts_certifier_settings_user" }
  end
end
