# frozen_string_literal: true

module CertificationReportsHelper
  STATUS_BADGE_CLASSES = {
    "en_progreso"    => "bg-[hsl(48,96%,89%)] text-[hsl(32,81%,29%)]",
    "listo_revision" => "bg-[hsl(217,91%,93%)] text-[hsl(217,91%,35%)]",
    "enviado"        => "bg-[hsl(142,71%,90%)] text-[hsl(142,71%,29%)]"
  }.freeze

  def certifier_status_badge_class(status)
    STATUS_BADGE_CLASSES.fetch(status.to_s, "bg-[hsl(215,20%,93%)] text-[hsl(215,20%,42%)]")
  end

  # "1:07" — the same m:ss the recording indicator counts in, so the card a
  # certifier sees after reopening matches what they saw while recording.
  def certifier_audio_duration(seconds)
    total = seconds.to_i
    format("%d:%02d", total / 60, total % 60)
  end

  # Only the technical characteristics the certifier actually typed. A blank
  # spec is omitted, never rendered as a dash, a zero or a guessed default: an
  # empty field means nobody recorded that value (fixed rule 1).
  def certifier_equipment_specs(equipment)
    specs = []
    specs << t("certifier.equipment.machine_rooms.#{equipment.machine_room}") if equipment.machine_room.present?
    specs << t("certifier.equipment.drive_types.#{equipment.drive_type}") if equipment.drive_type.present?
    specs << equipment.door_type if equipment.door_type.present?
    specs << t("certifier.equipment.specs.landings", count: equipment.landings_count) if equipment.landings_count.present?
    specs << t("certifier.equipment.specs.boardings", count: equipment.boardings_count) if equipment.boardings_count.present?
    specs << t("certifier.equipment.specs.speed", value: equipment.speed_mps) if equipment.speed_mps.present?
    specs << t("certifier.equipment.specs.load", value: equipment.rated_load_kg) if equipment.rated_load_kg.present?
    specs << t("certifier.equipment.specs.capacity", count: equipment.capacity_persons) if equipment.capacity_persons.present?
    specs << equipment.traction_cables if equipment.traction_cables.present?
    specs << t("certifier.equipment.specs.last_maintenance", date: l(equipment.last_maintenance_date, format: :certifier_short)) if equipment.last_maintenance_date.present?
    specs
  end

  # The label a finding carries for its elevator, or the explicit "not assigned"
  # marker — the absence of an assignment is shown, never hidden.
  def certifier_finding_equipment_label(finding)
    finding.report_equipment&.label || t("certifier.equipment.unassigned")
  end
end
