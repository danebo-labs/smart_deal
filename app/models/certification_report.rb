# frozen_string_literal: true

# Persistent draft of a certification report (Fase 0 of
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md).
#
# Danebo never evaluates compliance: it stores what the certifier dictated and
# confirmed, and offers the fields the certifier fills in (fixed rule 1). There
# is deliberately no "aprobado"/"rechazado" state — `status` tracks the draft's
# own lifecycle, not an inspection verdict.
#
# Ownership is double: account scoping by host AND property by user (fixed
# rule 12). Reports are not shared inside an account at this stage.
class CertificationReport < ApplicationRecord
  STATUSES = {
    en_progreso:    "en_progreso",
    listo_revision: "listo_revision",
    enviado:        "enviado"
  }.freeze

  belongs_to :account
  belongs_to :user

  has_many :inspection_findings,
           -> { order(:position, :id) },
           dependent: :destroy,
           inverse_of: :certification_report

  # Declared after inspection_findings, and the order is load-bearing: a
  # dictation refuses to be destroyed while a finding still points at it, so
  # the findings must be destroyed first. Destroying a dictation also deletes
  # its audio from S3, which is why deleting a draft does not leave paid-for
  # bytes behind.
  has_many :voice_dictations, dependent: :destroy, inverse_of: :certification_report

  enum :status, STATUSES, default: :en_progreso

  validates :building_name, presence: true

  # The "mis informes" list of Fase 2: both isolation axes in one scope.
  scope :owned_by, ->(account_id:, user_id:) { where(account_id: account_id, user_id: user_id) }
  scope :recent_first, -> { order(created_at: :desc) }
end
