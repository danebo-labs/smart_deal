# frozen_string_literal: true

# One confirmed finding of a certification report draft.
#
# `severity` is nullable and Danebo never writes it: leve/grave is the
# certifier's classification (fixed rule 1). Same for nch2840_box, norm_point
# and inspection_item — the columns exist so no second migration is needed, but
# their UI surface waits for the 2-oct gate (section 2.2, gap 1).
#
# `account_id` is denormalized from the report to honour fixed rule 8 (every new
# model carries account_id and follows host scoping) without a join on every
# tenant-scoped read.
class InspectionFinding < ApplicationRecord
  SEVERITIES = { leve: "leve", grave: "grave" }.freeze

  # The 8 CENTRAVE items of the hybrid structure decided in section 3.3.
  # Grouping by them is optional: findings without an item are kept in an
  # explicit group, and the absence of a classification never means "sin
  # defectos". Stored as the integer already present in inspection_item.
  CENTRAVE_ITEMS = {
    1 => :carpeta_ascensores,
    2 => :cabina,
    3 => :espacio_maquinas,
    4 => :contrapeso,
    5 => :caja_elevadores,
    6 => :pozo,
    7 => :puertas_cerraduras,
    8 => :suspension_cables
  }.freeze

  belongs_to :account
  belongs_to :certification_report
  belongs_to :field_photo, optional: true
  # Which elevator of the report this finding is about. Optional and never
  # assigned automatically — an unassigned finding is shown as such.
  belongs_to :report_equipment, optional: true
  # Traceability back to the dictation this text came from (Fase 4). Optional:
  # a typed finding has no dictation. The unique index on the column is the
  # second guarantee that confirming a dictation twice yields one finding.
  belongs_to :voice_dictation, optional: true

  enum :severity, SEVERITIES, prefix: true

  before_validation :inherit_account_from_report

  validates :body, presence: true
  validates :inspection_item, inclusion: { in: CENTRAVE_ITEMS.keys }, allow_nil: true
  validate :account_matches_report
  validate :photo_belongs_to_same_account
  validate :equipment_belongs_to_same_report

  # Photos referenced here are report evidence, not cache: they are exempt from
  # FieldPhotoRetentionJob (fixed rule 10).
  scope :with_photo, -> { where.not(field_photo_id: nil) }
  scope :unassigned_equipment, -> { where(report_equipment_id: nil) }

  def centrave_item_key
    CENTRAVE_ITEMS[inspection_item]
  end

  private

  def inherit_account_from_report
    self.account_id ||= certification_report&.account_id
  end

  def account_matches_report
    return if account_id.blank? || certification_report.nil?
    return if account_id == certification_report.account_id

    errors.add(:account_id, "must match the certification report's account")
  end

  # Evidence never crosses tenants: a photo from another account must not be
  # attachable even if an id leaks into params.
  def photo_belongs_to_same_account
    return if field_photo_id.blank? || account_id.blank?
    return if field_photo&.account_id == account_id

    errors.add(:field_photo, "must belong to the same account as the report")
  end

  # Same report, not merely the same tenant: an equipment id belonging to
  # another draft of the same company must not be attachable either.
  def equipment_belongs_to_same_report
    return if report_equipment_id.blank?
    return if report_equipment&.certification_report_id == certification_report_id &&
              report_equipment.account_id == account_id

    errors.add(:report_equipment, "must belong to the same report")
  end
end
