# frozen_string_literal: true

class Account < ApplicationRecord
  has_many :users, dependent: :restrict_with_error
  has_many :kb_documents, dependent: :restrict_with_error
  has_many :conversation_sessions, dependent: :restrict_with_error
  has_many :web_manual_batches, dependent: :restrict_with_error
  has_many :technician_documents, dependent: :restrict_with_error

  validates :slug, presence: true, uniqueness: true
end
