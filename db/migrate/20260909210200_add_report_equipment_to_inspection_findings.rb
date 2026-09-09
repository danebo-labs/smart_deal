# frozen_string_literal: true

# Which elevator a finding belongs to. Nullable and never assigned
# automatically: a finding dictated before any equipment exists stays
# unassigned and is displayed in an explicit "pendientes de asignar" group
# rather than being attached to the first equipment.
#
# The foreign key is restrictive on purpose (no cascade, no nullify): deleting
# an equipment that still has findings must fail so the certifier reassigns
# them deliberately. Losing findings — the confirmed text of an inspection —
# as a side effect of tidying up equipment is never acceptable.
class AddReportEquipmentToInspectionFindings < ActiveRecord::Migration[8.1]
  def change
    add_reference :inspection_findings, :report_equipment,
                  foreign_key: true,
                  index: { name: "idx_inspection_findings_report_equipment" }
  end
end
