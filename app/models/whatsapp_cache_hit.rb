# frozen_string_literal: true

class WhatsappCacheHit < ApplicationRecord
  validates :recipient, :route, presence: true

  VALID_ROUTES = %w[section_hit show_doc_list reset_ack_with_picker no_context_help].freeze
  validates :route, inclusion: { in: VALID_ROUTES }

  scope :today,    -> { where(created_at: Date.current.all_day) }
  scope :by_route, -> { group(:route).count }
end
