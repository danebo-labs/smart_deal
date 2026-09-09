# frozen_string_literal: true

# Traceability from a confirmed finding back to the dictation it came from,
# and the second, independent guarantee that confirming twice cannot produce
# two findings (fixed rule 13).
#
# The index is unique but the column is nullable, and PostgreSQL treats NULLs
# as distinct in a unique index by default — so any number of typed findings
# (Fase 2, no dictation at all) coexist, while a given dictation can back at
# most one finding. Deliberately NOT nulls_not_distinct, unlike the dedup index
# on voice_dictations: here the default NULL behaviour is exactly what is
# wanted.
#
# Fase 7, if it is ever activated, relaxes this to [voice_dictation_id,
# segment_index] so one long dictation can yield several findings without
# losing the idempotency of confirmation.
class AddVoiceDictationToInspectionFindings < ActiveRecord::Migration[8.1]
  def change
    add_reference :inspection_findings, :voice_dictation,
                  foreign_key: true,
                  index: { unique: true, name: "idx_inspection_findings_voice_dictation" }
  end
end
