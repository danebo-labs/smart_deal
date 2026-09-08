# frozen_string_literal: true

# Persistent draft of a certification report — core scope of Fase 0 in
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md.
#
# user_id is NOT NULL because "mis informes" is per-user property, not only
# per-account (fixed rule 12): another user of the same account must not reach
# these rows. building_name is the single required identifier; every other
# building field stays optional so an inspection is never blocked by typing
# (fixed rule 4).
class CreateCertificationReports < ActiveRecord::Migration[8.1]
  def change
    create_table :certification_reports do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint  :user_id, null: false
      t.string  :status, null: false, default: "en_progreso"
      t.string  :building_name, null: false
      t.string  :commune
      t.string  :street
      t.string  :street_number
      t.string  :property_use
      t.date    :municipal_reception_date
      t.string  :internal_number
      t.date    :inspection_date
      t.string  :maintenance_company
      t.string  :maintenance_technician
      t.timestamps
    end

    # The "mis informes" query in one index: host tenancy, then ownership,
    # then recency.
    add_index :certification_reports,
              [ :account_id, :user_id, :created_at ],
              name: "idx_certification_reports_account_user_recent"
  end
end
