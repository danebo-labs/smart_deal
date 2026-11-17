# frozen_string_literal: true

# One submission on a field case, from admission through its single
# definitive result. A later attempt does not replace the winner.
class FieldTurn < ApplicationRecord
  STATUSES = %w[pending completed failed historical_partial].freeze
  KINDS = %w[text photo].freeze
  PHASES = %w[queued interpreting vision technical published failed imported].freeze
  TERMINAL_STATUSES = %w[completed failed historical_partial].freeze

  belongs_to :field_case
  belongs_to :field_photo, optional: true

  validates :sequence, numericality: { only_integer: true, greater_than: 0 }
  validates :attempt, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }
  validates :phase, inclusion: { in: PHASES }
  validates :client_submission_id, :input_digest, :correlation_id, :execution_token, :admitted_at, presence: true
  validate :result_shape
  validate :photo_belongs_to_case_account

  private

  def result_shape
    errors.add(:attachment, :invalid) unless attachment.is_a?(Hash)
    errors.add(:response, :invalid) if response.present? && !response.is_a?(Hash)
    errors.add(:checkpoint, :invalid) if checkpoint.present? && !checkpoint.is_a?(Hash)

    if status == "pending"
      errors.add(:response, :invalid) if response.present?
      errors.add(:completed_at, :invalid) if completed_at.present?
      errors.add(:failure_code, :invalid) if failure_code.present?
    elsif TERMINAL_STATUSES.include?(status)
      errors.add(:completed_at, :blank) if completed_at.blank?
    end

    if status == "completed"
      text = response.is_a?(Hash) ? response["published_text"] : nil
      errors.add(:response, :invalid) if text.blank?
    end
    errors.add(:failure_code, :blank) if status == "failed" && failure_code.blank?
  end

  def photo_belongs_to_case_account
    return if field_photo_id.blank?
    return if field_photo && field_case && field_photo.account_id == field_case.account_id

    errors.add(:field_photo, :invalid)
  end
end
