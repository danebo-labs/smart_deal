# frozen_string_literal: true

# One elevator inside a report draft (Fase 1A).
#
# `label` is the visible identifier the certifier uses ("Ascensor A"); every
# technical characteristic is optional and stays exactly as typed. Danebo never
# derives a spec, never fills a blank one, and never assigns a finding to an
# equipment on its own.
#
# `account_id` is denormalized from the report and validated to match, the same
# pattern InspectionFinding uses (fixed rule 8): tenant-scoped reads need no
# join and the two values cannot drift apart.
class ReportEquipment < ApplicationRecord
  # Bounded to the characteristics the real report of section 3.1 records. The
  # certifier picks one of these or leaves it blank — no third option is
  # inferred, and a blank one is never presented as a value.
  MACHINE_ROOMS = %w[con_sala sin_sala].freeze
  DRIVE_TYPES   = %w[hidraulico electromecanico].freeze

  belongs_to :account
  belongs_to :certification_report

  # Restrictive on purpose, matching the foreign key: deleting an equipment that
  # still carries findings must fail so the certifier reassigns them by hand.
  # Confirmed findings are never collateral damage of tidying up equipment.
  has_many :inspection_findings, dependent: :restrict_with_error

  before_validation :inherit_account_from_report

  validates :label, presence: true
  validates :machine_room, inclusion: { in: MACHINE_ROOMS }, allow_blank: true
  validates :drive_type, inclusion: { in: DRIVE_TYPES }, allow_blank: true
  validate :account_matches_report

  scope :ordered, -> { order(:position, :id) }

  private

  def inherit_account_from_report
    self.account_id ||= certification_report&.account_id
  end

  def account_matches_report
    return if account_id.blank? || certification_report.nil?
    return if account_id == certification_report.account_id

    errors.add(:account_id, "must match the certification report's account")
  end
end
