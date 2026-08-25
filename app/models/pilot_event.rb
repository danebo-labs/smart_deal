# frozen_string_literal: true

# Append-only pilot telemetry. Written with insert! (no callbacks, no
# validations, no broadcasts). Duplicates are tolerated — there is no unique
# key because (event, correlation_id, occurred_at) collides for legitimate
# same-second siblings sharing a correlation_id. Readers dedup when merging
# with the log.
class PilotEvent < ApplicationRecord
  RAG_QUALITY_EVENT = "rag_quality"

  scope :occurred_within, ->(range) { where(occurred_at: range) }

  def self.hot_path_rows(range:, user_ids: [])
    scope = occurred_within(range)
    scope = scope.where(user_id: user_ids) if user_ids.any?
    scope.order(:occurred_at).pluck(
      :event, :correlation_id, :account_id, :user_id,
      :conversation_session_id, :occurred_at, :payload
    )
  end
end
