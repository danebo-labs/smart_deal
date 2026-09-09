# frozen_string_literal: true

class Account < ApplicationRecord
  has_many :users, dependent: :restrict_with_error
  has_many :kb_documents, dependent: :restrict_with_error
  has_many :conversation_sessions, dependent: :restrict_with_error
  has_many :web_manual_batches, dependent: :restrict_with_error
  has_many :technician_documents, dependent: :restrict_with_error
  # Declared before field_photos on purpose: a report's evidence photos are
  # protected by a restrictive FK from inspection_findings, so this guard must
  # abort the destroy before the photo cascade below hits that FK.
  has_many :certification_reports, dependent: :restrict_with_error
  # Same reason, and equipments are also protected by a restrictive FK from
  # inspection_findings.
  has_many :report_equipments, dependent: :restrict_with_error
  # A dictation can outlive its report or have never had one, so the report
  # guard above does not cover every row. Same reason it sits before
  # field_photos.
  has_many :voice_dictations, dependent: :restrict_with_error
  # Operational data with a TTL, not knowledge that should block account deletion.
  has_many :field_photos, dependent: :destroy

  # The single user allowed to edit this company's issuer identity (Fase 1A).
  # Nullable: with nobody assigned the configuration is read-only for everyone
  # rather than claimable by whoever opens it first.
  belongs_to :certifier_settings_user, class_name: "User", optional: true

  validates :slug, presence: true, uniqueness: true
  validates :display_name, presence: true
  validate :certifier_settings_user_belongs_to_account

  before_validation :default_display_name

  # A company is an account, so the issuer header is shared by every report of
  # the account — but reports themselves are not shared between its users
  # (fixed rule 12).
  def certifier_identified?
    certifier_name.present? && certifier_minvu_role.present?
  end

  def certifier_logo?
    certifier_logo_s3_key.present?
  end

  # Only the designated owner writes the shared configuration. Everyone else in
  # the company reads it and uses it in their own reports.
  def certifier_settings_manager?(user)
    return false if user.nil? || certifier_settings_user_id.blank?

    certifier_settings_user_id == user.id
  end

  private

  def certifier_settings_user_belongs_to_account
    return if certifier_settings_user_id.blank?
    return if certifier_settings_user&.account_id == id

    errors.add(:certifier_settings_user, "must belong to this account")
  end

  # Mirrors the migration backfill: accounts created without an explicit
  # display_name (console, ops scripts, older tests) fall back to their slug
  # instead of failing validation.
  def default_display_name
    self.display_name = slug if display_name.blank?
  end
end
