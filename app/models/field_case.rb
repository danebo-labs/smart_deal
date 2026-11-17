# frozen_string_literal: true

# One technician case inside an account. The id is the durable handle.
# episode_id stays stable when the web session expires or another case is open.
# document_focus belongs to this case and starts empty.
class FieldCase < ApplicationRecord
  MODES = %w[resumable read_only].freeze
  SCHEMA_VERSION = 1

  belongs_to :account
  belongs_to :user
  has_many :field_turns, dependent: :destroy, inverse_of: :field_case

  validates :episode_id, :mode, :opened_at, :last_activity_at, presence: true
  validates :mode, inclusion: { in: MODES }
  validates :schema_version, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :state_revision, :last_sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :owner_belongs_to_account
  validate :state_shape

  def resumable?
    mode == "resumable"
  end

  def self.generate_episode_id
    "ep_#{SecureRandom.hex(8)}"
  end

  private

  def owner_belongs_to_account
    return if user.nil? || account_id.nil?
    return if user.account_id == account_id

    errors.add(:user, :invalid)
  end

  def state_shape
    errors.add(:document_focus, :invalid) unless document_focus.is_a?(Array)
    errors.add(:technical_state, :invalid) unless technical_state.is_a?(Hash)
  end
end
