# frozen_string_literal: true

# A confirmed finding inside a report draft. `body` is the text the certifier
# confirmed; traceability back to a dictation arrives in Fase 4 as
# voice_dictation_id.
#
# inspection_item / nch2840_box / norm_point / severity exist from day one to
# avoid a second migration, but only a human ever fills them (fixed rule 1) and
# their UI surface is gated (section 2.2, gap 1).
#
# The field_photo foreign key is restrictive on purpose: it is the backstop of
# the evidence retention policy (fixed rule 10) — if FieldPhotoRetentionJob ever
# reaches a referenced photo, the DELETE aborts before the S3 bytes are gone.
class CreateInspectionFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :inspection_findings do |t|
      t.references :certification_report, null: false, foreign_key: true, index: false
      t.references :account, null: false, foreign_key: true
      t.text    :body, null: false
      t.string  :location
      t.references :field_photo, foreign_key: true
      t.integer :position, null: false, default: 0
      t.integer :inspection_item
      t.string  :nch2840_box
      t.string  :norm_point
      t.string  :severity
      t.timestamps
    end

    # Covers both "findings of this report" and their manual display order.
    add_index :inspection_findings,
              [ :certification_report_id, :position ],
              name: "idx_inspection_findings_report_position"
  end
end
