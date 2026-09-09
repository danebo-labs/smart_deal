# frozen_string_literal: true

# Fields the certifier fills in while reviewing a draft, all optional.
#
# `result` is the one that matters most: it is nullable, starts empty, and is
# only ever written by a human choosing "aprobado" or "rechazado". Danebo does
# not compute it from the registered defects and does not infer it from
# anything (fixed rule 1). It is deliberately a separate column from `status`,
# which tracks the draft's own lifecycle and must never carry a verdict.
#
# `normative_reference` is free text typed by the certifier. Automatic
# derivation from a reception date stays deferred (section 3.3) until the
# official source and date criterion are verified.
class AddReviewFieldsToCertificationReports < ActiveRecord::Migration[8.1]
  def change
    change_table :certification_reports, bulk: true do |t|
      t.string :inspector_name
      t.date   :report_date
      t.string :normative_reference
      t.string :result
      t.text   :result_note
    end
  end
end
