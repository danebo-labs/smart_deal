# frozen_string_literal: true

class Account < ApplicationRecord
  has_many :users, dependent: :restrict_with_error
  has_many :kb_documents, dependent: :restrict_with_error
  has_many :conversation_sessions, dependent: :restrict_with_error
  has_many :web_manual_batches, dependent: :restrict_with_error
  has_many :technician_documents, dependent: :restrict_with_error

  validates :slug, presence: true, uniqueness: true
  validates :display_name, presence: true

  before_validation :default_display_name

  private

  # Mirrors the migration backfill: accounts created without an explicit
  # display_name (console, ops scripts, older tests) fall back to their slug
  # instead of failing validation.
  def default_display_name
    self.display_name = slug if display_name.blank?
  end
end
