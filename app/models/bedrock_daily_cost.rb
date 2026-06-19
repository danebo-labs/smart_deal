# frozen_string_literal: true

# Authoritative per-UTC-day, per-model Bedrock spend, populated from S3 Model
# Invocation Logs (exact billed tokens) by ReconcileBedrockCostJob. This is
# invoice truth — distinct from the estimated BedrockQuery rows (retrieve_and_
# generate returns no usage block). One row per [utc_date, model_id]; a re-run
# for a day fully replaces that day's rows (idempotent).
class BedrockDailyCost < ApplicationRecord
  validates :utc_date, :model_id, :reconciled_at, presence: true
  validates :model_id, uniqueness: { scope: :utc_date }

  scope :for_utc_day, ->(date) { where(utc_date: date) }

  def self.total_cost(date)
    for_utc_day(date).sum(:cost_usd)
  end

  # Truth (logs) vs the live estimate (BedrockQuery rows) for one UTC day.
  # NOTE: the delta reflects BOTH the estimator's input undercount AND any
  # Bedrock invocations the app never tracked (page-filter, alias-extraction,
  # embeds). It is a drift signal, not a pure tokenizer-error measure.
  def self.truth_vs_estimate(date)
    truth    = total_cost(date).to_f
    estimate = BedrockQuery.aws_reconciliation(date)[:total_cost].to_f
    delta    = (truth - estimate).round(6)
    pct      = truth.zero? ? 0.0 : (delta / truth * 100).round(2)
    { date: date, truth: truth.round(6), estimate: estimate.round(6),
      delta: delta, est_drift_pct: pct }
  end
end
