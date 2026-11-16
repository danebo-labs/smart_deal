# frozen_string_literal: true

# Durable copy of one Field Companion observation. Written with insert paths
# that rescue their own errors. isolate_web_trial does not delete these rows.
class FieldCompanionTrace < ApplicationRecord
  MESSAGE_KINDS = %w[user_message assistant_message visual_card].freeze
  KINDS = (MESSAGE_KINDS + %w[failure terminal capture presentation click]).freeze
  PROVENANCES = %w[observed recovered reconstructed uncaptured].freeze

  scope :occurred_within, ->(range) { where(occurred_at: range) }
end
