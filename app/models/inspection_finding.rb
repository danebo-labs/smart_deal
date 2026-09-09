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

  belongs_to :account
  belongs_to :certification_report
  belongs_to :field_photo, optional: true
  # Traceability back to the dictation this text came from (Fase 4). Optional:
  # a typed finding has no dictation. The unique index on the column is the
  # second guarantee that confirming a dictation twice yields one finding.
  belongs_to :voice_dictation, optional: true

  enum :severity, SEVERITIES, prefix: true

  before_validation :inherit_account_from_report

  validates :body, presence: true
  validate :account_matches_report
  validate :photo_belongs_to_same_account

  # Photos referenced here are report evidence, not cache: they are exempt from
  # FieldPhotoRetentionJob (fixed rule 10).
  scope :with_photo, -> { where.not(field_photo_id: nil) }

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
end
